import AppKit
import Observation

/// A searchable list of installed applications, for the "add app" picker.
///
/// The scan touches the filesystem, so it runs off the main actor and publishes results back.
/// It is shallow by design: `/Applications/Foo.app` and one level into subfolders such as
/// `/Applications/Utilities`, which is where essentially every user-visible app lives. A deep
/// recursive crawl would be slower and would surface helper apps nobody wants in a menu bar.
@Observable
final class InstalledAppsIndex {
    private(set) var applications: [AppReference] = []
    private(set) var isScanning = false

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// `nonisolated` so the background scan can read it without hopping to the main actor.
    private nonisolated static let searchRoots: [URL] = {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
        if let home = FileManager.default.homeDirectoryForCurrentUser as URL? {
            roots.append(home.appending(path: "Applications", directoryHint: .isDirectory))
        }
        return roots
    }()

    func refresh() {
        scanTask?.cancel()
        isScanning = true
        scanTask = Task {
            let found = await Self.scan()
            guard !Task.isCancelled else { return }
            self.applications = found
            self.isScanning = false
        }
    }

    func search(_ query: String) -> [AppReference] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return applications }
        return applications.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Runs on a background executor: `AppReference` is `Sendable`, so the result crosses
    /// back to the main actor without copying concerns.
    private nonisolated static func scan() async -> [AppReference] {
        await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            var seen = Set<String>()
            var results: [AppReference] = []

            func consider(_ url: URL) {
                guard url.pathExtension == "app",
                      let reference = AppReference(applicationURL: url),
                      seen.insert(reference.bundleIdentifier).inserted
                else { return }
                results.append(reference)
            }

            for root in searchRoots {
                guard let entries = try? manager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for entry in entries {
                    if entry.pathExtension == "app" {
                        consider(entry)
                    } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        // One level deeper: /Applications/Utilities, vendor folders, etc.
                        let nested = (try? manager.contentsOfDirectory(
                            at: entry,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        )) ?? []
                        nested.forEach(consider)
                    }
                }
            }

            return results.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
    }
}
