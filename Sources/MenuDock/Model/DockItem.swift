import Foundation

/// One application slot: an app plus its presentation overrides.
///
/// Used both as a top-level menu bar item and as a member inside a group, which is why it
/// carries its own identity and icon rather than inheriting from a parent.
/// Decoded tolerantly — see the note on ``Configuration``. Only `app` is genuinely required;
/// everything else falls back to its default so new fields never invalidate saved configs.
nonisolated struct AppEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var app: AppReference
    var icon: IconSpec = .appIcon
    /// Overrides `app.name` in menus when the user renames the entry.
    var customTitle: String?

    var displayTitle: String {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed! : app.name)
    }

    private enum CodingKeys: String, CodingKey { case id, app, icon, customTitle }

    init(id: UUID = UUID(), app: AppReference, icon: IconSpec = .appIcon, customTitle: String? = nil) {
        self.id = id
        self.app = app
        self.icon = icon
        self.customTitle = customTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        app = try container.decode(AppReference.self, forKey: .app)
        icon = try container.decodeIfPresent(IconSpec.self, forKey: .icon) ?? .appIcon
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    }
}

/// A folder of apps that expands from a single menu bar icon.
nonisolated struct GroupEntry: Codable, Hashable, Sendable {
    var name: String = "Group"
    var icon: IconSpec = .builtin(id: "folder")
    var members: [AppEntry] = []

    private enum CodingKeys: String, CodingKey { case name, icon, members }

    init(name: String = "Group",
         icon: IconSpec = .builtin(id: "folder"),
         members: [AppEntry] = []) {
        self.name = name
        self.icon = icon
        self.members = members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        icon = try container.decodeIfPresent(IconSpec.self, forKey: .icon) ?? .builtin(id: "folder")
        members = try container.decodeIfPresent([AppEntry].self, forKey: .members) ?? []
    }
}

/// A single `NSStatusItem`'s worth of configuration.
///
/// The `id` is the anchor for the whole system: it lets ``StatusItemCoordinator`` diff model
/// changes against live status items, so an edit updates one item in place instead of tearing
/// down the whole menu bar — and it makes this array's order the menu bar's order.
nonisolated struct DockItem: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: Kind

    enum Kind: Hashable, Sendable {
        case application(AppEntry)
        case group(GroupEntry)
    }

    private enum CodingKeys: String, CodingKey { case id, kind }

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    init(app: AppReference) {
        self.init(kind: .application(AppEntry(app: app)))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing `id` is recoverable — a fresh one costs nothing, since position comes from
        // this array's order. A missing `kind` is not: there would be nothing to show.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
    }
}

nonisolated extension DockItem {
    var displayTitle: String {
        switch kind {
        case .application(let entry): entry.displayTitle
        case .group(let group): group.name
        }
    }

    var icon: IconSpec {
        get {
            switch kind {
            case .application(let entry): entry.icon
            case .group(let group): group.icon
            }
        }
        set {
            switch kind {
            case .application(var entry):
                entry.icon = newValue
                kind = .application(entry)
            case .group(var group):
                group.icon = newValue
                kind = .group(group)
            }
        }
    }

    /// Every app this item can launch — one for an app item, N for a group.
    var referencedApps: [AppReference] {
        switch kind {
        case .application(let entry): [entry.app]
        case .group(let group): group.members.map(\.app)
        }
    }

    /// Every icon-library file this item references, including group members'.
    var customIconFileNames: [String] {
        switch kind {
        case .application(let entry):
            [entry.icon.customFileName].compactMap { $0 }
        case .group(let group):
            ([group.icon.customFileName] + group.members.map(\.icon.customFileName)).compactMap { $0 }
        }
    }

    var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }
}

// MARK: - Codable

nonisolated extension DockItem.Kind: Codable {
    private enum CodingKeys: String, CodingKey { case type, entry, group }
    private enum Discriminator: String, Codable { case application, group }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .type) {
        case .application:
            self = .application(try container.decode(AppEntry.self, forKey: .entry))
        case .group:
            self = .group(try container.decode(GroupEntry.self, forKey: .group))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .application(let entry):
            try container.encode(Discriminator.application, forKey: .type)
            try container.encode(entry, forKey: .entry)
        case .group(let group):
            try container.encode(Discriminator.group, forKey: .type)
            try container.encode(group, forKey: .group)
        }
    }
}
