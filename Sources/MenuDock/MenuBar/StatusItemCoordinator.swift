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
    private let openSettings: () -> Void

    /// Keyed for O(1) diffing; ``liveOrder`` carries the arrangement.
    private var controllers: [DockItem.ID: StatusItemController] = [:]
    /// Left-to-right order of what is actually on the menu bar right now.
    private var liveOrder: [DockItem.ID] = []
    private var appearanceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init(
        store: ConfigurationStore,
        icons: IconLibrary,
        running: RunningAppsMonitor,
        animator: IconAnimator,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        self.icons = icons
        self.running = running
        self.animator = animator
        self.openSettings = openSettings

        observeAppearanceChanges()
        observeScreenChanges()
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
            MainActor.assumeIsolated { self?.invalidateAndRefresh() }
        }
    }

    // MARK: - Reconciliation

    private func reconcile() {
        let configuration = store.configuration

        // Narrow the running-app monitor to just what is on screen.
        running.track(Set(configuration.items.flatMap(\.referencedApps).map(\.bundleIdentifier)))
        animator.animationEnabled = configuration.preferences.animateIcons

        let desired = configuration.items
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
            removeItem: { [weak store] id in store?.remove(id: id) }
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
                    menus: menus
                )
            }
        }
        liveOrder = desiredOrder

        // Set aside icon files nothing references any more — but never after a failed load,
        // where "nothing references them" only means "we could not read what does".
        if !store.didFailToLoad {
            icons.pruneOrphans(keeping: configuration.referencedIconFileNames)
        }
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
