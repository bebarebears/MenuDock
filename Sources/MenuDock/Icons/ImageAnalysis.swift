import AppKit

/// Decides whether a user-supplied image should be treated as a *template* — i.e. whether
/// AppKit should throw away its colours and tint it to match the menu bar.
///
/// Template rendering is what makes an icon adapt to Light/Dark mode and to menu bar
/// transparency: AppKit keeps only the alpha channel and fills it with the appropriate
/// system colour, exactly like Apple's own status items. Applying it to a multi-colour logo
/// would flatten it into a silhouette, so the decision has to be right by default.
///
/// The signal is **saturation**, not luminance. A monochrome icon — black glyph, white glyph,
/// or any grey — has near-zero saturation on every pixel; a brand logo does not. Luminance
/// would misfire on a black-and-white logo that is legitimately two-tone.
enum ImageAnalysis {

    struct Result {
        /// True when the image is effectively colourless and safe to template.
        var isMonochrome: Bool
        /// Fraction of visible pixels carrying meaningful colour, for diagnostics/UI.
        var colourFraction: Double
        /// Fraction of the canvas that is not transparent.
        var coverage: Double
    }

    /// A pixel counts as "coloured" above this saturation. Low enough to catch muted brand
    /// colours, high enough to ignore anti-aliasing fringes and JPEG chroma noise.
    private static let saturationThreshold: Double = 0.15

    /// Allow a small fraction of coloured pixels before giving up on templating — scanned or
    /// re-encoded artwork often has a handful of stray tinted pixels at edges.
    private static let colourTolerance: Double = 0.02

    /// Ignore near-transparent pixels; their colour is meaningless and usually garbage.
    private static let alphaThreshold: Double = 0.1

    /// Rasterises to a small fixed grid and inspects it. 64×64 is ample — we are measuring a
    /// global property, and sampling small keeps this cheap enough to run inline on import.
    static func analyze(_ image: NSImage, sampleEdge: Int = 64) -> Result {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: sampleEdge, pixelsHigh: sampleEdge,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: sampleEdge * 4, bitsPerPixel: 32
        ) else {
            return Result(isMonochrome: false, colourFraction: 0, coverage: 0)
        }

        rep.size = NSSize(width: sampleEdge, height: sampleEdge)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(x: 0, y: 0, width: sampleEdge, height: sampleEdge)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else {
            return Result(isMonochrome: false, colourFraction: 0, coverage: 0)
        }

        var visible = 0
        var coloured = 0
        let total = sampleEdge * sampleEdge

        for pixel in 0..<total {
            let offset = pixel * 4
            let alpha = Double(data[offset + 3]) / 255.0
            guard alpha > alphaThreshold else { continue }
            visible += 1

            // Un-premultiply: NSBitmapImageRep stores premultiplied alpha, so a 50%-opaque
            // pure red reads as (128, 0, 0) and would otherwise still measure as saturated —
            // correct here, but the same maths turns a 50%-opaque grey into a false positive
            // if the channels are not restored to their true ratios first.
            let r = Double(data[offset]) / 255.0 / alpha
            let g = Double(data[offset + 1]) / 255.0 / alpha
            let b = Double(data[offset + 2]) / 255.0 / alpha

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            if saturation > saturationThreshold { coloured += 1 }
        }

        guard visible > 0 else {
            return Result(isMonochrome: false, colourFraction: 0, coverage: 0)
        }

        let colourFraction = Double(coloured) / Double(visible)
        return Result(
            isMonochrome: colourFraction < colourTolerance,
            colourFraction: colourFraction,
            coverage: Double(visible) / Double(total)
        )
    }
}
