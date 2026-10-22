import Foundation
import RingClient
@preconcurrency import WebRTC

/// Manages simultaneous WebRTC streams for all cameras
@MainActor
public final class MultiStreamManager: ObservableObject {

    public struct StreamInfo {
        public var session: LiveViewSession?
        public var videoTrack: RTCVideoTrack?
        public var audioTrack: RTCAudioTrack?
        public var state: LiveViewSession.State = .idle
        public var error: String?
    }

    @Published public private(set) var streams: [Int: StreamInfo] = [:]
    @Published public private(set) var isConnecting = false
    @Published public private(set) var activeDeviceId: Int?  // Audio plays from this device only
    @Published public private(set) var isMuted = false

    /// Bumped on every start/stop so a session that finishes connecting after
    /// the window closed is stopped instead of streaming in the background.
    private var generation = 0

    public init() {}

    /// Start streams for all provided devices
    public func startAllStreams(for devices: [RingDevice]) async {
        generation += 1
        let currentGeneration = generation
        isConnecting = true
        streams = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, StreamInfo(state: .connecting)) })

        await withTaskGroup(of: Void.self) { group in
            for device in devices {
                group.addTask { await self.startStream(for: device, generation: currentGeneration) }
            }
        }

        if generation == currentGeneration {
            isConnecting = false
        }
    }

    private func startStream(for device: RingDevice, generation startedIn: Int) async {
        let id = device.id
        do {
            let session = try await RingClient.shared.startLiveView(deviceId: id)
            guard generation == startedIn else { return }
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
                        track.isEnabled = self.activeDeviceId == id && !self.isMuted
                        self.streams[id]?.audioTrack = track
                    }
                }
            )

            try await session.start()

            // The window may have closed, or the camera been retried, while connecting
            if generation != startedIn || streams[id]?.session !== session {
                await session.stop()
            }
        } catch {
            guard generation == startedIn else { return }
            NSLog("❌ Failed to start stream for \(device.name): \(error.localizedDescription)")
            streams[id]?.state = .failed(error.localizedDescription)
            streams[id]?.error = error.localizedDescription
        }
    }

    /// Retry a single camera (e.g. after it failed to connect)
    public func restartStream(for device: RingDevice) async {
        let oldSession = streams[device.id]?.session
        streams[device.id] = StreamInfo(state: .connecting)
        await oldSession?.stop()
        await startStream(for: device, generation: generation)
    }

    /// Stop all streams
    public func stopAllStreams() async {
        generation += 1
        isConnecting = false
        let sessions = streams.values.compactMap(\.session)
        streams.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.stop() }
            }
        }
    }

    public func getVideoTrack(for deviceId: Int) -> RTCVideoTrack? {
        streams[deviceId]?.videoTrack
    }

    public func getState(for deviceId: Int) -> LiveViewSession.State {
        streams[deviceId]?.state ?? .idle
    }

    public func getError(for deviceId: Int) -> String? {
        streams[deviceId]?.error
    }

    // MARK: - Audio

    /// Only the active device's audio plays
    public func setActiveDevice(_ deviceId: Int) {
        guard activeDeviceId != deviceId else { return }
        activeDeviceId = deviceId
        applyAudioState()
    }

    /// Mute/unmute incoming audio (persists when switching cameras)
    public func setMuted(_ muted: Bool) {
        isMuted = muted
        applyAudioState()
    }

    private func applyAudioState() {
        for (id, info) in streams {
            info.audioTrack?.isEnabled = (id == activeDeviceId) && !isMuted
        }
    }

    // MARK: - Push-to-Talk

    public func startTalking(for deviceId: Int) async {
        await streams[deviceId]?.session?.startTalking()
    }

    public func stopTalking(for deviceId: Int) async {
        await streams[deviceId]?.session?.stopTalking()
    }
}
