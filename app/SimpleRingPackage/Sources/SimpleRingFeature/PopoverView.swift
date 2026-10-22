import SwiftUI
import DesignSystem
import RingClient
@preconcurrency import WebRTC

// MARK: - Live-First Popover View

public struct PopoverView: View {
    let devices: [RingDevice]
    let events: [RingEvent]
    @Binding var selectedDevice: RingDevice?
    let isVisible: Bool

    @State private var recording: RecordingState?
    @StateObject private var streamManager = MultiStreamManager()

    @AppStorage("drawerExpanded") private var isDrawerExpanded = true

    /// The events drawer (list + recording playback) is hidden for now, leaving
    /// a window that is just the live video. Set to true to bring it back.
    private static let showsEvents = false

    private let drawerExpandedHeight: CGFloat = 230

    // Filter to only cameras and doorbells (not chimes)
    private var videoDevices: [RingDevice] {
        devices.filter { $0.deviceType != .chime }
    }

    public init(
        devices: [RingDevice],
        events: [RingEvent],
        selectedDevice: Binding<RingDevice?>,
        isVisible: Bool
    ) {
        self.devices = devices
        self.events = events
        self._selectedDevice = selectedDevice
        self.isVisible = isVisible
    }

    /// Streams run only while the window is visible; this changes whenever
    /// either the visibility or the set of cameras changes.
    private var streamKey: [Int] {
        isVisible ? videoDevices.map(\.id) : []
    }

    private var drawerVisibleHeight: CGFloat {
        guard Self.showsEvents else { return 0 }
        return isDrawerExpanded ? drawerExpandedHeight : DrawerMetrics.handleHeight
    }

    /// Window layout: the video area at the camera's real aspect ratio (known
    /// from its frames; a sensible default until then) plus the drawer.
    private var layout: WindowLayout {
        guard let device = selectedDevice else {
            return WindowLayout(idealSize: CGSize(width: 400, height: 420), videoAspect: nil, chromeHeight: 0)
        }
        let aspect = streamManager.videoAspects[device.id]
            ?? (device.deviceType == .doorbell ? 1.0 : 16.0 / 9.0)
        let width: CGFloat = aspect >= 1.3 ? 480 : 400
        return WindowLayout(
            idealSize: CGSize(width: width, height: width / aspect + drawerVisibleHeight),
            videoAspect: aspect,
            chromeHeight: drawerVisibleHeight
        )
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let device = selectedDevice {
                VStack(spacing: 0) {
                    ZStack {
                        MultiStreamVideoView(
                            device: device,
                            devices: videoDevices,
                            streamManager: streamManager,
                            onClose: {
                                NotificationCenter.default.post(name: .closeMenuBarWindow, object: nil)
                            },
                            onSwitchDevice: { newDevice in
                                recording = nil
                                selectedDevice = newDevice
                            }
                        )

                        if let recording {
                            RecordingOverlay(recording: recording) {
                                self.recording = nil
                            }
                            .transition(.opacity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .animation(.easeInOut(duration: 0.2), value: recording?.event.id)

                    if Self.showsEvents {
                        DrawerPanel(isExpanded: $isDrawerExpanded, expandedHeight: drawerExpandedHeight) {
                            EventsPanel(
                                events: events,
                                selectedEventId: recording?.event.id,
                                onSelect: play
                            )
                        }
                    }
                }
            } else {
                VStack(spacing: Spacing.md) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading…")
                        .font(.Ring.body)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        .windowLayout(layout)
        // (Re)starts streams when the window opens or the cameras change (on
        // launch the view can appear before devices load); stops them on hide.
        .task(id: streamKey) {
            await streamManager.stopAllStreams()
            guard isVisible, !videoDevices.isEmpty else { return }
            await streamManager.startAllStreams(for: videoDevices)
        }
        .onChange(of: isVisible) { _, visible in
            if !visible { recording = nil }
        }
        .onDisappear {
            Task { await streamManager.stopAllStreams() }
        }
    }

    // MARK: - Recordings

    private func play(_ event: RingEvent) {
        recording = RecordingState(event: event)
        Task {
            do {
                let url = try await RingClient.shared.getEventVideoURL(eventId: event.id)
                guard recording?.event.id == event.id else { return }
                recording?.url = url
            } catch {
                guard recording?.event.id == event.id else { return }
                recording?.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Popover") {
    PopoverView(devices: [], events: [], selectedDevice: .constant(nil), isVisible: true)
        .preferredColorScheme(.dark)
}
#endif
