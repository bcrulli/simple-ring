import Foundation
import RingClient
@preconcurrency import WebRTC

/// Manages simultaneous WebRTC streams for all cameras.
///
/// Each stream negotiates two-way audio once, so the speaker and mic buttons
/// act instantly: sound is muted by default and only the viewed camera's sound
/// plays; the microphone is only attached (and opened) while talking.
@MainActor
public final class MultiStreamManager: ObservableObject {

    public struct StreamInfo {
        public var session: LiveViewSession?
        public var videoTrack: RTCVideoTrack?
        public var audioTrack: RTCAudioTrack?
        public var state: LiveViewSession.State = .connecting
        public var error: String?
        /// Identifies the current connection attempt, so a superseded attempt
        /// (window closed, camera retried) stops itself.
        fileprivate var attempt = UUID()
    }

    @Published public private(set) var streams: [Int: StreamInfo] = [:]
    @Published public private(set) var activeDeviceId: Int?
    @Published public private(set) var isSoundOn = false
    @Published public private(set) var isTalking = false
    /// Width / height of each camera's video, learned from its frames
    @Published public private(set) var videoAspects: [Int: CGFloat] = [:]

    public init() {}

    // MARK: - Starting and stopping

    /// Start streams for all provided devices
    public func startAllStreams(for devices: [RingDevice]) async {
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

    /// Retry a camera after it failed to connect
    public func restartStream(for device: RingDevice) async {
        let old = streams[device.id]?.session
        if device.id == activeDeviceId { isTalking = false }
        streams[device.id] = StreamInfo()
        await old?.stop()
        await connect(device)
    }

    private func connect(_ device: RingDevice) async {
        let id = device.id
        guard let attempt = streams[id]?.attempt else { return }
        do {
            let session = try await RingClient.shared.startLiveView(deviceId: id)
            guard streams[id]?.attempt == attempt else { return }
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
                onAudioTrack: { [weak self, weak session] track in
                    Task { @MainActor in
                        guard let self, let session, self.streams[id]?.session === session else { return }
                        track.isEnabled = self.isSoundOn && id == self.activeDeviceId
                        self.streams[id]?.audioTrack = track
                    }
                }
            )

            try await session.start()

            // Superseded while connecting (window closed or camera retried)
            if streams[id]?.attempt != attempt {
                await session.stop()
            }
        } catch {
            guard streams[id]?.attempt == attempt else { return }
            ringLog.error("❌ Failed to start stream for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            streams[id]?.state = .failed(error.localizedDescription)
            streams[id]?.error = error.localizedDescription
        }
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

    /// The camera being viewed: only its sound plays, and switching away stops talking.
    public func setActiveDevice(_ deviceId: Int) {
        guard activeDeviceId != deviceId else { return }
        if isTalking, let previous = activeDeviceId, let session = streams[previous]?.session {
            Task { await session.stopTalking() }
        }
        isTalking = false
        activeDeviceId = deviceId
        applySound()
    }

    /// Turn the camera's sound on or off (instant, no reconnect)
    public func setSoundOn(_ on: Bool) {
        isSoundOn = on
        applySound()
    }

    private func applySound() {
        for (id, info) in streams {
            info.audioTrack?.isEnabled = isSoundOn && id == activeDeviceId
        }
    }

    /// Start or stop talking through the viewed camera (instant, no reconnect).
    /// The microphone is only open while talking.
    public func toggleTalking() async {
        guard let id = activeDeviceId, let session = streams[id]?.session else { return }
        if isTalking {
            isTalking = false
            await session.stopTalking()
        } else {
            isTalking = true
            await session.startTalking()
            // Talking to someone you can't hear isn't useful
            if !isSoundOn { setSoundOn(true) }
        }
    }
}
