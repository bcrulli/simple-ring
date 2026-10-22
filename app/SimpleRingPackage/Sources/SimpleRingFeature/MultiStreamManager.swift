import Foundation
import RingClient
@preconcurrency import WebRTC

/// Manages simultaneous WebRTC streams for all cameras.
///
/// Streams receive audio only, so the Mac microphone is never in use while
/// viewing; the speaker button mutes/unmutes instantly. Talking reconnects the
/// viewed camera with two-way audio, and hanging up reconnects it receive-only,
/// so the macOS mic indicator shows exactly while you're talking.
@MainActor
public final class MultiStreamManager: ObservableObject {

    public struct StreamInfo {
        public var session: LiveViewSession?
        public var videoTrack: RTCVideoTrack?
        public var audioTrack: RTCAudioTrack?
        public var state: LiveViewSession.State = .connecting
        public var error: String?
        /// Whether this camera's session sends your voice (mic in use)
        public var canTalk = false
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

    private var devices: [Int: RingDevice] = [:]

    public init() {}

    // MARK: - Starting and stopping

    /// Start streams for all provided devices
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

    /// Retry a camera, or reconnect it with or without talking
    public func restartStream(for device: RingDevice, canTalk: Bool = false) async {
        let old = streams[device.id]
        var info = StreamInfo()
        info.canTalk = canTalk
        // Keep showing the last frame while reconnecting instead of a placeholder
        info.videoTrack = old?.videoTrack
        if old?.videoTrack != nil { info.state = old?.state ?? .connecting }
        streams[device.id] = info
        await old?.session?.stop()
        await connect(device)
    }

    private func connect(_ device: RingDevice) async {
        let id = device.id
        guard let attempt = streams[id]?.attempt, let canTalk = streams[id]?.canTalk else { return }
        do {
            let session = try await RingClient.shared.startLiveView(deviceId: id, canTalk: canTalk)
            guard streams[id]?.attempt == attempt else { return }
            streams[id]?.session = session

            await session.setCallbacks(
                onStateChange: { [weak self, weak session] state in
                    Task { @MainActor in
                        guard let self, let session, self.streams[id]?.session === session else { return }
                        self.streams[id]?.state = state
                        if case .failed(let message) = state {
                            self.streams[id]?.error = message
                            self.streams[id]?.videoTrack = nil  // show the error, not a frozen frame
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
            streams[id]?.videoTrack = nil  // show the error, not a frozen frame
            if id == activeDeviceId { isTalking = false }
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

    /// The camera being viewed: only its sound plays. Switching away while
    /// talking hangs up (reconnects that camera receive-only).
    public func setActiveDevice(_ deviceId: Int) {
        guard activeDeviceId != deviceId else { return }
        if let previous = activeDeviceId, streams[previous]?.canTalk == true, let device = devices[previous] {
            Task { await restartStream(for: device, canTalk: false) }
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

    /// Start talking (reconnects the viewed camera with the microphone) or hang
    /// up (reconnects it receive-only, which releases the microphone).
    public func toggleTalking() async {
        guard let id = activeDeviceId, let device = devices[id] else { return }
        let talk = !isTalking
        isTalking = talk
        if talk && !isSoundOn { setSoundOn(true) }  // hear who you're talking to
        await restartStream(for: device, canTalk: talk)
    }
}
