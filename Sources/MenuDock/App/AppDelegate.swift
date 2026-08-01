import AppKit

/// Entry point.
///
/// There is no `SwiftUI.App` here on purpose. SwiftUI's `MenuBarExtra` manages exactly one
/// status item, and this app's premise is N of them, created and destroyed at runtime — so
/// the menu bar is AppKit's job. SwiftUI is used where it is strongest: the settings window's
/// content, hosted inside a plain `NSWindow`.
@main
enum MenuDockMain {
    /// Held for the process lifetime; `NSApplication.delegate` does not retain.
    static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        // `.accessory` matches `LSUIElement`: no Dock tile, no global menu bar, but — unlike
        // `.prohibited` — windows can still become key, which the settings window needs.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var coordinator: StatusItemCoordinator?
    private var settingsWindow: SettingsWindowController?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        self.environment = environment

        self.coordinator = StatusItemCoordinator(
            store: environment.store,
            icons: environment.icons,
            running: environment.running,
            animator: environment.animator,
            metrics: environment.metrics,
            clipboard: environment.clipboard,
            openSettings: { [weak self] in self?.showSettings() }
        )

        // `AppLauncher` posts this when it hits an app it cannot resolve and the user asks
        // to go fix it — a notification keeps the launcher free of any UI dependency.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .menuDockShouldOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }

        // First run leaves an empty menu bar. With no Dock tile and no window there is
        // literally nothing to click, so open Settings rather than appearing to do nothing.
        if environment.store.configuration.items.isEmpty {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any debounced edit that has not hit disk yet.
        environment?.store.saveNow()
        environment?.clipboard.saveNow()
    }

    /// Re-opening the app from Finder or `open -a` should surface Settings, since that is the
    /// only window this app has.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        guard let environment else { return }

        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(environment: environment)
        }
        environment.installedApps.refresh()

        NSApp.activate()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
}
