import AppKit
import Carbon.HIToolbox
import OSLog
import SwiftUI

/// The floating window the clipboard history is shown in.
///
/// Borderless, so the rounded card in ``ClipboardPanelView`` is the whole visible window rather
/// than something drawn inside a titled frame. `canBecomeKey` has to be overridden because AppKit
/// refuses key status to borderless windows by default, and a dropdown that cannot take the
/// keyboard cannot be searched or navigated.
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the clipboard dropdown: where it appears, what the keyboard does to it, and the
/// hold-⌘⇧-and-tap-V cycling gesture.
///
/// ## Why this activates MenuDock
///
/// The alternative is a non-activating panel, which keeps the user's app frontmost and looks
/// tidier — and cannot receive a single keystroke without Accessibility permission, because
/// reading keys destined for another app is exactly what that permission exists to gate. Search,
/// arrow keys and cycling would all be dead until the user had been to System Settings.
///
/// So the panel takes focus, and the app the user came from is remembered and reactivated on the
/// way out. The cost is one focus round trip; the gain is that every part of recall except the
/// final synthesised ⌘V works with no permission at all.
@MainActor
final class ClipboardPanelController {
    private let history: ClipboardHistoryStore
    private let permission: AccessibilityPermission
    private let model: ClipboardPanelModel

    private var panel: ClipboardPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// The app that was frontmost when the panel opened, so a chosen item lands where the user
    /// was actually working.
    private(set) var previousApp: NSRunningApplication?

    /// Settings in force, refreshed by the coordinator on every configuration change.
    var entry: ClipboardEntry = ClipboardEntry()

    /// Where the menu bar icon is, so the panel can drop from it even when opened by shortcut.
    var anchorProvider: (() -> NSRect?)?

    // MARK: Cycling state

    /// True between the first ⌘⇧V and the release of those modifiers. While it is set, letting go
    /// pastes — see ``checkModifiers()``.
    private var isCycling = false

    /// Polls the live modifier state while a cycle is in progress.
    private var modifierWatch: Timer?

    private static let width: CGFloat = 380
    /// Gap between the menu bar and the top of the panel.
    private static let anchorGap: CGFloat = 6

    /// The hold-and-release gesture can fail in ways that produce no output at all — a cycle
    /// cancelled before it commits reaches none of ``ClipboardPaster``'s logging, so "it works
    /// sometimes" had nothing to read. These record the two decisions that end a gesture.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuDock",
                             category: "ClipboardPanel")

    init(history: ClipboardHistoryStore, permission: AccessibilityPermission) {
        self.history = history
        self.permission = permission
        self.model = ClipboardPanelModel(history: history)

        model.onChoose = { [weak self] item in self?.choose(item) }
        model.onDelete = { [weak self] item in self?.delete(item) }
        model.onClose = { [weak self] in self?.close() }
        model.onLayoutChange = { [weak self] in self?.resizeToFit() }
    }

    isolated deinit {
        teardownMonitors()
    }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Presenting

    /// Opens the panel, or closes it if it is already up. What the menu bar icon does.
    func toggle(anchor: NSRect?) {
        if isVisible {
            close()
        } else {
            show(anchor: anchor, cycling: false)
        }
    }

    func show(anchor: NSRect?, cycling: Bool) {
        // Retention is otherwise only applied when something is captured, so a Mac left alone
        // over the weekend would open "keep for 1 hour" onto Friday's clipboard. Pruning on the
        // way in costs one date comparison per item and makes the setting mean what it says.
        history.prune(retention: entry.retention, maxItems: entry.maxItems)

        model.title = entry.effectiveTitle
        model.query = ""
        model.selection = 0
        model.isCycling = cycling
        model.clampSelection()

        // Captured before activating, or it would be MenuDock.
        //
        // MenuDock is also rejected explicitly, which is not belt-and-braces. Handing focus back
        // after a paste is asynchronous, so a second ⌘⇧V a moment later can arrive while this app
        // is *still* frontmost — and capturing ourselves then would aim the next paste at our own
        // panel, where it lands nowhere and reports success. Keeping the previous value is right
        // in that window: it is the app the user was in either way.
        if !isVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = frontmost
            }
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        position(panel, under: anchor ?? anchorProvider?())
        installMonitors()

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes without pasting. Clearing ``isCycling`` first is what makes Escape a genuine cancel:
    /// the modifier release that follows finds no cycle in progress and commits nothing.
    func close() {
        model.isCycling = false
        isCycling = false
        stopModifierWatch()
        teardownMonitors()
        panel?.orderOut(nil)
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        // Follows the user onto other Spaces and sits over fullscreen apps — a shortcut that
        // works everywhere except the app you are currently in fullscreen is not a shortcut.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // A real `NSVisualEffectView` rather than SwiftUI's `.regularMaterial`. In a borderless
        // transparent window the SwiftUI material has nothing behind it to sample and renders as
        // flat grey; the AppKit view blurs what is actually on screen behind the panel.
        let backdrop = NSVisualEffectView()
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 11
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        // Hairline border, which is what keeps the card legible against a light wallpaper.
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        let hosting = NSHostingView(rootView: ClipboardPanelView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])

        panel.contentView = backdrop
        return panel
    }

    // MARK: - Geometry

    /// Height for the current number of rows, so a two-item history is a small card rather than a
    /// tall one that is mostly empty.
    private var fittingHeight: CGFloat {
        let rows = model.results.count
        let chrome = ClipboardPanelView.searchHeight + ClipboardPanelView.footerHeight + 12
        guard rows > 0 else { return chrome + 118 }
        let visible = min(rows, ClipboardPanelView.maximumVisibleRows)
        return chrome + CGFloat(visible) * ClipboardPanelView.rowHeight
    }

    private func resizeToFit() {
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame
        let height = fittingHeight
        guard abs(frame.height - height) > 0.5 else { return }
        // Grows downward from a fixed top edge, so the panel stays pinned under the menu bar
        // instead of climbing over it as rows are filtered away.
        panel.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
            display: true,
            animate: false
        )
    }

    /// Drops the panel from the menu bar icon, clamped to stay on screen.
    private func position(_ panel: ClipboardPanel, under anchor: NSRect?) {
        let height = fittingHeight
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)

        // Centred under the icon is what reads as "this came from there". Without an anchor —
        // the shortcut pressed while the item is hidden in an overflowing menu bar — it falls
        // back to the top right, where the icon would have been.
        var x: CGFloat
        var top: CGFloat
        if let anchor {
            x = anchor.midX - Self.width / 2
            top = anchor.minY - Self.anchorGap
        } else {
            x = visible.maxX - Self.width - 12
            top = visible.maxY - Self.anchorGap
        }

        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        let bottom = max(top - height, visible.minY + 8)

        panel.setFrame(
            NSRect(x: x, y: bottom, width: Self.width, height: min(height, top - visible.minY - 8)),
            display: false
        )
    }

    // MARK: - Keyboard

    /// One local monitor handles every key the panel cares about.
    ///
    /// It has to be a monitor rather than SwiftUI key handling for one reason: the search field
    /// holds focus, so ↑/↓/⏎ would be consumed by the text field before any view could see them.
    /// A local monitor runs ahead of the responder chain, so returning `nil` for exactly the keys
    /// this panel owns leaves everything else — every character the user types — going to the
    /// field as normal.
    private func installMonitors() {
        guard keyMonitor == nil else { return }

        // `.keyDown` only. Modifier *releases* are deliberately not handled here — see
        // ``startModifierWatch()`` for why an event-based cycle end cannot be relied on.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self else { return event }
            // `assumeIsolated` cannot carry an `NSEvent` back out — the type is explicitly
            // non-Sendable — so the handler answers the one question that matters, *was this key
            // ours?*, and the event itself is returned from out here where it never crossed a
            // boundary.
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }

        // Clicking another app, or anywhere outside the panel, dismisses it — the behaviour every
        // menu on the system has.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // Never during a cycle. A hold is driven by the modifier watch, not by focus, and
                // `NSApp.activate()` is asynchronous — so the panel routinely loses and regains
                // key status while the activation it just asked for is still settling. Treating
                // that as "the user clicked away" cancelled the gesture *before it could commit*,
                // and did so through the one exit that logs nothing and pastes nothing: the user
                // let go and the panel had already quietly given up. Which activation lands first
                // is a race, which is what made it work sometimes and not others.
                guard !self.isCycling else {
                    self.log.info("""
                        Panel resigned key during a cycle — ignored, the gesture is still live.
                        """)
                    return
                }
                self.close()
            }
        }
    }

    private func teardownMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Returns whether this panel consumed the event. `false` lets it carry on to the search
    /// field, which is where every ordinary character belongs.
    private func handle(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }

        // ⌘1…⌘9 paste the numbered row outright. Checked before the named keys because the
        // digits are otherwise just characters bound for the search field.
        if event.modifierFlags.contains(.command),
           let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
           (1...9).contains(digit) {
            let results = model.results
            guard results.indices.contains(digit - 1) else { return true }
            choose(results[digit - 1])
            return true
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_DownArrow, kVK_Tab:
            model.move(by: 1)
        case kVK_UpArrow:
            model.move(by: -1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = model.selectedItem { choose(item) }
        case kVK_Delete where event.modifierFlags.contains(.command):
            // ⌘⌫ rather than plain ⌫, which belongs to the search field.
            if let item = model.selectedItem { delete(item) }
        default:
            return false
        }
        return true
    }

    // MARK: - Ending a cycle

    /// Watches the live modifier state for the end of a hold.
    ///
    /// ## Why this polls instead of listening for `flagsChanged`
    ///
    /// It used to listen, through the same local monitor that handles keys, and that was a race it
    /// lost in the worst direction. `NSApp.activate()` is **asynchronous**: on a quick tap the
    /// user's fingers leave ⌘⇧ before MenuDock is frontmost, so the key-up is delivered to the app
    /// they came from and this app never sees it. Nothing committed, and the panel just sat there.
    /// The faster you tapped — which is to say, the more ordinary your use of the shortcut — the
    /// less likely it was to work. It survived testing only because every scripted test held the
    /// modifiers for hundreds of milliseconds, which is exactly what a real hand does not do.
    ///
    /// `NSEvent.modifierFlags` is the live hardware state. It needs no event to be delivered
    /// anywhere, so it is correct whether or not this app ever became active, and a 30 ms tick is
    /// imperceptible next to the activation it is waiting on.
    private func startModifierWatch() {
        stopModifierWatch()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkModifiers() }
        }
        // `.common`, so the watch keeps ticking while the panel is being interacted with.
        RunLoop.main.add(timer, forMode: .common)
        modifierWatch = timer
        // Checked immediately as well: a tap fast enough to be over before the hot key was even
        // dispatched should paste, not wait 30 ms to notice.
        checkModifiers()
    }

    private func stopModifierWatch() {
        modifierWatch?.invalidate()
        modifierWatch = nil
    }

    /// Commits the selection once ⌘⇧ are no longer both held.
    ///
    /// ## Releasing always pastes, including on a bare tap
    ///
    /// This used to require the user to have navigated first — a single ⌘⇧V then release left the
    /// panel open to browse, on the reasoning that pasting row one is what ⌘V already does. That
    /// reasoning is wrong twice over. It is not always true: after recalling an older item the
    /// pasteboard holds *that*, while row one is still the newest thing copied, so the two
    /// genuinely differ. And it made the newest item the one entry the shortcut could not reach
    /// without cycling the whole list back around to it — the most useful row, hardest to get.
    ///
    /// So release commits, always, and the gesture is the one every Mac user already has in their
    /// hands from ⌘-Tab. Browsing did not disappear: clicking the icon opens the panel and leaves
    /// it open, and **Escape** during a hold cancels without pasting.
    private func checkModifiers() {
        guard isCycling else {
            stopModifierWatch()
            return
        }
        guard NSEvent.modifierFlags
            .intersection([.command, .shift]) != [.command, .shift] else { return }

        stopModifierWatch()
        isCycling = false
        model.isCycling = false

        guard let item = model.selectedItem else {
            // Nothing to commit — an empty history, or a filter matching no rows. Said out loud
            // because it is otherwise indistinguishable from a paste that failed.
            log.info("Modifiers released with no row selected; nothing was pasted.")
            close()
            return
        }
        log.info("Committing row \(self.model.selection, privacy: .public) on modifier release.")
        choose(item)
    }

    // MARK: - Shortcut

    /// Called on each press of the global shortcut.
    func handleShortcut() {
        if !isVisible {
            // Always opens *in* a cycle, on the newest item, with the watch already running.
            //
            // Whether the modifiers are still down is deliberately not consulted here. A tap
            // quick enough to be over before Carbon dispatched the hot key would look like "not
            // cycling" and leave the panel sitting open — which is the very complaint this
            // path exists to answer. Starting the cycle unconditionally and letting
            // ``checkModifiers()`` decide means a released-already tap commits on its first tick
            // instead of being misread as a request to browse.
            isCycling = true
            show(anchor: nil, cycling: true)
            startModifierWatch()
            return
        }

        if isCycling {
            model.move(by: 1)
            return
        }

        // Pressed again while browsing from a click: the shortcut is a toggle, like the icon.
        close()
    }

    // MARK: - Actions

    private func choose(_ item: ClipboardItem) {
        let target = previousApp
        let autoPaste = entry.pastesAutomatically
        close()

        guard history.writeToPasteboard(item) else {
            NSSound.beep()
            reportUnavailable(item)
            return
        }

        onWroteToPasteboard?()
        ClipboardPaster.deliver(to: target, autoPaste: autoPaste, permission: permission)
    }

    /// Set by the coordinator so a put-back is not immediately captured as a fresh copy.
    var onWroteToPasteboard: (() -> Void)?

    private func delete(_ item: ClipboardItem) {
        history.remove(id: item.id)
        model.clampSelection()
        resizeToFit()
    }

    /// Says why nothing was pasted, rather than leaving the previous clipboard contents to be
    /// pasted in its place — the failure that makes a clipboard manager untrustworthy.
    private func reportUnavailable(_ item: ClipboardItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "That item is no longer available."
        alert.informativeText = switch item.kind {
        case .files:
            "The files it points at have moved, been deleted, or are on a volume that is not "
                + "mounted. Nothing was copied."
        default:
            "Its contents could not be read from MenuDock's history. Nothing was copied."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
