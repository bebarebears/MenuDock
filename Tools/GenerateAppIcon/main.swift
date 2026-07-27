import AppKit

// Generates Resources/AppIcon.icns.
//
// The app icon is drawn here for the same reason the menu bar glyphs are (see
// `Icons/Builtin/`): it stays editable as geometry rather than as a binary someone has to open
// a design tool to change, and every size is rendered natively instead of downsampled from
// 1024 — which is what turns a crisp mark into mush at 16pt.
//
//     swift Tools/GenerateAppIcon/main.swift     (or: make icon)
//
// ## The mark
//
// The icon body is the screen; the white band across its top is the menu bar; the three
// punched-out shapes are your apps sitting in it, on the right where real status items live.
// That asymmetry is deliberate — centred, it reads as a generic window title bar.

// MARK: - Geometry
//
// ## Full-bleed, not the classic inset grid
//
// The obvious thing is Apple's long-standing 1024 grid: an 824pt body inset by 100 with a
// 185pt radius, which is how icons were authored for a decade. On macOS 26 that is wrong, and
// visibly so. The system now supplies the rounded container itself and composites the artwork
// *inside* it — so an icon that draws its own rounded body ends up as a shape nested in a
// shape, with two sets of corners and a band that stops short of the edges.
//
// Verified by rendering `NSWorkspace.icon(forFile:)` for this bundle beside Terminal's: the
// inset version showed the doubled shape, and Terminal — whose artwork fills its frame —
// did not.
//
// So the artwork runs edge to edge as a plain square and lets the system's mask be the
// silhouette. Rounding it here does not help and actively hurts: any radius that is not
// exactly the mask's leaves a dark crescent at each corner where the artwork pulls away from
// the container. A square has nothing to misalign.

let canvas: CGFloat = 1024

func bodyPath() -> NSBezierPath {
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: canvas, height: canvas))
}

// MARK: - Drawing

func drawBody() {
    NSGradient(colors: [
        NSColor(srgbRed: 0.31, green: 0.31, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
    ])!.draw(in: bodyPath(), angle: -90)
}

func drawGlyph() {
    let stripHeight: CGFloat = 248
    let strip = NSRect(x: 0, y: canvas - stripHeight, width: canvas, height: stripHeight)

    NSColor.white.setFill()
    NSBezierPath(rect: strip).fill()

    // Punched rather than drawn in the background colour, so the items read as holes in the
    // bar at every size instead of picking up a seam where the gradient shifts behind them.
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    for offset in stride(from: 0.0, through: 344.0, by: 172.0) {
        let diameter: CGFloat = 114
        NSBezierPath(ovalIn: NSRect(x: strip.maxX - 147 - offset - diameter / 2,
                                    y: strip.midY - diameter / 2,
                                    width: diameter,
                                    height: diameter)).fill()
    }
    NSGraphicsContext.current?.compositingOperation = .sourceOver
}

/// Renders the icon at one pixel size. Drawn at the target resolution rather than scaled from
/// a master, so the 16pt version keeps a hard edge on the band.
func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let scale = CGFloat(pixels) / canvas
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    drawBody()
    NSGraphicsContext.saveGraphicsState()
    bodyPath().addClip()
    drawGlyph()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Output

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1
    ? arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns"

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("MenuDock-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The names `iconutil` expects. Every entry is drawn, including both members of each
/// point-size pair, so `icon_16x16@2x` is a real 32px render and not the 16px one blown up.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let data = render(pixels: variant.pixels).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", outputPath, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(outputPath)")
