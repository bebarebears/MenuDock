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

    // MARK: - Animation state
    //
    // Everything the per-frame path needs, resolved once when the model changes rather than
    // recomputed on every tick. The tick itself does no lookups beyond a cached frame fetch.

    /// The animated glyph this item is currently showing, or `nil` if its icon is static.
    private var animatedIcon: BuiltinIcon?
    /// Point size the icon is being drawn at, with this item's override already applied.
    private var renderedSize: Double = 0
    /// Whether the running indicator is part of the rendered frame.
    private var showsRunningDot = false
    /// Last animation frame actually pushed to the button, so a tick that resolves to the same
    /// frame can return without touching AppKit at all.
    private var lastRenderedFrame: Int?

    /// Presents animated frames without redrawing the status item's view. See ``GlyphLayer``.
    private let glyph = GlyphLayer()

    /// True while this item's menu is being tracked, so the glyph layer knows to invert.
    private var isPresentingMenu = false

    /// Tooltip and accessibility strings already installed on the button.
    ///
    /// Cached purely so the animation path can skip them. They used to be reassigned on every
    /// frame, which meant a 12fps timer pushing identical strings into the accessibility system
    /// all day for no observable effect.
    private var installedTitle: String?
    private var installedRunningState: Bool?

    /// Set once this item's status item has been *seen* on screen.
    ///
    /// Occlusion is only trusted after that. If `occlusionState` never reports `.visible` for
    /// status item windows on some future macOS, the icon keeps animating exactly as before
    /// instead of silently freezing — an optimisation that can break the feature it optimises is
    /// not worth having.
    private var hasEverBeenVisible = false
    private var occlusionObserver: NSObjectProtocol?

    // MARK: - Click reaction

    /// Absolute time when the current one-shot reaction ends, or `nil`.
    ///
    /// Set by ``triggerReaction()`` on click; cleared when the reaction completes. While
    /// active the icon receives a phase in the 1…2 range instead of the normal 0…1 idle
    /// cycle, so the drawing closure can show a distinct reaction animation.
    private var reactionUntil: TimeInterval?
    /// How long the reaction lasts. Long enough to read as deliberate, short enough to not
    /// feel sluggish when the user clicks several times in a row.
    private static let reactionDuration: TimeInterval = 0.65

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
        // does not stick across relaunches; the gain is what you arrange is what you get.

        configureButton()
        resolveRenderState()
        updateAnimationSubscription()
        observeOcclusion()
        refresh()
    }

    /// `isolated` so the status item — main-actor-only, and not `Sendable` — can be removed
    /// here. Without it the icon would linger in the menu bar after its model entry is gone.
    isolated deinit {
        animator.unsubscribe(id)
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
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
        glyph.attach(to: button)
    }

    // MARK: - State

    /// Re-applies model and preference state. Called by the coordinator instead of
    /// destroying and recreating the status item, which would lose its menu bar position.
    func update(item: DockItem, preferences: Configuration.Preferences) {
        self.item = item
        self.preferences = preferences
        resolveRenderState()
        updateAnimationSubscription()
        applyImage()
        updateLabels()
    }

    /// Recomputes the handful of values the per-frame path reads, and drops the frame cursor if
    /// any of them changed — a resized or re-skinned icon must not keep showing frames rendered
    /// for the old one.
    private func resolveRenderState() {
        let icon = icons.builtinIcon(for: item.icon)
        let animated = icon?.isAnimated == true ? icon : nil
        let size = item.resolvedIconSize(default: preferences.iconSize)
        let dot = preferences.showRunningIndicator && isRunning

        if animated?.id != animatedIcon?.id || size != renderedSize || dot != showsRunningDot {
            lastRenderedFrame = nil
        }

        animatedIcon = animated
        renderedSize = size
        showsRunningDot = dot
    }

    /// Subscribes to the shared animation timer only while this item's icon actually animates,
    /// so a menu bar full of static icons never starts the timer at all.
    private func updateAnimationSubscription() {
        let wantsAnimation = animatedIcon != nil
        guard wantsAnimation != isSubscribedToAnimation else { return }
        isSubscribedToAnimation = wantsAnimation

        if wantsAnimation {
            animator.subscribe(id) { [weak self] now in self?.animationTick(at: now) }
            reportVisibility()
        } else {
            animator.unsubscribe(id)
            lastRenderedFrame = nil
        }
    }

    // MARK: - Visibility

    /// Watches for the menu bar going away — a fullscreen app, or auto-hide — so the animator
    /// can stop the timer while there is nothing to look at.
    private func observeOcclusion() {
        // Observed unfiltered rather than scoped to our own window: the status item's window may
        // not exist yet at init, and occlusion changes are rare enough that re-checking one
        // boolean on each is cheaper than the bookkeeping to attach late.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportVisibility() }
        }
    }

    private func reportVisibility() {
        guard isSubscribedToAnimation else { return }

        guard let window = statusItem.button?.window else {
            animator.setVisible(id, isVisible: true)
            return
        }

        if window.occlusionState.contains(.visible) {
            hasEverBeenVisible = true
            animator.setVisible(id, isVisible: true)
        } else {
            animator.setVisible(id, isVisible: !hasEverBeenVisible)
        }
    }

    // MARK: - Drawing

    /// Per-tick callback. The whole hot path of animating a menu bar icon.
    ///
    /// Draws only when the *quantised* frame actually changed. The timer necessarily ticks faster
    /// than some icons have distinct frames, so without this a share of ticks would push an
    /// identical image at the compositor. Comparing one integer first is free.
    ///
    /// Note what is *not* here: no model lookup, no running-state query, no tooltip, no
    /// accessibility strings, no `Date` call, and no rendering — the frame comes from
    /// ``BuiltinIconCatalog``'s cache. Those belong to ``refresh()``, which runs when something
    /// actually changed.
    private func animationTick(at now: TimeInterval) {
        guard let icon = animatedIcon else { return }

        let frame = BuiltinIconCatalog.frameIndex(for: phase(for: icon, at: now))
        guard frame != lastRenderedFrame else { return }
        lastRenderedFrame = frame

        showAnimatedFrame(icon: icon, index: frame)
    }

    /// Hands one cached frame to the glyph layer. See ``GlyphLayer`` for why animation does not
    /// go through `button.image`.
    private func showAnimatedFrame(icon: BuiltinIcon, index: Int) {
        glyph.show(
            BuiltinIconCatalog.frame(
                icon: icon,
                size: renderedSize,
                showsRunningDot: showsRunningDot,
                index: index
            ),
            size: renderedSize,
            isHighlighted: isPresentingMenu
        )
    }

    /// Redraws the icon and refreshes everything around it — tooltip, accessibility, running
    /// state. Cheap, but not free, which is why the animation path does not come through here.
    func refresh() {
        resolveRenderState()
        // The system appearance may have changed since the last frame; the glyph layer tints
        // itself, so it has to be told.
        glyph.invalidateTint()
        applyImage()
        updateLabels()
    }

    /// Draws the current frame for the current state.
    private func applyImage() {
        guard let button = statusItem.button else { return }

        if let icon = animatedIcon {
            let frame = BuiltinIconCatalog.frameIndex(
                for: phase(for: icon, at: Date.timeIntervalSinceReferenceDate)
            )
            lastRenderedFrame = frame
            showAnimatedFrame(icon: icon, index: frame)
        } else {
            lastRenderedFrame = nil
            // Static icons keep AppKit's own template rendering, where the cost is paid once.
            if glyph.isActive { glyph.clear() }
            button.image = icons.image(
                for: item.icon,
                app: primaryApp,
                size: renderedSize,
                running: isRunning,
                showsIndicator: preferences.showRunningIndicator
            )
        }
    }

    /// The phase to draw at: the shared idle cycle, or the one-shot reaction if one is playing.
    ///
    /// Checking the animator first is what guarantees an icon settles on its rest frame. Without
    /// it, a click landing just before the timer stops — screens sleeping, Reduce Motion being
    /// switched on — would leave the glyph frozen partway through its reaction.
    private func phase(for icon: BuiltinIcon, at now: TimeInterval) -> Double {
        guard animator.isAnimating else {
            reactionUntil = nil
            return 0
        }

        if let reactionEnd = reactionUntil {
            if now < reactionEnd {
                let elapsed = Self.reactionDuration - (reactionEnd - now)
                // Phase 1.0…2.0 signals "reaction" to the drawing closure.
                return 1.0 + min(elapsed / Self.reactionDuration, 1.0)
            }
            reactionUntil = nil
        }

        return BuiltinIconCatalog.phase(for: icon, at: now)
    }

    /// Tooltip and accessibility, written only when they would actually change.
    private func updateLabels() {
        guard let button = statusItem.button else { return }

        let title = item.displayTitle
        let isRunning = self.isRunning
        guard title != installedTitle || isRunning != installedRunningState else { return }

        installedTitle = title
        installedRunningState = isRunning

        button.toolTip = tooltip(title: title, isRunning: isRunning)
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(isRunning ? "Running" : "Not running")
    }

    private func tooltip(title: String, isRunning: Bool) -> String {
        switch item.kind {
        case .application, .group:
            return isRunning ? "\(title) — Running" : title
        case .folder(let entry):
            // A folder item's one useful extra fact is *where* it points, which the name often
            // hides — three different "src" folders look identical in a menu bar.
            guard entry.folders.count == 1 else {
                return entry.folders.isEmpty ? title : "\(title) — \(entry.folders.count) folders"
            }
            let path = entry.folders[0].displayPath
            return path == title ? title : "\(title) — \(path)"
        }
    }

    // MARK: - Model queries

    private var primaryApp: AppReference? {
        if case .application(let entry) = item.kind { return entry.app }
        return nil
    }

    /// Whether this item should read as "running": the app itself, or any member of a group.
    /// Folders have no such state.
    private var isRunning: Bool {
        switch item.kind {
        case .application(let entry):
            return running.isRunning(entry.app.bundleIdentifier)
        case .group(let group):
            return group.members.contains { running.isRunning($0.app.bundleIdentifier) }
        case .folder:
            return false
        }
    }

    // MARK: - Reaction

    /// Fires a one-shot reaction animation on the current icon, if it supports one.
    ///
    /// The icon's drawing closure receives a phase in the 1…2 range for the duration of the
    /// reaction; afterwards it returns to the normal idle cycle.
    ///
    /// Requires the animator to be running, and not only as an optimisation: with the timer
    /// stopped there is nothing to advance the reaction, so the icon would draw one frame of it
    /// and sit there. Reduce Motion means *no* motion, not one frame of it.
    func triggerReaction() {
        guard animatedIcon != nil, animator.isAnimating else { return }

        reactionUntil = Date.timeIntervalSinceReferenceDate + Self.reactionDuration
        applyImage()
    }

    // MARK: - Input

    @objc private func handleClick() {
        // No current event means this arrived from accessibility — VoiceOver, Switch Control, or
        // `AXUIElementPerformAction`. Bailing out (as this used to) makes the item dead to every
        // assistive technology on the system, so a missing event is treated as a plain click,
        // which is what those callers mean.
        let event = NSApp.currentEvent

        // Control-click is the trackpad-friendly synonym for right-click and arrives as a
        // left-click with a modifier, so both have to be checked.
        let wantsContextMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        // Fire a reaction animation on every click — left or right — so the icon always
        // acknowledges the interaction. Purely cosmetic; the drawing closure decides what
        // "reaction" means (the dog perks up, a pulse icon might flash, etc.).
        triggerReaction()

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

        case .folder(let entry):
            if wantsContextMenu {
                present(menus.contextMenu(for: entry, itemID: id))
            } else if entry.folders.count == 1 || entry.opensAllAtOnce {
                // One folder — or an explicit "open them all" — needs no menu, so the click
                // does the thing directly, exactly like an app item.
                for folder in entry.folders { AppLauncher.openFolder(folder) }
            } else {
                present(menus.folderMenu(for: entry, itemID: id))
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
        // The glyph layer does its own template tinting, so it has to be told about the
        // highlighted state AppKit would otherwise have inverted for us. `performClick` blocks
        // for the duration of menu tracking, so this brackets exactly the highlighted period —
        // and animation frames drawn *during* tracking pick the flag up too.
        isPresentingMenu = true
        glyph.invalidateTint()
        defer {
            statusItem.menu = nil
            isPresentingMenu = false
            glyph.invalidateTint()
            applyImage()
        }
        applyImage()
        statusItem.button?.performClick(nil)
    }
}
