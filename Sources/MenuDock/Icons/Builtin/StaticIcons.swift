import AppKit

/// 36 minimalist glyphs covering the app categories people actually put in a Dock.
///
/// These are **category glyphs, not brand logos** — one "Browser" icon serves Safari, Chrome,
/// Arc and Firefox. That is a deliberate choice on three grounds: redrawing third-party marks
/// would be a trademark problem to ship, brand logos age badly as companies rebrand, and a
/// coherent single-weight set reads far better in a menu bar than a row of mismatched logos.
/// Users who want a specific brand mark can still drop in their own SVG.
///
/// Every glyph shares one design system: 24 × 24 grid, 1.9-unit stroke, round caps and joins,
/// content inside 3…21 so silhouettes carry equal optical weight.
@MainActor
enum StaticIcons {

    static let all: [BuiltinIcon] = web + communication + productivity + development + media + design + system

    // MARK: - Web & Browsing (4)

    static let web: [BuiltinIcon] = [
        BuiltinIcon("globe", "Globe", .web) { pen, _ in
            pen.circle(12, 12, 8.5)
            pen.ellipse(12, 12, 3.6, 8.5)
            pen.line(3.8, 12, 20.2, 12)
        },

        BuiltinIcon("compass", "Compass", .web) { pen, _ in
            pen.circle(12, 12, 8.5)
            pen.filledPoly([(15.5, 8.5), (13.2, 13.2), (8.5, 15.5), (10.8, 10.8)])
        },

        BuiltinIcon("browser", "Browser", .web) { pen, _ in
            pen.rrect(3.5, 4.5, 17, 15, 2.6)
            pen.line(3.5, 9.2, 20.5, 9.2)
            pen.with(width: 1.4).disc(6.6, 6.9, 0.75)
            pen.with(width: 1.4).disc(9.3, 6.9, 0.75)
        },

        BuiltinIcon("bookmark", "Bookmark", .web) { pen, _ in
            pen.poly([(6.5, 3.8), (17.5, 3.8), (17.5, 20.2), (12, 15.6), (6.5, 20.2)], closed: true)
        },
    ]

    // MARK: - Communication (6)

    static let communication: [BuiltinIcon] = [
        BuiltinIcon("mail", "Mail", .communication) { pen, _ in
            pen.rrect(3, 6, 18, 12, 2.4)
            pen.poly([(4.4, 7.6), (12, 13.4), (19.6, 7.6)])
        },

        BuiltinIcon("chat", "Chat Bubble", .communication) { pen, _ in
            pen.rrect(3.5, 4.5, 17, 12.4, 3.4)
            pen.poly([(8.6, 16.9), (8.6, 20.6), (12.8, 16.9)], closed: true)
        },

        BuiltinIcon("chats", "Conversation", .communication) { pen, _ in
            pen.rrect(2.8, 4, 13.4, 9.8, 2.8)
            pen.poly([(6.6, 13.8), (6.6, 17), (9.8, 13.8)], closed: true)
            pen.rrect(9.6, 10.6, 11.6, 8.4, 2.6)
            pen.poly([(17.6, 19), (17.6, 21.6), (14.8, 19)], closed: true)
        },

        BuiltinIcon("video", "Video Call", .communication) { pen, _ in
            pen.rrect(2.8, 6.4, 13, 11.2, 2.6)
            pen.poly([(16.4, 10.4), (21, 7.6), (21, 16.4), (16.4, 13.6)], closed: true)
        },

        BuiltinIcon("phone", "Phone", .communication) { pen, _ in
            pen.curve { path in
                path.move(to: NSPoint(x: 6.2, y: 3.8))
                path.line(to: NSPoint(x: 9.4, y: 3.8))
                path.curve(to: NSPoint(x: 10.8, y: 8.6),
                           controlPoint1: NSPoint(x: 9.9, y: 5.6), controlPoint2: NSPoint(x: 10.3, y: 7.2))
                path.line(to: NSPoint(x: 8.6, y: 10.4))
                path.curve(to: NSPoint(x: 13.6, y: 15.4),
                           controlPoint1: NSPoint(x: 9.8, y: 12.6), controlPoint2: NSPoint(x: 11.4, y: 14.2))
                path.line(to: NSPoint(x: 15.4, y: 13.2))
                path.curve(to: NSPoint(x: 20.2, y: 14.6),
                           controlPoint1: NSPoint(x: 16.8, y: 13.7), controlPoint2: NSPoint(x: 18.4, y: 14.1))
                path.line(to: NSPoint(x: 20.2, y: 17.8))
                path.curve(to: NSPoint(x: 17.6, y: 20.2),
                           controlPoint1: NSPoint(x: 20.2, y: 19.2), controlPoint2: NSPoint(x: 19, y: 20.3))
                path.curve(to: NSPoint(x: 3.8, y: 6.4),
                           controlPoint1: NSPoint(x: 9.6, y: 19.4), controlPoint2: NSPoint(x: 4.6, y: 14.4))
                path.curve(to: NSPoint(x: 6.2, y: 3.8),
                           controlPoint1: NSPoint(x: 3.7, y: 5), controlPoint2: NSPoint(x: 4.8, y: 3.8))
            }
        },

        BuiltinIcon("send", "Send", .communication) { pen, _ in
            pen.poly([(20.4, 3.6), (3.6, 10.4), (10.6, 13.4), (13.6, 20.4)], closed: true)
            pen.line(10.6, 13.4, 20.4, 3.6)
        },
    ]

    // MARK: - Productivity (6)

    static let productivity: [BuiltinIcon] = [
        BuiltinIcon("note", "Notes", .productivity) { pen, _ in
            pen.rrect(4.5, 3, 15, 18, 2.4)
            pen.line(8, 8.4, 16, 8.4)
            pen.line(8, 12, 16, 12)
            pen.line(8, 15.6, 13, 15.6)
        },

        BuiltinIcon("checklist", "Tasks", .productivity) { pen, _ in
            pen.poly([(3.4, 7.4), (5.2, 9.2), (8.6, 5.4)])
            pen.line(11.6, 7.4, 20.6, 7.4)
            pen.poly([(3.4, 16.2), (5.2, 18), (8.6, 14.2)])
            pen.line(11.6, 16.2, 20.6, 16.2)
        },

        BuiltinIcon("calendar", "Calendar", .productivity) { pen, _ in
            pen.rrect(3.4, 5, 17.2, 15.6, 2.6)
            pen.line(3.4, 10, 20.6, 10)
            pen.line(8.2, 3.2, 8.2, 6.6)
            pen.line(15.8, 3.2, 15.8, 6.6)
            pen.with(width: 1.4).disc(8.4, 14.2, 0.85)
            pen.with(width: 1.4).disc(12, 14.2, 0.85)
            pen.with(width: 1.4).disc(15.6, 14.2, 0.85)
        },

        BuiltinIcon("clock", "Clock", .productivity) { pen, _ in
            pen.circle(12, 12, 8.6)
            pen.poly([(12, 6.8), (12, 12), (16, 14)])
        },

        BuiltinIcon("document", "Document", .productivity) { pen, _ in
            pen.poly([(5.5, 2.8), (14.2, 2.8), (18.5, 7.4), (18.5, 21.2), (5.5, 21.2)], closed: true)
            pen.poly([(14, 3), (14, 7.6), (18.3, 7.6)])
        },

        BuiltinIcon("folder", "Folder", .productivity) { pen, _ in
            pen.poly([(3, 19.4), (3, 5.4), (9.4, 5.4), (11.6, 8.2), (21, 8.2), (21, 19.4)], closed: true)
        },
    ]

    // MARK: - Development (6)

    static let development: [BuiltinIcon] = [
        BuiltinIcon("terminal", "Terminal", .development) { pen, _ in
            pen.rrect(3, 4.4, 18, 15.2, 2.6)
            pen.poly([(7, 9.6), (10.2, 12.4), (7, 15.2)])
            pen.line(12.6, 15.4, 17, 15.4)
        },

        BuiltinIcon("code", "Code", .development) { pen, _ in
            pen.poly([(8.6, 7), (3.4, 12), (8.6, 17)])
            pen.poly([(15.4, 7), (20.6, 12), (15.4, 17)])
        },

        BuiltinIcon("branch", "Version Control", .development) { pen, _ in
            pen.circle(7, 5.6, 2.4)
            pen.circle(7, 18.4, 2.4)
            pen.circle(17, 9.4, 2.4)
            pen.line(7, 8, 7, 16)
            pen.curve { path in
                path.move(to: NSPoint(x: 17, y: 11.8))
                path.curve(to: NSPoint(x: 9.3, y: 18),
                           controlPoint1: NSPoint(x: 17, y: 16), controlPoint2: NSPoint(x: 13.4, y: 17.6))
            }
        },

        BuiltinIcon("database", "Database", .development) { pen, _ in
            pen.ellipse(12, 6.4, 7.6, 3.2)
            pen.line(4.4, 6.4, 4.4, 17.6)
            pen.line(19.6, 6.4, 19.6, 17.6)
            pen.arc(12, 17.6, 7.6, from: 90, to: 270)
            pen.arc(12, 12, 7.6, from: 90, to: 270)
        },

        BuiltinIcon("bug", "Debugger", .development) { pen, _ in
            // Fewer, shorter, thinner legs than anatomy suggests. Six full-length legs plus
            // antennae turn into a spiky blob once the glyph is 18pt across.
            pen.rrect(7.6, 8.2, 8.8, 11.6, 4.4)
            pen.line(12, 10.4, 12, 17.6)
            let legs = pen.with(width: 1.55)
            legs.line(7.6, 11.6, 4.6, 10.0)
            legs.line(7.6, 14.4, 4.4, 14.4)
            legs.line(7.6, 17.0, 4.6, 18.6)
            legs.line(16.4, 11.6, 19.4, 10.0)
            legs.line(16.4, 14.4, 19.6, 14.4)
            legs.line(16.4, 17.0, 19.4, 18.6)
            legs.line(9.8, 7.2, 8.6, 4.8)
            legs.line(14.2, 7.2, 15.4, 4.8)
        },

        BuiltinIcon("container", "Container", .development) { pen, _ in
            pen.poly([(12, 3.2), (20.6, 7.8), (20.6, 16.2), (12, 20.8), (3.4, 16.2), (3.4, 7.8)], closed: true)
            pen.poly([(3.4, 7.8), (12, 12.4), (20.6, 7.8)])
            pen.line(12, 12.4, 12, 20.8)
        },
    ]

    // MARK: - Media (6)

    static let media: [BuiltinIcon] = [
        BuiltinIcon("music", "Music", .media) { pen, _ in
            pen.line(9.6, 17, 9.6, 4.8)
            pen.line(9.6, 4.8, 19.4, 3.2)
            pen.line(19.4, 3.2, 19.4, 15.4)
            pen.ellipse(7.2, 17.2, 2.5, 2.1)
            pen.ellipse(17, 15.6, 2.5, 2.1)
        },

        BuiltinIcon("play", "Player", .media) { pen, _ in
            pen.circle(12, 12, 8.6)
            pen.filledPoly([(9.8, 7.6), (16.6, 12), (9.8, 16.4)])
        },

        BuiltinIcon("headphones", "Audio", .media) { pen, _ in
            pen.arc(12, 12.4, 8.2, from: -90, to: 90)
            pen.rrect(3.2, 12.2, 4.4, 7.6, 2.2)
            pen.rrect(16.4, 12.2, 4.4, 7.6, 2.2)
        },

        BuiltinIcon("camera", "Camera", .media) { pen, _ in
            pen.rrect(2.8, 6.6, 18.4, 13.4, 2.8)
            pen.poly([(8.4, 6.6), (9.8, 3.8), (14.2, 3.8), (15.6, 6.6)])
            pen.circle(12, 13.2, 3.9)
        },

        BuiltinIcon("film", "Film", .media) { pen, _ in
            // A clapperboard, not a film strip. Sprocket holes shrink below the visible
            // threshold at 18pt and the remaining rails read as a table grid; the clapper's
            // diagonal stripes stay unmistakable at any size.
            pen.rrect(3, 9.4, 18, 10.6, 2.2)
            pen.poly([(3.2, 9.4), (7.0, 4.6), (10.6, 4.6), (6.8, 9.4)], closed: true)
            pen.poly([(10.6, 9.4), (14.4, 4.6), (18.0, 4.6), (14.2, 9.4)], closed: true)
            pen.line(3, 9.4, 21, 9.4)
        },

        BuiltinIcon("image", "Photos", .media) { pen, _ in
            pen.rrect(3, 4.6, 18, 14.8, 2.6)
            pen.circle(8.6, 9.6, 1.8)
            pen.poly([(3.4, 18.4), (10, 12.2), (14.4, 16.2), (17.2, 13.6), (20.6, 16.8)])
        },
    ]

    // MARK: - Design (4)

    static let design: [BuiltinIcon] = [
        BuiltinIcon("pen", "Vector Pen", .design) { pen, _ in
            pen.poly([(3.6, 20.4), (6, 13.4), (15.4, 4), (20, 8.6), (10.6, 18), (3.6, 20.4)], closed: true)
            pen.line(6, 13.4, 10.6, 18)
            pen.line(12.8, 6.6, 17.4, 11.2)
        },

        BuiltinIcon("palette", "Palette", .design) { pen, _ in
            pen.curve { path in
                path.move(to: NSPoint(x: 12, y: 20.6))
                path.curve(to: NSPoint(x: 3.4, y: 12),
                           controlPoint1: NSPoint(x: 7.2, y: 20.6), controlPoint2: NSPoint(x: 3.4, y: 16.8))
                path.curve(to: NSPoint(x: 12, y: 3.4),
                           controlPoint1: NSPoint(x: 3.4, y: 7.2), controlPoint2: NSPoint(x: 7.2, y: 3.4))
                path.curve(to: NSPoint(x: 20.6, y: 11.2),
                           controlPoint1: NSPoint(x: 16.8, y: 3.4), controlPoint2: NSPoint(x: 20.6, y: 6.8))
                path.curve(to: NSPoint(x: 16.6, y: 14.6),
                           controlPoint1: NSPoint(x: 20.6, y: 13.4), controlPoint2: NSPoint(x: 18.8, y: 14.6))
                path.curve(to: NSPoint(x: 12, y: 20.6),
                           controlPoint1: NSPoint(x: 13.4, y: 14.6), controlPoint2: NSPoint(x: 14.2, y: 20.6))
            }
            pen.with(width: 1.4).disc(8.4, 8.6, 1.05)
            pen.with(width: 1.4).disc(13.4, 7.4, 1.05)
            pen.with(width: 1.4).disc(7.6, 13.8, 1.05)
        },

        BuiltinIcon("layers", "Layers", .design) { pen, _ in
            pen.poly([(12, 3.2), (21, 8), (12, 12.8), (3, 8)], closed: true)
            pen.poly([(4.6, 12.4), (12, 16.4), (19.4, 12.4)])
            pen.poly([(4.6, 16.4), (12, 20.4), (19.4, 16.4)])
        },

        BuiltinIcon("frame", "Artboard", .design) { pen, _ in
            pen.line(7.6, 2.8, 7.6, 21.2)
            pen.line(16.4, 2.8, 16.4, 21.2)
            pen.line(2.8, 7.6, 21.2, 7.6)
            pen.line(2.8, 16.4, 21.2, 16.4)
        },
    ]

    // MARK: - System & Utilities (4)

    static let system: [BuiltinIcon] = [
        BuiltinIcon("gear", "Settings", .system) { pen, _ in
            // A cog is a filled body with *squared, shallow* teeth. Thin radial spokes —
            // the obvious shortcut — read as a sun at menu bar size, because that is exactly
            // what distinguishes a sun from a gear: ray thickness and tooth depth.
            let teeth = 8
            let slice = 360.0 / Double(teeth)
            var points: [(Double, Double)] = []
            for index in 0..<teeth {
                let base = Double(index) * slice
                points.append((base - slice * 0.19, 9.3))
                points.append((base + slice * 0.19, 9.3))
                points.append((base + slice * 0.31, 7.2))
                points.append((base + slice * 0.69, 7.2))
            }
            // A wider bore keeps the cog's optical weight in line with the outlined glyphs
            // it sits beside; a solid disc with teeth reads much heavier than its neighbours.
            pen.filledRadialPolygon(12, 12, points, joinRadius: 0.8)
            pen.punchDisc(12, 12, 4.0)
        },

        BuiltinIcon("search", "Search", .system) { pen, _ in
            pen.circle(10.6, 10.6, 6.4)
            pen.line(15.4, 15.4, 20.4, 20.4)
        },

        BuiltinIcon("lock", "Security", .system) { pen, _ in
            pen.rrect(4.6, 10.4, 14.8, 10.4, 2.6)
            pen.arc(12, 10.4, 4.4, from: -90, to: 90)
            pen.with(width: 1.4).disc(12, 15.6, 1.3)
        },

        BuiltinIcon("power", "Power", .system) { pen, _ in
            pen.arc(12, 13, 7.4, from: 40, to: 320)
            pen.line(12, 3.4, 12, 10.6)
        },
    ]
}
