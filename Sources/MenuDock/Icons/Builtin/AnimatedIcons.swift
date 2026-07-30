import AppKit

/// 28 gently animated glyphs.
///
/// ## Restraint is the whole design brief
///
/// A menu bar sits in peripheral vision for the entire working day. Peripheral vision is
/// motion-sensitive by evolutionary design, so anything sharp or fast there reads as an alert
/// and pulls focus away from the user's actual work. Three rules follow:
///
/// - **Long periods** (2.2–4.5s). Nothing snaps.
/// - **Eased, not linear.** Motion accelerates and settles like a physical object; constant
///   velocity is what makes a spinner feel nagging.
/// - **Small amplitude.** Movement stays within a unit or two, or expresses itself as opacity.
///   Template rendering keys off the alpha channel, so fading is free and is by far the least
///   distracting way to animate.
///
/// Animation is suppressed entirely when the system's Reduce Motion setting is on — see
/// ``IconAnimator``.
@MainActor
enum AnimatedIcons {

    static let all: [BuiltinIcon] = [
        pulse, breathe, orbit, wave, spinner, blink,
        bounce, typing, heartbeat, progress, radar, morph,
        coffee, flame, pendulum, sync, downloading, charging,
        leaf, sparkle, clock, hourglass, ripple, rocket,
        dog, cat, ghost, bell,
    ]

    // MARK: - Easing

    /// Smoothstep — the workhorse ease-in-out. Zero velocity at both ends, so loops never
    /// visibly "tick" at the seam.
    ///
    /// `nonisolated`: pure arithmetic, and it is called from nested helpers inside the drawing
    /// closures, which do not inherit main-actor isolation.
    private nonisolated static func ease(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }

    /// A 0→1→0 round trip with eased ends, for anything that grows and returns.
    private nonisolated static func pingPong(_ phase: Double) -> Double {
        let t = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return ease(t)
    }

    // MARK: - Icons

    /// A dot with a ring expanding and fading outward from it.
    static let pulse = BuiltinIcon("anim.pulse", "Pulse", .animated, period: 2.6) { pen, phase in
        pen.disc(12, 12, 3.2)
        let t = ease(phase)
        let radius = 4.6 + t * 5.4
        pen.with(width: 1.7).with(alpha: (1 - t) * 0.85).circle(12, 12, radius)
    }

    /// A ring that inhales and exhales. The calmest thing in the set.
    static let breathe = BuiltinIcon("anim.breathe", "Breathe", .animated, period: 4.5) { pen, phase in
        let t = pingPong(phase)
        pen.circle(12, 12, 5.4 + t * 3.4)
        pen.with(alpha: 0.45 + t * 0.4).disc(12, 12, 1.8)
    }

    /// A small satellite tracing a circle around a fixed centre.
    static let orbit = BuiltinIcon("anim.orbit", "Orbit", .animated, period: 3.6) { pen, phase in
        pen.disc(12, 12, 2.6)
        pen.with(width: 1.3).with(alpha: 0.3).circle(12, 12, 7.6)
        let angle = phase * 2 * .pi - .pi / 2
        pen.disc(12 + cos(angle) * 7.6, 12 + sin(angle) * 7.6, 1.9)
    }

    /// Three bars rising and falling out of step, like a very relaxed level meter.
    static let wave = BuiltinIcon("anim.wave", "Wave", .animated, period: 2.4) { pen, phase in
        let offsets = [0.0, 0.33, 0.66]
        for (index, offset) in offsets.enumerated() {
            let local = (phase + offset).truncatingRemainder(dividingBy: 1)
            let height = 5.0 + pingPong(local) * 9.0
            let x = 7.0 + Double(index) * 5.0
            pen.with(width: 2.6).line(x, 12 - height / 2, x, 12 + height / 2)
        }
    }

    /// An arc chasing its own tail. The arc length breathes as it turns so it never looks like
    /// a progress indicator stuck at one value.
    static let spinner = BuiltinIcon("anim.spinner", "Spinner", .animated, period: 3.0) { pen, phase in
        pen.with(width: 1.4).with(alpha: 0.25).circle(12, 12, 8.0)
        let start = phase * 360
        let sweep = 70 + pingPong(phase) * 110
        pen.with(width: 2.1).arc(12, 12, 8.0, from: start, to: start + sweep)
    }

    /// An eye that holds open, blinks once, and holds again — the blink occupies only the last
    /// eighth of the loop, so it reads as a moment of character rather than a flicker.
    static let blink = BuiltinIcon("anim.blink", "Blink", .animated, period: 4.2) { pen, phase in
        let blinkStart = 0.87
        let openness: Double
        if phase < blinkStart {
            openness = 1
        } else {
            let t = (phase - blinkStart) / (1 - blinkStart)
            openness = abs(t - 0.5) * 2
        }

        let lidHeight = 0.6 + openness * 5.2
        pen.curve { path in
            path.move(to: NSPoint(x: 3.4, y: 12))
            path.curve(to: NSPoint(x: 20.6, y: 12),
                       controlPoint1: NSPoint(x: 8, y: 12 - lidHeight * 1.6),
                       controlPoint2: NSPoint(x: 16, y: 12 - lidHeight * 1.6))
            path.curve(to: NSPoint(x: 3.4, y: 12),
                       controlPoint1: NSPoint(x: 16, y: 12 + lidHeight * 1.6),
                       controlPoint2: NSPoint(x: 8, y: 12 + lidHeight * 1.6))
        }
        if openness > 0.35 {
            pen.with(alpha: (openness - 0.35) / 0.65).disc(12, 12, 2.5)
        }
    }

    /// A dot falling and rebounding, with the squash-and-stretch that sells the impact.
    static let bounce = BuiltinIcon("anim.bounce", "Bounce", .animated, period: 2.4) { pen, phase in
        pen.with(width: 1.6).line(5.4, 19.4, 18.6, 19.4)

        // Parabolic flight rather than a sine: gravity looks wrong as a sine wave.
        let t = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        let height = 1 - (1 - t) * (1 - t)
        let radius = 2.9
        let y = 17.4 - height * 8.4

        // Squash on contact, stretch at speed.
        let squash = 1 + (1 - height) * 0.28 * (phase < 0.08 || phase > 0.92 ? 1 : 0)
        pen.fill(NSBezierPath(ovalIn: NSRect(
            x: 12 - radius * squash, y: y - radius / squash,
            width: radius * 2 * squash, height: radius * 2 / squash
        )))
    }

    /// The three-dot typing indicator. Instantly legible, and the most "cute" thing here.
    static let typing = BuiltinIcon("anim.typing", "Typing", .animated, period: 2.2) { pen, phase in
        for index in 0..<3 {
            let local = (phase + Double(index) * -0.16).truncatingRemainder(dividingBy: 1)
            let normalised = local < 0 ? local + 1 : local
            // Each dot lifts during its own third of the cycle and rests for the remainder.
            let lift = normalised < 0.42 ? pingPong(normalised / 0.42) : 0
            let x = 6.0 + Double(index) * 6.0
            pen.with(alpha: 0.45 + lift * 0.55).disc(x, 13.4 - lift * 2.6, 2.1)
        }
    }

    /// A heart with the real lub-dub double beat, then a long rest.
    static let heartbeat = BuiltinIcon("anim.heartbeat", "Heartbeat", .animated, period: 2.8) { pen, phase in
        func beat(_ centre: Double, _ width: Double) -> Double {
            let distance = abs(phase - centre)
            guard distance < width else { return 0 }
            return ease(1 - distance / width)
        }
        let scale = 1 + beat(0.06, 0.09) * 0.17 + beat(0.24, 0.075) * 0.11

        let cx = 12.0, cy = 12.6
        pen.curve({ path in
            func point(_ x: Double, _ y: Double) -> NSPoint {
                NSPoint(x: cx + (x - cx) * scale, y: cy + (y - cy) * scale)
            }
            path.move(to: point(12, 19.4))
            path.curve(to: point(3.6, 10.4),
                       controlPoint1: point(6.6, 16.4), controlPoint2: point(3.6, 13.8))
            path.curve(to: point(12, 8.4),
                       controlPoint1: point(3.6, 6.4), controlPoint2: point(9.4, 5.4))
            path.curve(to: point(20.4, 10.4),
                       controlPoint1: point(14.6, 5.4), controlPoint2: point(20.4, 6.4))
            path.curve(to: point(12, 19.4),
                       controlPoint1: point(20.4, 13.8), controlPoint2: point(17.4, 16.4))
        }, fill: true)
    }

    /// A bar that fills, then empties from the same edge — no jarring reset to zero.
    static let progress = BuiltinIcon("anim.progress", "Progress", .animated, period: 3.2) { pen, phase in
        pen.with(width: 1.5).rrect(3.4, 9.6, 17.2, 4.8, 2.4)
        let fraction = pingPong(phase)
        if fraction > 0.02 {
            pen.fillRRect(5.0, 11.2, 14.0 * fraction, 1.6, 0.8)
        }
    }

    /// A radar sweep with a fading trail behind the leading edge.
    static let radar = BuiltinIcon("anim.radar", "Radar", .animated, period: 3.4) { pen, phase in
        pen.with(width: 1.4).with(alpha: 0.28).circle(12, 12, 8.4)
        pen.with(width: 1.4).with(alpha: 0.28).circle(12, 12, 4.4)

        let head = phase * 360
        // The trail is 5 thin, widely-spaced spokes rather than a dense fan. Overlapping
        // strokes at low alpha accumulate into a solid wedge that reads as a filled pie —
        // spacing them out keeps it legible as a sweep.
        for step in stride(from: 4, through: 1, by: -1) {
            let radians = (head - Double(step) * 13 - 90) * .pi / 180
            pen.with(width: 1.3).with(alpha: 0.16 * (1 - Double(step) / 5.0) + 0.08)
                .line(12, 12, 12 + cos(radians) * 8.4, 12 + sin(radians) * 8.4)
        }
        let radians = (head - 90) * .pi / 180
        pen.with(width: 1.9).line(12, 12, 12 + cos(radians) * 8.4, 12 + sin(radians) * 8.4)
        pen.disc(12, 12, 1.6)
    }

    /// A square easing into a circle and back, by interpolating only its corner radius.
    static let morph = BuiltinIcon("anim.morph", "Morph", .animated, period: 4.0) { pen, phase in
        let t = pingPong(phase)
        let side = 14.4
        let radius = 1.8 + t * (side / 2 - 1.8)
        pen.rrect(12 - side / 2, 12 - side / 2, side, side, radius)
    }

    // MARK: - Objects
    //
    // These lean on a second trick beyond motion: a recognisable *thing*. A pulse or a spinner
    // says "something is happening"; a coffee cup with steam says which menu bar item this is
    // from three feet away, which is what a launcher icon is actually for.

    /// A cup with two wisps of steam drifting up and fading out.
    static let coffee = BuiltinIcon("anim.coffee", "Coffee", .animated, period: 3.6) { pen, phase in
        pen.poly([(6.0, 11.4), (7.4, 20.4), (14.8, 20.4), (16.2, 11.4)], closed: true)
        pen.arc(16.2, 14.2, 2.5, from: 25, to: 155)

        // Offset half a loop apart so the two wisps never move in lockstep, which is what makes
        // rising steam look like steam rather than a pair of lifts.
        for index in 0..<2 {
            let local = (phase + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            let t = ease(local)
            let x = 9.4 + Double(index) * 3.4
            let y = 9.6 - t * 5.2
            // Fade in over the first fifth, then out — a wisp appearing at full strength is a
            // flicker, not a wisp.
            let alpha = min(local * 5, 1) * (1 - t) * 0.85
            pen.with(width: 1.5).with(alpha: alpha).curve { path in
                path.move(to: NSPoint(x: x, y: y + 2.6))
                path.curve(to: NSPoint(x: x, y: y),
                           controlPoint1: NSPoint(x: x - 1.3, y: y + 1.7),
                           controlPoint2: NSPoint(x: x + 1.3, y: y + 0.9))
            }
        }
    }

    /// A candle flame, leaning on two out-of-phase sines so the flicker never repeats visibly
    /// within a loop.
    ///
    /// The asymmetry is the whole icon. A symmetrical teardrop with a rounded top is a water
    /// drop, and no amount of motion fixes that — what says *fire* is the pointed tip leaning off
    /// the axis and the kink partway down one side.
    static let flame = BuiltinIcon("anim.flame", "Flame", .animated, period: 2.6) { pen, phase in
        let lean = sin(phase * 2 * .pi) * 1.15 + sin(phase * 6 * .pi) * 0.35

        pen.curve { path in
            let tip = NSPoint(x: 12 + lean, y: 3.6)
            path.move(to: tip)
            path.curve(to: NSPoint(x: 17.2, y: 14.4),
                       controlPoint1: NSPoint(x: 13.8 + lean * 0.6, y: 7.2),
                       controlPoint2: NSPoint(x: 17.2, y: 10.2))
            path.curve(to: NSPoint(x: 6.8, y: 14.4),
                       controlPoint1: NSPoint(x: 17.2, y: 19.8),
                       controlPoint2: NSPoint(x: 6.8, y: 19.8))
            // Up the left side to the shoulder, then a tighter run to the tip.
            path.curve(to: NSPoint(x: 9.8, y: 8.4),
                       controlPoint1: NSPoint(x: 6.8, y: 11.8),
                       controlPoint2: NSPoint(x: 9.2, y: 11.2))
            path.curve(to: tip,
                       controlPoint1: NSPoint(x: 10.3, y: 6.2),
                       controlPoint2: NSPoint(x: 10.9 + lean * 0.5, y: 4.8))
        }

        // Inner flame, filled, tracking the lean at half amplitude.
        pen.with(alpha: 0.5).curve({ path in
            let core = NSPoint(x: 12 + lean * 0.55, y: 11.2)
            path.move(to: core)
            path.curve(to: NSPoint(x: 14.6, y: 16.2),
                       controlPoint1: NSPoint(x: 13.4, y: 12.8),
                       controlPoint2: NSPoint(x: 14.6, y: 14.4))
            path.curve(to: NSPoint(x: 9.4, y: 16.2),
                       controlPoint1: NSPoint(x: 14.6, y: 18.6),
                       controlPoint2: NSPoint(x: 9.4, y: 18.6))
            path.curve(to: core,
                       controlPoint1: NSPoint(x: 9.4, y: 14.4),
                       controlPoint2: NSPoint(x: 10.6, y: 12.8))
        }, fill: true)
    }

    /// A pendulum, swinging on a sine because that is genuinely what a pendulum does.
    static let pendulum = BuiltinIcon("anim.pendulum", "Pendulum", .animated, period: 3.0) { pen, phase in
        let swing = sin(phase * 2 * .pi) * 0.40
        let pivotX = 12.0, pivotY = 5.0, length = 12.0
        let x = pivotX + sin(swing) * length
        let y = pivotY + cos(swing) * length

        pen.with(width: 1.3).with(alpha: 0.22).arc(pivotX, pivotY, length, from: 157, to: 203)
        pen.with(width: 1.6).line(pivotX, pivotY, x, y)
        pen.disc(x, y, 2.5)
        pen.disc(pivotX, pivotY, 1.2)
    }

    /// Two arcs chasing each other around a circle, each with an arrowhead. The one icon here
    /// that turns continuously — anything doing work deserves to look like it is.
    static let sync = BuiltinIcon("anim.sync", "Sync", .animated, period: 2.8) { pen, phase in
        let radius = 7.4
        for side in [0.0, 180.0] {
            let start = phase * 360 + side
            pen.with(width: 1.8).arc(12, 12, radius, from: start, to: start + 116)

            // Arrowhead on the leading end, aligned to the tangent so it points along the
            // direction of travel instead of at a fixed angle.
            let radians = (start + 116 - 90) * .pi / 180
            let px = 12 + cos(radians) * radius
            let py = 12 + sin(radians) * radius
            let tx = -sin(radians), ty = cos(radians)
            let nx = cos(radians), ny = sin(radians)
            pen.filledPoly([
                (px + tx * 3.0, py + ty * 3.0),
                (px + nx * 2.0, py + ny * 2.0),
                (px - nx * 2.0, py - ny * 2.0),
            ])
        }
    }

    /// An arrow descending into a tray, fading out as it lands, with a beat of rest before the
    /// next one. The rest is what keeps it from reading as an alert.
    static let downloading = BuiltinIcon("anim.download", "Downloading", .animated, period: 2.2) { pen, phase in
        pen.poly([(3.6, 15.4), (3.6, 20.0), (20.4, 20.0), (20.4, 15.4)])

        let travel = 0.78
        guard phase < travel else { return }
        let local = phase / travel
        let y = 4.6 + ease(local) * 7.6
        let alpha = min(local * 6, 1) * (1 - max((local - 0.7) / 0.3, 0))

        let arrow = pen.with(alpha: alpha)
        arrow.line(12, y - 3.4, 12, y + 1.0)
        arrow.poly([(9.2, y - 1.6), (12, y + 1.2), (14.8, y - 1.6)])
    }

    /// A battery filling. The fill fades out at the top of the loop instead of snapping back to
    /// empty, so there is no visible seam.
    static let charging = BuiltinIcon("anim.charging", "Charging", .animated, period: 3.2) { pen, phase in
        pen.with(width: 1.7).rrect(3.2, 8.0, 15.4, 8.0, 2.2)
        pen.fillRRect(19.2, 10.4, 2.0, 3.2, 0.8)

        let fillEnd = 0.84
        let level = ease(min(phase / fillEnd, 1))
        let alpha = phase > fillEnd ? 1 - (phase - fillEnd) / (1 - fillEnd) : 1
        guard level > 0.02, alpha > 0.02 else { return }
        pen.with(alpha: alpha).fillRRect(5.0, 9.8, 11.8 * level, 4.4, 0.9)
    }

    /// A leaf swaying. The slowest thing in the set, and the least likely to be noticed —
    /// which for a decorative menu bar icon is the highest compliment available.
    static let leaf = BuiltinIcon("anim.leaf", "Leaf", .animated, period: 4.5) { pen, phase in
        let sway = sin(phase * 2 * .pi) * 1.2
        let tip = NSPoint(x: 13.0 + sway, y: 4.2)
        let base = NSPoint(x: 5.2, y: 19.8)

        pen.curve { path in
            path.move(to: base)
            path.curve(to: tip,
                       controlPoint1: NSPoint(x: 3.8, y: 11.0),
                       controlPoint2: NSPoint(x: 7.8 + sway, y: 5.2))
            path.curve(to: base,
                       controlPoint1: NSPoint(x: 19.4 + sway, y: 8.2),
                       controlPoint2: NSPoint(x: 15.2, y: 17.2))
        }
        // Midrib, tracking close to the axis. Bowed further out it stops reading as a vein and
        // starts reading as a slice through the leaf.
        pen.with(width: 1.4).curve { path in
            path.move(to: base)
            path.curve(to: tip,
                       controlPoint1: NSPoint(x: 7.4, y: 14.6),
                       controlPoint2: NSPoint(x: 10.4 + sway, y: 8.6))
        }
    }

    /// A four-point sparkle pulsing, with a smaller one offset behind it.
    static let sparkle = BuiltinIcon("anim.sparkle", "Sparkle", .animated, period: 3.0) { pen, phase in
        // A closure rather than a nested `func`: local functions do not inherit the drawing
        // closure's main-actor isolation, so one that touches `pen` would not compile.
        let star = { (cx: Double, cy: Double, size: Double, t: Double) in
            let long = size * (0.55 + pingPong(t) * 0.45)
            let short = long * 0.26
            pen.filledRadialPolygon(cx, cy, [
                (0, long), (45, short), (90, long), (135, short),
                (180, long), (225, short), (270, long), (315, short),
            ])
        }
        star(10.6, 10.6, 7.8, phase)
        star(18.0, 17.6, 3.8, (phase + 0.45).truncatingRemainder(dividingBy: 1))
    }

    /// A clock whose sweep hand turns once per loop. The hour hand creeps, because a clock with
    /// two hands locked together does not look like a clock.
    static let clock = BuiltinIcon("anim.clock", "Clock", .animated, period: 3.6) { pen, phase in
        pen.circle(12, 12, 8.4)
        pen.disc(12, 12, 1.1)

        let hour = -0.12 + phase * 0.24
        pen.with(width: 2.0).line(12, 12, 12 + sin(hour) * 4.2, 12 - cos(hour) * 4.2)

        let sweep = phase * 2 * .pi
        pen.with(width: 1.4).line(12, 12, 12 + sin(sweep) * 6.3, 12 - cos(sweep) * 6.3)
    }

    /// Sand draining from the top bulb into the bottom one, then the whole glass turns over.
    ///
    /// The spin is not decoration — it is what makes the loop honest. Draining sand that
    /// teleports back to the top is the exact "visible tick at the seam" this set avoids, and
    /// because the frame is symmetric a 180° turn lands back on the starting silhouette.
    static let hourglass = BuiltinIcon("anim.hourglass", "Hourglass", .animated, period: 4.5) { pen, phase in
        let spinStart = 0.86
        let spin = phase < spinStart ? 0 : ease((phase - spinStart) / (1 - spinStart)) * .pi

        func turn(_ x: Double, _ y: Double) -> NSPoint {
            let dx = x - 12, dy = y - 12
            return NSPoint(x: 12 + dx * cos(spin) - dy * sin(spin),
                           y: 12 + dx * sin(spin) + dy * cos(spin))
        }

        // Caps, then the funnel walls starting *on* the cap lines. Closing each bulb into a
        // triangle would double the stroke along the caps, and at 18pt two strokes 1.8 units
        // apart merge into one heavy bar.
        let stroke = { (a: NSPoint, b: NSPoint, width: Double) in
            pen.with(width: width).line(a.x, a.y, b.x, b.y)
        }
        stroke(turn(5.8, 4.0), turn(18.2, 4.0), 1.8)
        stroke(turn(5.8, 20.0), turn(18.2, 20.0), 1.8)

        let walls = { (capY: Double, waistY: Double) in
            pen.poly([turn(7.0, capY), turn(12, waistY), turn(17.0, capY)].map { ($0.x, $0.y) })
        }
        walls(4.0, 11.6)
        walls(20.0, 12.4)

        let drained = ease(min(phase / spinStart, 1))

        // Top bulb: the sand surface descends towards the waist, so the wedge shrinks to nothing.
        let remaining = 1 - drained
        if remaining > 0.05 {
            let surface = 11.4 - 5.4 * remaining
            let halfWidth = (11.4 - surface) * 0.62
            pen.filledPoly([
                (12 - halfWidth, surface), (12 + halfWidth, surface), (12, 11.4),
            ].map { point in let q = turn(point.0, point.1); return (q.x, q.y) })
        }

        // Bottom bulb: a heap building on the base.
        if drained > 0.05 {
            let height = 4.8 * drained
            pen.filledPoly([
                (12 - 3.8, 19.7), (12 + 3.8, 19.7), (12, 19.7 - height),
            ].map { point in let q = turn(point.0, point.1); return (q.x, q.y) })
        }

        // The falling stream, only while there is sand left to fall.
        if remaining > 0.05, spin == 0 {
            pen.with(width: 1.2).with(alpha: 0.7).line(12, 12.6, 12, 17.4)
        }
    }

    /// Concentric rings expanding outward and fading — a signal leaving an antenna.
    static let ripple = BuiltinIcon("anim.ripple", "Ripple", .animated, period: 3.0) { pen, phase in
        pen.disc(12, 12, 2.2)
        // Three rings a third of a loop apart, so one is always mid-flight.
        for index in 0..<3 {
            let local = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let t = ease(local)
            let radius = 3.4 + t * 6.6
            pen.with(width: 1.6).with(alpha: (1 - t) * 0.8 * min(local * 6, 1)).circle(12, 12, radius)
        }
    }

    /// A rocket hovering, with an exhaust plume that flickers rather than pulses evenly.
    static let rocket = BuiltinIcon("anim.rocket", "Rocket", .animated, period: 3.2) { pen, phase in
        let hover = sin(phase * 2 * .pi) * 0.7
        let cy = 11.4 + hover

        // Body: a nose cone easing into a tube. Kept wide on purpose — at 18pt a narrow body is
        // two strokes with no gap between them, which renders as a dark wedge rather than a
        // rocket.
        pen.with(width: 1.7).curve { path in
            path.move(to: NSPoint(x: 12, y: cy - 8.0))
            path.curve(to: NSPoint(x: 16.4, y: cy + 3.4),
                       controlPoint1: NSPoint(x: 15.4, y: cy - 5.0),
                       controlPoint2: NSPoint(x: 16.4, y: cy - 0.8))
            path.line(to: NSPoint(x: 7.6, y: cy + 3.4))
            path.curve(to: NSPoint(x: 12, y: cy - 8.0),
                       controlPoint1: NSPoint(x: 7.6, y: cy - 0.8),
                       controlPoint2: NSPoint(x: 8.6, y: cy - 5.0))
        }
        // Fins, set outside the body so the silhouette stays legible.
        pen.with(width: 1.5).poly([(8.0, cy - 0.2), (4.4, cy + 5.0), (8.0, cy + 3.4)], closed: true)
        pen.with(width: 1.5).poly([(16.0, cy - 0.2), (19.6, cy + 5.0), (16.0, cy + 3.4)], closed: true)
        // Window.
        pen.with(width: 1.4).circle(12, cy - 3.4, 1.6)

        // Exhaust: two flickering tongues on different frequencies.
        let flare = 0.55 + abs(sin(phase * 2 * .pi * 3.5)) * 0.45
        pen.with(width: 1.7).with(alpha: 0.85).line(12, cy + 4.0, 12, cy + 4.0 + 3.4 * flare)
        let side = 0.45 + abs(sin(phase * 2 * .pi * 2.3 + 1.1)) * 0.4
        pen.with(width: 1.4).with(alpha: 0.55).line(10.4, cy + 4.0, 10.4, cy + 4.0 + 2.4 * side)
        pen.with(width: 1.4).with(alpha: 0.55).line(13.6, cy + 4.0, 13.6, cy + 4.0 + 2.4 * side)
    }

    // MARK: - Interactive

    /// A dog face that breathes gently at rest and reacts when you click its menu bar item.
    ///
    /// The idle loop is a slow, calming breath with occasional blinks — minimal motion that
    /// never nags in peripheral vision. When clicked the dog perks up: ears lift, eyes widen,
    /// and a tiny tongue appears for a moment before settling back to idle.
    ///
    /// Phase convention (shared with ``StatusItemController``):
    /// - `0…1` — idle breathing cycle.
    /// - `1…2` — one-shot click reaction. ``StatusItemController`` drives this range directly.
    static let dog = BuiltinIcon("anim.dog", "Dog", .animated, period: 3.4) { pen, phase in
        let isReaction = phase >= 1.0
        let t = isReaction ? (phase - 1.0) : phase

        // Shared parameters, modified by state.
        let headCenterX = 12.0
        let headCenterY = 13.0
        let baseHeadRadius = 6.5

        let headRadius: Double
        let leftEarTip: (Double, Double)
        let rightEarTip: (Double, Double)
        let eyeRadius: Double
        let eyeY: Double
        let showTongue: Bool

        if isReaction {
            // --- Reaction: perk up over ~0.55 s, then settle ---
            let progress = min(t / 0.55, 1.0)
            let settle = progress >= 1.0 ? ease((t - 0.55) / 0.45) : 1.0
            let intensity = ease(progress) * settle

            // Ears lift outward and up.
            let earLift = 3.0 * intensity
            leftEarTip = (4.0 - intensity * 1.5, 5.0 - earLift)
            rightEarTip = (20.0 + intensity * 1.5, 5.0 - earLift)

            // Eyes widen.
            eyeRadius = 0.9 + intensity * 0.7
            eyeY = 12.5 - intensity * 0.4

            // Bounce: head scales slightly.
            let bounce = 1.0 + pingPong(min(t * 1.8, 1.0)) * 0.08
            headRadius = baseHeadRadius * bounce * (1.0 + intensity * 0.04)

            showTongue = intensity > 0.3
        } else {
            // --- Idle: slow breath + blink ---
            let breathe = 1.0 + sin(t * 2 * .pi) * 0.028
            headRadius = baseHeadRadius * breathe

            // Ears at rest, drooping slightly.
            leftEarTip = (4.8, 6.2)
            rightEarTip = (19.2, 6.2)

            // Blink during the last 13 % of the cycle.
            let blinkLocal = (t * 3.4).truncatingRemainder(dividingBy: 1)
            let isBlinking = blinkLocal > 0.87
            eyeRadius = isBlinking ? 0.3 : 1.1
            eyeY = 12.5

            // Tongue flicks out briefly once per cycle.
            showTongue = blinkLocal > 0.66 && blinkLocal < 0.78
        }

        // --- Ears ---
        pen.poly([(7.5, 8.0), leftEarTip, (9.8, 8.2)], closed: true)
        pen.poly([(16.5, 8.0), rightEarTip, (14.2, 8.2)], closed: true)

        // --- Head ---
        pen.circle(headCenterX, headCenterY, headRadius)

        // --- Eyes ---
        if eyeRadius < 0.5 {
            // Closed / blinking: thin lines.
            pen.line(8.0, eyeY, 10.6, eyeY)
            pen.line(13.4, eyeY, 16.0, eyeY)
        } else {
            let eyePen = pen.with(width: 1.4)
            eyePen.disc(9.3, eyeY, eyeRadius)
            eyePen.disc(14.7, eyeY, eyeRadius)
        }

        // --- Nose ---
        pen.disc(headCenterX, 15.2, 1.0)

        // --- Mouth ---
        if showTongue {
            // Happy panting mouth with tongue.
            pen.arc(headCenterX, 15.6, 2.2, from: 215, to: 325)
            pen.curve { path in
                path.move(to: NSPoint(x: 11.0, y: 16.2))
                path.curve(to: NSPoint(x: 13.0, y: 16.2),
                           controlPoint1: NSPoint(x: 11.0, y: 17.8), controlPoint2: NSPoint(x: 13.0, y: 17.8))
            }
        } else {
            // Gentle smile.
            pen.arc(headCenterX, 15.8, 1.8, from: 215, to: 325)
        }
    }

    /// A cat that sits still with slow blinks, and looks up sharply when clicked.
    ///
    /// Built as the dog's opposite on purpose: pointed ears instead of folded, slit pupils
    /// instead of round, whiskers instead of a muzzle. Two animals drawn from the same parts
    /// would just be one animal with a different label.
    ///
    /// Phase convention: `0…1` idle, `1…2` click reaction. See ``StatusItemController``.
    static let cat = BuiltinIcon("anim.cat", "Cat", .animated, period: 3.6) { pen, phase in
        let isReaction = phase >= 1.0
        let t = isReaction ? (phase - 1.0) : phase

        let headY: Double
        let earLift: Double
        let pupilHeight: Double
        let pupilWidth: Double
        let whiskerSpread: Double

        if isReaction {
            // Perks up over ~0.5s, then settles back.
            let progress = min(t / 0.5, 1.0)
            let settle = progress >= 1.0 ? 1.0 - ease(min((t - 0.5) / 0.5, 1.0)) * 0.35 : 1.0
            let intensity = ease(progress) * settle

            headY = 13.2 - intensity * 0.7
            earLift = intensity * 1.4
            // Eyes go round with surprise, which is the whole tell.
            pupilHeight = 1.5 + intensity * 1.1
            pupilWidth = 0.75 + intensity * 0.85
            whiskerSpread = intensity * 1.1
        } else {
            // Idle: a breath so slight it reads as stillness, plus a slow blink.
            headY = 13.2 + sin(t * 2 * .pi) * 0.22
            earLift = 0
            let blink = (t * 2.0).truncatingRemainder(dividingBy: 1)
            let isBlinking = blink > 0.93
            pupilHeight = isBlinking ? 0.2 : 2.0
            pupilWidth = isBlinking ? 0.2 : 0.75
            whiskerSpread = 0
        }

        // Ears: pointed triangles, with an inner notch that survives 18pt because it is a
        // single stroke rather than a second outline.
        pen.poly([(6.2, headY - 3.0), (5.4, headY - 8.2 - earLift), (10.2, headY - 5.4)], closed: true)
        pen.poly([(17.8, headY - 3.0), (18.6, headY - 8.2 - earLift), (13.8, headY - 5.4)], closed: true)

        // Head: slightly wide, the way a cat's is.
        pen.ellipse(12, headY, 6.4, 5.8)

        // Eyes: vertical slits at rest.
        if pupilHeight < 0.5 {
            pen.with(width: 1.4).line(8.4, headY - 0.8, 10.6, headY - 0.8)
            pen.with(width: 1.4).line(13.4, headY - 0.8, 15.6, headY - 0.8)
        } else {
            pen.with(width: 1.3).ellipse(9.5, headY - 0.8, pupilWidth, pupilHeight)
            pen.with(width: 1.3).ellipse(14.5, headY - 0.8, pupilWidth, pupilHeight)
        }

        // Nose and mouth.
        pen.filledPoly([(11.2, headY + 2.0), (12.8, headY + 2.0), (12, headY + 3.0)])
        pen.with(width: 1.3).arc(10.6, headY + 3.0, 1.4, from: 90, to: 175)
        pen.with(width: 1.3).arc(13.4, headY + 3.0, 1.4, from: 185, to: 270)

        // Whiskers, spreading when startled. Kept inside the 3…21 content box like every other
        // glyph, so the cat carries the same optical weight as its neighbours.
        let whiskers = pen.with(width: 1.2)
        for index in 0..<2 {
            let dy = Double(index) * 1.5 - 0.2 - whiskerSpread * Double(index)
            whiskers.line(6.2, headY + 1.4 + dy, 3.0, headY + 0.7 + dy - whiskerSpread)
            whiskers.line(17.8, headY + 1.4 + dy, 21.0, headY + 0.7 + dy - whiskerSpread)
        }
    }

    /// A ghost bobbing on the spot, which startles upward when clicked.
    ///
    /// Phase convention: `0…1` idle, `1…2` click reaction.
    static let ghost = BuiltinIcon("anim.ghost", "Ghost", .animated, period: 3.8) { pen, phase in
        let isReaction = phase >= 1.0
        let t = isReaction ? (phase - 1.0) : phase

        let lift: Double
        let eyeRadius: Double
        if isReaction {
            // One startled hop, eyes wide for the duration of it.
            let progress = min(t / 0.75, 1.0)
            lift = -pingPong(progress) * 2.6
            eyeRadius = 1.15 + ease(min(t / 0.3, 1.0)) * 0.6 * (1 - progress * 0.4)
        } else {
            lift = sin(t * 2 * .pi) * 0.9
            eyeRadius = 1.15
        }

        let cy = 11.2 + lift

        pen.curve { path in
            path.move(to: NSPoint(x: 4.8, y: cy + 7.6))
            path.line(to: NSPoint(x: 4.8, y: cy))
            path.curve(to: NSPoint(x: 19.2, y: cy),
                       controlPoint1: NSPoint(x: 4.8, y: cy - 9.4),
                       controlPoint2: NSPoint(x: 19.2, y: cy - 9.4))
            path.line(to: NSPoint(x: 19.2, y: cy + 7.6))
            // Scalloped hem, drawn right to left so the curve alternates below and above the
            // baseline — a straight hem makes this a lightbulb.
            path.curve(to: NSPoint(x: 14.4, y: cy + 7.6),
                       controlPoint1: NSPoint(x: 18.0, y: cy + 5.2),
                       controlPoint2: NSPoint(x: 15.6, y: cy + 5.2))
            path.curve(to: NSPoint(x: 9.6, y: cy + 7.6),
                       controlPoint1: NSPoint(x: 13.2, y: cy + 10.0),
                       controlPoint2: NSPoint(x: 10.8, y: cy + 10.0))
            path.curve(to: NSPoint(x: 4.8, y: cy + 7.6),
                       controlPoint1: NSPoint(x: 8.4, y: cy + 5.2),
                       controlPoint2: NSPoint(x: 6.0, y: cy + 5.2))
        }

        pen.disc(9.5, cy - 1.6, eyeRadius)
        pen.disc(14.5, cy - 1.6, eyeRadius)
    }

    /// A bell that barely tilts at rest and rings properly when clicked.
    ///
    /// The idle motion is almost nothing on purpose: a bell that swings all day is a notification
    /// nobody asked for. The click is what makes it ring, and the swing decays like a real one.
    ///
    /// Phase convention: `0…1` idle, `1…2` click reaction.
    static let bell = BuiltinIcon("anim.bell", "Bell", .animated, period: 4.0) { pen, phase in
        let isReaction = phase >= 1.0
        let t = isReaction ? (phase - 1.0) : phase

        let tilt: Double
        if isReaction {
            // Three swings, damped to nothing by the end of the reaction.
            let decay = max(0, 1 - t / 0.95)
            tilt = sin(t * 2 * .pi * 3.2) * 0.30 * decay * decay
        } else {
            tilt = sin(t * 2 * .pi) * 0.04
        }

        // Everything rotates about the crown, so the bell hangs rather than slides.
        func hang(_ x: Double, _ y: Double, extra: Double = 0) -> NSPoint {
            let angle = tilt * (1 + extra)
            let dx = x - 12, dy = y - 4.2
            return NSPoint(x: 12 + dx * cos(angle) - dy * sin(angle),
                           y: 4.2 + dx * sin(angle) + dy * cos(angle))
        }

        // The crown has to be *narrow*. Two control points at the same height give a broad flat
        // top, which is a cloche; pulling them in towards the centre line is what makes the
        // shoulders slope and the thing read as a bell.
        pen.curve { path in
            path.move(to: hang(6.0, 16.4))
            path.curve(to: hang(12, 4.4),
                       controlPoint1: hang(6.2, 9.4),
                       controlPoint2: hang(8.4, 4.4))
            path.curve(to: hang(18.0, 16.4),
                       controlPoint1: hang(15.6, 4.4),
                       controlPoint2: hang(17.8, 9.4))
            path.close()
        }
        // Lip, a touch wider than the body.
        let lipLeft = hang(4.8, 16.4), lipRight = hang(19.2, 16.4)
        pen.with(width: 1.7).line(lipLeft.x, lipLeft.y, lipRight.x, lipRight.y)

        // The clapper swings further than the bell, which is what sells the ring.
        let clapper = hang(12, 18.8, extra: 0.9)
        pen.disc(clapper.x, clapper.y, 1.3)
    }
}
