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
        case files = "Files & Folders"
        case development = "Development"
        case media = "Media"
        case design = "Design"
        case finance = "Finance"
        case travel = "Travel"
        case home = "Home & Utilities"
        case social = "Social"
        case system = "System & Utilities"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .animated: "sparkles"
            case .web: "globe"
            case .communication: "bubble.left.and.bubble.right"
            case .productivity: "checkmark.circle"
            case .files: "folder"
            case .development: "chevron.left.forwardslash.chevron.right"
            case .media: "play.circle"
            case .design: "paintbrush.pointed"
            case .finance: "creditcard"
            case .travel: "airplane"
            case .home: "house"
            case .social: "person.2"
            case .system: "gearshape"
            }
        }
    }
}

/// The complete built-in set: 79 static glyphs plus 28 animated ones.
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

    /// How many distinct frames one animation loop is quantised to.
    ///
    /// Frames are cached by index, so a loop is rendered at most this many times ever — after
    /// the first cycle, animating costs a dictionary lookup and an image assignment.
    static let frameCount = 36

    /// Frames in the whole index space: the idle loop, then the one-shot click reaction.
    static let totalFrameCount = frameCount * 2

    /// Current phase for an icon, derived from absolute time so every status item showing the
    /// same icon stays in step and no per-item animation state has to be stored.
    static func phase(for icon: BuiltinIcon, at time: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Double {
        guard let period = icon.period, period > 0 else { return 0 }
        let raw = time.truncatingRemainder(dividingBy: period) / period
        // Quantise so the render cache is hit instead of drawing a new frame every tick.
        return (raw * Double(frameCount)).rounded(.down) / Double(frameCount)
    }

    /// The cache slot a phase belongs to, covering the idle loop (`0…1`) and the click reaction
    /// (`1…2`) in one index space.
    ///
    /// Every caller derives frame identity from *this* function. When the cache used rounding
    /// and the "has the frame changed?" check used truncation, the two disagreed near frame
    /// boundaries and the disagreement showed up as redundant redraws — which is the one cost
    /// animating a menu bar icon actually has.
    static func frameIndex(for phase: Double) -> Int {
        let scaled = Int((phase * Double(frameCount)).rounded())
        return min(max(scaled, 0), totalFrameCount - 1)
    }

    static func phase(forFrame index: Int) -> Double {
        Double(index) / Double(frameCount)
    }

    // MARK: - Frame cache

    /// Boxed so the hot path mutates one shared array in place. A `[Key: [NSImage?]]` would
    /// copy-on-write a 72-element array on every stored frame.
    private final class FrameStrip {
        var images: [NSImage?]
        init(count: Int) { images = [NSImage?](repeating: nil, count: count) }
    }

    private struct FrameKey: Hashable {
        let id: String
        let size: Double
        let showsRunningDot: Bool
    }

    private static var frameStrips: [FrameKey: FrameStrip] = [:]

    /// A single animation frame, rendered once and reused for the life of the cache.
    ///
    /// This is the whole reason animation is affordable. Steady-state cost per tick is a
    /// dictionary lookup, an array subscript, and an `NSImage` assignment — no drawing, no
    /// bitmap allocation, no `NSGraphicsContext`. Every surface that shows animated glyphs (the
    /// menu bar, the icon gallery, the preview well) goes through here, so the gallery's ~30
    /// live previews share frames with the status items instead of each re-rendering its own.
    static func frame(
        icon: BuiltinIcon,
        size: Double,
        showsRunningDot: Bool = false,
        index: Int
    ) -> NSImage {
        let key = FrameKey(id: icon.id, size: size, showsRunningDot: showsRunningDot)
        let strip: FrameStrip
        if let existing = frameStrips[key] {
            strip = existing
        } else {
            strip = FrameStrip(count: totalFrameCount)
            frameStrips[key] = strip
        }

        let slot = min(max(index, 0), totalFrameCount - 1)
        if let cached = strip.images[slot] { return cached }

        let rendered = IconRenderer.menuBarImage(
            builtin: icon,
            size: size,
            showsRunningDot: showsRunningDot,
            phase: phase(forFrame: slot)
        )
        strip.images[slot] = rendered
        return rendered
    }

    /// Drops every cached frame. Needed when icon sizes change, or when the display setup
    /// changes and renders were baked for the old backing scale.
    static func invalidateFrames() {
        frameStrips.removeAll(keepingCapacity: true)
    }

    /// Renders an icon to a menu-bar-ready template image at exactly `size` points.
    ///
    /// Drawn directly at the target size — never scaled from a reference render — so the glyph
    /// is pixel-exact at whatever size the user picked.
    static func image(id: String, size: Double, phase: Double = 0) -> NSImage? {
        guard let icon = icon(id: id) else { return nil }
        return image(icon: icon, size: size, phase: phase)
    }

    /// Uncached render. Prefer ``frame(icon:size:showsRunningDot:index:)`` for anything that
    /// draws repeatedly — this exists for one-off renders at unusual sizes.
    static func image(icon: BuiltinIcon, size: Double, phase: Double = 0) -> NSImage {
        IconRenderer.menuBarImage(builtin: icon, size: size, showsRunningDot: false, phase: phase)
    }
}
