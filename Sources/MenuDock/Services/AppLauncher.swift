import AppKit
import OSLog

/// Every way MenuDock can act on another application.
///
/// ## Why a single `open` path instead of "check running, then branch"
///
/// The obvious implementation of Dock behaviour is:
///
/// ```swift
/// if let running = app.runningInstances.first { running.activate() } else { launch() }
/// ```
///
/// That is subtly wrong in the case users notice most: an app that is *running with no
/// windows* (Safari with every window closed, still in the Dock). `activate()` brings the
/// process forward and the user stares at a menu bar with no window. The real Dock sends the
/// app a **reopen** Apple Event (`kAEReopenApplication`), which is what makes Safari create a
/// fresh window.
///
/// `NSWorkspace.openApplication(at:configuration:)` does all of this in one call:
/// it launches if the app is not running, activates it if it is, and sends reopen either way —
/// without `createsNewApplicationInstance` it will never spawn a duplicate process. So the
/// primary click is one code path with genuine Dock semantics, and the running-state check
/// is reserved for what it is actually good for: menu contents and the indicator dot.
enum AppLauncher {
    /// `nonisolated` because `openApplication`'s completion handler is a `@Sendable` closure
    /// that runs off the main actor. `Logger` is itself `Sendable`, so this is safe.
    private nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuDock",
                                                category: "AppLauncher")

    // MARK: - Primary action

    /// The left-click action: launch if closed, bring to front if open, open a window if
    /// running window-less. Mirrors clicking a Dock tile.
    static func open(_ reference: AppReference) {
        guard let url = reference.resolvedURL else {
            presentMissingApplication(reference)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        // Left at the default `false`: this is what guarantees we reuse a running instance
        // rather than launching a second copy.
        configuration.createsNewApplicationInstance = false

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                log.error("Failed to open \(reference.bundleIdentifier): \(error.localizedDescription)")
            }
        }
    }

    /// Explicitly starts a second copy (`open -n`). Exposed as an Option-click alternate.
    static func openNewInstance(_ reference: AppReference) {
        guard let url = reference.resolvedURL else {
            presentMissingApplication(reference)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    // MARK: - Running-app actions

    /// Brings an already-running app forward *without* the reopen event, so no new window
    /// appears. Used by group menus where the user picked a specific running app.
    static func activate(_ reference: AppReference) {
        guard let running = reference.runningInstances.first else {
            open(reference)
            return
        }
        activate(running)
    }

    static func activate(_ application: NSRunningApplication) {
        // `.activateIgnoringOtherApps` was deprecated in macOS 14 in favour of cooperative
        // activation; `.activateAllWindows` remains the correct way to ask for every window
        // of the target to come forward, matching Dock behaviour.
        application.activate(options: [.activateAllWindows])
    }

    static func hide(_ reference: AppReference) {
        for instance in reference.runningInstances {
            instance.hide()
        }
    }

    static func unhide(_ reference: AppReference) {
        for instance in reference.runningInstances {
            instance.unhide()
        }
    }

    /// Politely asks the app to quit (it may present "unsaved changes" sheets).
    /// `force` escalates to `SIGKILL`-equivalent termination, matching Force Quit.
    static func quit(_ reference: AppReference, force: Bool = false) {
        for instance in reference.runningInstances {
            if force {
                instance.forceTerminate()
            } else {
                instance.terminate()
            }
        }
    }

    static func revealInFinder(_ reference: AppReference) {
        guard let url = reference.resolvedURL else {
            presentMissingApplication(reference)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Errors

    /// The app was uninstalled or moved somewhere we cannot resolve. Because MenuDock has no
    /// Dock tile or window, a silent failure would look like a broken click — so we surface
    /// an alert and offer to remove the dead entry's source of truth.
    private static func presentMissingApplication(_ reference: AppReference) {
        log.error("Could not resolve \(reference.bundleIdentifier)")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(reference.name)” could not be found."
        alert.informativeText = """
            The application may have been moved, renamed, or uninstalled.

            Last known location:
            \(reference.lastKnownPath)
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open MenuDock Settings…")

        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NotificationCenter.default.post(name: .menuDockShouldOpenSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let menuDockShouldOpenSettings = Notification.Name("MenuDockShouldOpenSettings")
}
