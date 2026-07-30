import AppKit

/// Shows an animated glyph in a status item **without redrawing the status item's view**.
///
/// ## Why this exists
///
/// Assigning `NSStatusBarButton.image` is the obvious way to animate a menu bar icon, and on
/// current macOS it is startlingly expensive. The assignment invalidates the button, and the
/// button's redraw runs `NSStatusBarButtonCell.drawWithFrame:` →
/// `NSSystemStatusBar.drawBackgroundInRect:inView:highlight:`, which pushes a new selected-content
/// frame into the status item's *scene* and takes a **synchronous fence with the window server**
/// to do it — `CAFenceHandle.newFenceFromDefaultServer` → `mach_msg`, visible in any `sample` of
/// the process. It is a round trip to another process, per frame, to re-measure an icon whose size
/// has not changed.
///
/// A `CALayer` never redraws the view. Setting `contents` hands a finished image to the
/// compositor, which is the cheapest update macOS offers.
///
/// Measured on the development machine (two displays, Debug build, 12fps):
///
/// | | `button.image =` | `CALayer.contents` |
/// |---|---|---|
/// | 1 animated icon | 7.5% CPU | **0.5%** |
/// | 4 animated icons | 16.0% CPU | **0.9%** |
///
/// Things that were tried first and did not help, so nobody has to try them again: swapping the
/// representations inside one reused `NSImage` (7.5%), `isBordered = false` (8.0%), and a fixed
/// `statusItem.length` instead of `variableLength` (7.7%). The fence is in the view redraw itself,
/// so the only fix is not redrawing the view.
///
/// ## What this gives up, and why it is acceptable
///
/// Template rendering becomes ours instead of AppKit's: the glyph is a tint layer masked by the
/// frame's alpha, coloured with `labelColor` resolved in the *button's* appearance (so it follows
/// the menu bar, not the app), or with the menu-selection colour while the item's menu is open.
/// What is lost is the last few percent of AppKit's vibrancy blend against the wallpaper behind a
/// translucent menu bar. Against a 14× CPU difference for an icon that sits on screen all day,
/// that is a trade worth making — and it is only made for *animated* glyphs. Static icons keep
/// going through `button.image`, where the cost is paid once and AppKit's behaviour is exact.
@MainActor
final class GlyphLayer {

    /// Coloured layer, masked to the glyph's alpha. Tinting this way means one CGImage per frame
    /// and no re-rendering when only the colour changes.
    private let tint = CALayer()
    private let mask = CALayer()

    private weak var button: NSStatusBarButton?

    /// Transparent stand-in left in `button.image` so the status item keeps the width it would
    /// have had. `variableLength` derives the item's width from the button's content, so an
    /// image-less button collapses to a sliver.
    private var spacer: NSImage?
    private var spacerSize: Double = 0

    private var installedFrame: CGRect = .zero
    private var installedTint: CGColor?

    // MARK: - Attachment

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.wantsLayer = true

        mask.contentsGravity = .resizeAspect
        tint.mask = mask
        tint.isHidden = true
        button.layer?.addSublayer(tint)
    }

    /// Hands presentation back to `button.image`, for an item whose icon is no longer animated.
    func clear() {
        tint.isHidden = true
        mask.contents = nil
        spacer = nil
        spacerSize = 0
    }

    var isActive: Bool { !tint.isHidden }

    // MARK: - Per-frame update

    /// Puts one rendered frame on screen. This is the hot path — everything it can skip, it does.
    ///
    /// - Parameters:
    ///   - frame: a rendered glyph, black-on-transparent, used only as a mask.
    ///   - size: the point size the frame was rendered at.
    ///   - isHighlighted: true while the item's menu is open, when the glyph must invert.
    func show(_ frame: NSImage, size: Double, isHighlighted: Bool) {
        guard let button else { return }

        // Sharpest representation, not the one `cgImage(forProposedRect:)` guesses from a
        // point-sized rect: that returns the 1× bitmap and leaves the glyph soft on Retina.
        guard let rep = sharpestRepresentation(of: frame) else { return }
        guard let image = rep.cgImage else { return }

        installSpacerIfNeeded(size: size, on: button)

        let bounds = button.bounds
        let target = CGRect(
            x: ((bounds.width - size) / 2).rounded(),
            y: ((bounds.height - size) / 2).rounded(),
            width: size,
            height: size
        )
        if target != installedFrame {
            installedFrame = target
            tint.frame = target
            mask.frame = CGRect(origin: .zero, size: target.size)
        }

        let colour = tintColour(isHighlighted: isHighlighted, appearance: button.effectiveAppearance)
        if colour != installedTint {
            installedTint = colour
            tint.backgroundColor = colour
        }

        mask.contentsScale = Double(rep.pixelsWide) / max(size, 1)
        mask.contents = image
        tint.isHidden = false
    }

    /// Re-resolves the tint on the next ``show(_:size:isHighlighted:)``. Called when the system
    /// appearance changes, since `labelColor` means something different afterwards.
    func invalidateTint() {
        installedTint = nil
    }

    // MARK: - Details

    private func sharpestRepresentation(of image: NSImage) -> NSBitmapImageRep? {
        image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }
    }

    private func tintColour(isHighlighted: Bool, appearance: NSAppearance) -> CGColor {
        var resolved = NSColor.labelColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            // While a menu is open AppKit fills the item with the selection colour, and a template
            // image would invert to match. This is that inversion, done by hand.
            resolved = (isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor).cgColor
        }
        return resolved
    }

    private func installSpacerIfNeeded(size: Double, on button: NSStatusBarButton) {
        guard spacerSize != size || button.image !== spacer else { return }
        spacerSize = size
        spacer = Self.transparentImage(size: size)
        button.image = spacer
    }

    /// A genuinely empty image of an exact size: `NSImage(size:)` alone has no representation,
    /// which some layout paths treat as having nothing to measure.
    private static func transparentImage(size: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) {
            rep.size = NSSize(width: size, height: size)
            image.addRepresentation(rep)
        }
        return image
    }
}
