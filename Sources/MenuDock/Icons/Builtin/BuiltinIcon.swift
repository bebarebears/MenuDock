import AppKit

/// One entry in the built-in icon set.
///
/// `id` is what gets written to the configuration file, so it is a stable slug that must never
/// change once shipped — renaming `name` is free, renaming `id` orphans every user who picked
/// that icon.
@MainActor
struct BuiltinIcon: Identifiable {
    let id: String
    let name: String
    let category: Category

    /// Seconds for one full animation loop, or `nil` for a static icon.
    ///
    /// Deliberately long (2–4s). A menu bar sits in peripheral vision all day; anything faster
    /// reads as an alert demanding attention rather than a decorative touch.
    let period: Double?

    /// Draws the icon in design space. `phase` runs 0…1 across one loop and is always 0 for
    /// static icons.
    let draw: (Pen, Double) -> Void

    var isAnimated: Bool { period != nil }

    init(_ id: String,
         _ name: String,
         _ category: Category,
         period: Double? = nil,
         draw: @escaping (Pen, Double) -> Void) {
        self.id = id
        self.name = name
        self.category = category
        self.period = period
        self.draw = draw
    }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case animated = "Animated"
        case web = "Web & Browsing"
        case communication = "Communication"
        case productivity = "Productivity"
        case development = "Development"
        case media = "Media"
        case design = "Design"
        case system = "System & Utilities"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .animated: "sparkles"
            case .web: "globe"
            case .communication: "bubble.left.and.bubble.right"
            case .productivity: "checkmark.circle"
            case .development: "chevron.left.forwardslash.chevron.right"
            case .media: "play.circle"
            case .design: "paintbrush.pointed"
            case .system: "gearshape"
            }
        }
    }
}

/// The complete built-in set: 36 static glyphs plus 12 animated ones.
@MainActor
enum BuiltinIconCatalog {

    static let all: [BuiltinIcon] = AnimatedIcons.all + StaticIcons.all

    private static let index: [String: BuiltinIcon] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    static func icon(id: String) -> BuiltinIcon? { index[id] }

    static func icons(in category: BuiltinIcon.Category) -> [BuiltinIcon] {
        all.filter { $0.category == category }
    }

    static func search(_ query: String) -> [BuiltinIcon] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
                || $0.category.rawValue.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// How many distinct frames an animated icon is quantised to.
    ///
    /// Frames are cached by index, so a loop is rendered at most this many times ever — after
    /// the first cycle, animating costs a dictionary lookup and an image assignment.
    static let frameCount = 36

    /// Current phase for an icon, derived from absolute time so every status item showing the
    /// same icon stays in step and no per-item animation state has to be stored.
    static func phase(for icon: BuiltinIcon, at time: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Double {
        guard let period = icon.period, period > 0 else { return 0 }
        let raw = time.truncatingRemainder(dividingBy: period) / period
        // Quantise so the render cache is hit instead of drawing a new frame every tick.
        return (raw * Double(frameCount)).rounded(.down) / Double(frameCount)
    }

    /// Renders an icon to a menu-bar-ready template image at exactly `size` points.
    ///
    /// Drawn directly at the target size — never scaled from a reference render — so the glyph
    /// is pixel-exact at whatever size the user picked.
    static func image(id: String, size: Double, phase: Double = 0) -> NSImage? {
        guard let icon = icon(id: id) else { return nil }
        return image(icon: icon, size: size, phase: phase)
    }

    static func image(icon: BuiltinIcon, size: Double, phase: Double = 0) -> NSImage {
        let edge = CGFloat(size)
        let canvas = NSSize(width: edge, height: edge)
        let image = NSImage(size: canvas)

        for scale in [CGFloat(1), CGFloat(2)] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(edge * scale), pixelsHigh: Int(edge * scale),
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }

            rep.size = canvas

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            inDesignSpace(NSRect(origin: .zero, size: canvas)) {
                icon.draw(Pen(), phase)
            }
            NSGraphicsContext.restoreGraphicsState()

            image.addRepresentation(rep)
        }

        // Built-ins are always monochrome by construction, so template rendering is
        // unconditional — they tint with Light/Dark mode and menu bar transparency for free.
        image.isTemplate = true
        return image
    }
}
