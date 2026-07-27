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
}
