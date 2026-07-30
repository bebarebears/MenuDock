import AppKit

/// A stable, relocation-tolerant pointer to a folder on disk.
///
/// The folder counterpart to ``AppReference``, and deliberately not the same type: an app has a
/// bundle identifier, which is a durable name LaunchServices can resolve from anywhere on disk.
/// A folder has no such thing, so only two tiers are available:
///
/// 1. **Last known path** — correct almost always, and free to check.
/// 2. **Bookmark data** — survives the folder being renamed or moved, which is the one case a
///    path cannot survive.
///
/// Path first because it is a single `stat` and covers the overwhelming majority; the bookmark
/// is the fallback that keeps a renamed folder working instead of silently breaking a menu bar
/// icon the user set up months ago.
nonisolated struct FolderReference: Codable, Hashable, Sendable, Identifiable {
    /// Own identity rather than the path, so two entries pointing at the same folder stay
    /// individually selectable in the settings list.
    var id: UUID = UUID()
    /// Localized display name captured when the folder was added (`Documents`, not `documents`).
    var name: String
    var lastKnownPath: String
    /// Non-security-scoped bookmark. Present unless bookmark creation failed.
    var bookmark: Data?

    private enum CodingKeys: String, CodingKey { case id, name, lastKnownPath, bookmark }

    init(id: UUID = UUID(), name: String, lastKnownPath: String, bookmark: Data? = nil) {
        self.id = id
        self.name = name
        self.lastKnownPath = lastKnownPath
        self.bookmark = bookmark
    }

    /// Builds a reference from a URL, or returns `nil` if it is not a directory.
    ///
    /// Application bundles are rejected: they are directories on disk, but a user dropping one
    /// means "launch this", not "browse inside it" — see ``DockItem`` construction in the
    /// settings sidebar.
    init?(folderURL url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isApplicationKey])
        guard values?.isDirectory == true, values?.isApplication != true else { return nil }

        self.id = UUID()
        self.name = FileManager.default.displayName(atPath: url.path)
        self.lastKnownPath = url.path
        self.bookmark = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        lastKnownPath = try container.decode(String.self, forKey: .lastKnownPath)
        // A missing name is recoverable from the path; a missing path is not.
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? URL(fileURLWithPath: lastKnownPath).lastPathComponent
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
    }
}

nonisolated extension FolderReference {
    /// Resolves to the folder's current location, or `nil` if it no longer exists.
    var resolvedURL: URL? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: lastKnownPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: lastKnownPath, isDirectory: true)
        }

        if let bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    /// Path with the home directory abbreviated, for display in settings.
    var displayPath: String {
        (lastKnownPath as NSString).abbreviatingWithTildeInPath
    }
}
