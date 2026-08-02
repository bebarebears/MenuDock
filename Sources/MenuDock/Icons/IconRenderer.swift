import AppKit

/// Turns an arbitrary source image into something that belongs in the macOS menu bar.
///
/// Three jobs, in order:
///
/// 1. **Fit** the artwork into the status item's square without distorting its aspect ratio.
/// 2. **Decide on template rendering** (see ``ImageAnalysis``) so monochrome art tracks
///    Light/Dark mode and menu bar transparency, while colour art is left alone.
/// 3. **Composite the running indicator**, the Dock's dot-under-the-icon, when enabled.
///
/// ### Vector artwork is preserved
/// `NSImage` decodes SVG natively into a resolution-independent representation. When no
/// compositing is required we keep that representation and only stamp `size`/`isTemplate`, so
/// the icon re-renders sharply at any backing scale rather than being frozen into pixels.
/// Anything that needs compositing falls back to explicit 1× and 2× bitmaps, which is what
/// every system icon ships as anyway.
enum IconRenderer {

    /// Vertical space reserved beneath the glyph for the running dot.
    private static let indicatorLane: CGFloat = 4
    private static let indicatorRadius: CGFloat = 1.5

    /// - Parameter tint: a fixed colour for this item, or `nil` to leave the artwork alone.
    ///   **Ignored for artwork that is not template-rendered**, and deliberately so: an app's own
    ///   icon or a full-colour logo already carries its own colour, and forcing another one over
    ///   the top produces a silhouette rather than a tinted icon. See ``IconTint``.
    static func menuBarImage(
        from source: NSImage?,
        spec: IconSpec,
        size: Double,
        showsRunningDot: Bool,
        tint: IconTint? = nil
    ) -> NSImage {
        let edge = CGFloat(size)
        let canvas = NSSize(width: edge, height: edge)

        guard let source else {
            return placeholder(size: canvas)
        }

        let template = shouldRenderAsTemplate(source, spec: spec)
        // A tint only means anything for artwork whose colour AppKit was going to supply.
        let tint = template ? tint : nil

        // Fast path: no compositing needed, so hand back the original representation with
        // only its metadata adjusted. Vector stays vector.
        //
        // A tint takes it off this path — colouring the artwork means rasterising it, since the
        // whole point is that the pixels are no longer a mask for AppKit to fill.
        if !showsRunningDot, tint == nil {
            guard let copy = source.copy() as? NSImage else { return placeholder(size: canvas) }
            copy.size = aspectFit(copy.size, into: canvas)
            copy.isTemplate = template
            return copy
        }

        let glyphArea = NSSize(width: edge, height: edge - indicatorLane)
        let glyphSize = aspectFit(source.size, into: glyphArea)
        let glyphRect = NSRect(
            x: (edge - glyphSize.width) / 2,
            y: indicatorLane + (glyphArea.height - glyphSize.height) / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )

        let composed = compose(size: canvas) {
            source.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            // A template image is reduced to its alpha mask, so the dot only needs to exist —
            // AppKit supplies the colour. A colour image keeps its own pixels, so the dot has
            // to be drawn in a colour that reads against the current menu bar; the render
            // cache is invalidated on appearance changes to keep that correct.
            if template {
                NSColor.black.setFill()
            } else {
                NSColor.labelColor.setFill()
            }

            let dot = NSBezierPath(ovalIn: NSRect(
                x: edge / 2 - indicatorRadius,
                y: indicatorRadius / 2,
                width: indicatorRadius * 2,
                height: indicatorRadius * 2
            ))
            dot.fill()

            // The dot is drawn *before* the tint so it takes the colour too — a purple icon with
            // a black dot under it looks like two unrelated things stacked, not one item.
            applyTint(tint, over: canvas)
        }

        composed.isTemplate = template && tint == nil
        return composed
    }

    // MARK: - Built-in glyphs

    /// Renders a built-in icon, compositing the running dot in the same pass.
    ///
    /// Built-ins get their own path rather than going through the `NSImage` pipeline because
    /// they are procedural: the glyph can be drawn *directly into the final rect* at every
    /// scale factor, so it is pixel-exact instead of being rendered once and resampled to fit
    /// around the indicator lane.
    static func menuBarImage(
        builtin icon: BuiltinIcon,
        size: Double,
        showsRunningDot: Bool,
        phase: Double,
        tint: IconTint? = nil
    ) -> NSImage {
        let edge = CGFloat(size)
        let canvas = NSSize(width: edge, height: edge)
        let glyphEdge = showsRunningDot ? edge - indicatorLane : edge
        let glyphRect = NSRect(x: (edge - glyphEdge) / 2,
                               y: showsRunningDot ? indicatorLane : 0,
                               width: glyphEdge, height: glyphEdge)

        let image = compose(size: canvas) {
            inDesignSpace(glyphRect) {
                icon.draw(Pen(), phase)
            }
            if showsRunningDot {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: edge / 2 - indicatorRadius,
                    y: indicatorRadius / 2,
                    width: indicatorRadius * 2,
                    height: indicatorRadius * 2
                )).fill()
            }
            applyTint(tint, over: canvas)
        }

        // Built-ins are monochrome by construction, so templating is unconditional — until a
        // tint says the colour is the user's to choose rather than the menu bar's.
        image.isTemplate = tint == nil
        return image
    }

    /// Recolours whatever has already been drawn into the current context.
    ///
    /// `.sourceAtop` is the whole trick: it paints the colour only where there are already
    /// non-transparent pixels, and *scales by their alpha*. So a glyph's antialiased edges stay
    /// antialiased and its internal opacity levels — the faint track under a bar, a half-opacity
    /// highlight — survive as lighter shades of the tint rather than being flattened to one
    /// colour. Masking a solid fill would lose all of that.
    private static func applyTint(_ tint: IconTint?, over canvas: NSSize) {
        guard let tint else { return }
        tint.color.set()
        NSRect(origin: .zero, size: canvas).fill(using: .sourceAtop)
    }

    // MARK: - Template decision

    /// Whether this artwork will be reduced to an alpha mask and coloured by AppKit.
    ///
    /// Not private, for the same reason ``automaticDecision(for:)`` below is not: Settings has to
    /// know the answer to say whether a tint would do anything, and re-deriving it there would be
    /// two implementations of one rule that silently disagree the day either changes.
    static func shouldRenderAsTemplate(_ image: NSImage, spec: IconSpec) -> Bool {
        switch spec {
        case .appIcon:
            // Real app icons are full-colour artwork; templating them yields a blob.
            return false

        case .symbol, .builtin:
            return true

        case .custom(_, let rendering, _):
            switch rendering {
            case .template: return true
            case .original: return false
            case .auto: return ImageAnalysis.analyze(image).isMonochrome
            }
        }
    }

    /// Exposed so the settings UI can explain what Automatic mode decided, instead of leaving
    /// the user guessing why their icon lost its colour.
    static func automaticDecision(for image: NSImage) -> ImageAnalysis.Result {
        ImageAnalysis.analyze(image)
    }

    // MARK: - Size limits

    /// The tallest icon that fits the menu bar without being clipped.
    ///
    /// Read from `NSStatusBar` rather than hard-coded, because the bar is not the same height
    /// on every Mac. Two points of breathing room stop a full-bleed square icon from touching
    /// the bar's edges, which reads as a rendering glitch rather than a large icon.
    static var maximumIconSize: Double {
        max(16, Double(NSStatusBar.system.thickness) - 2)
    }

    /// The smallest size that still resolves as a recognisable glyph.
    static let minimumIconSize: Double = 10

    // MARK: - Drawing helpers

    /// Scales `source` to fit inside `bounds` without cropping or distorting.
    ///
    /// Deliberately *not* rounded to whole points. Rounding looks like a crispness win but
    /// silently changes the aspect ratio — an 18pt-wide 4:1 logo fits at 4.5pt tall, and
    /// rounding that to 5pt stretches it by 11%. Half-points land on exact pixels at 2×,
    /// which is every display this icon realistically appears on.
    private static func aspectFit(_ source: NSSize, into bounds: NSSize) -> NSSize {
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return NSSize(width: source.width * scale, height: source.height * scale)
    }

    /// Renders `draw` into one bitmap per backing scale in use and packs them into one
    /// `NSImage`, so the status item picks the right one per display without AppKit having to
    /// interpolate. See ``BitmapCompositor``, which ``ActivityRenderer`` shares.
    private static func compose(size: NSSize, draw: () -> Void) -> NSImage {
        BitmapCompositor.compose(size: size, draw: draw)
    }

    /// Shown when an app has been uninstalled or a custom icon file has gone missing, so a
    /// broken entry is visibly broken rather than an invisible gap in the menu bar.
    private static func placeholder(size: NSSize) -> NSImage {
        let image = NSImage(systemSymbolName: "questionmark.app.dashed",
                            accessibilityDescription: "Missing application")
            ?? NSImage(size: size)
        image.size = size
        image.isTemplate = true
        return image
    }
}
