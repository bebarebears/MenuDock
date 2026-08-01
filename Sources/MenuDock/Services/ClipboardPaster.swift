import AppKit
import ApplicationServices
// For `IsSecureEventInputEnabled`, which has no Swift-era replacement.
import Carbon.HIToolbox
import OSLog

/// Puts a chosen item back where the user was working.
///
/// ## The permission line, and why the feature does not sit on top of it
///
/// macOS will not let one app synthesise keystrokes for another without Accessibility permission,
/// and there is no way around that — nor should there be. So the recall flow is built in two
/// halves:
///
/// - **Always:** the item goes on the pasteboard and focus returns to the app the user came from.
///   They press ⌘V. This needs no permission whatsoever and is the whole feature minus one
///   keystroke.
/// - **With permission:** that final ⌘V is sent too.
///
/// Building it the other way round — gating recall on the permission — would mean a clipboard
/// history that does nothing at all until the user has been sent to System Settings, which is a
/// poor trade for saving them one keypress.
///
/// ## Saying so when the keystroke does not go
///
/// The half that needs permission fails invisibly by nature: nothing appears in the target app,
/// which is also what "I picked the wrong row" looks like. It used to fail *silently* as well —
/// one log line, and a system prompt that is a no-op whenever a row for MenuDock already exists in
/// the Accessibility list. A user whose grant had gone stale (see ``AccessibilityPermission``) was
/// therefore shown a switch that was on, a button that did nothing, and a feature that did nothing.
/// So a refusal now explains itself, once per launch, and says which of the two refusals it is.
@MainActor
enum ClipboardPaster {

    /// Whether the explanation below has already been shown this launch. Once is the right number:
    /// the user needs telling, and needs telling once.
    private static var hasExplained = false

    /// Why a paste did not happen.
    ///
    /// Auto-paste fails in three ways that look identical from the outside — nothing appears in
    /// the target app — and only one of them is a bug. Without a record, telling "permission was
    /// revoked" apart from "the app never took focus" means guessing. `make logs` shows these.
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuDock",
                                    category: "ClipboardPaste")

    // MARK: - Delivery

    /// Returns focus to `app`, then optionally sends ⌘V.
    ///
    /// The caller has already put the payload on the pasteboard — this is only the handover.
    ///
    /// - Parameters:
    ///   - app: the application that was frontmost when the panel opened. `nil` means MenuDock
    ///     was already frontmost or the app has since quit, in which case there is nothing to
    ///     return to and nothing to paste into.
    ///   - autoPaste: the user's preference. Ignored when the permission is not granted.
    ///   - permission: the live trust state, re-read here rather than trusted from a cache.
    static func deliver(to app: NSRunningApplication?,
                        autoPaste: Bool,
                        permission: AccessibilityPermission) {
        guard let app, !app.isTerminated else {
            log.info("No app to return to; item is on the pasteboard only.")
            return
        }

        let name = app.localizedName ?? "the previous app"

        // Cooperative activation, macOS 14's answer to exactly this handover. Saying "I am giving
        // my active status to that app" is what makes the request authoritative; a bare
        // `activate()` competes with MenuDock's own still-settling `NSApp.activate()` from opening
        // the panel, and which one lands last is a race the paste loses about as often as it wins.
        NSApp.yieldActivation(to: app)
        app.activate()

        guard autoPaste else {
            log.info("Auto-paste is off; returned focus to \(name, privacy: .public).")
            return
        }

        // Read live: the user can revoke Accessibility in System Settings while the app is
        // running, and a cached `true` would turn auto-paste into a silently dead keystroke.
        guard permission.refresh() else {
            log.error("""
                Accessibility permission is not in force, so ⌘V cannot be sent to \
                \(name, privacy: .public). The item is on the pasteboard — press ⌘V.
                """)
            explainOnce(permission, returningTo: app)
            return
        }

        Task { @MainActor in
            // The keystroke has to arrive *after* the target app is frontmost, and activation is
            // asynchronous. A fixed delay is the usual shortcut and it is wrong in both
            // directions — too short on a loaded machine, needlessly laggy on an idle one — so
            // this waits for the activation it asked for and gives up rather than firing blind.
            guard await waitForFrontmost(app) else {
                // Deliberately does *not* paste anyway. Posting ⌘V while something else is
                // frontmost would paste into whatever that is, which is worse than not pasting.
                log.error("""
                    \(name, privacy: .public) did not come to the front, so ⌘V was not sent. \
                    The item is on the pasteboard.
                    """)
                return
            }

            // Secure input is the one refusal that survives every permission: while it is on — a
            // password field has focus somewhere, or a terminal has asked for it and not given it
            // back — the window server discards synthesised keystrokes outright. Accessibility is
            // granted, the post succeeds, and nothing happens. Worth naming, because the remedy is
            // in a different app entirely.
            if IsSecureEventInputEnabled() {
                log.error("""
                    Secure input is enabled, so macOS discards synthesised keystrokes and ⌘V \
                    could not reach \(name, privacy: .public). Some app has a password field \
                    focused — click into an ordinary text field and try again. The item is on \
                    the pasteboard.
                    """)
                return
            }

            sendCommandV()
            // Info rather than debug: this is the one line saying the feature worked end to end,
            // and debug messages are not persisted, so `make logs` after the fact showed every
            // failure and no successes — which made "it works sometimes" impossible to read.
            log.info("Sent ⌘V to \(name, privacy: .public).")
        }
    }

    // MARK: - Explaining

    /// Tells the user why nothing was pasted, at the one moment it is obviously relevant — they
    /// have just picked something expecting it to land, and it did not.
    ///
    /// ## Why this is an alert and not the system prompt
    ///
    /// Raising `AXIsProcessTrustedWithOptions` here was the obvious thing and it is the wrong one.
    /// macOS shows that dialog **only when it has no row for the app at all**, so it does nothing
    /// in every case where the user has already been to System Settings once: a grant they
    /// switched off, a prompt they dismissed, or — the case that prompted this — a grant that has
    /// gone stale because the app was rebuilt. Those are the majority of real refusals, and in all
    /// of them the user gets a feature that quietly does nothing and a system that agrees it is
    /// permitted. An alert always appears, always says something true, and can carry the remedy.
    ///
    /// The prompt still exists where a prompt belongs: behind *Grant Permission…* in Settings,
    /// where the user has asked for it and a dialog is what they are expecting.
    ///
    /// Focus is handed back to `app` afterwards, so the pasteboard fallback the alert mentions is
    /// one keystroke away rather than behind a window the user has to dismiss twice.
    private static func explainOnce(_ permission: AccessibilityPermission,
                                    returningTo app: NSRunningApplication) {
        guard !hasExplained else { return }
        hasExplained = true

        let alert = NSAlert()
        alert.alertStyle = .warning

        if permission.denial == .grantedToAnotherBuild {
            alert.messageText = "MenuDock's Accessibility permission is out of date."
            alert.informativeText = """
                macOS ties this permission to the exact copy of an app it was granted to, so \
                updating or rebuilding MenuDock invalidates it — the switch in Privacy & Security \
                › Accessibility still looks on, but it no longer applies.

                Remove MenuDock from that list with the – button and add it back with +. Switching \
                it off and on again works too.

                Until then, choosing an item still copies it: press ⌘V yourself.
                """
        } else {
            alert.messageText = "MenuDock cannot paste for you yet."
            alert.informativeText = """
                Pressing ⌘V in another app needs Accessibility permission, which macOS has not \
                granted MenuDock.

                Add MenuDock in Privacy & Security › Accessibility. If it is already listed and \
                switched on, the entry belongs to an earlier build — switch it off and on again, \
                or remove it with – and add it back.

                Everything else works without this: choosing an item copies it and returns you to \
                your app, and you press ⌘V.
                """
        }

        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { permission.openSystemSettings() }
        app.activate()
    }

    // MARK: - Sending

    /// Polls until `app` is frontmost, up to a short ceiling. Returns whether it got there.
    private static func waitForFrontmost(_ app: NSRunningApplication) async -> Bool {
        // 20 × 20 ms. Activation normally completes in one or two of these; the ceiling exists
        // for the case where the app is showing a modal sheet and will never take focus.
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Synthesises ⌘V into whatever is frontmost.
    private static func sendCommandV() {
        // `.combinedSessionState` rather than `.hidSystemState`: the event is injected into the
        // session's event stream, which is what an app's own key handling reads.
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let key = CGKeyCode(GlobalHotKey.keyV)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        // Flags are set explicitly rather than left to inherit. If the user is still holding the
        // recall shortcut's ⇧, an inherited flag set would deliver ⌘⇧V — "Paste and Match Style"
        // in most apps, and something else entirely in a few. Stating exactly ⌘ makes the paste
        // mean the same thing regardless of what is physically held down.
        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
