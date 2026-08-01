import AppKit

// Renders every Activity gauge style onto a menu-bar-like strip, in Light and Dark, so the
// design can be judged at the size it actually ships at instead of in a debugger.
//
//   swift Tools/RenderActivity/main.swift   (see `make activity-sheet`)

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - Synthetic data

/// Plausible-looking history, so the sheet shows what a real machine looks like rather than a
/// sine wave that flatters the graph renderer.
func series(_ kind: ActivityMetric) -> [Double] {
    var values: [Double] = []
    var state = 0.35
    for step in 0..<60 {
        let time = Double(step) / 60
        switch kind {
        case .cpu:
            state += Double.random(in: -0.09...0.09)
            state = min(max(state, 0.04), 0.95)
            values.append(state + (step > 38 && step < 48 ? 0.35 : 0))
        case .memory:
            values.append(0.52 + sin(time * 6) * 0.02)
        case .gpu:
            values.append(max(0, 0.12 + sin(time * 11) * 0.14 + Double.random(in: -0.03...0.03)))
        case .networkDown:
            values.append(step > 30 && step < 52 ? Double.random(in: 6e6...1.2e7) : Double.random(in: 0...4e4))
        case .networkUp:
            values.append(step > 30 && step < 52 ? Double.random(in: 2e5...4e5) : Double.random(in: 0...9e3))
        case .diskRead:
            values.append(step % 17 < 3 ? Double.random(in: 2e7...9e7) : Double.random(in: 0...5e5))
        case .diskWrite:
            values.append(step % 23 < 5 ? Double.random(in: 1e8...4e8) : 0)
        }
    }
    return values
}

func readings(for metrics: [ActivityMetric]) -> [ActivityMetric: ActivityRenderer.Reading] {
    var result: [ActivityMetric: ActivityRenderer.Reading] = [:]
    for metric in metrics {
        let values = series(metric)
        result[metric] = ActivityRenderer.Reading(current: values.last, series: values)
    }
    return result
}

// MARK: - Template tinting

/// Reproduces what the menu bar does to a template image: use its alpha as a mask over a solid
/// colour. Without this the sheet would show black-on-black in the Dark panel.
func tinted(_ image: NSImage, colour: NSColor) -> NSImage {
    let output = NSImage(size: image.size)
    output.lockFocus()
    colour.set()
    NSRect(origin: .zero, size: image.size).fill()
    image.draw(in: NSRect(origin: .zero, size: image.size),
               from: .zero, operation: .destinationIn, fraction: 1)
    output.unlockFocus()
    return output
}

// MARK: - Sheet layout

struct Row {
    let caption: String
    let entry: ActivityEntry
}

let allMetrics = ActivityMetric.allCases

let rows: [Row] = [
    Row(caption: "Graph · short label",
        entry: ActivityEntry(gauges: [ActivityGauge(metric: .cpu, style: .graph, label: .short)])),
    Row(caption: "Graph · full label",
        entry: ActivityEntry(gauges: [ActivityGauge(metric: .cpu, style: .graph, label: .full)])),
    Row(caption: "Graph · no label",
        entry: ActivityEntry(gauges: [ActivityGauge(metric: .cpu, style: .graph, label: .none)])),
    Row(caption: "Bar · short label",
        entry: ActivityEntry(gauges: [ActivityGauge(metric: .memory, style: .bar, label: .short)])),
    Row(caption: "Ring · short label",
        entry: ActivityEntry(gauges: [ActivityGauge(metric: .cpu, style: .ring, label: .short)])),
    Row(caption: "Number · short label",
        entry: ActivityEntry(gauges: [ActivityGauge(metric: .cpu, style: .number, label: .short)])),
    Row(caption: "Number · rate",
        entry: ActivityEntry(gauges: [ActivityGauge(metric: .networkDown, style: .number, label: .short)])),
    Row(caption: "CPU graph + RAM bar (the default)",
        entry: ActivityEntry(gauges: ActivityEntry.defaultGauges)),
    Row(caption: "Four gauges, mixed styles",
        entry: ActivityEntry(gauges: [
            ActivityGauge(metric: .cpu, style: .graph, label: .short),
            ActivityGauge(metric: .gpu, style: .ring, label: .short),
            ActivityGauge(metric: .memory, style: .bar, label: .short),
            ActivityGauge(metric: .networkDown, style: .number, label: .short)
        ])),
    Row(caption: "Network pair, numbers",
        entry: ActivityEntry(gauges: [
            ActivityGauge(metric: .networkDown, style: .number, label: .short),
            ActivityGauge(metric: .networkUp, style: .number, label: .short)
        ])),
    Row(caption: "Everything at once",
        entry: ActivityEntry(gauges: allMetrics.map {
            ActivityGauge(metric: $0, style: .graph, label: .short)
        }))
]

let heights: [Double] = [16, 18, 22]

let captionWidth: CGFloat = 250
let rowHeight: CGFloat = 34
let panelPadding: CGFloat = 18
let headerHeight: CGFloat = 46

let data = readings(for: allMetrics)

/// Width needed by the widest strip in the sheet, at the largest height.
let widestStrip = rows
    .map { ActivityRenderer.size(for: $0.entry, height: heights.max()!).width }
    .max() ?? 200

let columnWidth = CGFloat(widestStrip) + 40
let panelWidth = captionWidth + columnWidth * CGFloat(heights.count) + panelPadding * 2
let panelHeight = headerHeight + rowHeight * CGFloat(rows.count) + panelPadding

func drawPanel(origin: CGPoint, dark: Bool) {
    let background = dark
        ? NSColor(calibratedWhite: 0.12, alpha: 1)
        : NSColor(calibratedWhite: 0.93, alpha: 1)
    let ink = dark ? NSColor.white : NSColor.black
    let subdued = ink.withAlphaComponent(0.55)

    background.setFill()
    NSBezierPath(roundedRect: NSRect(x: origin.x, y: origin.y, width: panelWidth, height: panelHeight),
                 xRadius: 12, yRadius: 12).fill()

    let title = dark ? "Dark menu bar" : "Light menu bar"
    NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: ink
    ]).draw(at: CGPoint(x: origin.x + panelPadding, y: origin.y + panelHeight - 30))

    for (index, height) in heights.enumerated() {
        let x = origin.x + panelPadding + captionWidth + columnWidth * CGFloat(index)
        NSAttributedString(string: "\(Int(height)) pt", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: subdued
        ]).draw(at: CGPoint(x: x, y: origin.y + panelHeight - 46))
    }

    for (rowIndex, row) in rows.enumerated() {
        let y = origin.y + panelHeight - headerHeight - rowHeight * CGFloat(rowIndex + 1)

        NSAttributedString(string: row.caption, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: subdued
        ]).draw(at: CGPoint(x: origin.x + panelPadding, y: y + rowHeight / 2 - 7))

        for (index, height) in heights.enumerated() {
            let image = ActivityRenderer.image(for: row.entry, readings: data, height: height)
            let stamped = tinted(image, colour: ink)
            let x = origin.x + panelPadding + captionWidth + columnWidth * CGFloat(index)
            stamped.draw(in: NSRect(x: x,
                                    y: y + (rowHeight - CGFloat(height)) / 2,
                                    width: image.size.width,
                                    height: CGFloat(height)))
        }
    }
}

let gutter: CGFloat = 20
let sheetSize = NSSize(width: panelWidth * 2 + gutter * 3, height: panelHeight + gutter * 2)

let scale: CGFloat = 2
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(sheetSize.width * scale), pixelsHigh: Int(sheetSize.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
rep.size = sheetSize

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
NSRect(origin: .zero, size: sheetSize).fill()
drawPanel(origin: CGPoint(x: gutter, y: gutter), dark: false)
drawPanel(origin: CGPoint(x: gutter * 2 + panelWidth, y: gutter), dark: true)
NSGraphicsContext.restoreGraphicsState()

let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("activity-styles.png")
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: url)
print("wrote \(url.path)")

for row in rows {
    let size = ActivityRenderer.size(for: row.entry, height: 18)
    print(String(format: "  %-38@ %5.1f x %.0f pt", row.caption as NSString, size.width, size.height))
}
