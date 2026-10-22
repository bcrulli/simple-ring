import SwiftUI
#if os(macOS)
import AppKit

// MARK: - Menu Bar Window Notifications

public extension Notification.Name {
    /// Posted to ask the app to close/hide the main menu-bar window —
    /// the same effect as clicking the menu bar icon to dismiss it.
    static let closeMenuBarWindow = Notification.Name("SimpleRing.closeMenuBarWindow")
}

/// Makes the hosting window resizable by dragging its edges, like any other
/// macOS window, and enforces a minimum size.
public struct WindowConfigurator: NSViewRepresentable {
    let minSize: NSSize

    public init(minSize: NSSize = NSSize(width: 300, height: 420)) {
        self.minSize = minSize
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [minSize] in
            Self.configure(view.window, minSize: minSize)
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [minSize] in
            Self.configure(nsView.window, minSize: minSize)
        }
    }

    private static func configure(_ window: NSWindow?, minSize: NSSize) {
        guard let window else { return }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        window.minSize = minSize
    }
}
#endif
