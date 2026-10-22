import SwiftUI
import RingClient
@preconcurrency import WebRTC
import DesignSystem

// MARK: - Multi Stream Video View
// Displays video from pre-established streams, enabling instant camera switching

public struct MultiStreamVideoView: View {
    let device: RingDevice
    let devices: [RingDevice]
    @ObservedObject var streamManager: MultiStreamManager
    let onClose: () -> Void
    let onSwitchDevice: (RingDevice) -> Void

    @State private var isHovering = false  // Auto-hide overlay when not hovering
    @AppStorage("showBatteryIndicator") private var showBatteryIndicator = true

    // Device control states
    @State private var isFloodlightOn = false
    @State private var isSirenActive = false
    @State private var sirenResetTask: Task<Void, Never>?
    @State private var isControlLoading = false  // Show loading during API calls

    // Zoom state
    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero

    // Focus state for keyboard
    @FocusState private var isViewFocused: Bool

    // Zoom limits
    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 4.0

    // Get current device index for indicator dots
    private var currentIndex: Int {
        devices.firstIndex(where: { $0.id == device.id }) ?? 0
    }

    // Check if we can navigate
    private var canGoBack: Bool { currentIndex > 0 }
    private var canGoForward: Bool { currentIndex < devices.count - 1 }

    // Get current video track from stream manager
    private var videoTrack: RTCVideoTrack? {
        streamManager.getVideoTrack(for: device.id)
    }

    // Get current connection state
    private var connectionState: LiveViewSession.State {
        streamManager.getState(for: device.id)
    }

    // Get error message
    private var errorMessage: String? {
        streamManager.getError(for: device.id)
    }

    private var controlsVisible: Bool {
        isHovering || streamManager.isTalking || videoTrack == nil
    }

    public var body: some View {
        ZStack {
            // Video background
            Color.black

            if let track = videoTrack {
                WebRTCVideoView(videoTrack: track) { aspect in
                    streamManager.setVideoAspect(aspect, for: device.id)
                }
                .scaleEffect(zoomScale)
                .offset(zoomOffset)
                .id(device.id)
                .gesture(zoomPanGesture)
                #if os(macOS)
                .onScrollWheel { delta in
                    // Vertical scroll = zoom
                    if abs(delta.y) > 0.5 {
                        withAnimation(.easeOut(duration: 0.1)) {
                            let zoomDelta = delta.y > 0 ? 0.1 : -0.1
                            zoomScale = min(maxZoom, max(minZoom, zoomScale + zoomDelta))
                            if zoomScale <= 1.0 {
                                zoomOffset = .zero
                                lastDragOffset = .zero
                            }
                        }
                    }
                }
                #endif
            } else {
                connectionPlaceholder
            }

            // Zoom indicator (when zoomed in, auto-hide with overlay)
            if zoomScale > 1.0 {
                zoomIndicator
                    .opacity(controlsVisible ? 1 : 0)
            }

            // Overlay controls (auto-hide when not hovering)
            VStack {
                // Top bar
                topBar

                Spacer()
                    .allowsHitTesting(false)  // Allow touches to pass through to arrows

                // Camera indicator dots
                if devices.count > 1 {
                    cameraIndicatorDots
                        .padding(.bottom, Spacing.sm)
                }

                // Bottom controls
                if videoTrack != nil {
                    bottomControls
                }
            }
            .opacity(controlsVisible ? 1 : 0)

            // Camera switching arrows (auto-hide when not hovering)
            if devices.count > 1 {
                cameraSwitchingOverlay
                    .opacity(controlsVisible ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onHover { hovering in
            isHovering = hovering
        }
        // Only use swipe gesture when not zoomed (zoom has its own pan gesture)
        .gesture(
            zoomScale == 1.0 ?
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    // Swipe threshold: 50px
                    if value.translation.width < -50 && canGoForward {
                        switchToDevice(at: currentIndex + 1)
                    } else if value.translation.width > 50 && canGoBack {
                        switchToDevice(at: currentIndex - 1)
                    }
                }
            : nil
        )
        .onAppear {
            // Set this device as active for audio
            streamManager.setActiveDevice(device.id)
            // Auto-focus on appear for keyboard navigation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isViewFocused = true
            }
        }
        // Reset zoom and switch audio when changing devices
        .onChange(of: device.id) { _, newId in
            withAnimation(.easeOut(duration: 0.2)) {
                zoomScale = 1.0
                zoomOffset = .zero
            }
            // Switch audio to the new device
            streamManager.setActiveDevice(newId)
        }
        // Make focusable with binding for auto-focus
        .focusable()
        .focused($isViewFocused)
        .focusEffectDisabled()
        // Keyboard arrow key support
        .onKeyPress(.leftArrow) {
            if canGoBack {
                switchToDevice(at: currentIndex - 1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if canGoForward {
                switchToDevice(at: currentIndex + 1)
                return .handled
            }
            return .ignored
        }
        // Zoom keyboard shortcuts
        .onKeyPress(.init("+")) {
            zoomIn()
            return .handled
        }
        .onKeyPress(.init("=")) {
            zoomIn()
            return .handled
        }
        .onKeyPress(.init("-")) {
            zoomOut()
            return .handled
        }
        .onKeyPress(.init("0")) {
            resetZoom()
            return .handled
        }
        // Cmd+1/2/3/4 to switch cameras directly (via modifier to reduce type-check complexity)
        .cameraSwitchingShortcuts(devices: devices) { index in
            switchToDevice(at: index)
        }
    }

    // MARK: - Camera Switching Overlay

    private var cameraSwitchingOverlay: some View {
        HStack {
            if canGoBack {
                glassButton("chevron.left", size: 34, help: "Previous camera") {
                    switchToDevice(at: currentIndex - 1)
                }
            }
            Spacer()
                .allowsHitTesting(false)
            if canGoForward {
                glassButton("chevron.right", size: 34, help: "Next camera") {
                    switchToDevice(at: currentIndex + 1)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Camera Indicator Dots

    private var cameraIndicatorDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, dev in
                Circle()
                    .fill(index == currentIndex ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .overlay(
                        // Show connecting indicator
                        Group {
                            if streamManager.getState(for: dev.id) == .connecting ||
                               streamManager.getState(for: dev.id) == .creatingOffer ||
                               streamManager.getState(for: dev.id) == .negotiating {
                                Circle()
                                    .stroke(Color.Ring.accent, lineWidth: 1)
                                    .frame(width: 10, height: 10)
                            }
                        }
                    )
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 4)
        .background(.black.opacity(0.3))
        .clipShape(Capsule())
    }

    private func switchToDevice(at index: Int) {
        guard index >= 0 && index < devices.count else { return }
        let newDevice = devices[index]
        onSwitchDevice(newDevice)
    }

    // MARK: - Zoom Functions

    private func zoomIn() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoomScale = min(maxZoom, zoomScale + 0.5)
        }
    }

    private func zoomOut() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoomScale = max(minZoom, zoomScale - 0.5)
            if zoomScale <= 1.0 {
                zoomOffset = .zero
                lastDragOffset = .zero
            }
        }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoomScale = 1.0
            zoomOffset = .zero
            lastDragOffset = .zero
        }
    }

    // Pan gesture for when zoomed in
    private var zoomPanGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale > 1.0 else { return }
                zoomOffset = CGSize(
                    width: lastDragOffset.width + value.translation.width,
                    height: lastDragOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastDragOffset = zoomOffset
            }
    }

    // MARK: - Talk Button

    /// Tap to talk, tap again to stop. The first tap reconnects the camera with
    /// a microphone; the mic is only open while talking.
    private var pushToTalkButton: some View {
        let talking = streamManager.isTalking
        let reconnecting = streamManager.activeAudioMode == .talk && videoTrack == nil
        return Button {
            Task { await streamManager.toggleTalking() }
        } label: {
            ZStack {
                Circle()
                    .fill(talking ? Color.Ring.error : Color.Ring.accent)
                    .frame(width: 52, height: 52)
                    .shadow(color: (talking ? Color.Ring.error : Color.Ring.accent).opacity(0.5), radius: talking ? 12 : 6)
                if reconnecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: talking ? "mic.fill" : "mic")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: talking)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: talking)
        .help(talking ? "Stop talking" : "Talk")
    }

    // MARK: - Zoom Indicator

    private var zoomIndicator: some View {
        VStack {
            Spacer()
            HStack {
                // Zoom level badge
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                    Text(String(format: "%.1fx", zoomScale))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6))
                .clipShape(Capsule())

                // Reset zoom button
                Button {
                    resetZoom()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.6))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.leading, Spacing.md)
            .padding(.bottom, 100)  // Above bottom controls
        }
    }

    // MARK: - Connection Placeholder

    private var connectionPlaceholder: some View {
        VStack(spacing: Spacing.md) {
            switch connectionState {
            case .failed, .disconnected:
                Image(systemName: connectionState.isFailed ? "wifi.exclamationmark" : "video.slash")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(connectionState.isFailed ? "Couldn't connect to \(device.name)" : "Disconnected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                if let errorMessage, connectionState.isFailed {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                Button("Retry") {
                    Task { await streamManager.restartStream(for: device) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, Spacing.xs)
            default:
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
                Text("Connecting to \(device.name)…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(Spacing.xl)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: Spacing.sm) {
            if videoTrack != nil {
                LiveBadge()
            }

            Text(device.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if showBatteryIndicator, let battery = device.batteryLevel {
                HStack(spacing: 3) {
                    Image(systemName: batteryIcon(for: battery))
                    Text("\(battery)%")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(battery < 20 ? Color.Ring.error : .white.opacity(0.75))
            }

            Spacer(minLength: Spacing.sm)

            deviceControlButtons

            glassButton("xmark", size: 28, help: "Close") {
                onClose()
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4)
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.xl)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 0..<20: return "battery.0percent"
        case 20..<50: return "battery.25percent"
        case 50..<75: return "battery.50percent"
        case 75..<100: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: - Device Control Buttons

    private var deviceControlButtons: some View {
        HStack(spacing: Spacing.sm) {
            if device.hasFloodlight {
                glassButton(
                    isFloodlightOn ? "lightbulb.fill" : "lightbulb",
                    size: 28,
                    activeColor: isFloodlightOn ? .yellow : nil,
                    help: isFloodlightOn ? "Turn off light" : "Turn on light"
                ) { toggleFloodlight() }
                .disabled(isControlLoading)
            }
            if device.hasSiren {
                glassButton(
                    isSirenActive ? "light.beacon.max.fill" : "light.beacon.max",
                    size: 28,
                    activeColor: isSirenActive ? Color.Ring.error : nil,
                    help: isSirenActive ? "Stop siren" : "Sound siren"
                ) { toggleSiren() }
                .disabled(isControlLoading)
            }
        }
    }

    private func toggleFloodlight() {
        isControlLoading = true
        Task {
            do {
                let newState = !isFloodlightOn
                try await RingClient.shared.setFloodlight(deviceId: device.id, enabled: newState)
                isFloodlightOn = newState
            } catch {
                ringLog.error("❌ Failed to toggle floodlight: \(String(describing: error), privacy: .public)")
            }
            isControlLoading = false
        }
    }

    private func toggleSiren() {
        isControlLoading = true
        Task {
            do {
                let newState = !isSirenActive
                try await RingClient.shared.setSiren(deviceId: device.id, enabled: newState)
                isSirenActive = newState
                isControlLoading = false
                // Ring stops the siren after 30 seconds; mirror that in the UI
                sirenResetTask?.cancel()
                if newState {
                    sirenResetTask = Task {
                        try? await Task.sleep(for: .seconds(30))
                        if !Task.isCancelled { isSirenActive = false }
                    }
                }
            } catch {
                ringLog.error("❌ Failed to toggle siren: \(String(describing: error), privacy: .public)")
                isControlLoading = false
            }
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        ZStack {
            // Hold-to-talk, centred
            pushToTalkButton

            HStack {
                let listening = streamManager.activeAudioMode != .off
                glassButton(
                    listening ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    size: 36,
                    activeColor: listening ? Color.Ring.accent : nil,
                    help: listening ? "Turn sound off" : "Turn sound on"
                ) {
                    Task { await streamManager.setListening(!listening) }
                }

                Spacer()

                HStack(spacing: Spacing.sm) {
                    glassButton("minus.magnifyingglass", size: 32, help: "Zoom out") { zoomOut() }
                        .disabled(zoomScale <= minZoom)
                        .opacity(zoomScale > minZoom ? 1 : 0.4)
                    glassButton("plus.magnifyingglass", size: 32, help: "Zoom in") { zoomIn() }
                        .disabled(zoomScale >= maxZoom)
                        .opacity(zoomScale < maxZoom ? 1 : 0.4)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.md)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    private func glassButton(
        _ systemName: String,
        size: CGFloat,
        activeColor: Color? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        GlassButton(systemName: systemName, size: size, activeColor: activeColor, help: help, action: action)
    }
}

// MARK: - Scroll Wheel Modifier for macOS Zoom

#if os(macOS)
import AppKit

struct ScrollWheelModifier: ViewModifier {
    let onScroll: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content.overlay(
            ScrollWheelView(onScroll: onScroll)
        )
    }
}

struct ScrollWheelView: NSViewRepresentable {
    let onScroll: (CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // Use scrollingDeltaY for smooth scrolling
        let delta = CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        onScroll?(delta)
    }

    // Pass through all mouse events so buttons remain clickable
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // This view doesn't handle clicks, only scroll
    }

    override var acceptsFirstResponder: Bool { false }
}

extension View {
    func onScrollWheel(_ action: @escaping (CGPoint) -> Void) -> some View {
        modifier(ScrollWheelModifier(onScroll: action))
    }
}
#endif

// MARK: - Camera Switching Keyboard Shortcuts Modifier

struct CameraSwitchingShortcuts: ViewModifier {
    let devices: [RingDevice]
    let switchToDevice: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { keyPress in
                // Only handle if Command is pressed
                guard keyPress.modifiers.contains(.command) else {
                    return .ignored
                }

                // Map character to device index
                switch keyPress.characters {
                case "1" where devices.count >= 1:
                    switchToDevice(0)
                    return .handled
                case "2" where devices.count >= 2:
                    switchToDevice(1)
                    return .handled
                case "3" where devices.count >= 3:
                    switchToDevice(2)
                    return .handled
                case "4" where devices.count >= 4:
                    switchToDevice(3)
                    return .handled
                default:
                    return .ignored
                }
            }
    }
}

extension View {
    func cameraSwitchingShortcuts(devices: [RingDevice], switchToDevice: @escaping (Int) -> Void) -> some View {
        modifier(CameraSwitchingShortcuts(devices: devices, switchToDevice: switchToDevice))
    }
}
