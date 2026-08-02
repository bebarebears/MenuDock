import AppKit

/// A fixed colour for one menu bar item's icon, replacing the menu bar's own tint.
///
/// ## Why this is a stored colour and not a system one
///
/// Every icon MenuDock draws is a template image by default: black on transparent, flagged for
/// AppKit, tinted by the menu bar to whatever the bar's own foreground colour is. That is the
/// right default and it is why the icons look like they belong up there — they track Light and
/// Dark, translucency over a wallpaper, and the inverted state while a menu is open, all for free
/// and all exactly in step with the clock beside them.
///
/// A tint is the deliberate opt-out. It gives up every one of those behaviours for one thing in
/// return: at a glance, *which icon is which*. A menu bar with nine identical grey glyphs is a
/// row of nine identical grey glyphs, and colour is the only cue that survives peripheral vision.
///
/// ## Why not a `Color` or an `NSColor`
///
/// Neither is `Codable` in any form that survives a round trip through a file a human might
/// read — `NSColor` archives to a keyed blob, and SwiftUI's `Color` encodes an opaque
/// representation whose shape is not promised between releases. Three doubles in sRGB is the
/// whole of the information, it diffs sensibly, and a user hand-editing `config.json` can see
/// what it says.
///
/// ## One colour, both appearances
///
/// A tinted icon is drawn in the same colour on a light and a dark menu bar. The alternative —
/// storing a pair, or deriving a light variant — sounds more thorough and is worse in practice:
/// the palette below is chosen from the middle of the luminance range precisely so one value
/// reads against both, and a user picking a custom colour is choosing one they can see, right
/// now, in the appearance they use.
nonisolated struct IconTint: Codable, Hashable, Sendable {
    /// sRGB components, 0…1.
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Decoded component-wise with clamping rather than by the synthesized initialiser, so a
    /// hand-edited config carrying `2.0` or a negative produces a colour rather than a throw that
    /// would take the whole configuration down with it. See ``Configuration`` on tolerance.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try container.decodeIfPresent(Double.self, forKey: .red) ?? 0,
            green: try container.decodeIfPresent(Double.self, forKey: .green) ?? 0,
            blue: try container.decodeIfPresent(Double.self, forKey: .blue) ?? 0
        )
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue }
}

// MARK: - Palette

nonisolated extension IconTint {

    /// A named colour in the built-in palette.
    struct Named: Hashable, Sendable, Identifiable {
        let name: String
        let tint: IconTint
        var id: String { name }
    }

    private init(_ hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// The ten offered in Settings.
    ///
    /// Every one sits in the middle of the luminance range on purpose. The obvious palette —
    /// system red, system yellow, system green — is unusable here: those are tuned to be legible
    /// *as UI accents against a window background*, and half of them disappear on a light menu
    /// bar. System yellow in particular is very nearly white. These are the same hues pulled
    /// darker and slightly desaturated, which costs a little vividness on a dark bar and is the
    /// difference between visible and not on a light one.
    static let palette: [Named] = [
        Named(name: "Red", tint: IconTint(0xE0443B)),
        Named(name: "Orange", tint: IconTint(0xE07B2E)),
        Named(name: "Amber", tint: IconTint(0xC99A15)),
        Named(name: "Green", tint: IconTint(0x38A05A)),
        Named(name: "Teal", tint: IconTint(0x1F9C9C)),
        Named(name: "Blue", tint: IconTint(0x3B7DE0)),
        Named(name: "Indigo", tint: IconTint(0x5D5CE0)),
        Named(name: "Purple", tint: IconTint(0x9B4FC4)),
        Named(name: "Pink", tint: IconTint(0xDB4A8C)),
        Named(name: "Graphite", tint: IconTint(0x8A8A8E)),
    ]

    /// The palette entry this colour came from, if it is one — so the swatch grid can show the
    /// current selection rather than making the user remember which one they picked.
    var paletteName: String? {
        Self.palette.first { $0.tint == self }?.name
    }
}

// MARK: - Drawing

extension IconTint {
    /// The colour to draw with. Opaque, in sRGB, matching the stored components exactly.
    var color: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }
}

// MARK: - Severity colours

extension GaugeSeverity {

    /// The colour a gauge in this band draws in.
    ///
    /// Resolved per appearance rather than fixed, and this is the one place in MenuDock where
    /// that is genuinely necessary. Everything else the app draws is a template image, so Light
    /// and Dark are AppKit's problem; a coloured gauge is not, and a green that reads on a black
    /// menu bar is nearly invisible on a white one. So each band carries a pair: darker and more
    /// saturated for Light, lighter for Dark, both landing at roughly the same *perceived*
    /// contrast against their own background.
    ///
    /// Deliberately not the `system*` colours. Those are tuned as accents against a window
    /// background, and `systemYellow` on a light menu bar is very nearly white.
    var color: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            switch self {
            case .low:
                return isDark
                    ? NSColor(srgbRed: 0.36, green: 0.84, blue: 0.47, alpha: 1)
                    : NSColor(srgbRed: 0.13, green: 0.58, blue: 0.25, alpha: 1)
            case .medium:
                return isDark
                    ? NSColor(srgbRed: 1.00, green: 0.79, blue: 0.25, alpha: 1)
                    : NSColor(srgbRed: 0.73, green: 0.49, blue: 0.02, alpha: 1)
            case .high:
                return isDark
                    ? NSColor(srgbRed: 1.00, green: 0.42, blue: 0.38, alpha: 1)
                    : NSColor(srgbRed: 0.79, green: 0.13, blue: 0.11, alpha: 1)
            }
        }
    }
}
