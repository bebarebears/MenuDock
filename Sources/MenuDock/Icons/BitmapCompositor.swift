import AppKit

/// Renders drawing code into one bitmap per backing scale in use and packs them into a single
/// `NSImage`.
///
/// Shared by ``IconRenderer`` and ``ActivityRenderer`` because it is the same job in both: hand
/// AppKit an image that already contains the exact pixels each attached display needs, rather
/// than one representation it has to interpolate. A status item sits in the sharpest, smallest
/// piece of UI on the machine — a resampled glyph reads as blurry immediately.
enum BitmapCompositor {

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

    static func compose(size: NSSize, draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)

        for scale in renderScales {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()),
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
}
