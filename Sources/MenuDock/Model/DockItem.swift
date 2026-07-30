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

/// A group of apps that expands from a single menu bar icon.
nonisolated struct GroupEntry: Codable, Hashable, Sendable {
    var name: String = "Group"
    var icon: IconSpec = .builtin(id: "grid")
    var members: [AppEntry] = []

    private enum CodingKeys: String, CodingKey { case name, icon, members }

    init(name: String = "Group",
         icon: IconSpec = .builtin(id: "grid"),
         members: [AppEntry] = []) {
        self.name = name
        self.icon = icon
        self.members = members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        icon = try container.decodeIfPresent(IconSpec.self, forKey: .icon) ?? .builtin(id: "grid")
        members = try container.decodeIfPresent([AppEntry].self, forKey: .members) ?? []
    }
}

/// One or more folders that open in Finder from a single menu bar icon.
///
/// Holding a *list* rather than a single folder is what lets one icon stand for a whole working
/// context — "Current Project", say, pointing at the repo, its designs, and its notes. With one
/// folder configured a click opens it immediately; with several the icon offers them, unless
/// ``opensAllAtOnce`` says the user would rather have every window at once.
nonisolated struct FolderEntry: Codable, Hashable, Sendable {
    var name: String = "Folders"
    var icon: IconSpec = .builtin(id: "folder")
    var folders: [FolderReference] = []
    /// Left-click opens every folder instead of offering a list. Only meaningful with 2+ folders.
    var opensAllAtOnce: Bool = false

    private enum CodingKeys: String, CodingKey { case name, icon, folders, opensAllAtOnce }

    init(name: String = "Folders",
         icon: IconSpec = .builtin(id: "folder"),
         folders: [FolderReference] = [],
         opensAllAtOnce: Bool = false) {
        self.name = name
        self.icon = icon
        self.folders = folders
        self.opensAllAtOnce = opensAllAtOnce
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Folders"
        icon = try container.decodeIfPresent(IconSpec.self, forKey: .icon) ?? .builtin(id: "folder")
        folders = try container.decodeIfPresent([FolderReference].self, forKey: .folders) ?? []
        opensAllAtOnce = try container.decodeIfPresent(Bool.self, forKey: .opensAllAtOnce) ?? false
    }

    /// Title for a folder item the user has not named, so a single-folder item reads as the
    /// folder itself rather than a generic "Folders".
    var effectiveTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "Folders" { return trimmed }
        if folders.count == 1 { return folders[0].name }
        return "Folders"
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

    /// Icon edge length in points for this item alone, or `nil` to follow the global preference.
    ///
    /// Lives on the item rather than on the icon spec because it describes *this slot in the
    /// menu bar*, not the artwork: a user who nudges their Finder icon up to 20pt expects it to
    /// stay 20pt after they swap the glyph for a different one. Keeping it here also means one
    /// size knob for every icon source instead of one that only appears for custom images.
    var iconSize: Double?

    enum Kind: Hashable, Sendable {
        case application(AppEntry)
        case group(GroupEntry)
        case folder(FolderEntry)
    }

    private enum CodingKeys: String, CodingKey { case id, kind, iconSize }

    init(id: UUID = UUID(), kind: Kind, iconSize: Double? = nil) {
        self.id = id
        self.kind = kind
        self.iconSize = iconSize
    }

    init(app: AppReference) {
        self.init(kind: .application(AppEntry(app: app)))
    }

    init(folder: FolderReference) {
        self.init(kind: .folder(FolderEntry(name: folder.name, folders: [folder])))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing `id` is recoverable — a fresh one costs nothing, since position comes from
        // this array's order. A missing `kind` is not: there would be nothing to show.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize)

        // Migration: the size override used to live inside `IconSpec.custom`, where it applied
        // to one image rather than to the item. Lift it here and strip it from the spec, so
        // there is exactly one source of truth and a user's chosen size survives the upgrade.
        if iconSize == nil, let legacy = kind.icon.customPointSize {
            iconSize = legacy
        }
        if kind.icon.customPointSize != nil {
            kind.icon = kind.icon.ignoringPointSize
        }
    }
}

nonisolated extension DockItem.Kind {
    /// Read/write access to whichever entry's icon this kind wraps, so callers never have to
    /// unwrap the enum just to change a glyph.
    var icon: IconSpec {
        get {
            switch self {
            case .application(let entry): entry.icon
            case .group(let group): group.icon
            case .folder(let folder): folder.icon
            }
        }
        set {
            switch self {
            case .application(var entry):
                entry.icon = newValue
                self = .application(entry)
            case .group(var group):
                group.icon = newValue
                self = .group(group)
            case .folder(var folder):
                folder.icon = newValue
                self = .folder(folder)
            }
        }
    }
}

nonisolated extension DockItem {
    var displayTitle: String {
        switch kind {
        case .application(let entry): entry.displayTitle
        case .group(let group): group.name
        case .folder(let folder): folder.effectiveTitle
        }
    }

    var icon: IconSpec {
        get { kind.icon }
        set { kind.icon = newValue }
    }

    /// Every app this item can launch — one for an app item, N for a group, none for folders.
    var referencedApps: [AppReference] {
        switch kind {
        case .application(let entry): [entry.app]
        case .group(let group): group.members.map(\.app)
        case .folder: []
        }
    }

    /// Every icon-library file this item references, including group members'.
    var customIconFileNames: [String] {
        switch kind {
        case .application(let entry):
            [entry.icon.customFileName].compactMap { $0 }
        case .group(let group):
            ([group.icon.customFileName] + group.members.map(\.icon.customFileName)).compactMap { $0 }
        case .folder(let folder):
            [folder.icon.customFileName].compactMap { $0 }
        }
    }

    var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    /// The size this item's icon should be drawn at, honouring its own override and clamped to
    /// what the menu bar can actually show.
    ///
    /// `@MainActor` only because the upper bound is read from the live `NSStatusBar`; everything
    /// else about `DockItem` is plain data.
    @MainActor
    func resolvedIconSize(default globalSize: Double) -> Double {
        min(max(iconSize ?? globalSize, IconRenderer.minimumIconSize), IconRenderer.maximumIconSize)
    }
}

// MARK: - Codable

nonisolated extension DockItem.Kind: Codable {
    private enum CodingKeys: String, CodingKey { case type, entry, group, folder }
    private enum Discriminator: String, Codable { case application, group, folder }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .type) {
        case .application:
            self = .application(try container.decode(AppEntry.self, forKey: .entry))
        case .group:
            self = .group(try container.decode(GroupEntry.self, forKey: .group))
        case .folder:
            self = .folder(try container.decode(FolderEntry.self, forKey: .folder))
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
        case .folder(let folder):
            try container.encode(Discriminator.folder, forKey: .type)
            try container.encode(folder, forKey: .folder)
        }
    }
}
