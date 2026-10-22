import SwiftUI

// MARK: - Menu Bar Window Notifications
// The feature views live in this package, but the menu bar panel and the
// settings window are owned by the app delegate, so views talk to it
// through these notifications.

public extension Notification.Name {
    /// Show the main menu-bar panel (e.g. when a notification is clicked).
    static let showMenuBarWindow = Notification.Name("SimpleRing.showMenuBarWindow")

    /// Close/hide the main menu-bar panel (same as clicking the menu bar icon).
    static let closeMenuBarWindow = Notification.Name("SimpleRing.closeMenuBarWindow")

    /// Open the Settings window.
    static let openSettingsWindow = Notification.Name("SimpleRing.openSettingsWindow")

    /// The visible content's ideal size changed. userInfo["size"] is a CGSize.
    static let menuBarWindowIdealSizeChanged = Notification.Name("SimpleRing.menuBarWindowIdealSizeChanged")
}

public extension View {
    /// Tells the menu bar panel how big this content would like to be. The panel
    /// adds any extra size the user gave it by dragging its edges, so e.g.
    /// expanding the events drawer grows the window instead of squeezing the video.
    func idealWindowSize(_ size: CGSize) -> some View {
        self
            .onAppear { Self.post(size) }
            .onChange(of: size) { _, newSize in Self.post(newSize) }
    }

    private static func post(_ size: CGSize) {
        NotificationCenter.default.post(
            name: .menuBarWindowIdealSizeChanged,
            object: nil,
            userInfo: ["size": size]
        )
    }
}
