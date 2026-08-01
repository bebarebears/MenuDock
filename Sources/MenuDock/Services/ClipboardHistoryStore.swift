import AppKit
import CryptoKit
import Observation
import OSLog

/// Everything the user has copied, and the files behind it.
///
/// ## Shape of the storage
///
/// `~/Library/Application Support/MenuDock/Clipboard/` holds one `history.json` index plus one
/// payload file per item, named from the item's UUID. The index is small enough to load at launch
/// and rewrite on every capture; the payloads are read only when an item is chosen or previewed.
/// See ``ClipboardItem`` for why it is split that way.
///
/// ## Why this is not in `ConfigurationStore`
///
/// The configuration is the user's *settings* — a small file they are invited to hand-edit, diff
/// and back up. Clipboard history is neither small nor interesting to edit by hand, it changes
/// hundreds of times a day rather than when the user opens Settings, and it is the one part of
/// MenuDock's storage a user might want to delete without losing their menu bar. Keeping the two
/// apart means "clear my history" is a directory, and a config backup does not carry a copy of
/// everything you pasted last week.
@Observable
final class ClipboardHistoryStore {
    /// Newest first — the order the dropdown shows, so the list never has to sort.
    private(set) var items: [ClipboardItem] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuDock",
                                                 category: "Clipboard")
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private static let debounce = Duration.milliseconds(600)

    /// Decoded thumbnails, kept so scrolling the list does not re-read PNGs from disk.
    ///
    /// Bounded rather than unlimited: a history of 1,000 images would otherwise pin every
    /// thumbnail in memory for the life of a process that runs for weeks.
    @ObservationIgnored private var thumbnailCache: [UUID: NSImage] = [:]
    @ObservationIgnored private static let thumbnailCacheLimit = 120

    /// Longest preview string kept in the index. Two lines of a list row is the most that can be
    /// shown, and a copied 4 MB log file should not put 4 MB into a file we rewrite on every copy.
    static let previewLimit = 220

    /// Edge length of the stored thumbnail, in pixels. Sized for a 2× display at the row's 34pt.
    static let thumbnailPixels: CGFloat = 68

    static var clipboardDirectory: URL {
        ConfigurationStore.supportDirectory.appending(path: "Clipboard", directoryHint: .isDirectory)
    }

    private var indexURL: URL {
        directory.appending(path: "history.json", directoryHint: .notDirectory)
    }

    init(directory: URL = ClipboardHistoryStore.clipboardDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Loading

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            let decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
            // Drop anything whose payload has gone missing — a half-copied support folder, or a
            // file the user deleted by hand. A row that cannot be pasted is worse than no row.
            items = decoded.filter { hasPayload($0) }
            if items.count != decoded.count { scheduleSave() }
        } catch {
            // Unlike the configuration, a broken history index is not worth quarantining and
            // telling the user about: there is nothing here they chose or arranged, and the next
            // thing they copy rebuilds it. Orphaned payload files are swept below.
            log.error("Could not read clipboard history: \(error.localizedDescription)")
            items = []
            sweepOrphanedPayloads()
        }
    }

    private func hasPayload(_ item: ClipboardItem) -> Bool {
        switch item.kind {
        case .text:
            FileManager.default.fileExists(atPath: url(item.textFileName).path)
        case .image:
            FileManager.default.fileExists(atPath: url(item.imageFileName).path)
        case .files:
            // File items reference paths rather than owning payloads, so there is nothing of ours
            // to be missing. A path that no longer resolves is still worth listing — the user may
            // have the volume unmounted — and is marked in the row instead.
            true
        }
    }

    private func url(_ fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    /// Writes the index immediately. Called on quit so a pending debounce is never lost.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: indexURL, options: .atomic)
        } catch {
            log.error("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    /// Files a fresh capture, or promotes the existing copy of identical content to the top.
    ///
    /// Promotion rather than a second row is what keeps the list useful: copying the same snippet
    /// four times while working should leave one entry at the top, not four identical ones
    /// pushing everything else off the end.
    func record(_ capture: ClipboardCapture, retention: ClipboardRetention, maxItems: Int) {
        if let existing = items.firstIndex(where: { $0.contentHash == capture.contentHash }) {
            var promoted = items.remove(at: existing)
            promoted.capturedAt = Date()
            promoted.sourceAppName = capture.sourceAppName ?? promoted.sourceAppName
            promoted.sourceBundleIdentifier =
                capture.sourceBundleIdentifier ?? promoted.sourceBundleIdentifier
            items.insert(promoted, at: 0)
            scheduleSave()
            return
        }

        let item = ClipboardItem(
            kind: capture.kind,
            preview: capture.preview,
            contentHash: capture.contentHash,
            sourceAppName: capture.sourceAppName,
            sourceBundleIdentifier: capture.sourceBundleIdentifier,
            byteCount: capture.byteCount
        )

        // Payload files are written off the main actor: a copied screenshot is several megabytes,
        // and the menu bar has no business waiting on a disk write for it. Only `Data` crosses the
        // boundary, so there is nothing here to race on.
        let writes = capture.payloads(for: item).map { (url($0.key), $0.value) }
        Task.detached(priority: .utility) {
            for (destination, data) in writes {
                try? data.write(to: destination, options: .atomic)
            }
        }

        // Cached straight from the bytes in hand, so the new row can draw before the detached
        // write above has reached the disk.
        if let data = capture.thumbnailData, let thumbnail = NSImage(data: data) {
            store(thumbnail: thumbnail, for: item.id)
        }

        items.insert(item, at: 0)
        prune(retention: retention, maxItems: maxItems)
        scheduleSave()
    }

    // MARK: - Removal

    func remove(id: ClipboardItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        delete(payloadsOf: items.remove(at: index))
        thumbnailCache.removeValue(forKey: id)
        scheduleSave()
    }

    /// Empties the history and everything backing it.
    func clear() {
        for item in items { delete(payloadsOf: item) }
        items.removeAll()
        thumbnailCache.removeAll()
        saveNow()
        // Belt and braces: anything left in the directory after that is by definition not
        // referenced, and "Clear History" has to mean the bytes are gone.
        sweepOrphanedPayloads()
    }

    /// Applies the entry's retention rules, deleting what has aged out or fallen off the end.
    func prune(retention: ClipboardRetention, maxItems: Int) {
        var removed: [ClipboardItem] = []

        if let lifetime = retention.seconds {
            let cutoff = Date().addingTimeInterval(-lifetime)
            // Partitioned rather than filtered in place so the payload files of the expired ones
            // can be deleted — dropping them from the array alone would leak the bytes forever.
            let expired = items.filter { $0.capturedAt < cutoff }
            if !expired.isEmpty {
                removed.append(contentsOf: expired)
                items.removeAll { $0.capturedAt < cutoff }
            }
        }

        let limit = min(max(maxItems, ClipboardEntry.maxItemsRange.lowerBound),
                        ClipboardEntry.maxItemsRange.upperBound)
        if items.count > limit {
            removed.append(contentsOf: items[limit...])
            items.removeSubrange(limit...)
        }

        guard !removed.isEmpty else { return }
        for item in removed {
            delete(payloadsOf: item)
            thumbnailCache.removeValue(forKey: item.id)
        }
        scheduleSave()
    }

    private func delete(payloadsOf item: ClipboardItem) {
        for fileName in item.payloadFileNames {
            try? FileManager.default.removeItem(at: url(fileName))
        }
    }

    /// Removes payload files no item refers to.
    ///
    /// Unlike ``IconLibrary/pruneOrphans(keeping:)`` this genuinely deletes, and that asymmetry is
    /// deliberate: an icon is artwork the user supplied and would have to find again, while an
    /// orphaned clipboard payload is a copy of something already gone from the list. Setting it
    /// aside would mean "Clear History" quietly left the bytes on disk.
    private func sweepOrphanedPayloads() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        let referenced = Set(items.flatMap(\.payloadFileNames))
        for file in contents where file.lastPathComponent != "history.json" {
            guard !referenced.contains(file.lastPathComponent) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Reading payloads

    /// The full text of a text item, read on demand.
    func text(for item: ClipboardItem) -> String? {
        guard case .text = item.kind else { return nil }
        return try? String(contentsOf: url(item.textFileName), encoding: .utf8)
    }

    /// The row thumbnail for an image item, from the cache or from disk.
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.isImage else { return nil }
        if let cached = thumbnailCache[item.id] { return cached }
        guard let image = NSImage(contentsOf: url(item.thumbnailFileName)) else { return nil }
        store(thumbnail: image, for: item.id)
        return image
    }

    private func store(thumbnail: NSImage, for id: UUID) {
        if thumbnailCache.count >= Self.thumbnailCacheLimit {
            thumbnailCache.removeAll(keepingCapacity: true)
        }
        thumbnailCache[id] = thumbnail
    }

    /// Puts an item back on the general pasteboard, in every representation it was captured with.
    ///
    /// Returns `false` when the payload could not be read — a text file deleted underneath us, or
    /// a copied file whose volume is no longer mounted. Callers use that to explain themselves
    /// rather than silently pasting the *previous* clipboard contents, which is the failure mode
    /// that makes a clipboard manager untrustworthy.
    @discardableResult
    func writeToPasteboard(_ item: ClipboardItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text(let hasRichText):
            guard let text = text(for: item) else { return false }
            if hasRichText, let rtf = try? Data(contentsOf: url(item.richTextFileName)) {
                pasteboard.setData(rtf, forType: .rtf)
            }
            return pasteboard.setString(text, forType: .string)

        case .image:
            guard let data = try? Data(contentsOf: url(item.imageFileName)) else { return false }
            pasteboard.setData(data, forType: .png)
            // TIFF alongside PNG, because a number of older apps only look for TIFF and would
            // otherwise see an empty pasteboard.
            if let tiff = NSImage(data: data)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            return true

        case .files(let paths):
            let urls = paths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return false }
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }

    // MARK: - Reporting

    /// Bytes of payload, for the summary line in Settings. File items contribute nothing because
    /// they store paths, not copies.
    var totalByteCount: Int {
        items.reduce(0) { $0 + $1.byteCount }
    }
}

// MARK: - Capture

/// One reading of the pasteboard, before it becomes a stored item.
///
/// A value type carrying raw `Data` rather than AppKit objects, so the parts of recording that
/// have no business on the main actor — hashing and writing files — can be handed off without
/// dragging `NSPasteboard` or `NSImage` across an isolation boundary.
nonisolated struct ClipboardCapture: Sendable {
    var kind: ClipboardItem.Kind
    var preview: String
    var contentHash: String
    var byteCount: Int
    var sourceAppName: String?
    var sourceBundleIdentifier: String?

    var textData: Data?
    var richTextData: Data?
    var imageData: Data?
    var thumbnailData: Data?

    /// File name → bytes, for everything this capture needs written to disk.
    func payloads(for item: ClipboardItem) -> [String: Data] {
        var result: [String: Data] = [:]
        if let textData { result[item.textFileName] = textData }
        if let richTextData { result[item.richTextFileName] = richTextData }
        if let imageData { result[item.imageFileName] = imageData }
        if let thumbnailData { result[item.thumbnailFileName] = thumbnailData }
        return result
    }

    /// Stable digest of what was copied, used to recognise a re-copy.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
