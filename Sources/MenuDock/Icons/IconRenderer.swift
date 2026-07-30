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

    static func menuBarImage(
        from source: NSImage?,
        spec: IconSpec,
        size: Double,
        showsRunningDot: Bool
    ) -> NSImage {
        let edge = CGFloat(size)
        let canvas = NSSize(width: edge, height: edge)

        guard let source else {
            return placeholder(size: canvas)
        }

        let template = shouldRenderAsTemplate(source, spec: spec)

        // Fast path: no compositing needed, so hand back the original representation with
        // only its metadata adjusted. Vector stays vector.
        if !showsRunningDot {
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
        }

        composed.isTemplate = template
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
        phase: Double
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
        }

        // Built-ins are monochrome by construction, so templating is unconditional.
        image.isTemplate = true
        return image
    }

    // MARK: - Template decision

    private static func shouldRenderAsTemplate(_ image: NSImage, spec: IconSpec) -> Bool {
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

    /// The backing scale factors worth rendering for, so a Retina-only Mac — which is every Mac
    /// sold in a decade — never pays to rasterise a 1× representation nothing will display.
    ///
    /// Halving the work matters because animated icons render a full loop of frames on first
    /// play. Plugging in a 1× display later is handled by invalidating the caches on
    /// `NSApplication.didChangeScreenParametersNotification`; until that fires, AppKit
    /// downscaling a 2× rep is a non-event.
    static var renderScales: [CGFloat] {
        let scales = Set(NSScreen.screens.map(\.backingScaleFactor)).filter { $0 > 0 }
        return scales.isEmpty ? [2] : scales.sorted()
    }

    /// Renders `draw` into one bitmap per backing scale in use and packs them into one
    /// `NSImage`, so the status item picks the right one per display without AppKit having to
    /// interpolate.
    private static func compose(size: NSSize, draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)

        for scale in renderScales {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }

            rep.size = size

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            draw()
            NSGraphicsContext.restoreGraphicsState()

            image.addRepresentation(rep)
        }

        return image
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
