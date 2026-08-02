import AppKit

/// Decides which items to leave out when the menu bar cannot hold them all.
///
/// ## The problem this exists for
///
/// The menu bar is the only container in macOS with no scrolling, no overflow indicator, and no
/// API to ask how much room is left. Items that do not fit are not clipped or stacked — they are
/// simply not drawn, and the ones that go are the leftmost, which is to say the ones the user
/// arranged first. Worse, MenuDock cannot tell that it happened: a status item that the window
/// server declined to place still reports a perfectly ordinary frame.
///
/// The size of the problem is not marginal. A 14" MacBook has a notch eating the middle of the
/// bar and a much narrower screen to begin with; measured against a 27" display, the usable strip
/// to the right of the notch is roughly a third the width. So the same setup that is comfortable
/// docked is over budget the moment the laptop is unplugged — and the user's only recourse today
/// is to open Settings and delete items, then add them back tomorrow morning.
///
/// ## What it actually measures
///
/// Three quantities, and it is worth being precise about which are known and which are inferred.
///
/// **The usable region** is known. On a notched Mac, `NSScreen.auxiliaryTopRightArea` is exactly
/// the strip to the right of the camera housing — the only part of the bar a status item can
/// occupy. On every other Mac there is no such API, and the constraint is the frontmost app's
/// menus, whose width is unknowable from outside that app; ``appMenuReserve`` is a deliberately
/// generous guess at it.
///
/// **What other apps have taken** is measured, not guessed: everything between the right edge of
/// MenuDock's rightmost status item and the right edge of the screen belongs to somebody else —
/// other menu bar apps, Control Centre, the clock. That distance is a fact, read off the live
/// window frames.
///
/// **What MenuDock wants** is computed from the model rather than measured, and that is the load-
/// bearing decision here. It has to be, for two reasons. The obvious one is that a hidden item
/// has no window to measure. The subtle one is that measuring would make the decision depend on
/// its own outcome: hide an item, the remaining ones shift, the measurement changes, and the next
/// pass reaches a different conclusion — a menu bar that oscillates once a second. Deriving the
/// demand from the model gives a number that does not move when the answer changes, which is what
/// makes the loop terminate.
///
/// ## What it does not do
///
/// It cannot see other apps' items individually, so it cannot know that Dropbox is about to add
/// one. It re-measures when the screen configuration changes and whenever nothing is hidden, and
/// otherwise trusts its last reading. The consequence is that another app filling the bar *while
/// MenuDock is already hiding things* is absorbed by the reserve rather than reacted to.
@MainActor
@Observable
final class MenuBarSpaceMonitor {

    /// The items currently left out, in addition to whatever the active profile hides.
    ///
    /// Observable for the *settings pane*, which dims the rows it names, and deliberately not for
    /// ``StatusItemCoordinator``: that object reads this property inside `reconcile()`, which is
    /// not wrapped in `withObservationTracking`, so the read does not subscribe it to a value it
    /// is itself upstream of. The coordinator is driven by ``onChange`` instead.
    private(set) var hiddenItemIDs: Set<DockItem.ID> = []

    /// Set by ``StatusItemCoordinator`` to trigger a reconcile when this set changes.
    ///
    /// A callback rather than observation, and for the same reason ``MetricsMonitor`` keeps its
    /// samples out of observation: the coordinator re-runs its whole diff on anything it
    /// observes, and this object is updated *from* that diff. Observing it would close the loop
    /// into a cycle.
    @ObservationIgnored var onChange: (() -> Void)?

    /// What the last evaluation concluded, so Settings can explain itself rather than leaving the
    /// user to infer why an icon is missing.
    private(set) var lastVerdict: Verdict?

    struct Verdict: Equatable {
        /// Points available to MenuDock's own items.
        var available: Double
        /// Points every item in the active profile would need.
        var wanted: Double
        /// How many items were dropped to make it fit.
        var hiddenCount: Int
        /// True when even the essential items do not fit, so macOS will still clip something.
        var isOverBudgetRegardless: Bool
    }

    /// What the live menu bar looks like right now, gathered by the coordinator from its
    /// controllers.
    struct Layout {
        /// Measured width of each status item currently on the bar.
        var widths: [DockItem.ID: Double] = [:]
        /// Right edge of MenuDock's rightmost status item, in screen coordinates.
        var rightmostEdge: Double?
        /// The screen that status item is on.
        var screen: NSScreen?
    }

    // MARK: - Tuning

    /// Width assumed for the frontmost app's menus on a Mac with no notch.
    ///
    /// There is no way to read this: the menu bar belongs to whichever app is frontmost, its
    /// width changes as the user switches apps, and nothing publishes it. The figure is a
    /// generous one — a wide app like Xcode or Photoshop with a long name — because the failure
    /// modes are not symmetric. Guess too high and MenuDock hides an item it could have kept,
    /// which the user can see and switch off. Guess too low and macOS silently clips icons, which
    /// is the exact problem this class exists to prevent.
    private static let appMenuReserve: Double = 480

    /// Space assumed for the other apps' items before anything has been measured.
    ///
    /// Only ever used on the very first evaluation of a launch, before the status items have laid
    /// out and reported a frame.
    private static let unmeasuredOtherAppsWidth: Double = 220

    /// Padding macOS adds around a status item's content, beyond the image itself.
    ///
    /// Not published anywhere, so this is measured empirically and rounded up. Rounding *up* is
    /// the safe direction for the same asymmetry as ``appMenuReserve``.
    private static let itemPadding: Double = 12

    /// Slack required before an item is put back.
    ///
    /// Without it, an item whose width is exactly the shortfall would be hidden, freeing precisely
    /// enough room to show it, which frees nothing — and the bar flickers between the two states
    /// at the rate the evaluation runs. Restoring only once there is real headroom breaks the tie
    /// in the stable direction.
    private static let restoreHysteresis: Double = 24

    /// Distance from the screen's right edge to MenuDock's rightmost item, from the last
    /// measurement taken while nothing was hidden. See the class note on why it is only trusted
    /// from that state.
    @ObservationIgnored private var otherAppsWidth: Double?

    /// The last measured width of every item that has been on the bar this session.
    ///
    /// This is what makes the evaluation converge rather than oscillate. A hidden item has no
    /// window, so without a remembered width it would fall back to the derived estimate — and the
    /// estimate is not the measurement. The demand would therefore change between the pass that
    /// hid an item and the pass that followed, which is exactly the moving target the class note
    /// says the whole design is arranged to avoid: hide, demand drops, everything fits, restore,
    /// demand rises, hide again, once per run loop turn, forever.
    @ObservationIgnored private var knownWidths: [DockItem.ID: Double] = [:]

    // MARK: - Evaluation

    /// Recomputes the hidden set, and reports whether it changed.
    ///
    /// - Parameter items: the items the active profile shows, in menu bar order.
    @discardableResult
    func evaluate(
        items: [DockItem],
        preferences: Configuration.Preferences,
        layout: Layout
    ) -> Bool {
        // Remembered before the early exits, so switching auto-hiding off and on again does not
        // start from an empty table and a pass of estimates.
        for (id, width) in layout.widths where width > 0 {
            knownWidths[id] = width
        }

        guard preferences.autoHideWhenCrowded else {
            lastVerdict = nil
            return apply([])
        }

        // Measured only from the state where our own layout is not distorting it.
        if hiddenItemIDs.isEmpty,
           let edge = layout.rightmostEdge,
           let screen = layout.screen ?? NSScreen.main {
            otherAppsWidth = max(screen.frame.maxX - edge, 0)
        }

        guard let region = usableRegion(on: layout.screen ?? NSScreen.main) else {
            lastVerdict = nil
            return apply([])
        }

        let taken = otherAppsWidth ?? Self.unmeasuredOtherAppsWidth
        let available = max(region.width - taken, 0)

        let widths = items.reduce(into: [DockItem.ID: Double]()) { result, item in
            result[item.id] = width(of: item, preferences: preferences, layout: layout)
        }
        let wanted = widths.values.reduce(0, +)

        // Everything fits — but only claim so with room to spare, or an item restored on an exact
        // fit would immediately be hidden again. See `restoreHysteresis`.
        let slack = hiddenItemIDs.isEmpty ? 0 : Self.restoreHysteresis
        if wanted + slack <= available {
            lastVerdict = Verdict(available: available, wanted: wanted,
                                  hiddenCount: 0, isOverBudgetRegardless: false)
            return apply([])
        }

        var hidden: Set<DockItem.ID> = []
        var remaining = wanted

        // Drop by priority band, and within a band from the left.
        //
        // Left first because that is the end macOS would have taken anyway: status items pack
        // towards the right, so the leftmost is the one that falls off. Choosing the same
        // casualty means switching this feature on changes *how* an item disappears — cleanly,
        // with a name and a reason in Settings — rather than changing *which*.
        let candidates = items
            .filter { $0.priority != .essential }
            .sorted { $0.priority.dropOrder < $1.priority.dropOrder }

        for item in candidates where remaining > available {
            hidden.insert(item.id)
            remaining -= widths[item.id] ?? 0
        }

        lastVerdict = Verdict(
            available: available,
            wanted: wanted,
            hiddenCount: hidden.count,
            // Every droppable item is gone and it still does not fit: the essentials alone are
            // over budget, and macOS will clip one of them. Said out loud in Settings, because
            // the user has switched on a feature that is now failing to do its job.
            isOverBudgetRegardless: remaining > available
        )
        return apply(hidden)
    }

    private func apply(_ hidden: Set<DockItem.ID>) -> Bool {
        guard hidden != hiddenItemIDs else { return false }
        hiddenItemIDs = hidden
        onChange?()
        return true
    }

    /// Forgets the measured baseline, so the next evaluation re-reads it.
    ///
    /// Called when the display setup changes: the previous reading describes a screen that may no
    /// longer be attached, and carrying it over to a different one is worse than having none.
    func invalidateMeasurements() {
        otherAppsWidth = nil
        // Item widths are kept: a status item is the same size on any screen, since its height
        // comes from the icon-size preference rather than from the display.
    }

    // MARK: - Geometry

    /// The strip of menu bar a status item may occupy on this screen.
    private func usableRegion(on screen: NSScreen?) -> CGRect? {
        guard let screen else { return nil }

        // On a notched Mac this is exact: the area to the right of the camera housing is the only
        // place a status item can go, and the system publishes it.
        if let right = screen.auxiliaryTopRightArea, right.width > 0 {
            return right
        }

        // Everywhere else, the limit is the frontmost app's menus, which nothing publishes.
        let width = screen.frame.width - Self.appMenuReserve
        guard width > 0 else { return nil }
        return CGRect(x: screen.frame.minX + Self.appMenuReserve,
                      y: screen.frame.maxY - NSStatusBar.system.thickness,
                      width: width,
                      height: NSStatusBar.system.thickness)
    }

    /// How much menu bar this item needs.
    ///
    /// Prefers the measured width when the item is on screen — it is the truth, and it already
    /// includes whatever padding this version of macOS applies. Falls back to deriving it for
    /// items that are currently hidden and so have no window to ask.
    private func width(
        of item: DockItem,
        preferences: Configuration.Preferences,
        layout: Layout
    ) -> Double {
        if let measured = layout.widths[item.id], measured > 0 { return measured }
        // What it measured last time it was on the bar. See ``knownWidths``.
        if let remembered = knownWidths[item.id] { return remembered }

        let height = item.resolvedIconSize(default: preferences.iconSize)
        if let activity = item.activity {
            return ActivityRenderer.size(for: activity, height: height).width + Self.itemPadding
        }
        return height + Self.itemPadding
    }
}
