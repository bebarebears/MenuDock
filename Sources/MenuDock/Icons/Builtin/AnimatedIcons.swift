import AppKit

/// 12 gently animated glyphs.
///
/// ## Restraint is the whole design brief
///
/// A menu bar sits in peripheral vision for the entire working day. Peripheral vision is
/// motion-sensitive by evolutionary design, so anything sharp or fast there reads as an alert
/// and pulls focus away from the user's actual work. Three rules follow:
///
/// - **Long periods** (2.4–4.5s). Nothing snaps.
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
}
