import AppKit
import SwiftUI

/// Hosts the SwiftUI settings UI in a plain `NSWindow`.
///
/// SwiftUI's `Settings` scene is the usual answer, but it is reachable only through the
/// application menu's "Settings…" item — and an `LSUIElement` app has no application menu.
/// Opening it programmatically means invoking a private selector whose name changed between
/// macOS 13 and 14. Owning the window outright is less code and cannot break under a
/// system update.
@MainActor
final class SettingsWindowController: NSWindowController {

    init(environment: AppEnvironment) {
        let hosting = NSHostingController(rootView: SettingsView(environment: environment))
        let window = NSWindow(contentViewController: hosting)

        window.title = "MenuDock"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 720, height: 460)
        // Without this, closing the window deallocates it and the next open crashes.
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        // Remembers position and size across launches, like any well-behaved Mac window.
        window.setFrameAutosaveName("MenuDockSettingsWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
