import AppKit
import ImageIO
import UniformTypeIdentifiers

// Renders the marketing images for docs/images/ straight from the icon-drawing code, so the
// showcase can never drift from what the app actually draws. Run with `make showcase`.
//
// The glyphs are drawn black-on-transparent by Pen and are templates by construction, so each
// one is tinted to white and composited onto a dark panel. A panel with its own background is
// deliberate: GitHub renders README images on either a light or a dark page, and a bare
// transparent glyph sheet would be invisible on one of them.

// MARK: - Shim
//
// BuiltinIcon.swift calls into IconRenderer, which is not part of this tool's source set.
// Only this one entry point is needed, and it is the same handful of lines as the original.

@MainActor
enum IconRenderer {
    static func menuBarImage(builtin icon: BuiltinIcon,
                             size: Double,
                             showsRunningDot: Bool,
                             phase: Double) -> NSImage {
        let canvas = NSSize(width: size, height: size)
        let image = NSImage(size: canvas)
        image.lockFocus()
        inDesignSpace(NSRect(origin: .zero, size: canvas)) {
            icon.draw(Pen(), phase)
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

// MARK: - Palette

enum Style {
    static let scale: CGFloat = 2          // retina; GitHub serves these at half width
    static let cell: CGFloat = 64
    static let glyph: CGFloat = 34
    static let pad: CGFloat = 32
    static let radius: CGFloat = 18

    static let backdropTop = NSColor(srgbRed: 0.129, green: 0.133, blue: 0.153, alpha: 1)
    static let backdropBottom = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.094, alpha: 1)
    static let ink = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.93)
}

// MARK: - Drawing helpers

/// Draws into a bitmap of `size` points at `Style.scale` device pixels per point.
@MainActor
func canvas(_ size: NSSize, _ body: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(size.width * Style.scale),
                              pixelsHigh: Int(size.height * Style.scale),
                              bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    body()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// A template glyph carries only an alpha mask, so `.sourceAtop` over a filled rect paints it
/// in any colour without touching Pen, which draws unconditionally in black.
@MainActor
func tinted(_ image: NSImage, _ colour: NSColor, edge: CGFloat) -> NSImage {
    let size = NSSize(width: edge, height: edge)
    let out = NSImage(size: size)
    out.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: size))
    colour.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

@MainActor
func drawBackdrop(_ size: NSSize) {
    let panel = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                            xRadius: Style.radius, yRadius: Style.radius)
    panel.addClip()
    NSGradient(starting: Style.backdropTop, ending: Style.backdropBottom)?
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)
}

/// Lays `icons` out on a `columns`-wide grid and draws each at `phase`.
@MainActor
func drawGrid(_ icons: [BuiltinIcon], columns: Int, phase: Double, size: NSSize) {
    for (i, icon) in icons.enumerated() {
        let col = i % columns
        let row = i / columns
        let glyph = IconRenderer.menuBarImage(builtin: icon, size: Style.glyph,
                                              showsRunningDot: false, phase: phase)
        // y is flipped: row 0 should sit at the top of the panel.
        let x = Style.pad + CGFloat(col) * Style.cell + (Style.cell - Style.glyph) / 2
        let y = size.height - Style.pad - CGFloat(row + 1) * Style.cell
              + (Style.cell - Style.glyph) / 2
        tinted(glyph, Style.ink, edge: Style.glyph)
            .draw(in: NSRect(x: x, y: y, width: Style.glyph, height: Style.glyph))
    }
}

@MainActor
func gridSize(count: Int, columns: Int) -> NSSize {
    let rows = Int(ceil(Double(count) / Double(columns)))
    return NSSize(width: CGFloat(columns) * Style.cell + Style.pad * 2,
                  height: CGFloat(rows) * Style.cell + Style.pad * 2)
}

@MainActor
func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("  \(path)  \(rep.pixelsWide)×\(rep.pixelsHigh)  \(data.count / 1024) KB")
}

// MARK: - Sheets

@MainActor
func renderStaticSheet(to path: String) {
    let icons = BuiltinIconCatalog.all.filter { !$0.isAnimated }
    let columns = 13
    let size = gridSize(count: icons.count, columns: columns)
    let rep = canvas(size) {
        drawBackdrop(size)
        drawGrid(icons, columns: columns, phase: 0, size: size)
    }
    print("static glyphs: \(icons.count)")
    writePNG(rep, to: path)
}

/// One shared phase drives every icon, so all of them complete exactly one loop across the
/// GIF and it cycles seamlessly. In the app each icon runs on its own period against
/// wall-clock time; for a showcase, in-step reads better and loops cleanly.
@MainActor
func renderAnimatedGIF(to path: String, frames: Int, fps: Double) {
    let icons = BuiltinIconCatalog.all.filter(\.isAnimated)
    let columns = 14
    let size = gridSize(count: icons.count, columns: columns)

    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                               UTType.gif.identifier as CFString,
                                               frames, nil)!
    CGImageDestinationSetProperties(dest, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ] as CFDictionary)

    let frameProps = [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 1.0 / fps,
            kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps,
        ]
    ] as CFDictionary

    for f in 0..<frames {
        let phase = Double(f) / Double(frames)
        let rep = canvas(size) {
            drawBackdrop(size)
            drawGrid(icons, columns: columns, phase: phase, size: size)
        }
        CGImageDestinationAddImage(dest, rep.cgImage!, frameProps)
    }
    CGImageDestinationFinalize(dest)

    let bytes = (try? Data(contentsOf: url).count) ?? 0
    print("animated glyphs: \(icons.count)")
    print("  \(path)  \(frames) frames @ \(Int(fps))fps  \(bytes / 1024) KB")
}

/// One row per icon, sampled left-to-right across its loop — the motion as a still, for
/// readers whose client does not play the GIF, and a fair record of how restrained it is.
@MainActor
func renderMotionStudy(ids: [String], to path: String, steps: Int) {
    let icons = ids.compactMap { BuiltinIconCatalog.icon(id: $0) }
    guard !icons.isEmpty else { return }

    let size = NSSize(width: CGFloat(steps) * Style.cell + Style.pad * 2,
                      height: CGFloat(icons.count) * Style.cell + Style.pad * 2)
    let rep = canvas(size) {
        drawBackdrop(size)
        for (row, icon) in icons.enumerated() {
            for step in 0..<steps {
                let phase = Double(step) / Double(steps)
                let glyph = IconRenderer.menuBarImage(builtin: icon, size: Style.glyph,
                                                      showsRunningDot: false, phase: phase)
                let x = Style.pad + CGFloat(step) * Style.cell + (Style.cell - Style.glyph) / 2
                let y = size.height - Style.pad - CGFloat(row + 1) * Style.cell
                      + (Style.cell - Style.glyph) / 2
                tinted(glyph, Style.ink, edge: Style.glyph)
                    .draw(in: NSRect(x: x, y: y, width: Style.glyph, height: Style.glyph))
            }
        }
    }
    print("motion study: \(icons.map(\.name).joined(separator: ", "))")
    writePNG(rep, to: path)
}

// MARK: - Entry

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

renderStaticSheet(to: "\(out)/icons-static.png")
renderAnimatedGIF(to: "\(out)/icons-animated.gif", frames: 36, fps: 12)
// Chosen for legible motion in a still: position, opacity, rotation and a character. The
// hourglass was cut — its half-turn lands mid-rotation on a 10-step sample and reads as a
// rendering glitch rather than a flip.
renderMotionStudy(ids: ["anim.rocket", "anim.coffee", "anim.wave",
                        "anim.radar", "anim.typing", "anim.dog"],
                  to: "\(out)/icons-motion.png", steps: 10)
