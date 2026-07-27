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
}
