import Foundation
import Observation
import OSLog

/// Single source of truth for the user's configuration.
///
/// Deliberately a plain `@Observable` class rather than `UserDefaults` or SwiftData:
/// the document is a small, human-readable JSON file the user can back up, diff, or hand-edit,
/// and it lives next to the icon library it references. SwiftUI observes it directly;
/// ``StatusItemCoordinator`` observes it via `withObservationTracking`.
///
/// Writes are debounced and atomic — menu bar edits arrive in bursts (a drag-reorder fires
/// on every frame) and we do not want a partially written config if the app is killed mid-save.
@Observable
final class ConfigurationStore {
    private(set) var configuration: Configuration

    /// True when the config on disk could not be decoded and was quarantined, so this session
    /// started from defaults.
    ///
    /// Callers must treat the in-memory configuration as *unknown*, not as *empty*: anything
    /// that reclaims resources by diffing against it — icon pruning, above all — has to stand
    /// down, or a decode failure escalates into deleting the user's data.
    private(set) var didFailToLoad = false

    /// Where the unreadable file was preserved, for the UI to point at.
    private(set) var quarantinedConfigurationURL: URL?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuDock",
                                                 category: "ConfigurationStore")
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private static let debounce = Duration.milliseconds(400)

    // MARK: - Locations

    /// `~/Library/Application Support/MenuDock`
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MenuDock", directoryHint: .isDirectory)
    }

    static var configurationURL: URL {
        supportDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    }

    // MARK: - Lifecycle

    init(fileURL: URL = ConfigurationStore.configurationURL) {
        self.fileURL = fileURL

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.configuration = Configuration()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            self.configuration = try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            // A config that cannot be read must never prevent launch — with no Dock icon and
            // no window, the user would have no way to reach the app at all. Preserve the file
            // and start from defaults, but record that we did so: see `didFailToLoad`.
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            self.configuration = Configuration()
            self.didFailToLoad = true
            self.quarantinedConfigurationURL = backup
            self.log.error("""
                Could not read config (\(error.localizedDescription)); \
                preserved at \(backup.lastPathComponent). Icon pruning is disabled this session.
                """)
        }
    }

    // MARK: - Mutation

    /// Applies an edit and schedules a debounced save. All mutations funnel through here so
    /// there is exactly one place that can forget to persist.
    func update(_ mutate: (inout Configuration) -> Void) {
        var copy = configuration
        mutate(&copy)
        guard copy != configuration else { return }
        configuration = copy
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    /// Forces an immediate write. Called on `applicationWillTerminate` so a pending
    /// debounce is never lost on quit.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to save configuration: \(error.localizedDescription)")
        }
    }

    // MARK: - Convenience item operations

    func addApplication(at url: URL) {
        guard let reference = AppReference(applicationURL: url) else { return }
        update { $0.items.append(DockItem(app: reference)) }
    }

    func addGroup(named name: String = "New Group") {
        update { $0.items.append(DockItem(kind: .group(GroupEntry(name: name)))) }
    }

    /// Adds an Activity or Clipboard item, unless one is already in the menu bar.
    ///
    /// The guard lives here rather than only in the UI because this is the funnel every caller
    /// goes through — the + menu, a menu action, a future URL scheme. A UI that merely hides the
    /// button enforces nothing.
    @discardableResult
    func addSingleton(_ kind: DockItem.Kind) -> DockItem.ID? {
        guard !configuration.contains(singletonLike: kind) else { return nil }
        let item = DockItem(kind: kind)
        update { $0.items.append(item) }
        return item.id
    }

    @discardableResult
    func addActivity() -> DockItem.ID? {
        addSingleton(.activity(ActivityEntry()))
    }

    @discardableResult
    func addClipboard() -> DockItem.ID? {
        addSingleton(.clipboard(ClipboardEntry()))
    }

    /// Adds one menu bar item per folder, so selecting four folders in the open panel gives four
    /// one-click icons rather than one icon that asks which folder you meant.
    func addFolders(at urls: [URL]) {
        let references = urls.compactMap(FolderReference.init(folderURL:))
        guard !references.isEmpty else { return }
        update { $0.items.append(contentsOf: references.map(DockItem.init(folder:))) }
    }

    func remove(id: DockItem.ID) {
        update { $0.items.removeAll { $0.id == id } }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        update { $0.items.move(fromOffsets: source, toOffset: destination) }
    }

    func replace(_ item: DockItem) {
        update {
            guard let index = $0.index(of: item.id) else { return }
            $0.items[index] = item
        }
    }

    func item(id: DockItem.ID) -> DockItem? {
        configuration.items.first { $0.id == id }
    }

    // MARK: - Profiles

    /// Creates a profile and switches to it.
    ///
    /// Switching immediately is the point: a profile that is created and then sits there does
    /// nothing visible, and the user has no way to find out what it did. Because a brand-new
    /// profile contains every item — membership defaults to "all", see ``DockItem/profileIDs`` —
    /// switching to it changes nothing about the menu bar, which is exactly the right first
    /// impression. The user then removes what they do not want from it.
    @discardableResult
    func addProfile(named name: String = "New Profile") -> Profile.ID {
        let profile = Profile(name: name)
        update {
            $0.profiles.append(profile)
            $0.activeProfileID = profile.id
        }
        return profile.id
    }

    func removeProfile(id: Profile.ID) {
        update { configuration in
            configuration.profiles.removeAll { $0.id == id }
            if configuration.activeProfileID == id {
                configuration.activeProfileID = nil
            }
            // Strip the deleted profile from every item's membership, and collapse a set that
            // has become empty back to `nil`. Without the second half, deleting the last profile
            // an item belonged to would leave it belonging to none — invisible under every
            // profile, and with nothing in the UI to explain why.
            for index in configuration.items.indices {
                guard var membership = configuration.items[index].profileIDs else { continue }
                membership.remove(id)
                configuration.items[index].profileIDs = membership.isEmpty ? nil : membership
            }
        }
    }

    func renameProfile(id: Profile.ID, to name: String) {
        update {
            guard let index = $0.profiles.firstIndex(where: { $0.id == id }) else { return }
            $0.profiles[index].name = name
        }
    }

    func setProfileSymbol(id: Profile.ID, to symbolName: String) {
        update {
            guard let index = $0.profiles.firstIndex(where: { $0.id == id }) else { return }
            $0.profiles[index].symbolName = symbolName
        }
    }

    /// Switches the menu bar to a profile, or to `nil` for every item.
    func activateProfile(_ id: Profile.ID?) {
        update {
            guard id == nil || $0.profiles.contains(where: { $0.id == id }) else { return }
            $0.activeProfileID = id
        }
    }

    /// Adds or removes one item from one profile.
    func setMembership(_ isMember: Bool, ofItem itemID: DockItem.ID, inProfile profile: Profile.ID) {
        update { configuration in
            guard let index = configuration.index(of: itemID) else { return }
            configuration.items[index].setMembership(
                isMember,
                ofProfile: profile,
                allProfiles: configuration.profiles.map(\.id)
            )
        }
    }
}
