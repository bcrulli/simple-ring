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

    /// The visible content's window layout changed. userInfo["layout"] is a WindowLayout.
    static let menuBarWindowIdealSizeChanged = Notification.Name("SimpleRing.menuBarWindowIdealSizeChanged")
}

/// How the visible content wants the window sized.
public struct WindowLayout: Equatable, Sendable {
    /// Default size for this content
    public var idealSize: CGSize
    /// Live video's width / height. When set, the window keeps the video area
    /// at this aspect ratio (no black bars), including while resizing.
    public var videoAspect: CGFloat?
    /// Height of everything below/around the video (e.g. the events drawer)
    public var chromeHeight: CGFloat

    public init(idealSize: CGSize, videoAspect: CGFloat?, chromeHeight: CGFloat) {
        self.idealSize = idealSize
        self.videoAspect = videoAspect
        self.chromeHeight = chromeHeight
    }
}

public extension View {
    /// Tells the menu bar panel how this content wants the window sized.
    func windowLayout(_ layout: WindowLayout) -> some View {
        self
            .onAppear { postWindowLayout(layout) }
            .onChange(of: layout) { _, newLayout in postWindowLayout(newLayout) }
    }

    /// Fixed-size content (no live video).
    func idealWindowSize(_ size: CGSize) -> some View {
        windowLayout(WindowLayout(idealSize: size, videoAspect: nil, chromeHeight: 0))
    }
}

private func postWindowLayout(_ layout: WindowLayout) {
    NotificationCenter.default.post(
        name: .menuBarWindowIdealSizeChanged,
        object: nil,
        userInfo: ["layout": layout]
    )
}
