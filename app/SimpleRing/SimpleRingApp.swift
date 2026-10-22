import SwiftUI
import SimpleRingFeature
import DesignSystem
import RingClient
import AppKit
import Combine

@main
struct SimpleRingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The real Settings window is owned by AppDelegate: SwiftUI's Settings
        // scene can't be opened from an NSHostingView on macOS 14+.
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate (owns the status item, the main panel and settings)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var stateObservation: AnyCancellable?

    /// What the visible content would like the panel to be (reported by the views).
    private var idealSize = CGSize(width: 340, height: 520)

    /// Extra size the user added (or removed) by dragging the panel's edges.
    private var userSizeOffset: CGSize {
        get {
            CGSize(
                width: UserDefaults.standard.double(forKey: "panelWidthOffset"),
                height: UserDefaults.standard.double(forKey: "panelHeightOffset")
            )
        }
        set {
            UserDefaults.standard.set(Double(newValue.width), forKey: "panelWidthOffset")
            UserDefaults.standard.set(Double(newValue.height), forKey: "panelHeightOffset")
        }
    }

    private let panelMinSize = NSSize(width: 300, height: 320)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        observeMenuBarState()

        let center = NotificationCenter.default
        center.addObserver(forName: .closeMenuBarWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        center.addObserver(forName: .showMenuBarWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.panel?.isVisible != true { self?.showPanel() }
            }
        }
        center.addObserver(forName: .openSettingsWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        center.addObserver(forName: .menuBarWindowIdealSizeChanged, object: nil, queue: .main) { [weak self] note in
            guard let size = note.userInfo?["size"] as? CGSize else { return }
            MainActor.assumeIsolated {
                self?.idealSize = size
                self?.applyPanelSize(animated: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
        updateIcon(for: appState.menuBarState)
    }

    @objc private func statusItemClicked() {
        togglePanel()
    }

    private func observeMenuBarState() {
        stateObservation = appState.$menuBarState.sink { [weak self] state in
            self?.updateIcon(for: state)
        }
    }

    private func updateIcon(for state: AppState.MenuBarState) {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let tint: NSColor?
        switch state {
        case .normal:
            symbolName = "bell"
            tint = nil
        case .hasNewEvent:
            symbolName = "bell.fill"
            tint = nil
        case .authExpired:
            symbolName = "bell.badge.fill"
            tint = NSColor(Color.Ring.error)
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SimpleRing")
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint
    }

    // MARK: - Panel

    private func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Fresh content each time so onAppear/onDisappear start and stop the
        // live streams, just like a popover.
        panel.contentView = NSHostingView(
            rootView: MainPopoverView().environmentObject(appState)
        )

        applyPanelSize(animated: false)
        positionPanel(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        startOutsideClickMonitor()

        if appState.menuBarState == .hasNewEvent {
            appState.menuBarState = .normal
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = NSView()
        stopOutsideClickMonitor()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: idealSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = panelMinSize
        panel.delegate = self
        return panel
    }

    /// Sizes the panel to the content's ideal size plus the user's drag offset,
    /// keeping its top edge pinned under the menu bar.
    private func applyPanelSize(animated: Bool) {
        guard let panel else { return }
        let offset = userSizeOffset
        let size = NSSize(
            width: max(panelMinSize.width, idealSize.width + offset.width),
            height: max(panelMinSize.height, idealSize.height + offset.height)
        )
        let current = panel.frame
        guard current.size != size else { return }

        var frame = NSRect(
            x: current.midX - size.width / 2,
            y: current.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if let visible = panel.screen?.visibleFrame {
            frame.origin.x = max(visible.minX + 8, min(frame.origin.x, visible.maxX - size.width - 8))
            frame.origin.y = max(visible.minY + 8, frame.origin.y)
        }

        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel else { return }
        userSizeOffset = CGSize(
            width: panel.frame.width - idealSize.width,
            height: panel.frame.height - idealSize.height
        )
        panel.invalidateShadow()
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let buttonWindow = statusItem.button?.window else { return }
        let buttonFrame = buttonWindow.frame
        let panelSize = panel.frame.size

        var origin = NSPoint(
            x: buttonFrame.midX - panelSize.width / 2,
            y: buttonFrame.minY - panelSize.height - 4
        )

        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - panelSize.width - 8))
            origin.y = max(visible.minY + 8, origin.y)
        }

        panel.setFrameOrigin(origin)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Clicks on the status item are handled by its own action;
                // hiding here too would close and immediately reopen the panel.
                if let buttonWindow = self.statusItem.button?.window,
                   buttonWindow.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                self.hidePanel()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Settings Window

    private func showSettings() {
        let window = settingsWindow ?? {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SettingsView().environmentObject(appState)
                )
            )
            window.title = "SimpleRing Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Main Popover View (handles auth state)

struct MainPopoverView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.authState {
            case .authenticated:
                PopoverView(
                    devices: appState.devices,
                    events: appState.events,
                    selectedDevice: $appState.selectedDevice
                )
            case .unauthenticated, .expired:
                LoginView {
                    Task {
                        await appState.onLoginSuccess()
                    }
                }
            case .loading:
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .idealWindowSize(CGSize(width: 340, height: 320))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - App State

enum AuthViewState {
    case loading
    case unauthenticated
    case authenticated
    case expired
}

@MainActor
final class AppState: ObservableObject {
    enum MenuBarState {
        case normal
        case hasNewEvent
        case authExpired
    }

    @Published var authState: AuthViewState = .loading
    @Published var menuBarState: MenuBarState = .normal
    @Published var selectedDevice: RingDevice?
    @Published var devices: [RingDevice] = []
    @Published var events: [RingEvent] = []

    @Published var alertsEnabled = UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled") }
    }

    private var pollingTask: Task<Void, Never>?

    init() {
        Task { await restoreSession() }
    }

    func restoreSession() async {
        authState = .loading
        let restored = (try? await RingClient.shared.restoreSession()) ?? false
        if restored {
            await onLoginSuccess()
        } else {
            authState = .unauthenticated
        }
    }

    func onLoginSuccess() async {
        authState = .authenticated
        await loadData()
        _ = await NotificationManager.shared.requestPermission()
        startPolling()
    }

    func loadData() async {
        do {
            let devices = try await RingClient.shared.fetchDevices()
            let newEvents = await RingClient.shared.fetchRecentEvents(for: devices)

            if alertsEnabled {
                for event in NotificationManager.shared.detectNewEvents(old: events, new: newEvents) {
                    await NotificationManager.shared.sendNotification(for: event)
                    menuBarState = .hasNewEvent
                }
            }

            self.devices = devices
            events = newEvents

            if selectedDevice == nil || !devices.contains(where: { $0.id == selectedDevice?.id }) {
                // Prefer a doorbell, then any camera (chimes have no video)
                selectedDevice = devices.first { $0.deviceType == .doorbell }
                    ?? devices.first { $0.deviceType != .chime }
            }

            if menuBarState == .authExpired {
                menuBarState = .normal
            }
        } catch RingAPIError.unauthorized {
            authState = .expired
            menuBarState = .authExpired
            stopPolling()
        } catch {
            NSLog("❌ Failed to load data: \(error.localizedDescription)")
        }
    }

    func logout() async {
        stopPolling()
        try? await RingClient.shared.logout()
        devices = []
        events = []
        selectedDevice = nil
        authState = .unauthenticated
        menuBarState = .normal
    }

    // MARK: - Background Polling

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                let interval = UserDefaults.standard.object(forKey: "pollingInterval") as? Int ?? 30
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await loadData()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func restartPolling() {
        stopPolling()
        startPolling()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("pollingInterval") private var pollingInterval = 30
    @AppStorage("showBatteryIndicator") private var showBatteryIndicator = true
    @AppStorage("notificationSound") private var notificationSound = true

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Ring & Motion Alerts", isOn: $appState.alertsEnabled)
                Toggle("Notification Sound", isOn: $notificationSound)
                    .disabled(!appState.alertsEnabled)
                Picker("Check for Events Every", selection: $pollingInterval) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("2 minutes").tag(120)
                }
                .onChange(of: pollingInterval) { _, _ in
                    appState.restartPolling()
                }
            }

            Section("Display") {
                Toggle("Show Battery Level", isOn: $showBatteryIndicator)
            }

            Section {
                LabeledContent("Switch camera", value: "← →  or  ⌘1–4")
                LabeledContent("Zoom", value: "+ −  or scroll")
            } header: {
                Text("Keyboard Shortcuts")
            }

            Section("Account") {
                if case .authenticated = appState.authState {
                    Button("Log Out", role: .destructive) {
                        Task { await appState.logout() }
                    }
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
