import AppKit
import Observation

/// Keeps the live set of `NSStatusItem`s in sync with the configuration.
///
/// ## Reconcile, don't rebuild
///
/// The tempting implementation is "on any change, tear down every status item and recreate
/// them." That is visibly wrong: status items flicker out of the menu bar and back, and
/// because `autosaveName` positions are restored asynchronously, they can land in a different
/// order than they left. Instead this diffs by ``DockItem/id`` and only creates the genuinely
/// new, removes the genuinely gone, and updates the rest in place.
///
/// ## Push, not poll
///
/// State arrives through `@Observable` — a configuration edit or an app launching/quitting
/// re-arms ``observe()`` and triggers exactly one reconcile. Nothing runs on a timer, so an
/// idle MenuDock costs no CPU.
///
/// ## The list is the order
///
/// macOS offers no API to move an existing status item, and it places each newly created one
/// to the *left* of that app's existing items. Creation order is therefore the only lever, so
/// ``reconcile()`` rebuilds the whole row whenever the model's order changes — see
/// ``rebuildRequired(liveOrder:desiredOrder:)`` for exactly when that is.
@MainActor
final class StatusItemCoordinator {
    private let store: ConfigurationStore
    private let icons: IconLibrary
    private let running: RunningAppsMonitor
    private let animator: IconAnimator
    private let metrics: MetricsMonitor
    private let clipboard: ClipboardCoordinator
    private let space: MenuBarSpaceMonitor
    private let openSettings: () -> Void

    /// Keyed for O(1) diffing; ``liveOrder`` carries the arrangement.
    private var controllers: [DockItem.ID: StatusItemController] = [:]
    /// Left-to-right order of what is actually on the menu bar right now.
    private var liveOrder: [DockItem.ID] = []
    private var appearanceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// True while a space evaluation is already queued, so a burst of reconciles schedules one.
    private var isSpaceCheckScheduled = false

    init(
        store: ConfigurationStore,
        icons: IconLibrary,
        running: RunningAppsMonitor,
        animator: IconAnimator,
        metrics: MetricsMonitor,
        clipboard: ClipboardCoordinator,
        space: MenuBarSpaceMonitor,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        self.icons = icons
        self.running = running
        self.animator = animator
        self.metrics = metrics
        self.clipboard = clipboard
        self.space = space
        self.openSettings = openSettings

        observeAppearanceChanges()
        observeScreenChanges()
        // A callback rather than observation, deliberately: this object *is* what updates the
        // space monitor, so observing it would be a cycle. See ``MenuBarSpaceMonitor/onChange``.
        space.onChange = { [weak self] in self?.reconcile() }
        reconcile()
        observe()
    }

    isolated deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Observation

    /// Re-arms itself after every change. `withObservationTracking` is one-shot by design,
    /// and `onChange` fires *before* the mutation is applied — hence the hop through a task,
    /// so the reconcile reads post-change state.
    private func observe() {
        withObservationTracking {
            _ = store.configuration
            _ = running.runningIdentifiers
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcile()
                self.observe()
            }
        }
    }

    /// Light/Dark switches are handled automatically for template images, but a colour icon
    /// carrying a running-indicator dot is baked at render time and has to be redrawn.
    private func observeAppearanceChanges() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.icons.invalidateCache()
                self.controllers.values.forEach { $0.refresh() }
            }
        }
    }

    /// Renders are baked for the backing scale of the displays present when they were made, and
    /// the icon size ceiling comes from the live menu bar's thickness — both of which change when
    /// a display is connected, disconnected, or its resolution changes.
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The screen that was measured may no longer be attached, and a menu bar's worth
                // of geometry from a different display is worse than none — so the baseline goes
                // rather than being carried across. This is the event the whole auto-hide feature
                // exists for: undocking is what turns a comfortable setup into an over-budget one.
                self.space.invalidateMeasurements()
                self.invalidateAndRefresh()
                self.scheduleSpaceCheck()
            }
        }
    }

    // MARK: - Reconciliation

    private func reconcile() {
        let configuration = store.configuration

        // Narrow the running-app monitor to just what is on screen.
        //
        // Over *every* item rather than the visible ones. An app hidden by a profile is still an
        // app whose running state the user will see the moment they switch back, and re-tracking
        // the whole set on every profile switch would drop and rebuild the observation for no
        // gain. The same reasoning — and a much sharper version of it — applies to icon pruning
        // at the bottom of this method.
        running.track(Set(configuration.items.flatMap(\.referencedApps).map(\.bundleIdentifier)))
        animator.animationEnabled = configuration.preferences.animateIcons

        // Two filters, in this order: what the user chose to see, then what actually fits.
        let hidden = space.hiddenItemIDs
        let desired = configuration.profileFilteredItems.filter { !hidden.contains($0.id) }
        let desiredIDs = Set(desired.map(\.id))
        let desiredOrder = desired.map(\.id)

        // Removals first, so a rename-and-replace frees its menu bar slot before the
        // replacement asks for one.
        for id in controllers.keys where !desiredIDs.contains(id) {
            controllers.removeValue(forKey: id)
        }
        liveOrder.removeAll { !desiredIDs.contains($0) }

        // Anything that has to move can only move by being recreated, and an item can only be
        // recreated in the right place if everything after it is too. So the whole row goes.
        //
        // Dropping the controllers is what removes the status items — `StatusItemController`
        // does that in its `isolated deinit`, and nothing else holds a strong reference. The
        // removals must all complete before the first replacement is created, or the new items
        // would be positioned relative to the ones still on the bar.
        if rebuildRequired(liveOrder: liveOrder, desiredOrder: desiredOrder) {
            controllers.removeAll()
            liveOrder.removeAll()
        }

        let menus = MenuBuilder(
            icons: icons,
            running: running,
            openSettings: openSettings,
            removeItem: { [weak store] id in store?.remove(id: id) },
            profiles: { [weak store] in
                guard let store else { return ([], nil) }
                return (store.configuration.profiles, store.configuration.activeProfileID)
            },
            activateProfile: { [weak store] id in store?.activateProfile(id) }
        )

        // macOS places each newly created status item to the *left* of this app's existing
        // ones, so creating in reverse makes left-to-right order match the list in Settings.
        for item in desired.reversed() {
            if let existing = controllers[item.id] {
                existing.update(item: item, preferences: configuration.preferences)
            } else {
                controllers[item.id] = StatusItemController(
                    item: item,
                    preferences: configuration.preferences,
                    icons: icons,
                    running: running,
                    animator: animator,
                    metrics: metrics,
                    clipboard: clipboard,
                    menus: menus
                )
            }
        }
        liveOrder = desiredOrder

        // Set aside icon files nothing references any more — but never after a failed load,
        // where "nothing references them" only means "we could not read what does".
        //
        // `referencedIconFileNames` covers every item, not the visible ones, and that is
        // load-bearing: pruning against `desired` would set a user's custom artwork aside the
        // moment a profile stopped showing its item.
        if !store.didFailToLoad {
            icons.pruneOrphans(keeping: configuration.referencedIconFileNames)
        }

        scheduleSpaceCheck()
    }

    // MARK: - Space

    /// Re-evaluates the auto-hide decision once the status items have laid out.
    ///
    /// Deferred by a hop rather than run inline, because the measurement it depends on is only
    /// available afterwards: a status item created a microsecond ago has no window yet, and
    /// asking for its frame would read zero and conclude that MenuDock occupies nothing at all.
    ///
    /// This is also where the loop closes, so it is worth stating why it terminates. An
    /// evaluation may change the hidden set, which reconciles, which schedules another
    /// evaluation. The second one reaches the same answer because the demand it compares against
    /// is derived from the model — not from the items currently on screen — and so does not move
    /// when the answer does. See ``MenuBarSpaceMonitor``.
    private func scheduleSpaceCheck() {
        guard store.configuration.preferences.autoHideWhenCrowded || !space.hiddenItemIDs.isEmpty
        else { return }
        guard !isSpaceCheckScheduled else { return }
        isSpaceCheckScheduled = true

        Task { @MainActor [weak self] in
            self?.isSpaceCheckScheduled = false
            self?.evaluateSpace()
        }
    }

    private func evaluateSpace() {
        var layout = MenuBarSpaceMonitor.Layout()
        for (id, controller) in controllers {
            layout.widths[id] = controller.measuredWidth
        }
        // The rightmost of our items is the one that borders on everybody else's, so it is what
        // says how much of the bar is already spoken for.
        for id in liveOrder.reversed() {
            guard let placement = controllers[id]?.screenPlacement else { continue }
            layout.rightmostEdge = placement.rightEdge
            layout.screen = placement.screen
            break
        }

        space.evaluate(
            items: store.configuration.profileFilteredItems,
            preferences: store.configuration.preferences,
            layout: layout
        )
    }

    /// Whether the menu bar has to be torn down and rebuilt to match the model's order.
    ///
    /// Called with deletions already applied to `liveOrder`, which is what makes the plain
    /// comparison correct: deleting an item never disturbs the relative order of the rest, so
    /// after that filtering the two lists match unless something genuinely *moved*. An append
    /// counts as a move — a new item is born leftmost, so putting it on the right end means
    /// recreating everything that should sit to its left.
    ///
    /// The common edits — renaming, changing an icon, an app launching or quitting, resizing —
    /// leave the order untouched and never reach this, so the menu bar does not flicker while
    /// the user is typing in the settings window.
    private func rebuildRequired(liveOrder: [DockItem.ID], desiredOrder: [DockItem.ID]) -> Bool {
        liveOrder != desiredOrder
    }

    /// Drops every render cache — animation frames included — and redraws. Used when icon size
    /// or the display setup changes, both of which invalidate the pixels themselves.
    func invalidateAndRefresh() {
        icons.invalidateCache(includingAnimationFrames: true)
        controllers.values.forEach { $0.refresh() }
    }

    var itemCount: Int { controllers.count }
}
