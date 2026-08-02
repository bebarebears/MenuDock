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

    /// A fixed colour for this item's icon, or `nil` to take the menu bar's own tint.
    ///
    /// Beside `iconSize` and for the same reason: it describes this slot rather than the artwork,
    /// so a user who makes their Slack icon purple keeps it purple after swapping the glyph. See
    /// ``IconTint`` for what a tint gives up in exchange for being recognisable.
    var tint: IconTint?

    /// How readily this item yields its place when the menu bar runs short. See ``ItemPriority``.
    var priority: ItemPriority = .standard

    /// Which profiles show this item, or `nil` for *all of them*.
    ///
    /// `nil` and "every profile" are deliberately the same state rather than two, and that is
    /// what makes profiles a free upgrade: every item written before profiles existed decodes
    /// with no membership, which reads as belonging everywhere, so a user who adds a profile
    /// finds their menu bar unchanged instead of empty. An explicitly *empty* set means the same
    /// thing for the same reason — an item in no profile at all would be one the user could
    /// configure but never see, which is not a state worth being able to reach.
    var profileIDs: Set<Profile.ID>?

    enum Kind: Hashable, Sendable {
        case application(AppEntry)
        case group(GroupEntry)
        case folder(FolderEntry)
        case activity(ActivityEntry)
        case clipboard(ClipboardEntry)

        /// Kinds that may appear **at most once** in the menu bar.
        ///
        /// Both of these are single system-wide facilities rather than pointers at something the
        /// user chose: a second Activity item would sample the same counters twice and a second
        /// Clipboard item would watch the same pasteboard into a second history, competing for
        /// the same keyboard shortcut. Neither has a coherent meaning, so the limit is enforced
        /// rather than merely discouraged — in the Add menu, in the store, and on decode.
        var isSingleton: Bool {
            switch self {
            case .application, .group, .folder: false
            case .activity, .clipboard: true
            }
        }

        /// Identity for singleton enforcement: two kinds collide when both are singletons of the
        /// same case. Compared on this rather than on the whole value, which carries the user's
        /// settings and so is never equal between two items.
        var singletonToken: String? {
            switch self {
            case .application, .group, .folder: nil
            case .activity: "activity"
            case .clipboard: "clipboard"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, iconSize, tint, priority, profileIDs
    }

    init(id: UUID = UUID(),
         kind: Kind,
         iconSize: Double? = nil,
         tint: IconTint? = nil,
         priority: ItemPriority = .standard,
         profileIDs: Set<Profile.ID>? = nil) {
        self.id = id
        self.kind = kind
        self.iconSize = iconSize
        self.tint = tint
        self.priority = priority
        self.profileIDs = profileIDs
    }

    init(app: AppReference) {
        self.init(kind: .application(AppEntry(app: app)))
    }

    init(folder: FolderReference) {
        self.init(kind: .folder(FolderEntry(name: folder.name, folders: [folder])))
    }

    init(activity: ActivityEntry = ActivityEntry()) {
        self.init(kind: .activity(activity))
    }

    init(clipboard: ClipboardEntry = ClipboardEntry()) {
        self.init(kind: .clipboard(clipboard))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing `id` is recoverable — a fresh one costs nothing, since position comes from
        // this array's order. A missing `kind` is not: there would be nothing to show.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize)
        tint = try container.decodeIfPresent(IconTint.self, forKey: .tint)
        // Tolerant of an unrecognised raw value as well as an absent key: a priority written by a
        // newer MenuDock must not fail the decode of the whole configuration. See the note on
        // `decodeTolerantly` in ``ActivityEntry``.
        priority = try container.decodeTolerantly(ItemPriority.self, forKey: .priority,
                                                  fallback: .standard)
        profileIDs = try container.decodeIfPresent(Set<Profile.ID>.self, forKey: .profileIDs)

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
    ///
    /// An **activity** item has no icon in this sense: its whole appearance is generated from
    /// live data by ``ActivityRenderer``, and there is no artwork for a user to choose. Rather
    /// than make this property optional — which would put an unwrap at every one of its callers
    /// for the sake of one case — it reports a representative symbol and ignores writes. The
    /// symbol is what surfaces where a generic icon is genuinely wanted (the Add menu), and the
    /// two places that draw the real thing ask ``ActivityRenderer`` directly.
    var icon: IconSpec {
        get {
            switch self {
            case .application(let entry): entry.icon
            case .group(let group): group.icon
            case .folder(let folder): folder.icon
            case .clipboard(let clipboard): clipboard.icon
            case .activity: .symbol("waveform.path.ecg")
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
            case .clipboard(var clipboard):
                clipboard.icon = newValue
                self = .clipboard(clipboard)
            case .activity:
                break
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
        case .activity(let activity): activity.effectiveTitle
        case .clipboard(let clipboard): clipboard.effectiveTitle
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
        case .folder, .activity, .clipboard: []
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
        case .clipboard(let clipboard):
            [clipboard.icon.customFileName].compactMap { $0 }
        case .activity:
            []
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

    var isActivity: Bool {
        if case .activity = kind { return true }
        return false
    }

    var isClipboard: Bool {
        if case .clipboard = kind { return true }
        return false
    }

    /// The entry behind an activity item, or `nil` for every other kind.
    var activity: ActivityEntry? {
        if case .activity(let entry) = kind { return entry }
        return nil
    }

    /// The entry behind a clipboard item, or `nil` for every other kind.
    var clipboard: ClipboardEntry? {
        if case .clipboard(let entry) = kind { return entry }
        return nil
    }

    /// Whether this item appears while `profile` is the active one.
    ///
    /// A `nil` profile is "All Items", which shows everything; a `nil` or empty membership is
    /// "every profile", which is shown by all of them. Both defaults point the same way on
    /// purpose — nothing disappears until the user has said which profile it belongs to.
    func isMember(ofProfile profile: Profile.ID?) -> Bool {
        guard let profile else { return true }
        guard let profileIDs, !profileIDs.isEmpty else { return true }
        return profileIDs.contains(profile)
    }

    /// Adds or removes this item from one profile, normalising "in every profile" back to `nil`.
    ///
    /// Membership starts as `nil` — meaning *all* — so the first meaningful edit is a *removal*,
    /// and removing one profile from "all of them" has to first spell out what "all of them"
    /// currently is. Hence `allProfiles`: without it, unticking Work from a brand-new item would
    /// silently mean "in no profile", and the item would vanish from every one of them at once.
    mutating func setMembership(_ isMember: Bool, ofProfile profile: Profile.ID,
                                allProfiles: [Profile.ID]) {
        var membership = profileIDs ?? Set(allProfiles)
        if isMember {
            membership.insert(profile)
        } else {
            membership.remove(profile)
        }
        // Back to `nil` when it covers everything, so the config keeps saying "all" rather than
        // enumerating a list that would then need updating every time a profile is created.
        profileIDs = membership == Set(allProfiles) ? nil : membership
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
    private enum CodingKeys: String, CodingKey {
        case type, entry, group, folder, activity, clipboard
    }
    private enum Discriminator: String, Codable {
        case application, group, folder, activity, clipboard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .type) {
        case .application:
            self = .application(try container.decode(AppEntry.self, forKey: .entry))
        case .group:
            self = .group(try container.decode(GroupEntry.self, forKey: .group))
        case .folder:
            self = .folder(try container.decode(FolderEntry.self, forKey: .folder))
        case .activity:
            self = .activity(try container.decode(ActivityEntry.self, forKey: .activity))
        case .clipboard:
            self = .clipboard(try container.decode(ClipboardEntry.self, forKey: .clipboard))
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
        case .activity(let activity):
            try container.encode(Discriminator.activity, forKey: .type)
            try container.encode(activity, forKey: .activity)
        case .clipboard(let clipboard):
            try container.encode(Discriminator.clipboard, forKey: .type)
            try container.encode(clipboard, forKey: .clipboard)
        }
    }
}
