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

    @State private var playingVideoURL: URL?
    @State private var isLoadingVideo = false
    @StateObject private var streamManager = MultiStreamManager()

    @AppStorage("drawerExpanded") private var isDrawerExpanded = true

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

    private var drawerExpandedHeight: CGFloat {
        playingVideoURL != nil || isLoadingVideo ? 320 : 200
    }

    private var drawerVisibleHeight: CGFloat {
        isDrawerExpanded ? drawerExpandedHeight : DrawerMetrics.handleHeight
    }

    // The size this content would like the window to be. The window adds any
    // extra size the user gave it by dragging, so toggling the drawer grows or
    // shrinks the window rather than resizing the video.
    private var idealSize: CGSize {
        guard let device = selectedDevice else {
            return CGSize(width: 340, height: 420)
        }
        switch device.deviceType {
        case .doorbell:
            return CGSize(width: 340, height: 500 + drawerVisibleHeight)
        case .camera:
            return CGSize(width: 480, height: 270 + drawerVisibleHeight)
        default:
            return CGSize(width: 400, height: 300 + drawerVisibleHeight)
        }
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let device = selectedDevice {
                VStack(spacing: 0) {
                    MultiStreamVideoView(
                        device: device,
                        devices: videoDevices,
                        streamManager: streamManager,
                        onClose: {
                            NotificationCenter.default.post(name: .closeMenuBarWindow, object: nil)
                        },
                        onSwitchDevice: { newDevice in
                            selectedDevice = newDevice
                        }
                    )
                    .frame(maxHeight: .infinity)

                    DrawerPanel(
                        isExpanded: $isDrawerExpanded,
                        expandedHeight: drawerExpandedHeight
                    ) {
                        EventTimelinePanel(
                            playingVideoURL: $playingVideoURL,
                            isLoadingVideo: $isLoadingVideo,
                            events: events,
                            onEventTap: { event in playEvent(event) }
                        )
                    }
                    .overlay(alignment: .topTrailing) {
                        settingsButton
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
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .idealWindowSize(idealSize)
        // (Re)starts streams when the window opens or the cameras change (on
        // launch the view can appear before devices load); stops them on hide.
        .task(id: streamKey) {
            await streamManager.stopAllStreams()
            guard isVisible, !videoDevices.isEmpty else { return }
            await streamManager.startAllStreams(for: videoDevices)
        }
        .onChange(of: isVisible) { _, visible in
            if !visible { playingVideoURL = nil }  // stop any recording playback
        }
        .onDisappear {
            Task { await streamManager.stopAllStreams() }
        }
    }

    // MARK: - Settings Button (sits on the drawer handle row)

    private var settingsButton: some View {
        Button {
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 28, height: DrawerMetrics.handleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, Spacing.sm)
        .help("Settings")
    }

    // MARK: - Event Playback

    private func playEvent(_ event: RingEvent) {
        isLoadingVideo = true
        Task {
            do {
                playingVideoURL = try await RingClient.shared.getEventVideoURL(eventId: event.id)
            } catch {
                NSLog("❌ Failed to get event video for \(event.id): \(error)")
            }
            isLoadingVideo = false
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
