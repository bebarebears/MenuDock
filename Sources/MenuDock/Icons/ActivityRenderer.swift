import AppKit

/// Draws an Activity item's gauges into a single menu bar image, and works out how wide that
/// image has to be.
///
/// ## By default, everything is one template mask
///
/// The output is black-on-transparent and flagged as a template, so the menu bar tints it the
/// same way it tints every other status item — one code path for Light, Dark, tinted wallpapers,
/// and the inverted state while a menu is open. Depth comes from **alpha, not colour**: a graph's
/// fill is the same black as its stroke at a quarter of the opacity, and a bar's empty track is
/// that same black fainter still. This is the one drawing technique that guarantees an Activity
/// item never looks out of place next to the clock.
///
/// ## One coloured gauge changes the mode of every gauge beside it
///
/// A gauge set to ``GaugeColoring/byLoad`` cannot be part of a template image: a template is
/// reduced to its alpha, so every colour in it is discarded by definition. The moment any gauge
/// in an item asks for colour, therefore, the *whole strip* stops being a template — and the
/// monochrome gauges sharing it, which were relying on AppKit to colour them, have to be given a
/// colour explicitly. That is what the `tint` and `appearance` parameters are for: the first says
/// what the user chose, the second says which `labelColor` means, since a dynamic colour resolved
/// against the app's appearance is not necessarily the one the menu bar is using.
///
/// Two consequences follow, and both are paid for elsewhere. The item no longer tracks Light and
/// Dark for free, so ``StatusItemCoordinator`` redraws it when the system appearance changes; and
/// it no longer inverts under an open menu, so a coloured gauge keeps its colour against the
/// selection fill. The second is a real if minor loss, and it is why ``GaugeColoring/monochrome``
/// is the default rather than merely the older behaviour.
///
/// ## Width is derived, never guessed
///
/// ``size(for:height:)`` computes the item's width from its gauge list alone, with **no
/// reference to live values**. That is what makes the auto-sizing safe: a numeric gauge is sized
/// from the widest string its metric could ever produce (see
/// ``ActivityMetric/widestCompactString``) rather than from the number currently showing, so the
/// item does not change width as the value moves. A status item that breathes once a second
/// drags every icon to its left along with it, and that is far more distracting in peripheral
/// vision than a couple of points of unused space.
///
/// ## Layout is proportional to height
///
/// Every constant below is a fraction of the item's height rather than a point value, so the
/// whole strip scales with the icon-size preference instead of being tuned for one menu bar.
enum ActivityRenderer {

    /// One gauge's worth of data.
    struct Reading {
        /// The latest sample, or `nil` when the metric has not produced one yet — which is the
        /// normal state for a rate metric's first tick, and must be drawn as "no reading" rather
        /// than as zero.
        var current: Double?
        /// Recent history, oldest first, in the metric's own units.
        var series: [Double]

        init(current: Double? = nil, series: [Double] = []) {
            self.current = current
            self.series = series
        }
    }

    // MARK: - Layout constants, as fractions of the item's height

    private enum Layout {
        /// Space between two gauges.
        static let gap = 0.36
        /// Space between a gauge's caption and its visual.
        static let captionGap = 0.18
        /// Breathing room at each end, so the first gauge does not touch the neighbouring item.
        static let edgeInset = 0.08

        static let graphWidth = 1.35
        static let barWidth = 0.28
        static let ringWidth = 0.86

        /// Vertical inset applied to graph, bar and ring, keeping them clear of the bar's edges.
        static let verticalInset = 0.10

        static let captionFontSize = 0.55
        static let valueFontSize = 0.72

        /// Ink levels. The value is fully opaque; everything that is context rather than data is
        /// pushed back far enough to read as a track rather than as a second reading.
        static let captionAlpha = 0.62
        static let trackAlpha = 0.22
        static let graphFillAlpha = 0.30
        static let emptyAlpha = 0.38
    }

    /// How many samples a graph spreads across its width. Matches the monitor's history window,
    /// so a full buffer exactly fills the plot.
    private static let graphPointCapacity = 60

    // MARK: - Measurement

    /// The size this entry's image needs, derived from its gauges alone.
    static func size(for entry: ActivityEntry, height: Double) -> CGSize {
        let cells = entry.gauges.map { cellWidth(for: $0, height: height) }
        guard !cells.isEmpty else {
            // An item with no gauges still has to occupy something, or it becomes an invisible
            // sliver of menu bar the user cannot click to get back into Settings.
            return CGSize(width: height, height: height)
        }

        let gaps = Double(cells.count - 1) * (height * Layout.gap)
        let insets = height * Layout.edgeInset * 2
        return CGSize(width: (cells.reduce(0, +) + gaps + insets).rounded(.up), height: height)
    }

    private static func cellWidth(for gauge: ActivityGauge, height: Double) -> Double {
        var width = visualWidth(for: gauge, height: height)
        if let caption = gauge.label.text(for: gauge.metric) {
            width += captionSize(caption, height: height).width + height * Layout.captionGap
        }
        return width
    }

    private static func visualWidth(for gauge: ActivityGauge, height: Double) -> Double {
        switch gauge.style {
        case .graph: height * Layout.graphWidth
        case .bar: height * Layout.barWidth
        case .ring: height * Layout.ringWidth
        // The widest of every string the metric could print, not of the one it is printing. The
        // level metrics print *words*, which are not monospaced, so this is a measurement over a
        // handful of candidates rather than a lookup of one — see
        // ``ActivityMetric/widestCompactStrings``.
        case .number:
            gauge.metric.widestCompactStrings
                .map { valueSize($0, height: height).width }
                .max() ?? 0
        }
    }

    // MARK: - Fonts and measurement

    /// Fonts and text measurements, cached across renders.
    ///
    /// Both are the same observation: this renderer runs on a timer, and the *strings* it lays
    /// out barely change. There are seven captions in three modes, two placeholder value strings,
    /// and a handful of heights anyone actually uses — but laying text out costs ~3 µs a time and
    /// a six-gauge item measures nine strings on every single tick, before it draws anything.
    /// Measuring is idempotent, so it belongs in a table rather than in the hot path.
    ///
    /// Bounded for the same reason ``IconLibrary``'s render cache is: the keys include a
    /// user-controlled size, so an unbounded dictionary in a process that runs for weeks is a
    /// leak with extra steps. The real working set is a couple of dozen entries.
    private enum TextCache {
        struct Key: Hashable {
            let text: String
            let size: Double
            let isCaption: Bool
        }

        static var fonts: [Key: NSFont] = [:]
        static var sizes: [Key: CGSize] = [:]
        static let limit = 256
    }

    private static func font(size: Double, isCaption: Bool) -> NSFont {
        let key = TextCache.Key(text: "", size: size, isCaption: isCaption)
        if let cached = TextCache.fonts[key] { return cached }

        // Monospaced digits for values, so a reading changing from `9%` to `18%` moves no pixels
        // it does not have to. With a proportional face every digit has its own advance and the
        // whole gauge shimmers as the number ticks.
        let font: NSFont = isCaption
            ? .systemFont(ofSize: size, weight: .semibold)
            : .monospacedDigitSystemFont(ofSize: size, weight: .regular)

        if TextCache.fonts.count >= TextCache.limit { TextCache.fonts.removeAll(keepingCapacity: true) }
        TextCache.fonts[key] = font
        return font
    }

    private static func captionFont(height: Double) -> NSFont {
        font(size: height * Layout.captionFontSize, isCaption: true)
    }

    private static func valueFont(height: Double) -> NSFont {
        font(size: height * Layout.valueFontSize, isCaption: false)
    }

    private static func measure(_ text: String, height: Double, isCaption: Bool) -> CGSize {
        let size = height * (isCaption ? Layout.captionFontSize : Layout.valueFontSize)
        let key = TextCache.Key(text: text, size: size, isCaption: isCaption)
        if let cached = TextCache.sizes[key] { return cached }

        let measured = text.size(withAttributes: [.font: font(size: size, isCaption: isCaption)])
        if TextCache.sizes.count >= TextCache.limit { TextCache.sizes.removeAll(keepingCapacity: true) }
        TextCache.sizes[key] = measured
        return measured
    }

    private static func captionSize(_ text: String, height: Double) -> CGSize {
        measure(text, height: height, isCaption: true)
    }

    private static func valueSize(_ text: String, height: Double) -> CGSize {
        measure(text, height: height, isCaption: false)
    }

    // MARK: - Drawing

    /// Draws the whole strip.
    ///
    /// - Parameters:
    ///   - tint: the item's fixed colour, used only when the image cannot be a template. When it
    ///     can, the tint is applied far more cheaply by ``GlyphLayer``, which masks a single
    ///     coloured layer and never re-renders.
    ///   - appearance: whose `labelColor` to resolve against. Pass the status item button's, not
    ///     the app's: a translucent menu bar over a light wallpaper can be in the opposite
    ///     appearance from the window the settings pane is in.
    static func image(
        for entry: ActivityEntry,
        readings: [ActivityMetric: Reading],
        height: Double,
        tint: IconTint? = nil,
        appearance: NSAppearance? = nil
    ) -> NSImage {
        let canvas = size(for: entry, height: height)
        // One coloured gauge is enough to take the whole strip out of template rendering; see the
        // note at the top of this file.
        let isTemplate = !entry.hasColouredGauge

        let image = BitmapCompositor.compose(size: NSSize(width: canvas.width, height: canvas.height)) {
            withDrawingAppearance(appearance) {
                var x = height * Layout.edgeInset

                for gauge in entry.gauges {
                    let reading = readings[gauge.metric] ?? Reading()
                    let ink = ink(for: gauge, reading: reading, tint: tint, isTemplate: isTemplate)

                    if let caption = gauge.label.text(for: gauge.metric) {
                        let size = captionSize(caption, height: height)
                        draw(text: caption,
                             font: captionFont(height: height),
                             colour: ink.at(Layout.captionAlpha),
                             at: CGPoint(x: x, y: (height - size.height) / 2))
                        x += size.width + height * Layout.captionGap
                    }

                    let width = visualWidth(for: gauge, height: height)
                    let frame = CGRect(x: x, y: 0, width: width, height: height)
                    draw(gauge: gauge, reading: reading, ink: ink, in: frame, height: height)
                    x += width + height * Layout.gap
                }
            }
        }

        image.isTemplate = isTemplate
        return image
    }

    /// One gauge's colour, and the alpha levels its supporting parts are drawn at.
    ///
    /// Everything in a gauge is the *same* colour at different opacities — the track behind a bar
    /// is its own fill made faint, not a second grey. That is what keeps a coloured gauge reading
    /// as one object rather than as two overlapping ones, and it is why this is a single colour
    /// rather than a palette.
    private struct Ink {
        let colour: NSColor
        func at(_ alpha: Double) -> NSColor {
            alpha >= 1 ? colour : colour.withAlphaComponent(alpha)
        }
    }

    private static func ink(
        for gauge: ActivityGauge,
        reading: Reading,
        tint: IconTint?,
        isTemplate: Bool
    ) -> Ink {
        // A template is reduced to its alpha mask, so the colour here is only ever a carrier for
        // opacity. Black keeps the arithmetic honest and matches what every other icon does.
        guard !isTemplate else { return Ink(colour: .black) }

        if gauge.coloring == .byLoad, let current = reading.current {
            return Ink(colour: gauge.metric.severity(for: current).color)
        }
        // No reading yet, or a monochrome gauge sharing a strip that had to go colour: the item's
        // own tint if it has one, and otherwise the colour the menu bar would have used anyway.
        return Ink(colour: tint?.color ?? .labelColor)
    }

    /// Resolves dynamic colours against a specific appearance for the duration of `draw`.
    ///
    /// Without this, `labelColor` and the severity colours resolve against `NSApp`'s appearance,
    /// which is the settings window's rather than the menu bar's.
    private static func withDrawingAppearance(_ appearance: NSAppearance?, _ draw: () -> Void) {
        guard let appearance else { return draw() }
        appearance.performAsCurrentDrawingAppearance(draw)
    }

    private static func draw(
        gauge: ActivityGauge,
        reading: Reading,
        ink: Ink,
        in frame: CGRect,
        height: Double
    ) {
        // Both the current value and the history are scaled against the same ceiling, so a bar
        // and a graph of the same metric standing side by side never disagree about what "full"
        // means.
        let ceiling = scaleCeiling(for: gauge.metric, series: reading.series, current: reading.current)

        switch gauge.style {
        case .graph:
            drawGraph(reading.series, ceiling: ceiling, ink: ink, in: frame, height: height)
        case .bar:
            drawBar(reading.current.map { $0 / ceiling }, ink: ink, in: frame, height: height)
        case .ring:
            drawRing(reading.current.map { $0 / ceiling }, ink: ink, in: frame, height: height)
        case .number:
            drawNumber(reading.current, metric: gauge.metric, ink: ink, in: frame, height: height)
        }
    }

    /// The value that counts as full scale.
    ///
    /// For a percentage this is always 1, so the gauge is an absolute 0–100% reading. For a rate
    /// it is the largest value in the visible window, floored at
    /// ``ActivityMetric/scaleFloor`` — an adaptive scale, because bytes per second has no natural
    /// maximum and a fixed one is wrong for everybody: pick 1 Gbit/s and a coffee-shop connection
    /// is a flat line, pick 10 Mbit/s and a file copy is a solid block. The floor is what stops
    /// an idle interface's keepalive traffic from being amplified into a mountain range.
    ///
    /// The two cases are one expression because ``ActivityMetric/scaleFloor`` is 1 for the
    /// percentages, which are themselves never above 1.
    private static func scaleCeiling(
        for metric: ActivityMetric,
        series: [Double],
        current: Double?
    ) -> Double {
        let observed = max(series.max() ?? 0, current ?? 0)
        return max(observed, metric.scaleFloor)
    }

    // MARK: Graph

    private static func drawGraph(
        _ series: [Double],
        ceiling: Double,
        ink: Ink,
        in frame: CGRect,
        height: Double
    ) {
        let inset = height * Layout.verticalInset
        let plot = CGRect(x: frame.minX, y: inset,
                          width: frame.width, height: height - inset * 2)

        guard series.count >= 2 else {
            // Nothing to plot yet: a faint baseline, so the gauge reads as "waiting" rather than
            // as a rendering failure or a machine doing literally nothing.
            fill(CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: max(height * 0.06, 0.75)),
                 colour: ink.at(Layout.emptyAlpha), radius: height * 0.03)
            return
        }

        let points = Array(series.suffix(graphPointCapacity))
        let step = plot.width / Double(graphPointCapacity - 1)
        // Newest sample pinned to the right edge and history growing leftwards, so a partly
        // filled buffer looks like a graph filling up rather than one stretched to fit.
        let firstX = plot.maxX - Double(points.count - 1) * step

        func location(_ index: Int) -> CGPoint {
            let fraction = min(max(points[index] / ceiling, 0), 1)
            return CGPoint(x: firstX + Double(index) * step, y: plot.minY + fraction * plot.height)
        }

        let area = NSBezierPath()
        area.move(to: CGPoint(x: firstX, y: plot.minY))
        for index in points.indices { area.line(to: location(index)) }
        area.line(to: CGPoint(x: plot.maxX, y: plot.minY))
        area.close()
        ink.at(Layout.graphFillAlpha).setFill()
        area.fill()

        let line = NSBezierPath()
        for index in points.indices {
            if index == 0 { line.move(to: location(index)) } else { line.line(to: location(index)) }
        }
        line.lineWidth = max(height * 0.065, 0.9)
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        ink.at(1).setStroke()
        line.stroke()
    }

    // MARK: Bar

    private static func drawBar(_ fraction: Double?, ink: Ink, in frame: CGRect, height: Double) {
        let inset = height * Layout.verticalInset
        let track = CGRect(x: frame.minX, y: inset,
                           width: frame.width, height: height - inset * 2)
        let radius = frame.width / 2
        let capsule = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)

        ink.at(Layout.trackAlpha).setFill()
        capsule.fill()

        guard let fraction, fraction > 0 else { return }

        // Clipped to the capsule rather than drawn as its own rounded rect. Filling a
        // rounded-rect the width of the track produces a lozenge floating at the bottom — the
        // fill rounds *its own* bottom corners as well as its top, and a half-full meter ends up
        // looking like a thermometer bulb. Clipping means the fill inherits the track's outline
        // exactly and its top edge stays flat, which is what reads as a level.
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()

        // A non-zero reading always shows at least a stub. Rounding a 1% CPU load away to nothing
        // makes the gauge look broken rather than quiet.
        let filled = max(min(max(fraction, 0), 1) * track.height, frame.width)
        ink.at(1).setFill()
        NSBezierPath(rect: CGRect(x: track.minX, y: track.minY,
                                  width: track.width, height: filled)).fill()

        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Ring

    private static func drawRing(_ fraction: Double?, ink: Ink, in frame: CGRect, height: Double) {
        let lineWidth = max(height * 0.115, 1.2)
        let radius = (min(frame.width, height - height * Layout.verticalInset * 2) - lineWidth) / 2
        let centre = CGPoint(x: frame.midX, y: height / 2)
        guard radius > 0 else { return }

        let track = NSBezierPath(ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                width: radius * 2, height: radius * 2))
        track.lineWidth = lineWidth
        ink.at(Layout.trackAlpha).setStroke()
        track.stroke()

        guard let fraction, fraction > 0 else { return }
        let sweep = min(max(fraction, 0), 1) * 360

        // AppKit measures angles anticlockwise from 3 o'clock. A dial reads clockwise from 12,
        // so the arc starts at 90° and sweeps negative.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius,
                      startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        ink.at(1).setStroke()
        arc.stroke()
    }

    // MARK: Number

    private static func drawNumber(
        _ value: Double?,
        metric: ActivityMetric,
        ink: Ink,
        in frame: CGRect,
        height: Double
    ) {
        let text = value.map { metric.compactString($0) } ?? "–"
        let font = valueFont(height: height)
        let size = valueSize(text, height: height)

        // Left-aligned inside a cell measured for the widest possible string, so the slack sits
        // *after* the number rather than between the caption and it. Right-aligning looks more
        // like a number column and reads worse here: it holds the caption still and slides the
        // digits, so `C 100%` becoming `C  22%` looks like the value drifting away from its own
        // label. Anchoring the left edge keeps the caption-to-value relationship fixed and lets
        // the reserved slack merge into the gap before the next gauge.
        draw(text: text,
             font: font,
             colour: ink.at(value == nil ? Layout.emptyAlpha : 1),
             at: CGPoint(x: frame.minX, y: (height - size.height) / 2))
    }

    // MARK: Primitives

    private static func draw(text: String, font: NSFont, colour: NSColor, at point: CGPoint) {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: colour
        ]).draw(at: point)
    }

    private static func fill(_ rect: CGRect, colour: NSColor, radius: Double) {
        colour.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}
