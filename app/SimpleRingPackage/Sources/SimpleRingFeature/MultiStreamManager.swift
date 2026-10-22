import Foundation
import RingClient
@preconcurrency import WebRTC

/// Manages simultaneous WebRTC streams for all cameras.
///
/// Every camera starts video-only (`AudioMode.off`) so no audio device is
/// used until you ask for it; turning on listening or talking reconnects the
/// active camera with audio.
@MainActor
public final class MultiStreamManager: ObservableObject {
    public typealias AudioMode = LiveViewSession.AudioMode

    public struct StreamInfo {
        public var session: LiveViewSession?
        public var audioMode: AudioMode = .off
        public var videoTrack: RTCVideoTrack?
        public var state: LiveViewSession.State = .connecting
        public var error: String?
        /// Identifies the current connection attempt, so a superseded attempt
        /// (window closed, camera retried, audio mode changed) stops itself.
        fileprivate var attempt = UUID()
        fileprivate var startTalkingWhenReady = false
    }

    @Published public private(set) var streams: [Int: StreamInfo] = [:]
    @Published public private(set) var activeDeviceId: Int?
    @Published public private(set) var isTalking = false
    /// Width / height of each camera's video, learned from its frames
    @Published public private(set) var videoAspects: [Int: CGFloat] = [:]

    private var devices: [Int: RingDevice] = [:]

    public init() {}

    public var activeAudioMode: AudioMode {
        activeDeviceId.flatMap { streams[$0]?.audioMode } ?? .off
    }

    // MARK: - Starting and stopping

    /// Start video-only streams for all provided devices
    public func startAllStreams(for devices: [RingDevice]) async {
        self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        isTalking = false
        streams = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, StreamInfo()) })
        await withTaskGroup(of: Void.self) { group in
            for device in devices {
                group.addTask { await self.connect(device) }
            }
        }
    }

    /// Stop all streams
    public func stopAllStreams() async {
        isTalking = false
        let sessions = streams.values.compactMap(\.session)
        streams.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.stop() }
            }
        }
    }

    /// Retry a camera, or reconnect it with a different audio mode
    public func restartStream(for device: RingDevice, audioMode: AudioMode? = nil, talkWhenReady: Bool = false) async {
        let old = streams[device.id]
        var info = StreamInfo()
        info.audioMode = audioMode ?? old?.audioMode ?? .off
        info.startTalkingWhenReady = talkWhenReady
        streams[device.id] = info
        await old?.session?.stop()
        await connect(device)
    }

    private func connect(_ device: RingDevice) async {
        let id = device.id
        guard let info = streams[id] else { return }
        let attempt = info.attempt
        var mode = info.audioMode

        do {
            let session: LiveViewSession
            do {
                session = try await startSession(for: id, mode: mode, attempt: attempt)
            } catch where mode == .off && !(error is CancellationError) {
                // Last resort: connect with Ring's answer untouched (two-way
                // audio), which is known to work, rather than not at all.
                ringLog.notice("⚠️ Video-only session failed (\(error.localizedDescription, privacy: .public)); retrying with audio")
                guard streams[id]?.attempt == attempt else { return }
                mode = .talk
                streams[id]?.audioMode = .talk
                streams[id]?.state = .connecting
                session = try await startSession(for: id, mode: mode, attempt: attempt)
            }

            // Superseded while connecting (window closed, retried, mode changed)
            guard streams[id]?.attempt == attempt else {
                await session.stop()
                return
            }

            if streams[id]?.startTalkingWhenReady == true {
                streams[id]?.startTalkingWhenReady = false
                await session.startTalking()
                if id == activeDeviceId { isTalking = true }
            }
        } catch is CancellationError {
            return
        } catch {
            guard streams[id]?.attempt == attempt else { return }
            ringLog.error("❌ Failed to start stream for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            streams[id]?.state = .failed(error.localizedDescription)
            streams[id]?.error = error.localizedDescription
        }
    }

    private func startSession(for id: Int, mode: AudioMode, attempt: UUID) async throws -> LiveViewSession {
        let session = try await RingClient.shared.startLiveView(deviceId: id, audioMode: mode)
        guard streams[id]?.attempt == attempt else { throw CancellationError() }
        streams[id]?.session = session

        await session.setCallbacks(
            onStateChange: { [weak self, weak session] state in
                Task { @MainActor in
                    guard let self, let session, self.streams[id]?.session === session else { return }
                    self.streams[id]?.state = state
                    if case .failed(let message) = state {
                        self.streams[id]?.error = message
                    }
                }
            },
            onVideoTrack: { [weak self, weak session] track in
                Task { @MainActor in
                    guard let self, let session, self.streams[id]?.session === session else { return }
                    self.streams[id]?.videoTrack = track
                }
            },
            onAudioTrack: { track in
                track.isEnabled = true
            }
        )

        do {
            try await session.start()
        } catch {
            await session.stop()
            throw error
        }
        return session
    }

    // MARK: - Accessors

    public func getVideoTrack(for deviceId: Int) -> RTCVideoTrack? {
        streams[deviceId]?.videoTrack
    }

    public func getState(for deviceId: Int) -> LiveViewSession.State {
        streams[deviceId]?.state ?? .idle
    }

    public func getError(for deviceId: Int) -> String? {
        streams[deviceId]?.error
    }

    public func setVideoAspect(_ aspect: CGFloat, for deviceId: Int) {
        guard aspect.isFinite, aspect > 0 else { return }
        if let current = videoAspects[deviceId], abs(current - aspect) < 0.01 { return }
        videoAspects[deviceId] = aspect
    }

    // MARK: - Audio

    /// The camera being viewed. Switching away turns the previous camera's audio off.
    public func setActiveDevice(_ deviceId: Int) {
        guard activeDeviceId != deviceId else { return }
        if let previous = activeDeviceId,
           streams[previous]?.audioMode != .off,
           let device = devices[previous] {
            Task { await restartStream(for: device, audioMode: .off) }
        }
        isTalking = false
        activeDeviceId = deviceId
    }

    /// Turn listening to the active camera on or off
    public func setListening(_ listening: Bool) async {
        guard let id = activeDeviceId, let device = devices[id] else { return }
        let target: AudioMode = listening ? .listen : .off
        guard streams[id]?.audioMode != target else { return }
        isTalking = false
        await restartStream(for: device, audioMode: target)
    }

    /// Start or stop talking through the active camera. The first time, the
    /// camera reconnects with a microphone and talking starts once connected.
    public func toggleTalking() async {
        guard let id = activeDeviceId, let device = devices[id], let info = streams[id] else { return }
        if isTalking {
            await info.session?.stopTalking()
            isTalking = false
        } else if info.audioMode == .talk, let session = info.session {
            await session.startTalking()
            isTalking = true
        } else {
            await restartStream(for: device, audioMode: .talk, talkWhenReady: true)
        }
    }
}
