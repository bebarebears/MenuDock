import AppKit
import Observation

/// Ties the clipboard feature to the configuration: what is recorded, whether the shortcut is
/// live, and where the dropdown appears.
///
/// ## One switch, in one place
///
/// Everything here is downstream of a single question — *is there a Clipboard item in the menu
/// bar, and what does it say?* Adding the item starts the pasteboard poll and registers ⌘⇧V;
/// removing it stops both, and every setting in between is applied by the same path. Putting that
/// decision in one object rather than spreading it across the monitor, the hot key and the panel
/// is what makes "MenuDock is not watching my clipboard" a claim with one place to check it.
///
/// Mirrors ``StatusItemCoordinator``'s push-based observation: nothing polls the configuration,
/// and an idle MenuDock with no Clipboard item runs no code from this subsystem at all.
@MainActor
final class ClipboardCoordinator {
    let history: ClipboardHistoryStore
    let monitor: ClipboardMonitor
    let panel: ClipboardPanelController

    /// Whether macOS will let MenuDock press ⌘V for the user. Owned here rather than reached for
    /// statically so the Settings pane can *observe* it: the answer changes while the app is
    /// running, and a pane that renders it once tells the user something that was true a minute
    /// ago. See ``AccessibilityPermission``.
    let permission = AccessibilityPermission()

    private let store: ConfigurationStore
    private let hotKey = GlobalHotKey()

    /// The settings last applied, so a configuration change that does not touch the Clipboard
    /// item does not re-register the shortcut or re-prune the history.
    private var applied: ClipboardEntry?

    init(store: ConfigurationStore, display: DisplayActivityMonitor) {
        self.store = store
        self.history = ClipboardHistoryStore()
        self.monitor = ClipboardMonitor(history: history, display: display)
        self.panel = ClipboardPanelController(history: history, permission: permission)

        hotKey.onPress = { [weak self] in self?.panel.handleShortcut() }
        // Putting a chosen item back changes the pasteboard, and without this the monitor would
        // file that as a brand new copy and reshuffle the list the user just picked from.
        panel.onWroteToPasteboard = { [weak self] in self?.monitor.ignoreCurrentContents() }

        apply()
        observe()
    }

    isolated deinit {
        hotKey.unregister()
    }

    // MARK: - Observation

    /// Re-arms itself after every change, exactly as ``StatusItemCoordinator/observe()`` does —
    /// `withObservationTracking` is one-shot, and its callback runs *before* the mutation lands.
    private func observe() {
        withObservationTracking {
            _ = store.configuration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply()
                self.observe()
            }
        }
    }

    private func apply() {
        let entry = store.configuration.clipboardItem?.clipboard
        guard entry != applied else { return }
        applied = entry

        monitor.configure(entry)
        panel.entry = entry ?? ClipboardEntry()

        if let entry {
            updateHotKey(enabled: entry.hotkeyEnabled)
        } else {
            updateHotKey(enabled: false)
            // The dropdown cannot outlive the item it belongs to — it would be a window with no
            // way to reach it and no icon to explain where it came from.
            panel.close()
        }
    }

    private func updateHotKey(enabled: Bool) {
        guard enabled else {
            hotKey.unregister()
            return
        }
        guard !hotKey.isRegistered else { return }
        if !hotKey.register(keyCode: GlobalHotKey.keyV, modifiers: GlobalHotKey.commandShift) {
            // Another app already owns ⌘⇧V. Said out loud in Settings rather than silently
            // ignored, so a shortcut that does nothing has a visible reason.
            hotKeyUnavailable = true
            return
        }
        hotKeyUnavailable = false
    }

    /// True when the system refused to register ⌘⇧V, which in practice means another app has it.
    private(set) var hotKeyUnavailable = false

    // MARK: - Presenting

    /// Opens or closes the dropdown. Called by the menu bar icon, with its own frame so the panel
    /// can drop from it.
    func toggle(anchor: NSRect?) {
        panel.toggle(anchor: anchor)
    }

    func show(anchor: NSRect?) {
        panel.show(anchor: anchor, cycling: false)
    }

    /// Registers where the Clipboard status item is, so the shortcut can drop the panel from the
    /// icon rather than from a corner of the screen. Weakly held by the controller's closure, so
    /// an item that goes away simply stops answering.
    func setAnchorProvider(_ provider: (() -> NSRect?)?) {
        panel.anchorProvider = provider
    }

    /// Flushes the history index. Called on quit alongside the configuration's own save.
    func saveNow() {
        history.saveNow()
    }
}
