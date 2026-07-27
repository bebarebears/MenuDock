import AppKit

/// Drawing primitives for the built-in icon set.
///
/// Every built-in icon is drawn in code rather than shipped as artwork. That buys three things
/// a bundled PNG cannot: the icons stay razor-sharp at any menu bar height and backing scale,
/// they cost a few hundred bytes each instead of a resource fork, and animated icons can be
/// evaluated at an arbitrary phase instead of being baked into a filmstrip.
///
/// ## Design space
///
/// Icons are drawn on a **24 × 24 grid with y pointing down**, matching how every vector editor
/// and SVG works, so coordinates lifted from a design tool transfer directly. ``inDesignSpace``
/// installs the flip and scale as a CTM, which means stroke widths scale automatically and arcs
/// behave without per-call maths.
///
/// Content is kept inside the 3…21 range, leaving a 3-unit optical margin so icons of different
/// silhouettes read at the same visual weight in the menu bar.
@MainActor
struct Pen {
    /// Stroke weight in design units. 1.9 lands at ~1.4pt when rendered at 18pt, which matches
    /// the stroke weight of SF Symbols at menu bar size.
    var width: Double = 1.9

    /// Uniform alpha applied to every subsequent operation. Template rendering keys off the
    /// alpha channel, so fading a shape fades its tint — no colour required.
    var alpha: Double = 1.0

    func with(width: Double) -> Pen { Pen(width: width, alpha: alpha) }
    func with(alpha: Double) -> Pen { Pen(width: width, alpha: alpha) }

    private var colour: NSColor { NSColor.black.withAlphaComponent(alpha) }

    // MARK: - Strokes

    func stroke(_ path: NSBezierPath) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        colour.setStroke()
        path.stroke()
    }

    func fill(_ path: NSBezierPath) {
        colour.setFill()
        path.fill()
    }

    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x1, y: y1))
        path.line(to: NSPoint(x: x2, y: y2))
        stroke(path)
    }

    func poly(_ points: [(Double, Double)], closed: Bool = false) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: first.0, y: first.1))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: point.0, y: point.1))
        }
        if closed { path.close() }
        stroke(path)
    }

    func filledPoly(_ points: [(Double, Double)]) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: first.0, y: first.1))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: point.0, y: point.1))
        }
        path.close()
        fill(path)
    }

    // MARK: - Shapes

    func circle(_ cx: Double, _ cy: Double, _ r: Double) {
        stroke(NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)))
    }

    func disc(_ cx: Double, _ cy: Double, _ r: Double) {
        fill(NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)))
    }

    func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) {
        stroke(NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)))
    }

    func rrect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ radius: Double) {
        stroke(NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                            xRadius: radius, yRadius: radius))
    }

    func fillRRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ radius: Double) {
        fill(NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                          xRadius: radius, yRadius: radius))
    }

    /// Stroked arc. Angles are in degrees measured **clockwise from 12 o'clock**, which is how
    /// people describe dials — and it stays stable regardless of the y-flip.
    func arc(_ cx: Double, _ cy: Double, _ r: Double, from: Double, to: Double) {
        let path = NSBezierPath()
        let steps = max(8, Int(abs(to - from) / 4))
        for step in 0...steps {
            let degrees = from + (to - from) * Double(step) / Double(steps)
            let radians = (degrees - 90) * .pi / 180
            let point = NSPoint(x: cx + cos(radians) * r, y: cy + sin(radians) * r)
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        stroke(path)
    }

    /// Cubic bezier, for the handful of shapes polylines cannot express cleanly.
    func curve(_ build: (NSBezierPath) -> Void, fill shouldFill: Bool = false) {
        let path = NSBezierPath()
        build(path)
        if shouldFill { fill(path) } else { stroke(path) }
    }

    /// Erases a disc from what has already been drawn.
    ///
    /// Template rendering only reads the alpha channel, so punching a hole is the only way to
    /// get a genuine cut-out — drawing a "background-coloured" disc on top would render as an
    /// opaque blob once AppKit tints the glyph.
    func punchDisc(_ cx: Double, _ cy: Double, _ r: Double) {
        guard let context = NSGraphicsContext.current else { return }
        let previous = context.compositingOperation
        context.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
        context.compositingOperation = previous
    }

    /// Closed polygon from `(angle, radius)` pairs about a centre. Angles are degrees clockwise
    /// from 12 o'clock, matching ``arc(_:_:_:from:to:)``.
    func filledRadialPolygon(_ cx: Double, _ cy: Double, _ points: [(Double, Double)], joinRadius: Double = 0) {
        guard !points.isEmpty else { return }
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let radians = (point.0 - 90) * .pi / 180
            let location = NSPoint(x: cx + cos(radians) * point.1, y: cy + sin(radians) * point.1)
            if index == 0 { path.move(to: location) } else { path.line(to: location) }
        }
        path.close()
        path.lineJoinStyle = .round
        if joinRadius > 0 {
            // Stroking the closed path with round joins softens every corner at once, which is
            // what keeps a cog from looking like a sawblade at 18pt.
            path.lineWidth = joinRadius
            colour.setStroke()
            path.stroke()
        }
        fill(path)
    }
}

// MARK: - Design space

/// Runs `body` with the coordinate system mapped to a 24 × 24, y-down grid filling `rect`.
///
/// Installing the flip as a CTM rather than converting each coordinate by hand means stroke
/// widths, arcs, and bezier control points all scale correctly without per-call arithmetic.
@MainActor
func inDesignSpace(_ rect: NSRect, _ body: () -> Void) {
    guard let context = NSGraphicsContext.current else { return }
    context.saveGraphicsState()
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.maxY)
    transform.scaleX(by: rect.width / 24, yBy: -rect.height / 24)
    transform.concat()

    body()

    context.restoreGraphicsState()
}
