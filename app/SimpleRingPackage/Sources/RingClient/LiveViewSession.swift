import Foundation
@preconcurrency import WebRTC

// MARK: - Live View Session Manager

/// Uses Ring's newer client-initiated WebRTC API
/// POST to /integrations/v1/liveview/start with local SDP offer
/// Receives SDP answer in response - no WebSocket signaling needed
public actor LiveViewSession {
    /// Which audio the session negotiates. Audio is opt-in because WebRTC opens
    /// the audio device for playout, and when the output device is also an
    /// input (AirPods, headsets, many USB devices) macOS shows the mic indicator.
    public enum AudioMode: Sendable, Equatable {
        /// Video only - no audio device is touched
        case off
        /// Hear the doorbell
        case listen
        /// Hear and talk (the mic is only opened while talking)
        case talk
    }

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case creatingOffer
        case negotiating
        case connected
        case failed(String)
        case disconnected

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.connecting, .connecting),
                 (.creatingOffer, .creatingOffer),
                 (.negotiating, .negotiating),
                 (.connected, .connected),
                 (.disconnected, .disconnected):
                return true
            case (.failed(let l), .failed(let r)):
                return l == r
            default:
                return false
            }
        }

        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public private(set) var state: State = .idle
    private var sessionId: String
    private var peerConnection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var audioSender: RTCRtpSender?
    private var peerConnectionDelegate: PeerConnectionDelegate?

    // Push-to-talk state
    public private(set) var isTalking: Bool = false

    public let audioMode: AudioMode
    private let deviceId: Int
    private let accessToken: String
    private let hardwareId: String
    private let session: URLSession
    private var factory: RTCPeerConnectionFactory { Self.sharedFactory }

    /// One factory (and one SSL init) for the whole app. Creating a factory per
    /// session and calling RTCCleanupSSL() in deinit tore down SSL for every
    /// other camera that was still streaming.
    private static let sharedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    public var onStateChange: (@Sendable (State) -> Void)?
    public var onVideoTrack: (@Sendable (RTCVideoTrack) -> Void)?
    public var onAudioTrack: (@Sendable (RTCAudioTrack) -> Void)?

    // MARK: - Callbacks Setup

    public func setCallbacks(
        onStateChange: @escaping @Sendable (State) -> Void,
        onVideoTrack: @escaping @Sendable (RTCVideoTrack) -> Void,
        onAudioTrack: @escaping @Sendable (RTCAudioTrack) -> Void
    ) {
        self.onStateChange = onStateChange
        self.onVideoTrack = onVideoTrack
        self.onAudioTrack = onAudioTrack
    }

    // MARK: - Init

    public init(deviceId: Int, accessToken: String, hardwareId: String, audioMode: AudioMode) {
        self.audioMode = audioMode
        self.deviceId = deviceId
        self.accessToken = accessToken
        self.hardwareId = hardwareId
        self.sessionId = UUID().uuidString.lowercased()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    public func start() async throws {
        guard case .idle = state else {
            throw LiveViewError.alreadyStarted
        }

        state = .connecting
        onStateChange?(.connecting)
        NSLog("📹 LiveView: Starting live session for device \(deviceId)")

        do {
            // Step 1: Create peer connection and local offer
            state = .creatingOffer
            onStateChange?(.creatingOffer)

            try await setupPeerConnection()
            let localOffer = try await createOffer()

            // Step 2: Send offer to Ring API and get answer
            state = .negotiating
            onStateChange?(.negotiating)

            let answerSdp = try await startLiveView(offerSdp: localOffer.sdp)

            // Step 3+4: Set remote description AND activate camera in parallel
            // activateCamera only needs sessionId (set at init), not remote description
            async let activationTask: () = activateCamera()
            try await setRemoteDescription(answerSdp)
            try await activationTask

        } catch {
            NSLog("📹 LiveView: Failed to start: \(error)")
            let errorMsg = error.localizedDescription
            state = .failed(errorMsg)
            onStateChange?(.failed(errorMsg))
            throw error
        }
    }

    public func stop() async {

        // End session on server
        do {
            try await endLiveView()
        } catch {
            NSLog("📹 LiveView: Failed to end session: \(error)")
        }

        peerConnection?.close()
        peerConnection = nil
        peerConnectionDelegate = nil

        videoTrack = nil
        localAudioTrack = nil
        audioSender = nil
        isTalking = false

        state = .disconnected
        onStateChange?(.disconnected)
    }

    // MARK: - Push-to-Talk

    /// Start talking - enables microphone
    public func startTalking() {
        // Attaching the track is what opens the microphone
        audioSender?.track = localAudioTrack
        isTalking = true
    }

    /// Stop talking - disables microphone
    public func stopTalking() {
        // Detaching it releases the microphone (and the menu bar mic indicator)
        audioSender?.track = nil
        isTalking = false
    }

    // MARK: - Ring Live View API

    private func startLiveView(offerSdp: String) async throws -> String {
        let url = URL(string: "https://api.ring.com/integrations/v1/liveview/start")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("android:com.ringapp", forHTTPHeaderField: "User-Agent")
        request.setValue(hardwareId, forHTTPHeaderField: "hardware_id")

        let body: [String: Any] = [
            "session_id": sessionId,
            "device_id": deviceId,
            "sdp": offerSdp,
            "protocol": "webrtc"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveViewError.networkError
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            if let responseText = String(data: data, encoding: .utf8) {
                NSLog("📹 LiveView: Error response: \(responseText)")
            }
            throw LiveViewError.sessionCreationFailed(httpResponse.statusCode)
        }

        // Parse response to get SDP answer
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answerSdp = json["sdp"] as? String else {
            if let responseText = String(data: data, encoding: .utf8) {
                NSLog("📹 LiveView: Response: \(responseText)")
            }
            throw LiveViewError.invalidSessionResponse
        }

        return answerSdp
    }

    private func endLiveView() async throws {
        let url = URL(string: "https://api.ring.com/integrations/v1/liveview/end")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("android:com.ringapp", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "session_id": sessionId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            NSLog("📹 LiveView: End session response: \(httpResponse.statusCode)")
        }
    }

    private func activateCamera() async throws {
        let url = URL(string: "https://api.ring.com/integrations/v1/liveview/options")!

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("android:com.ringapp", forHTTPHeaderField: "User-Agent")
        request.setValue(hardwareId, forHTTPHeaderField: "hardware_id")

        let body: [String: Any] = [
            "session_id": sessionId,
            "actions": ["turn_off_stealth_mode"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            NSLog("📹 LiveView: Activate camera response: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 && httpResponse.statusCode != 204 {
                if let responseText = String(data: data, encoding: .utf8) {
                    NSLog("📹 LiveView: Activate camera error: \(responseText)")
                }
            }
        }
    }

    // MARK: - WebRTC Setup

    private func setupPeerConnection() async throws {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.iceTransportPolicy = .all  // Allow all transport types (UDP and TCP)
        config.tcpCandidatePolicy = .enabled  // Keep TCP enabled as fallback

        // Ring's STUN server only — no third-party (e.g. Google) network traffic.
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.ring.com:3478"])
        ]

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        // Create delegate to handle events
        let delegate = PeerConnectionDelegate(
            onVideoTrack: { [weak self] track in
                Task { [weak self] in
                    await self?.handleVideoTrack(track)
                }
            },
            onAudioTrack: { [weak self] track in
                Task { [weak self] in
                    await self?.handleAudioTrack(track)
                }
            },
            onIceConnectionChange: { [weak self] newState in
                Task { [weak self] in
                    await self?.handleIceConnectionStateChange(newState)
                }
            }
        )
        self.peerConnectionDelegate = delegate

        peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegate
        )

        guard let pc = peerConnection else {
            throw LiveViewError.peerConnectionNotReady
        }

        // Audio m-line is always present (Ring expects it); its direction
        // decides whether any audio device gets used.
        let audioTransceiverInit = RTCRtpTransceiverInit()
        audioTransceiverInit.streamIds = ["stream0"]
        switch audioMode {
        case .off: audioTransceiverInit.direction = .inactive
        case .listen: audioTransceiverInit.direction = .recvOnly
        case .talk: audioTransceiverInit.direction = .sendRecv
        }
        let audioTransceiver = pc.addTransceiver(of: .audio, init: audioTransceiverInit)

        if audioMode == .talk {
            let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
            // No track attached until talking: WebRTC opens the microphone
            // whenever a track is attached, even a disabled one.
            audioSender = audioTransceiver?.sender
            audioSender?.track = nil
        }

        // Set up video transceiver for receiving only
        let videoTransceiverInit = RTCRtpTransceiverInit()
        videoTransceiverInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: videoTransceiverInit)
    }

    private func createOffer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else {
            throw LiveViewError.peerConnectionNotReady
        }

        // No legacy OfferToReceive* constraints: with unified plan they force
        // transceivers to receive, which would override the audio mode.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: constraints) { sdp, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let sdp = sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: LiveViewError.offerCreationFailed)
                }
            }
        }

        // Set local description
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(offer) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Wait for ICE gathering to complete (or timeout)
        try await waitForIceGathering()

        // Return the offer with gathered ICE candidates
        guard let localDescription = pc.localDescription else {
            throw LiveViewError.offerCreationFailed
        }

        return localDescription
    }

    private func waitForIceGathering() async throws {
        guard let pc = peerConnection else { return }

        // Quick timeout - host candidates are instant, srflx arrive in 100-500ms
        let timeout = 2.0
        let startTime = Date()

        while pc.iceGatheringState != .complete {
            if Date().timeIntervalSince(startTime) > timeout {
                break
            }

            // Early exit: Check if we have at least 2 candidates (host + srflx)
            if let sdp = pc.localDescription?.sdp {
                let candidateCount = sdp.components(separatedBy: "a=candidate").count - 1
                if candidateCount >= 2 {
                    break
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 100ms polling (faster)
        }
    }

    private func setRemoteDescription(_ sdp: String) async throws {
        guard let pc = peerConnection else {
            throw LiveViewError.peerConnectionNotReady
        }

        let answer = RTCSessionDescription(type: .answer, sdp: sdp)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(answer) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Check if we already have a video track
        checkForVideoTrack()
    }

    // MARK: - Track Handling

    private func handleVideoTrack(_ track: RTCVideoTrack) {
        guard videoTrack !== track else { return }
        videoTrack = track
        onVideoTrack?(track)
        state = .connected
        onStateChange?(.connected)
    }

    private func handleAudioTrack(_ track: RTCAudioTrack) {
        // Audio tracks start enabled - MultiStreamManager mutes non-active cameras
        onAudioTrack?(track)
    }

    private func handleIceConnectionStateChange(_ newState: RTCIceConnectionState) {

        switch newState {
        case .connected, .completed:
            if state != .connected {
                checkForVideoTrack()
            }
        case .failed:
            state = .failed("ICE connection failed")
            onStateChange?(.failed("ICE connection failed"))
        case .disconnected:
            if state == .connected {
                state = .disconnected
                onStateChange?(.disconnected)
            }
        default:
            break
        }
    }

    private func checkForVideoTrack() {
        guard state != .connected, let pc = peerConnection else { return }
        for receiver in pc.receivers {
            if let track = receiver.track as? RTCVideoTrack {
                handleVideoTrack(track)
                return
            }
        }
    }
}

// MARK: - Peer Connection Delegate

private final class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate {
    private let onVideoTrack: (RTCVideoTrack) -> Void
    private let onAudioTrack: (RTCAudioTrack) -> Void
    private let onIceConnectionChange: (RTCIceConnectionState) -> Void

    init(
        onVideoTrack: @escaping (RTCVideoTrack) -> Void,
        onAudioTrack: @escaping (RTCAudioTrack) -> Void,
        onIceConnectionChange: @escaping (RTCIceConnectionState) -> Void
    ) {
        self.onVideoTrack = onVideoTrack
        self.onAudioTrack = onAudioTrack
        self.onIceConnectionChange = onIceConnectionChange
        super.init()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
            onVideoTrack(videoTrack)
        } else if let audioTrack = rtpReceiver.track as? RTCAudioTrack {
            onAudioTrack(audioTrack)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onIceConnectionChange(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Errors

public enum LiveViewError: Error, LocalizedError {
    case alreadyStarted
    case networkError
    case sessionCreationFailed(Int)
    case invalidSessionResponse
    case peerConnectionNotReady
    case offerCreationFailed

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "Live view already started"
        case .networkError:
            return "Network error"
        case .sessionCreationFailed(let code):
            return "Failed to create session (HTTP \(code))"
        case .invalidSessionResponse:
            return "Invalid session response"
        case .peerConnectionNotReady:
            return "Peer connection not ready"
        case .offerCreationFailed:
            return "Failed to create SDP offer"
        }
    }
}
