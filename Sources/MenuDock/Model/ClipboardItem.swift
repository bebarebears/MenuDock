import Foundation

/// One thing the user copied.
///
/// ## Metadata here, bytes on disk
///
/// This struct is what gets encoded into the history index, and the index is read in full at
/// launch and rewritten on every capture — so it holds only what a *list row* needs: a short
/// preview, where it came from, how big it is. The actual payload (the full text, the image, the
/// RTF) lives in its own file named from ``id`` and is read only when an item is chosen or
/// previewed. A thousand-entry history is therefore a few hundred kilobytes of JSON rather than
/// a few hundred megabytes of base64, and pasting a 20 MB screenshot does not make every
/// subsequent capture rewrite 20 MB.
///
/// File items are the exception that proves the rule: they store *paths*, and the files
/// themselves are never copied. Copying them would silently duplicate gigabytes and would make
/// "paste the file I copied" mean a stale snapshot instead of the file itself.
nonisolated struct ClipboardItem: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: Kind
    var capturedAt: Date = Date()

    /// One line for the list row. Already trimmed and collapsed — the row must not do work.
    var preview: String

    /// Digest of the payload, used to recognise a re-copy of something already in the history so
    /// it is promoted to the top instead of stored twice.
    var contentHash: String

    var sourceAppName: String?
    var sourceBundleIdentifier: String?

    /// Payload size in bytes, for the "how much is this costing me?" line in Settings.
    var byteCount: Int = 0

    nonisolated enum Kind: Hashable, Sendable {
        /// Plain text, optionally with RTF alongside it so pasting into a rich editor keeps
        /// formatting the user copied.
        case text(hasRichText: Bool)
        /// A bitmap, stored as PNG. Dimensions are kept for the row's subtitle.
        case image(pixelWidth: Int, pixelHeight: Int)
        /// File URLs, by path. Never copies of the files.
        case files(paths: [String])
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, capturedAt, preview, contentHash
        case sourceAppName, sourceBundleIdentifier, byteCount
    }

    init(id: UUID = UUID(),
         kind: Kind,
         capturedAt: Date = Date(),
         preview: String,
         contentHash: String,
         sourceAppName: String? = nil,
         sourceBundleIdentifier: String? = nil,
         byteCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.preview = preview
        self.contentHash = contentHash
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.byteCount = byteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `kind` is the one field with no sensible fallback — an item whose type is unknown
        // cannot be listed or pasted. Everything else degrades.
        kind = try container.decode(Kind.self, forKey: .kind)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceBundleIdentifier = try container
            .decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
    }
}

// MARK: - Presentation

nonisolated extension ClipboardItem {
    /// SF Symbol for the row's leading slot, when there is no thumbnail to show instead.
    var symbolName: String {
        switch kind {
        case .text(let hasRichText): hasRichText ? "doc.richtext" : "text.alignleft"
        case .image: "photo"
        case .files(let paths): paths.count > 1 ? "doc.on.doc" : "doc"
        }
    }

    /// The row's second line, describing *what* this is rather than what it says. ``preview``
    /// carries the content itself, so these two must not repeat each other.
    var typeDescription: String {
        switch kind {
        case .text(let hasRichText): hasRichText ? "Rich text" : "Text"
        case .image: "Image"
        case .files(let paths): paths.count == 1 ? "File" : "\(paths.count) files"
        }
    }

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }

    // MARK: Payload locations
    //
    // Derived from `id` rather than stored, so the index never carries a path that could
    // disagree with what is on disk, and deleting an item is a fixed set of file names.

    var textFileName: String { "\(id.uuidString).txt" }
    var richTextFileName: String { "\(id.uuidString).rtf" }
    var imageFileName: String { "\(id.uuidString).png" }
    var thumbnailFileName: String { "\(id.uuidString)-thumb.png" }

    /// Every file this item owns, for deletion. File items own none — they only reference paths.
    var payloadFileNames: [String] {
        switch kind {
        case .text(let hasRichText):
            hasRichText ? [textFileName, richTextFileName] : [textFileName]
        case .image:
            [imageFileName, thumbnailFileName]
        case .files:
            []
        }
    }
}

// MARK: - Codable

nonisolated extension ClipboardItem.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, hasRichText, pixelWidth, pixelHeight, paths
    }
    private enum Discriminator: String, Codable { case text, image, files }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .type) {
        case .text:
            self = .text(
                hasRichText: try container.decodeIfPresent(Bool.self, forKey: .hasRichText) ?? false
            )
        case .image:
            self = .image(
                pixelWidth: try container.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0,
                pixelHeight: try container.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
            )
        case .files:
            self = .files(paths: try container.decodeIfPresent([String].self, forKey: .paths) ?? [])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let hasRichText):
            try container.encode(Discriminator.text, forKey: .type)
            try container.encode(hasRichText, forKey: .hasRichText)
        case .image(let width, let height):
            try container.encode(Discriminator.image, forKey: .type)
            try container.encode(width, forKey: .pixelWidth)
            try container.encode(height, forKey: .pixelHeight)
        case .files(let paths):
            try container.encode(Discriminator.files, forKey: .type)
            try container.encode(paths, forKey: .paths)
        }
    }
}
