import Foundation

/// A named subset of the menu bar — "Work", "Personal", "Presenting".
///
/// ## Profiles filter one list; they do not own separate ones
///
/// The obvious model is that each profile holds its own array of items, and switching swaps one
/// array for another. It is wrong for this app in three separate ways.
///
/// It **duplicates every item that appears in more than one profile**, which is most of them: a
/// Chrome icon in both Work and Personal becomes two entries to rename, re-skin and resize
/// independently, and they drift the moment the user edits one.
///
/// It **breaks the menu bar's identity diffing**. ``StatusItemCoordinator`` reconciles by
/// ``DockItem/id``, and that is what lets an edit update one status item in place instead of
/// tearing down the row. Two arrays means two sets of ids for the same icon, so every profile
/// switch would be a full rebuild — every icon flickering out of the bar and back, in a
/// different order than it left, because macOS restores positions asynchronously.
///
/// And it **doubles the number of places a setting lives**, which is the thing this codebase
/// spends the most effort avoiding.
///
/// So a profile is a *membership label*, and items carry the labels. ``Configuration/items`` stays
/// the one list, in the one order, and a profile decides which of them the bar shows. Switching
/// profiles is then exactly the same operation as removing a few items and adding a few others,
/// which the coordinator already does well.
///
/// ## Membership lives on the item, not here
///
/// This struct holds no item list — see ``DockItem/profileIDs``. Putting it on the item is what
/// makes the migration free: every item that predates profiles has no membership recorded, which
/// reads as *"belongs to all of them"*, so adding a profile to an existing setup changes nothing
/// until the user says otherwise. The other direction — a profile listing its members — would
/// need every profile rewritten whenever an item is added, and would let the two representations
/// disagree about an id that exists in one and not the other.
nonisolated struct Profile: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    /// The SF Symbol shown beside the profile in Settings and in the switching menu.
    var symbolName: String = "square.stack.3d.up"

    private enum CodingKeys: String, CodingKey { case id, name, symbolName }

    init(id: UUID = UUID(), name: String, symbolName: String = "square.stack.3d.up") {
        self.id = id
        self.name = name
        self.symbolName = symbolName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)
            ?? "square.stack.3d.up"
    }

    var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Profile" : trimmed
    }

    /// Symbols offered when creating or renaming a profile. Concrete nouns rather than abstract
    /// shapes, because the point of the icon is to be recognised in a menu at a glance.
    static let symbolChoices = [
        "square.stack.3d.up", "briefcase", "house", "person", "display",
        "airplane", "cup.and.saucer", "moon", "hammer", "paintbrush",
        "gamecontroller", "graduationcap",
    ]
}

// MARK: - Priority

/// How readily an item gives up its place when the menu bar runs out of room.
///
/// This exists because the menu bar is the only container in macOS with no scrolling, no
/// overflow, and no way to ask how much of it is left. Items that do not fit are not clipped or
/// stacked — they are simply *not drawn*, silently, and the ones that vanish are the leftmost,
/// which is to say the ones the user arranged first and cares about most. A 14" MacBook has
/// roughly a third the usable width of a 27" display once the notch and the app menus have taken
/// their share, so the same setup that is comfortable docked is over budget undocked.
///
/// Priority is what lets MenuDock choose *which* items to drop instead of letting the window
/// server choose for it. See ``MenuBarSpaceMonitor``.
nonisolated enum ItemPriority: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// Never dropped, whatever the cost. If even these do not fit, macOS clips them as before —
    /// there is nothing further MenuDock can do, and pretending otherwise would mean hiding
    /// something the user explicitly said to keep.
    case essential
    /// The default. Dropped only once every optional item has already gone.
    case standard
    /// First to go.
    case optional

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .essential: "Always show"
        case .standard: "Normal"
        case .optional: "Hide first"
        }
    }

    var summary: String {
        switch self {
        case .essential: "Never hidden, even on a crowded menu bar."
        case .standard: "Hidden only after everything marked “Hide first”."
        case .optional: "The first to go when the menu bar runs short."
        }
    }

    var symbolName: String {
        switch self {
        case .essential: "pin.fill"
        case .standard: "minus"
        case .optional: "arrow.down.to.line"
        }
    }

    /// Lower goes first. Used to order the candidates for hiding.
    var dropOrder: Int {
        switch self {
        case .optional: 0
        case .standard: 1
        case .essential: 2
        }
    }
}
