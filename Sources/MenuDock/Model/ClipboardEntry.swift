import Foundation

/// How long a clipboard item is kept before it is discarded.
///
/// The raw values are written to the configuration file, so they are stable slugs. `forever` is
/// spelled out as a case rather than represented by a `nil` interval because it is a *choice* the
/// user makes, and an optional would make "not configured" and "keep everything" the same value.
nonisolated enum ClipboardRetention: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case hour
    case day
    case week
    case month
    case forever

    var id: String { rawValue }

    /// Age at which an item expires, or `nil` for "never expires".
    var seconds: TimeInterval? {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        case .forever: nil
        }
    }

    var displayName: String {
        switch self {
        case .hour: "1 hour"
        case .day: "1 day"
        case .week: "1 week"
        case .month: "30 days"
        case .forever: "Until I clear it"
        }
    }
}

/// The clipboard history item: one menu bar slot that records what you copy and hands it back.
///
/// ## Why the settings live here rather than in `Preferences`
///
/// Retention, capture rules and the shortcut are all properties of *this item*, and the item is
/// what decides whether any of it happens at all — with no Clipboard item in the menu bar nothing
/// is recorded, no timer runs, and no hotkey is registered. Putting the knobs in global
/// preferences would leave them stranded in the General tab describing a feature the user may not
/// have added, and would make "is anything watching my pasteboard?" a question with two answers.
///
/// Only one of these may exist at a time — see ``Configuration/collapsingDuplicateSingletons()``.
nonisolated struct ClipboardEntry: Codable, Hashable, Sendable {
    var name: String = "Clipboard"
    var icon: IconSpec = .builtin(id: "clipboard")

    // MARK: History

    var retention: ClipboardRetention = .week

    /// Hard ceiling on stored items, whatever ``retention`` says.
    ///
    /// Retention alone is not enough: a week of an active machine's clipboard is thousands of
    /// entries and a list nobody can find anything in. Both limits apply, and whichever bites
    /// first wins.
    var maxItems: Int = 200

    static let maxItemsRange: ClosedRange<Int> = 10...1_000

    // MARK: Capture

    var capturesText: Bool = true
    var capturesImages: Bool = true
    var capturesFiles: Bool = true

    /// Skip items marked concealed or transient by the app that copied them.
    ///
    /// Password managers flag their copies with `org.nspasteboard.ConcealedType`, and several
    /// apps mark scratch copies `TransientType`. Honouring both is the difference between a
    /// history that is useful and one that is a liability, so it defaults on — but it is a
    /// visible toggle rather than a silent rule, because a user who finds an expected item
    /// missing deserves to be able to see why.
    var ignoresConfidential: Bool = true

    // MARK: Recall

    var hotkeyEnabled: Bool = true

    /// After choosing an item, send ⌘V to whatever was frontmost.
    ///
    /// Requires Accessibility permission — macOS will not let one app synthesise keystrokes for
    /// another without it. With the toggle on but permission not granted, choosing an item still
    /// puts it on the pasteboard and returns focus; the user presses ⌘V themselves. That is why
    /// this is not gated on the permission: the feature degrades to something useful rather than
    /// to nothing.
    var pastesAutomatically: Bool = true

    private enum CodingKeys: String, CodingKey {
        case name, icon, retention, maxItems
        case capturesText, capturesImages, capturesFiles, ignoresConfidential
        case hotkeyEnabled, pastesAutomatically
    }

    init(name: String = "Clipboard",
         icon: IconSpec = .builtin(id: "clipboard"),
         retention: ClipboardRetention = .week,
         maxItems: Int = 200,
         capturesText: Bool = true,
         capturesImages: Bool = true,
         capturesFiles: Bool = true,
         ignoresConfidential: Bool = true,
         hotkeyEnabled: Bool = true,
         pastesAutomatically: Bool = true) {
        self.name = name
        self.icon = icon
        self.retention = retention
        self.maxItems = maxItems
        self.capturesText = capturesText
        self.capturesImages = capturesImages
        self.capturesFiles = capturesFiles
        self.ignoresConfidential = ignoresConfidential
        self.hotkeyEnabled = hotkeyEnabled
        self.pastesAutomatically = pastesAutomatically
    }

    /// Decoded tolerantly — see the note on ``Configuration``. `retention` additionally tolerates
    /// an unrecognised *value*, so a config touched by a future MenuDock that has learned a new
    /// duration does not fail to decode here and quarantine the user's whole menu bar.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Clipboard"
        icon = try container.decodeIfPresent(IconSpec.self, forKey: .icon)
            ?? .builtin(id: "clipboard")

        let rawRetention = try container.decodeIfPresent(String.self, forKey: .retention)
        retention = rawRetention.flatMap(ClipboardRetention.init(rawValue:)) ?? .week

        let rawMax = try container.decodeIfPresent(Int.self, forKey: .maxItems) ?? 200
        maxItems = min(max(rawMax, Self.maxItemsRange.lowerBound), Self.maxItemsRange.upperBound)

        capturesText = try container.decodeIfPresent(Bool.self, forKey: .capturesText) ?? true
        capturesImages = try container.decodeIfPresent(Bool.self, forKey: .capturesImages) ?? true
        capturesFiles = try container.decodeIfPresent(Bool.self, forKey: .capturesFiles) ?? true
        ignoresConfidential = try container
            .decodeIfPresent(Bool.self, forKey: .ignoresConfidential) ?? true
        hotkeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? true
        pastesAutomatically = try container
            .decodeIfPresent(Bool.self, forKey: .pastesAutomatically) ?? true
    }

    var effectiveTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Clipboard" : trimmed
    }

    /// Whether this entry wants anything at all recorded. All three off is a legitimate state —
    /// it is how a user pauses capture without losing what they already have.
    var capturesAnything: Bool {
        capturesText || capturesImages || capturesFiles
    }

    func captures(_ kind: ClipboardItem.Kind) -> Bool {
        switch kind {
        case .text: capturesText
        case .image: capturesImages
        case .files: capturesFiles
        }
    }
}
