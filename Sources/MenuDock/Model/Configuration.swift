import Foundation

/// The complete on-disk document.
///
/// `schemaVersion` is written eagerly from day one so a future migration has something to
/// branch on; adding it retroactively means guessing at unversioned files.
/// ## Decoding is deliberately tolerant
///
/// Every field below is decoded with `decodeIfPresent` and falls back to its default. This is
/// not defensive style for its own sake — Swift's *synthesized* `Decodable` ignores property
/// defaults and throws `keyNotFound` for any absent key, which means simply adding a new
/// preference silently invalidates every configuration file already on disk. That is a data-loss
/// bug shipped as a feature addition, and it is invisible until a user updates.
///
/// Writing `init(from:)` by hand costs a few lines once and makes forward field additions a
/// non-event forever.
nonisolated struct Configuration: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Configuration.currentSchemaVersion
    var items: [DockItem] = []
    var preferences: Preferences = Preferences()

    /// The named subsets the user has defined. Empty by default — profiles are a feature you opt
    /// into by creating one, not a concept you have to understand to use the app.
    var profiles: [Profile] = []

    /// Which profile is showing, or `nil` for "All Items".
    ///
    /// Stored in the configuration rather than held in memory because it is a *setting*, not a
    /// session state: a user who switches to Presenting and closes their laptop expects to still
    /// be presenting when they open it. It also means the menu bar is correct from the first
    /// frame after launch rather than settling a moment later.
    var activeProfileID: Profile.ID?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, items, preferences, profiles, activeProfileID
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Configuration.currentSchemaVersion
        items = try container.decodeIfPresent([DockItem].self, forKey: .items) ?? []
        preferences = try container.decodeIfPresent(Preferences.self, forKey: .preferences)
            ?? Preferences()
        profiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        activeProfileID = try container.decodeIfPresent(Profile.ID.self, forKey: .activeProfileID)

        // A selected profile that no longer exists — deleted on another Mac, or hand-edited
        // out — must fall back to "All Items" rather than filtering the menu bar down to the
        // items belonging to a profile nobody can select. An empty menu bar with no visible cause
        // is the single worst state this feature can produce.
        if let activeProfileID, !profiles.contains(where: { $0.id == activeProfileID }) {
            self.activeProfileID = nil
        }

        // The last line of defence for the one-of-each rule. Settings and the store both refuse
        // to create a second Activity or Clipboard item, but the configuration is a plain JSON
        // file the user is invited to hand-edit and back up — and a config copied between Macs,
        // merged by hand, or written by an older build can still arrive with two. Collapsing here
        // means every path into the model upholds the invariant, so nothing downstream has to ask.
        collapseDuplicateSingletons()
    }

    /// Drops all but the first item of each singleton kind, in place.
    ///
    /// Keeps the *first* rather than the newest because this array is also the menu bar's order:
    /// the leftmost of two Activity items is the one the user has been looking at, and silently
    /// promoting the other would move a familiar icon for no visible reason.
    private mutating func collapseDuplicateSingletons() {
        var seen: Set<String> = []
        items.removeAll { item in
            guard let token = item.kind.singletonToken else { return false }
            return !seen.insert(token).inserted
        }
    }

    nonisolated struct Preferences: Codable, Hashable, Sendable {
        /// Draw a Dock-style dot beneath icons of running apps.
        var showRunningIndicator: Bool = true
        /// Icon edge length in points. The menu bar gives us ~22pt of usable height.
        var iconSize: Double = 18
        /// Master switch for animated built-in icons. Reduce Motion overrides this to off.
        var animateIcons: Bool = true

        /// Drop low-priority items when the menu bar cannot fit them all. See
        /// ``MenuBarSpaceMonitor``.
        ///
        /// Off by default, and it has to be. An item disappearing from the menu bar without
        /// having been asked to is indistinguishable from a bug — the user's first thought is
        /// "MenuDock crashed", not "MenuDock made room" — so this is a thing you switch on
        /// knowingly, having read what it does, rather than something that happens to you the
        /// first time you undock a laptop.
        var autoHideWhenCrowded: Bool = false

        private enum CodingKeys: String, CodingKey {
            case showRunningIndicator, iconSize, animateIcons, autoHideWhenCrowded
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showRunningIndicator = try container
                .decodeIfPresent(Bool.self, forKey: .showRunningIndicator) ?? true
            iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize) ?? 18
            animateIcons = try container.decodeIfPresent(Bool.self, forKey: .animateIcons) ?? true
            autoHideWhenCrowded = try container
                .decodeIfPresent(Bool.self, forKey: .autoHideWhenCrowded) ?? false
        }
    }
}

nonisolated extension Configuration {
    /// Every icon-library file referenced by any item, for orphan cleanup.
    ///
    /// Deliberately over **every** item and not the visible ones. An item hidden by a profile or
    /// by auto-hiding still owns its artwork, and pruning against the visible set would move a
    /// user's custom icon into `Icons/Unused/` the moment they switched profile. See
    /// ``IconLibrary/pruneOrphans(keeping:)`` for the earlier version of that same mistake.
    var referencedIconFileNames: Set<String> {
        Set(items.flatMap(\.customIconFileNames))
    }

    /// The active profile, or `nil` when showing everything.
    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// The items the active profile shows, in menu bar order.
    ///
    /// Auto-hiding is *not* applied here — it is a separate, later filter owned by
    /// ``MenuBarSpaceMonitor``, because it depends on the geometry of the screen rather than on
    /// anything in this document. Keeping the two apart means the space monitor decides what to
    /// drop from a list that already reflects the user's choice of profile, which is the only
    /// order that makes sense: there is no point measuring items the user has already said they
    /// do not want to see.
    var profileFilteredItems: [DockItem] {
        guard activeProfileID != nil else { return items }
        return items.filter { $0.isMember(ofProfile: activeProfileID) }
    }

    /// How many items the active profile hides, for the sidebar's status line.
    var itemsHiddenByProfile: Int {
        items.count - profileFilteredItems.count
    }

    func index(of id: DockItem.ID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// Whether a singleton kind is already in the menu bar. Drives both the store's refusal to
    /// add a second and the Add menu's disabled rows — one predicate, so the button cannot offer
    /// something the store will then decline to do.
    func contains(singletonLike kind: DockItem.Kind) -> Bool {
        guard let token = kind.singletonToken else { return false }
        return items.contains { $0.kind.singletonToken == token }
    }

    var activityItem: DockItem? { items.first(where: \.isActivity) }
    var clipboardItem: DockItem? { items.first(where: \.isClipboard) }
}
