import Foundation

/// How a menu bar entry decides what to draw.
///
/// Encoded with an explicit `type` discriminator rather than relying on Swift's synthesized
/// enum coding, which produces brittle nested-container JSON that breaks the moment a case
/// gains or loses an associated value.
nonisolated enum IconSpec: Codable, Hashable, Sendable {
    /// Use the application's own bundle icon (the default for newly added apps).
    case appIcon
    /// An SF Symbol, by name. Always template-rendered, so it tints for free.
    case symbol(String)
    /// One of MenuDock's built-in glyphs, drawn procedurally. `id` is a stable catalogue slug.
    case builtin(id: String)
    /// A user-supplied image copied into the icon library. `fileName` is relative to the
    /// library directory — never an absolute path, so the config stays portable.
    ///
    /// `pointSize` overrides the global icon size for this artwork alone; `nil` means "follow
    /// the global size". Only custom artwork gets this knob, because only custom artwork needs
    /// it: the built-in glyphs are drawn on one grid with one stroke weight, and an app's own
    /// icon is a square bitmap Apple already balanced. A user's logo might be a wide wordmark
    /// or a tight square with no padding, and no single global size flatters both.
    case custom(fileName: String, rendering: RenderingMode, pointSize: Double?)

    /// Controls the monochrome-adaptation behaviour described in ``IconRenderer``.
    enum RenderingMode: String, Codable, Hashable, Sendable, CaseIterable {
        /// Inspect the image and template it only if it is effectively monochrome.
        case auto
        /// Always treat as a template: discard colour, tint to match the menu bar.
        case template
        /// Never template: draw the source pixels exactly as supplied.
        case original

        var displayName: String {
            switch self {
            case .auto: "Automatic"
            case .template: "Monochrome (adapts to menu bar)"
            case .original: "Original colours"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, name, fileName, rendering, id, pointSize
    }

    private enum Kind: String, Codable {
        case appIcon, symbol, builtin, custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .appIcon:
            self = .appIcon
        case .symbol:
            self = .symbol(try container.decode(String.self, forKey: .name))
        case .builtin:
            self = .builtin(id: try container.decode(String.self, forKey: .id))
        case .custom:
            self = .custom(
                fileName: try container.decode(String.self, forKey: .fileName),
                // Tolerate configs written before `rendering` and `pointSize` existed.
                rendering: try container.decodeIfPresent(RenderingMode.self, forKey: .rendering) ?? .auto,
                pointSize: try container.decodeIfPresent(Double.self, forKey: .pointSize)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .appIcon:
            try container.encode(Kind.appIcon, forKey: .type)
        case .symbol(let name):
            try container.encode(Kind.symbol, forKey: .type)
            try container.encode(name, forKey: .name)
        case .builtin(let id):
            try container.encode(Kind.builtin, forKey: .type)
            try container.encode(id, forKey: .id)
        case .custom(let fileName, let rendering, let pointSize):
            try container.encode(Kind.custom, forKey: .type)
            try container.encode(fileName, forKey: .fileName)
            try container.encode(rendering, forKey: .rendering)
            // Encoded only when set, so "follow the global size" stays the absence of a value
            // rather than a number that silently stops tracking the preference.
            try container.encodeIfPresent(pointSize, forKey: .pointSize)
        }
    }

    /// The icon-library file this spec owns, if any. Used for reference-counting on delete.
    var customFileName: String? {
        if case .custom(let fileName, _, _) = self { return fileName }
        return nil
    }

    /// The per-icon size override, if this is custom artwork the user has resized.
    var customPointSize: Double? {
        if case .custom(_, _, let pointSize) = self { return pointSize }
        return nil
    }

    /// The same spec with its size override dropped.
    ///
    /// For previews that pick their own size — the 48pt icon well, say — where honouring a
    /// 12pt override would shrink the artwork into a corner of the well instead of showing
    /// the user what they are editing.
    var ignoringPointSize: IconSpec {
        guard case .custom(let fileName, let rendering, _) = self else { return self }
        return .custom(fileName: fileName, rendering: rendering, pointSize: nil)
    }

    var builtinID: String? {
        if case .builtin(let id) = self { return id }
        return nil
    }
}
