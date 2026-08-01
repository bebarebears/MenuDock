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

    /// AppKit's own screen-fitting, declined.
    ///
    /// `constrainFrameRect(_:to:)` runs on every `setFrame` and every order-front, and its default
    /// implementation will move a window it considers badly placed — in particular one whose top
    /// edge is up against the menu bar, which is exactly where this panel is *supposed* to hang.
    /// ``ClipboardPanelController`` already clamps the panel to its screen deliberately, so the
    /// only thing AppKit's correction could do here is displace a frame that was already right.
    /// Returning the proposal untouched leaves the controller as the one thing that decides where
    /// this panel is.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
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

        model.prepare(title: entry.effectiveTitle, cycling: cycling)

        // Captured before activating, or it would be MenuDock.
        if !isVisible { captureCallingApp() }

        let panel = panel ?? makePanel()
        self.panel = panel

        position(panel, under: anchor ?? anchorProvider?())
        installMonitors()

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        lowerOtherWindows()
        // `NSApp.activate()` is asynchronous and does its own raising when it lands, so this runs
        // once more behind it.
        Task { @MainActor [weak self] in self?.lowerOtherWindows() }
    }

    /// Remembers the app to hand the chosen item back to.
    ///
    /// MenuDock is rejected explicitly, which is not belt-and-braces. Handing focus back after a
    /// paste is asynchronous, so a second ⌘⇧V a moment later can arrive while this app is *still*
    /// frontmost — and capturing ourselves then would aim the next paste at our own panel, where
    /// it lands nowhere and reports success. Keeping the previous value is right in that window:
    /// it is the app the user was in either way.
    ///
    /// Unless they are in *this* app for real. If one of MenuDock's own windows is key, the user
    /// is working in Settings, and the app remembered from some earlier paste is not where they
    /// are now — pressing ⌘V into it would drop the item into a window they are not looking at.
    /// Forgetting it means the item is copied and nothing else happens, which is the honest
    /// outcome when there is nowhere to paste.
    private func captureCallingApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            previousApp = frontmost
            return
        }
        if let key = NSApp.keyWindow, key !== panel {
            previousApp = nil
        }
    }

    /// Puts MenuDock's other windows back behind everything, after activation has yanked them up.
    ///
    /// Activating an app raises *all* of its windows, and AppKit offers no way to opt one out. For
    /// MenuDock that means the Settings window vaults over whatever the user was working in the
    /// moment they press ⌘⇧V — they asked for their clipboard and got a preferences pane in their
    /// face, on top of the very app the paste was meant for. It is also the reason the shortcut
    /// looked broken rather than merely untidy: what fills the screen is Settings, and the panel it
    /// is supposed to be showing is a strip under the menu bar above it.
    ///
    /// So the raise is undone — but only when there is another app to go back to. If the user
    /// pressed the shortcut while working *in* Settings, that window is the one they are using and
    /// sending it to the back would be its own bug.
    private func lowerOtherWindows() {
        guard previousApp != nil else { return }
        // `canBecomeMain` is what separates a window the user works in from the rest of what
        // `NSApp.windows` returns — which for this app is mostly status item windows, one per icon
        // in the menu bar. Reordering those is at best pointless and at worst a menu bar that
        // rearranges itself every time someone presses ⌘⇧V.
        for window in NSApp.windows
        where window.isVisible && window !== panel && window.canBecomeMain {
            window.order(.below, relativeTo: 0)
        }
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
        // Any size will do — ``position(_:under:)`` sets the real one before the panel is ever
        // shown — but it has to be a size, because the views below are laid out against it.
        let content = NSRect(x: 0, y: 0, width: Self.width, height: 300)
        let panel = ClipboardPanel(
            contentRect: content,
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
        // No appear/dismiss animation, for the same reason menus do not have one: this drops from
        // an icon the user just clicked and it should already be there. The fade also had a cost
        // beyond feel — an interrupted one leaves the window's layer stranded mid-transform, which
        // reads on screen as an empty translucent card sitting somewhere the panel never was.
        panel.animationBehavior = .none
        // Follows the user onto other Spaces and sits over fullscreen apps — a shortcut that
        // works everywhere except the app you are currently in fullscreen is not a shortcut.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // A real `NSVisualEffectView` rather than SwiftUI's `.regularMaterial`. In a borderless
        // transparent window the SwiftUI material has nothing behind it to sample and renders as
        // flat grey; the AppKit view blurs what is actually on screen behind the panel.
        let backdrop = NSVisualEffectView(frame: content)
        backdrop.autoresizingMask = [.width, .height]
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

        // Sized by the window, never the other way round.
        //
        // This used to be four Auto Layout constraints pinning the hosting view to the backdrop's
        // edges, and that is the bug that sent the panel off the top of the screen. A required
        // edge-to-edge pin lets the SwiftUI content's own ideal height — a list, so *every row*,
        // not the seven that fit — argue with the window's height, and Auto Layout settles it by
        // resizing the window. An AppKit window grows from its bottom-left origin, so the height
        // the list asked for went straight up: through the menu bar, off the screen, taking the
        // search field with it. And it stayed there, because from then on the panel was simply a
        // window of that size.
        //
        // Springs and struts have no such opinion, and `sizingOptions` is emptied so the hosting
        // view contributes no size constraints of its own either. ``fittingHeight`` is now the
        // only thing that decides how tall this panel is.
        let hosting = NSHostingView(rootView: ClipboardPanelView(model: model))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)

        panel.contentView = backdrop
        return panel
    }

    // MARK: - Geometry

    /// Where the panel hangs from, fixed for the life of one presentation.
    ///
    /// Every frame the panel is ever given is derived from this — both the first one and each
    /// resize as rows are filtered in and out.
    ///
    /// ## Why the panel does not measure itself
    ///
    /// It used to resize *around its own frame*, taking `panel.frame.maxY` as the top edge to keep
    /// pinned. That makes any one-off displacement permanent: a frame AppKit constrained to a
    /// screen, a Spaces switch, a display being unplugged, a hosting view briefly demanding more
    /// height than the window had. Whatever the panel's top edge became, the next resize adopted
    /// it as the truth and the one after that preserved it — so the panel would climb up out of
    /// the screen and *stay* there, with nothing but closing and reopening it to bring it back.
    ///
    /// An anchor cannot drift. Deriving each frame from it means a displacement, from any cause,
    /// survives exactly until the next keystroke.
    private struct Placement {
        /// Screen y of the panel's top edge — just under the menu bar.
        var top: CGFloat
        /// Screen x of its left edge, before clamping.
        var x: CGFloat
        /// The visible frame of the screen it must stay inside.
        var screen: NSRect
    }

    private var placement: Placement?

    /// Height for the current number of rows, so a two-item history is a small card rather than a
    /// tall one that is mostly empty.
    private var fittingHeight: CGFloat {
        let rows = model.results.count
        // The hint strip only exists during a hold-to-cycle, so it is only paid for then.
        let hints = model.isCycling ? ClipboardPanelView.hintBarHeight : 0
        let chrome = ClipboardPanelView.searchHeight + hints + 12
        guard rows > 0 else { return chrome + 118 }
        let visible = min(rows, ClipboardPanelView.maximumVisibleRows)
        return chrome + CGFloat(visible) * ClipboardPanelView.rowHeight
    }

    /// Resolves where the panel should hang, given the menu bar icon's frame if there is one.
    private func resolvePlacement(anchor: NSRect?) -> Placement {
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)

        // Centred under the icon is what reads as "this came from there". Without an anchor —
        // the shortcut pressed while the item is hidden in an overflowing menu bar — it falls
        // back to the top right, where the icon would have been.
        guard let anchor else {
            return Placement(top: visible.maxY - Self.anchorGap,
                             x: visible.maxX - Self.width - 12,
                             screen: visible)
        }
        // The top is clamped to the visible frame as well as offset from the icon. A status item
        // that is hidden in the overflow, or whose window has been torn down, reports a frame that
        // is somewhere else entirely — and an unclamped top taken from it is how the panel ended
        // up above the top of the screen in the first place.
        return Placement(top: min(anchor.minY - Self.anchorGap, visible.maxY),
                         x: anchor.midX - Self.width / 2,
                         screen: visible)
    }

    /// The frame for a given content height, clamped to the placement's screen.
    private func frame(for placement: Placement, height: CGFloat) -> NSRect {
        let screen = placement.screen
        let floor = screen.minY + 8
        // Never taller than the gap between the menu bar and the bottom of the screen, and never
        // so short there is nothing to look at.
        let height = min(height, max(placement.top - floor, ClipboardPanelView.searchHeight + 60))
        let rightmost = max(screen.maxX - Self.width - 8, screen.minX + 8)
        let x = min(max(placement.x, screen.minX + 8), rightmost)
        return NSRect(x: x, y: placement.top - height, width: Self.width, height: height)
    }

    private func resizeToFit() {
        guard let panel, panel.isVisible, let placement else { return }
        let target = frame(for: placement, height: fittingHeight)
        // Compared against the whole frame rather than just the height: if something has moved the
        // panel, this is the moment that gets noticed and undone.
        guard !target.equalTo(panel.frame) else { return }
        // Debug rather than info: where the panel ends up is the one thing a report of "it opened
        // off the top of the screen" needs and the one thing a screenshot of it cannot give, since
        // by the time anyone looks the panel has been closed and reopened. `make logs` shows it.
        log.debug("""
            resize \(NSStringFromRect(panel.frame), privacy: .public) \
            -> \(NSStringFromRect(target), privacy: .public)
            """)
        panel.setFrame(target, display: true, animate: false)
    }

    /// Drops the panel from the menu bar icon, clamped to stay on screen.
    private func position(_ panel: ClipboardPanel, under anchor: NSRect?) {
        let placement = resolvePlacement(anchor: anchor)
        self.placement = placement
        let target = frame(for: placement, height: fittingHeight)
        log.debug("""
            position anchor=\(anchor.map { NSStringFromRect($0) } ?? "nil", privacy: .public) \
            screen=\(NSStringFromRect(placement.screen), privacy: .public) \
            -> \(NSStringFromRect(target), privacy: .public)
            """)
        panel.setFrame(target, display: false)
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
        model.itemsChanged()
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
