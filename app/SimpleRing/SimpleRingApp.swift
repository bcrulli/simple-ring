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

    /// Layout reported by the visible content: its ideal size and, for live
    /// video, the video's aspect ratio plus the height of everything else.
    private var layout = WindowLayout(idealSize: CGSize(width: 400, height: 620), videoAspect: nil, chromeHeight: 0)

    /// Width the user chose by dragging (this session only, so every launch
    /// starts at the default size that fits the video exactly).
    private var userWidth: CGFloat?

    private let cornerRadius: CGFloat = 14

    private let panelMinSize = NSSize(width: 300, height: 160)

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
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoHidePanel() }
        }
        center.addObserver(forName: .menuBarWindowIdealSizeChanged, object: nil, queue: .main) { [weak self] note in
            guard let layout = note.userInfo?["layout"] as? WindowLayout else { return }
            MainActor.assumeIsolated {
                self?.layout = layout
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
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateIcon(for: appState.menuBarState)
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    /// Right-click (or Control-click) menu on the menu bar icon
    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SimpleRing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
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
        appState.isPanelVisible = true

        panel.setFrame(anchoredFrame(size: targetPanelSize()), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        refreshShadow()
        startOutsideClickMonitor()

        if appState.menuBarState == .hasNewEvent {
            appState.menuBarState = .normal
        }
    }

    private func hidePanel() {
        stopOutsideClickMonitor()
        panel?.orderOut(nil)
        appState.isPanelVisible = false  // stops the live streams
    }

    /// Hide on click-away / app switch — but not on the sign-in screen, so you
    /// can switch to your password manager without losing the window.
    private func autoHidePanel() {
        guard appState.authState == .authenticated else { return }
        hidePanel()
    }

    private func makePanel() -> NSPanel {
        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: layout.idealSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Round the window itself (not just the SwiftUI content) so the corners
        // and the window shadow are rounded on every edge.
        let container = NSView(frame: NSRect(origin: .zero, size: layout.idealSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        container.layer?.backgroundColor = NSColor.black.cgColor

        // Content is kept between shows so typed text, the drawer, etc. survive
        let hosting = NSHostingView(rootView: MainPopoverView().environmentObject(appState))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // We hide it ourselves (hidePanel) so the streams are stopped too
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = panelMinSize
        panel.delegate = self
        return panel
    }

    /// For live video: a size whose video area matches the video's aspect
    /// ratio exactly (no black bars), at the user's width if they resized.
    /// Otherwise the content's ideal size.
    private func targetPanelSize() -> NSSize {
        guard let aspect = layout.videoAspect else { return layout.idealSize }
        return fittedSize(width: userWidth ?? layout.idealSize.width, aspect: aspect)
    }

    /// Size for a given width that keeps the video's aspect ratio, limited to the screen.
    private func fittedSize(width: CGFloat, aspect: CGFloat) -> NSSize {
        let chrome = layout.chromeHeight
        var width = max(panelMinSize.width, width)
        if let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            let maxHeight = visible.height - 16
            if width / aspect + chrome > maxHeight {
                width = max(panelMinSize.width, (maxHeight - chrome) * aspect)
            }
            width = min(width, visible.width - 16)
        }
        return NSSize(width: width.rounded(), height: (width / aspect + chrome).rounded())
    }

    private func refreshShadow() {
        DispatchQueue.main.async { [weak self] in self?.panel?.invalidateShadow() }
    }

    /// A frame of the given size, horizontally centred on the menu bar icon
    /// with its top edge just below the menu bar (kept on screen).
    private func anchoredFrame(size: NSSize) -> NSRect {
        guard let buttonWindow = statusItem.button?.window else {
            return NSRect(origin: panel?.frame.origin ?? .zero, size: size)
        }
        let anchor = buttonWindow.frame
        var frame = NSRect(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - 4 - size.height,
            width: size.width,
            height: size.height
        )
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(visible.minX + 8, min(frame.origin.x, visible.maxX - size.width - 8))
            frame.origin.y = max(visible.minY + 8, frame.origin.y)
        }
        return frame
    }

    /// Resizes the panel for new content (e.g. the events drawer opening).
    private func applyPanelSize(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        let frame = anchoredFrame(size: targetPanelSize())
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.refreshShadow() }
            }
        } else {
            panel.setFrame(frame, display: true)
            refreshShadow()
        }
    }

    // While dragging an edge, keep the video's aspect ratio so it never gets black bars
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel, let aspect = layout.videoAspect else { return frameSize }
        let current = sender.frame.size
        let heightDriven = abs(frameSize.height - current.height) > abs(frameSize.width - current.width)
        let width = heightDriven ? (frameSize.height - layout.chromeHeight) * aspect : frameSize.width
        return fittedSize(width: width, aspect: aspect)
    }

    // Keep the panel centred under the menu bar icon while the user drags an edge
    func windowDidResize(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel, panel.inLiveResize else { return }
        let origin = anchoredFrame(size: panel.frame.size).origin
        if origin != panel.frame.origin {
            panel.setFrameOrigin(origin)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel else { return }
        if layout.videoAspect != nil {
            userWidth = panel.frame.width
        }
        refreshShadow()
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
                self.autoHidePanel()
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
            // Same level as the panel so it opens on top of it without closing it,
            // and hidden while another app is active so it doesn't float over it.
            window.level = .floating
            window.hidesOnDeactivate = true
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Menu Bar Panel

/// Borderless windows can't become key by default, which stops text fields
/// (like the login form) from receiving keyboard input.
private final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
                    selectedDevice: $appState.selectedDevice,
                    isVisible: appState.isPanelVisible
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
                    .idealWindowSize(CGSize(width: 400, height: 320))
            }
        }
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
    /// Streams only run while the panel is on screen
    @Published var isPanelVisible = false
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
