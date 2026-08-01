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

    private enum CodingKeys: String, CodingKey { case schemaVersion, items, preferences }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Configuration.currentSchemaVersion
        items = try container.decodeIfPresent([DockItem].self, forKey: .items) ?? []
        preferences = try container.decodeIfPresent(Preferences.self, forKey: .preferences)
            ?? Preferences()

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

        private enum CodingKeys: String, CodingKey {
            case showRunningIndicator, iconSize, animateIcons
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showRunningIndicator = try container
                .decodeIfPresent(Bool.self, forKey: .showRunningIndicator) ?? true
            iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize) ?? 18
            animateIcons = try container.decodeIfPresent(Bool.self, forKey: .animateIcons) ?? true
        }
    }
}

nonisolated extension Configuration {
    /// Every icon-library file referenced by any item, for orphan cleanup.
    var referencedIconFileNames: Set<String> {
        Set(items.flatMap(\.customIconFileNames))
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
