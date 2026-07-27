import AppKit

/// A stable, relocation-tolerant pointer to an installed application.
///
/// Apps move (`/Applications` → `~/Applications`), get renamed, and get reinstalled by
/// updaters that replace the bundle wholesale. Storing a raw path is therefore not enough.
/// We resolve in three tiers, cheapest and most durable first:
///
/// 1. **Bundle identifier** via LaunchServices — survives the bundle moving anywhere on disk.
/// 2. **Last known path** — covers apps LaunchServices hasn't indexed (e.g. an app the user
///    dragged in from a mounted volume and never launched).
/// 3. **Bookmark data** — survives a rename that also breaks the bundle ID lookup.
///
/// Marked `nonisolated` (the project defaults declarations to `@MainActor`) because this is
/// pure data with no UI affinity — ``InstalledAppsIndex`` constructs thousands of these on a
/// background executor while scanning `/Applications`.
///
/// Resolution is cheap enough to call on every click: the LaunchServices lookup is an
/// in-memory database hit, not a disk scan.
nonisolated struct AppReference: Codable, Hashable, Sendable, Identifiable {
    var bundleIdentifier: String
    /// Localized display name captured at add-time, used for menu titles and search.
    var name: String
    /// Where the bundle lived when the user added it.
    var lastKnownPath: String
    /// Non-security-scoped bookmark. Present unless bookmark creation failed.
    var bookmark: Data?

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, name: String, lastKnownPath: String, bookmark: Data? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.lastKnownPath = lastKnownPath
        self.bookmark = bookmark
    }

    /// Builds a reference from an `.app` bundle URL, or returns `nil` if the URL is not a
    /// launchable application bundle.
    init?(applicationURL url: URL) {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            return nil
        }
        self.bundleIdentifier = identifier
        self.name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        self.lastKnownPath = url.path
        self.bookmark = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

nonisolated extension AppReference {
    /// Resolves to the app's current on-disk location, or `nil` if it is no longer installed.
    var resolvedURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }

        let path = URL(fileURLWithPath: lastKnownPath)
        if FileManager.default.fileExists(atPath: path.path) {
            return path
        }

        if let bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }

        return nil
    }

    /// Every currently-running instance of this app. Usually 0 or 1, but agents and
    /// `open -n` can produce several.
    var runningInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    var isRunning: Bool {
        !runningInstances.isEmpty
    }
}
