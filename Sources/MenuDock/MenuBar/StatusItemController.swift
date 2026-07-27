import AppKit

/// Owns exactly one `NSStatusItem` and everything about its presentation and input.
///
/// ## Why the status item has no `menu`
///
/// Assigning `NSStatusItem.menu` is the easy path, and it makes the requested behaviour
/// impossible: AppKit then swallows the click to open the menu, and the button's `action`
/// never fires. There is no left-click-does-something-else with a `menu` attached.
///
/// So the button keeps a plain target/action, widened to fire on right-clicks too via
/// `sendAction(on:)`, and this class decides what each click means. When a menu genuinely
/// needs to appear, it is attached, clicked, and detached again — see ``present(_:)``.
final class StatusItemController {
    let id: DockItem.ID

    private let statusItem: NSStatusItem
    private let icons: IconLibrary
    private let running: RunningAppsMonitor
    private let animator: IconAnimator
    private let menus: MenuBuilder

    private var item: DockItem
    private var preferences: Configuration.Preferences
    private var isSubscribedToAnimation = false
    /// Last animation frame actually pushed to the button, so ``animationTick()`` can skip
    /// redundant redraws.
    private var lastRenderedFrame: Int?

    init(
        item: DockItem,
        preferences: Configuration.Preferences,
        icons: IconLibrary,
        running: RunningAppsMonitor,
        animator: IconAnimator,
        menus: MenuBuilder
    ) {
        self.id = item.id
        self.item = item
        self.preferences = preferences
        self.icons = icons
        self.running = running
        self.animator = animator
        self.menus = menus

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Deliberately no `autosaveName`.
        //
        // It persists a position per item, which then outranks creation order — so the list in
        // Settings would say one thing and the menu bar would keep showing another, forever.
        // The list is the ordering control, so position is derived from it on every launch
        // rather than remembered separately. The cost is that Cmd-dragging one of these icons
        // does not stick across relaunches; the gain is that what you arrange is what you get.

        configureButton()
        updateAnimationSubscription()
        refresh()
    }

    /// `isolated` so the status item — main-actor-only, and not `Sendable` — can be removed
    /// here. Without it the icon would linger in the menu bar after its model entry is gone.
    isolated deinit {
        animator.unsubscribe(id)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        // Without this the button only reports left-clicks, and right-click routes to the
        // (absent) menu instead of to us.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
    }

    // MARK: - State

    /// Re-applies model and preference state. Called by the coordinator instead of
    /// destroying and recreating the status item, which would lose its menu bar position.
    func update(item: DockItem, preferences: Configuration.Preferences) {
        self.item = item
        self.preferences = preferences
        updateAnimationSubscription()
        refresh()
    }

    /// Subscribes to the shared animation timer only while this item's icon actually animates,
    /// so a menu bar full of static icons never starts the timer at all.
    private func updateAnimationSubscription() {
        let wantsAnimation = icons.builtinIcon(for: item.icon)?.isAnimated == true
        guard wantsAnimation != isSubscribedToAnimation else { return }
        isSubscribedToAnimation = wantsAnimation

        if wantsAnimation {
            animator.subscribe(id) { [weak self] in self?.animationTick() }
        } else {
            animator.unsubscribe(id)
            lastRenderedFrame = nil
        }
    }

    /// Per-tick callback. Redraws only when the *quantised* frame actually changed.
    ///
    /// The timer necessarily ticks faster than the animation has distinct frames, so without
    /// this roughly a third of ticks would reassign an identical image — and each assignment
    /// makes AppKit recomposite the menu bar, which is the entire cost of animating. Comparing
    /// one integer first is free and removes those redraws outright.
    private func animationTick() {
        guard let icon = icons.builtinIcon(for: item.icon), icon.isAnimated else { return }
        let frame = Int(BuiltinIconCatalog.phase(for: icon) * Double(BuiltinIconCatalog.frameCount))
        guard frame != lastRenderedFrame else { return }
        refresh()
    }

    /// Redraws the icon for the current running state. Cheap — ``IconLibrary`` caches on
    /// every input that affects the result, so a no-op refresh is a dictionary lookup.
    func refresh() {
        guard let button = statusItem.button else { return }

        let app = primaryApp
        let isRunning = app.map { running.isRunning($0.bundleIdentifier) } ?? anyMemberRunning

        // Phase comes from absolute time, so every status item showing the same animated icon
        // stays in lockstep and no per-item animation state has to be kept.
        let phase = icons.builtinIcon(for: item.icon).map { icon in
            animator.isAnimating ? BuiltinIconCatalog.phase(for: icon) : 0
        } ?? 0
        lastRenderedFrame = Int(phase * Double(BuiltinIconCatalog.frameCount))

        button.image = icons.image(
            for: item.icon,
            app: app,
            size: preferences.iconSize,
            running: isRunning,
            showsIndicator: preferences.showRunningIndicator,
            phase: phase
        )

        let title = item.displayTitle
        button.toolTip = isRunning ? "\(title) — Running" : title
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(isRunning ? "Running" : "Not running")
    }

    private var primaryApp: AppReference? {
        if case .application(let entry) = item.kind { return entry.app }
        return nil
    }

    private var anyMemberRunning: Bool {
        guard case .group(let group) = item.kind else { return false }
        return group.members.contains { running.isRunning($0.app.bundleIdentifier) }
    }

    // MARK: - Input

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        // Control-click is the trackpad-friendly synonym for right-click and arrives as a
        // left-click with a modifier, so both have to be checked.
        let wantsContextMenu = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)

        switch item.kind {
        case .application(let entry):
            if wantsContextMenu {
                present(menus.contextMenu(for: entry, itemID: id))
            } else {
                // The whole point of the app: one click, correct behaviour, no menu.
                AppLauncher.open(entry.app)
            }

        case .group(let group):
            if wantsContextMenu {
                present(menus.contextMenu(for: group, itemID: id))
            } else {
                present(menus.groupMenu(for: group, itemID: id))
            }
        }
    }

    /// Shows a menu *and* keeps the status item drawn in its highlighted state.
    ///
    /// `NSMenu.popUp(positioning:at:in:)` would also work but leaves the button un-highlighted,
    /// which reads as broken next to every system menu extra. Attaching the menu and
    /// synthesising a click gives the native appearance; `performClick` blocks for the
    /// duration of menu tracking, so detaching immediately afterwards is safe and restores
    /// plain-click routing to `handleClick`.
    private func present(_ menu: NSMenu) {
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        statusItem.button?.performClick(nil)
    }
}
