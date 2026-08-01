import AppKit

/// Minimalist glyphs covering the app categories people actually put in a Dock, plus the places
/// people point folder items at.
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

    static let all: [BuiltinIcon] = {
        var icons: [BuiltinIcon] = []
        icons.append(contentsOf: web)
        icons.append(contentsOf: communication)
        icons.append(contentsOf: productivity)
        icons.append(contentsOf: files)
        icons.append(contentsOf: development)
        icons.append(contentsOf: media)
        icons.append(contentsOf: design)
        icons.append(contentsOf: finance)
        icons.append(contentsOf: travel)
        icons.append(contentsOf: home)
        icons.append(contentsOf: social)
        icons.append(contentsOf: system)
        return icons
    }()

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

    // MARK: - Productivity (8)

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

        BuiltinIcon("clipboard", "Clipboard", .productivity) { pen, _ in
            // The default for the Clipboard item. A board with a clip is the one shape that reads
            // as "clipboard" and not as "document" at 18pt, and the clip has to break the board's
            // top edge to do it — a clip drawn *inside* the outline is just a small rectangle.
            pen.rrect(4.6, 4.4, 14.8, 16.6, 2.4)
            pen.rrect(8.6, 2.6, 6.8, 4.0, 1.3)
            pen.with(width: 1.5).line(8.4, 11.6, 15.6, 11.6)
            pen.with(width: 1.5).line(8.4, 15.4, 13.4, 15.4)
        },

        BuiltinIcon("archive", "Archive", .productivity) { pen, _ in
            pen.rrect(3.5, 6, 17, 14.4, 2.4)
            pen.line(3.5, 10.2, 20.5, 10.2)
            pen.poly([(9, 6), (9, 3.2), (15, 3.2), (15, 6)])
        },
    ]

    // MARK: - Files & Folders (15)
    //
    // Added for folder items, which is why the set leans towards *places*: the icon has to say
    // which folder this is at a glance, and a second identical folder glyph would say nothing.
    // Finder's own icon appears in menus and settings lists; this is the menu bar, where a
    // single-weight monochrome glyph is the only thing that reads.

    static let files: [BuiltinIcon] = [
        BuiltinIcon("folderOpen", "Open Folder", .files) { pen, _ in
            // Back panel with the tab, then the front panel tilted forward. Drawing the front as
            // a parallelogram is what sells "open" — a plain folder with a line across it reads
            // as a folder with a line across it.
            pen.poly([(3.4, 17.8), (3.4, 5.4), (9.0, 5.4), (11.2, 8.2), (19.0, 8.2), (19.0, 11.0)])
            pen.poly([(3.4, 17.8), (6.2, 11.0), (21.0, 11.0), (18.2, 17.8)], closed: true)
        },

        BuiltinIcon("documents", "Documents", .files) { pen, _ in
            // Front page with a folded corner.
            pen.poly([(4.2, 21.0), (4.2, 8.4), (11.0, 8.4), (14.6, 12.0), (14.6, 21.0)], closed: true)
            pen.with(width: 1.4).poly([(10.9, 8.6), (10.9, 12.1), (14.4, 12.1)])
            // The page behind, drawn as only the edges that would actually be visible — two
            // overlapping outlines would read as a grid, since template rendering has no
            // opaque fill to hide anything behind.
            pen.poly([(7.0, 8.2), (7.0, 4.2), (14.0, 4.2), (17.6, 7.8), (17.6, 17.8), (14.8, 17.8)])
        },

        BuiltinIcon("download", "Downloads", .files) { pen, _ in
            pen.line(12, 3.6, 12, 13.4)
            pen.poly([(7.8, 9.6), (12, 13.8), (16.2, 9.6)])
            pen.poly([(3.6, 15.2), (3.6, 20.0), (20.4, 20.0), (20.4, 15.2)])
        },

        BuiltinIcon("tray", "Inbox", .files) { pen, _ in
            pen.rrect(3.2, 5.2, 17.6, 13.6, 2.6)
            pen.poly([(3.2, 13.2), (8.2, 13.2), (9.6, 15.4), (14.4, 15.4), (15.8, 13.2), (20.8, 13.2)])
        },

        BuiltinIcon("drive", "Hard Drive", .files) { pen, _ in
            // Enclosure plus platter and spindle. A slot-and-LED version of this reads as a
            // battery gauge at 18pt; a circle inside a box does not read as anything else.
            pen.rrect(3.0, 6.0, 18.0, 12.0, 2.4)
            pen.circle(12.0, 12.0, 3.6)
            pen.with(width: 1.5).disc(12.0, 12.0, 0.9)
        },

        BuiltinIcon("externalDrive", "External Drive", .files) { pen, _ in
            pen.rrect(2.6, 6.4, 14.2, 9.6, 2.2)
            pen.circle(9.7, 11.2, 2.9)
            pen.with(width: 1.4).disc(9.7, 11.2, 0.8)
            // Cable off the *side*, not the bottom: run downward from underneath, it reads as
            // the tail of a speech bubble.
            pen.with(width: 1.5).curve { path in
                path.move(to: NSPoint(x: 16.8, y: 11.2))
                path.curve(to: NSPoint(x: 19.6, y: 19.6),
                           controlPoint1: NSPoint(x: 20.6, y: 11.6),
                           controlPoint2: NSPoint(x: 20.6, y: 16.6))
            }
        },

        BuiltinIcon("flag", "Flag", .files) { pen, _ in
            // Was a USB stick here. A body with a nub on one side is the battery silhouette no
            // matter which way round it is drawn, and the set already has a battery.
            pen.line(5.8, 3.4, 5.8, 20.6)
            pen.curve { path in
                path.move(to: NSPoint(x: 5.8, y: 4.6))
                path.line(to: NSPoint(x: 19.6, y: 4.6))
                path.line(to: NSPoint(x: 16.4, y: 9.2))
                path.line(to: NSPoint(x: 19.6, y: 13.8))
                path.line(to: NSPoint(x: 5.8, y: 13.8))
                path.close()
            }
        },

        BuiltinIcon("cloud", "Cloud", .files) { pen, _ in
            // One closed bezier: two bumps and a flat base. Built as three arcs it would need
            // their endpoints to meet exactly at every size, and they would not.
            pen.curve { path in
                path.move(to: NSPoint(x: 7.4, y: 17.6))
                path.curve(to: NSPoint(x: 7.0, y: 10.4),
                           controlPoint1: NSPoint(x: 3.2, y: 17.6),
                           controlPoint2: NSPoint(x: 2.6, y: 11.2))
                path.curve(to: NSPoint(x: 16.4, y: 9.6),
                           controlPoint1: NSPoint(x: 8.0, y: 4.6),
                           controlPoint2: NSPoint(x: 15.4, y: 4.8))
                path.curve(to: NSPoint(x: 16.8, y: 17.6),
                           controlPoint1: NSPoint(x: 21.4, y: 10.6),
                           controlPoint2: NSPoint(x: 21.0, y: 17.6))
                path.close()
            }
        },

        BuiltinIcon("trash", "Trash", .files) { pen, _ in
            pen.line(3.6, 6.8, 20.4, 6.8)
            pen.poly([(9.4, 6.8), (9.4, 4.0), (14.6, 4.0), (14.6, 6.8)])
            pen.poly([(5.8, 6.8), (7.0, 20.4), (17.0, 20.4), (18.2, 6.8)])
            let ribs = pen.with(width: 1.4)
            ribs.line(10.2, 10.4, 10.5, 16.8)
            ribs.line(13.8, 10.4, 13.5, 16.8)
        },

        BuiltinIcon("package", "Package", .files) { pen, _ in
            pen.rrect(3.4, 6.6, 17.2, 13.8, 2.2)
            pen.line(3.4, 11.2, 20.6, 11.2)
            pen.line(12.0, 6.6, 12.0, 11.2)
        },

        BuiltinIcon("briefcase", "Briefcase", .files) { pen, _ in
            pen.rrect(2.8, 7.4, 18.4, 12.6, 2.4)
            pen.poly([(8.8, 7.4), (8.8, 4.6), (15.2, 4.6), (15.2, 7.4)])
            pen.line(2.8, 12.4, 21.2, 12.4)
        },

        BuiltinIcon("book", "Book", .files) { pen, _ in
            pen.poly([(12, 8.0), (7.2, 5.2), (3.4, 5.2), (3.4, 17.4), (7.6, 17.4), (12, 20.0)])
            pen.poly([(12, 8.0), (16.8, 5.2), (20.6, 5.2), (20.6, 17.4), (16.4, 17.4), (12, 20.0)])
            pen.with(width: 1.5).line(12, 8.0, 12, 20.0)
        },

        BuiltinIcon("tag", "Tag", .files) { pen, _ in
            pen.poly([(3.6, 3.6), (11.4, 3.6), (20.4, 12.6), (12.6, 20.4), (3.6, 11.4)], closed: true)
            pen.with(width: 1.5).disc(7.6, 7.6, 1.25)
        },

        BuiltinIcon("link", "Alias", .files) { pen, _ in
            // Two hooks on the same 45° axis with a bar across the middle: the standard chain
            // link, built from an arc and its two tangent segments so the halves line up exactly.
            pen.arc(16.5, 7.5, 3.2, from: 315, to: 135)
            pen.line(14.24, 5.24, 11.13, 8.35)
            pen.line(18.76, 9.76, 15.65, 12.87)

            pen.arc(7.5, 16.5, 3.2, from: 135, to: 315)
            pen.line(9.76, 18.76, 12.87, 15.65)
            pen.line(5.24, 14.24, 8.35, 11.13)

            pen.line(10.4, 13.6, 13.6, 10.4)
        },

        BuiltinIcon("paperclip", "Attachment", .files) { pen, _ in
            pen.curve { path in
                path.move(to: NSPoint(x: 16.6, y: 10.4))
                path.line(to: NSPoint(x: 9.0, y: 18.0))
                path.curve(to: NSPoint(x: 5.4, y: 14.4),
                           controlPoint1: NSPoint(x: 7.0, y: 20.0),
                           controlPoint2: NSPoint(x: 3.4, y: 16.4))
                path.line(to: NSPoint(x: 13.6, y: 6.2))
                path.curve(to: NSPoint(x: 16.8, y: 9.4),
                           controlPoint1: NSPoint(x: 15.4, y: 4.4),
                           controlPoint2: NSPoint(x: 18.6, y: 7.6))
                path.line(to: NSPoint(x: 10.2, y: 16.0))
            }
        },
    ]

    // MARK: - Development (8)

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

        BuiltinIcon("wrench", "Wrench", .development) { pen, _ in
            pen.circle(8.5, 8.5, 5.2)
            pen.line(12.6, 12.6, 20.6, 20.6)
        },

        BuiltinIcon("server", "Server", .development) { pen, _ in
            pen.rrect(3.5, 3.2, 17, 17.6, 2.4)
            let slots = pen.with(width: 1.3)
            slots.line(8.5, 7.6, 17.5, 7.6)
            slots.line(8.5, 11.6, 17.5, 11.6)
            slots.line(8.5, 15.6, 17.5, 15.6)
            let leds = pen.with(width: 1.2)
            leds.disc(5.8, 7.6, 0.7)
            leds.disc(5.8, 11.6, 0.7)
            leds.disc(5.8, 15.6, 0.7)
        },
    ]

    // MARK: - Media (8)

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

        BuiltinIcon("microphone", "Microphone", .media) { pen, _ in
            pen.rrect(9.6, 3.5, 4.8, 9.6, 2.4)
            pen.poly([(8, 14), (16, 14), (14, 20.8), (10, 20.8)], closed: true)
            pen.line(10, 20.8, 14, 20.8)
        },

        BuiltinIcon("tv", "Display", .media) { pen, _ in
            pen.rrect(3.2, 4, 17.6, 13, 2.6)
            pen.line(8.5, 17, 15.5, 17)
            pen.line(12, 17, 12, 21)
            pen.line(8, 21, 16, 21)
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

    // MARK: - System & Utilities (8)

    static let system: [BuiltinIcon] = [
        BuiltinIcon("grid", "Grid", .system) { pen, _ in
            // The default for app groups: four tiles reads as "several things behind one icon"
            // without borrowing the folder metaphor, which now means an actual folder.
            let side = 7.0
            let radius = 1.3
            pen.rrect(4.0, 4.0, side, side, radius)
            pen.rrect(13.0, 4.0, side, side, radius)
            pen.rrect(4.0, 13.0, side, side, radius)
            pen.rrect(13.0, 13.0, side, side, radius)
        },

        BuiltinIcon("stack", "Stack", .system) { pen, _ in
            pen.rrect(6.4, 3.4, 11.2, 4.8, 1.4)
            pen.rrect(4.8, 9.6, 14.4, 4.8, 1.4)
            pen.rrect(3.2, 15.8, 17.6, 4.8, 1.4)
        },

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

        BuiltinIcon("bell", "Notifications", .system) { pen, _ in
            // Sloped shoulders into a narrow crown. Control points at a shared height give a
            // broad flat top, and a bell with a flat top is a cloche.
            pen.curve { path in
                path.move(to: NSPoint(x: 6.0, y: 16.4))
                path.curve(to: NSPoint(x: 12, y: 4.4),
                           controlPoint1: NSPoint(x: 6.2, y: 9.4), controlPoint2: NSPoint(x: 8.4, y: 4.4))
                path.curve(to: NSPoint(x: 18.0, y: 16.4),
                           controlPoint1: NSPoint(x: 15.6, y: 4.4), controlPoint2: NSPoint(x: 17.8, y: 9.4))
                path.close()
            }
            pen.with(width: 1.7).line(4.8, 16.4, 19.2, 16.4)
            pen.disc(12, 18.8, 1.3)
        },

        BuiltinIcon("moon", "Dark Mode", .system) { pen, _ in
            pen.arc(14, 14, 7.6, from: 40, to: 200)
            pen.arc(14, 14, 7.6, from: 200, to: 40)
        },
    ]

    // MARK: - Finance (5)

    static let finance: [BuiltinIcon] = [
        BuiltinIcon("creditCard", "Credit Card", .finance) { pen, _ in
            pen.rrect(2.8, 5.5, 18.4, 13, 2.4)
            pen.fillRRect(4.8, 8.8, 6, 4.2, 0.9)
            pen.line(13.5, 9.3, 19.6, 9.3)
            pen.line(13.5, 12.5, 18, 12.5)
            pen.line(13.5, 15.7, 16, 15.7)
        },

        BuiltinIcon("wallet", "Wallet", .finance) { pen, _ in
            pen.rrect(3, 7.5, 18, 10, 2.6)
            pen.line(3, 11.5, 21, 11.5)
            pen.fillRRect(13.5, 13, 6.5, 6.2, 1.4)
        },

        BuiltinIcon("chart", "Chart", .finance) { pen, _ in
            pen.line(3.5, 20.5, 20.5, 20.5)
            pen.fillRRect(5.5, 14.5, 3.4, 6, 0.6)
            pen.fillRRect(10.2, 10, 3.4, 10.5, 0.6)
            pen.fillRRect(14.9, 6, 3.4, 14.5, 0.6)
        },

        BuiltinIcon("dollar", "Currency", .finance) { pen, _ in
            pen.circle(12, 12, 8.4)
            pen.line(12, 4.8, 12, 19.2)
            pen.poly([(14.8, 7.2), (9.2, 7.2), (9.2, 9.4), (13.2, 10.6), (14.8, 12.4), (14.8, 14.8), (9.2, 14.8)])
        },

        BuiltinIcon("pieChart", "Pie Chart", .finance) { pen, _ in
            pen.circle(12, 12, 8.2)
            pen.line(12, 12, 12, 3.8)
            pen.line(12, 12, 19, 9.5)
            pen.line(12, 12, 6.6, 17.6)
        },
    ]

    // MARK: - Travel (4)

    static let travel: [BuiltinIcon] = [
        BuiltinIcon("airplane", "Airplane", .travel) { pen, _ in
            pen.poly([(4.5, 17.5), (12, 5.5), (19.5, 17.5)], closed: true)
            pen.line(12, 5.5, 12, 17.5)
        },

        BuiltinIcon("location", "Location", .travel) { pen, _ in
            pen.curve({ path in
                path.move(to: NSPoint(x: 12, y: 21))
                path.curve(to: NSPoint(x: 5, y: 10),
                           controlPoint1: NSPoint(x: 12, y: 14), controlPoint2: NSPoint(x: 5, y: 13))
                path.curve(to: NSPoint(x: 12, y: 4.5),
                           controlPoint1: NSPoint(x: 5, y: 7), controlPoint2: NSPoint(x: 9, y: 4.5))
                path.curve(to: NSPoint(x: 19, y: 10),
                           controlPoint1: NSPoint(x: 15, y: 4.5), controlPoint2: NSPoint(x: 19, y: 7))
                path.curve(to: NSPoint(x: 12, y: 21),
                           controlPoint1: NSPoint(x: 19, y: 13), controlPoint2: NSPoint(x: 12, y: 14))
            }, fill: true)
            pen.punchDisc(12, 10, 2.6)
        },

        BuiltinIcon("car", "Car", .travel) { pen, _ in
            pen.rrect(3, 10.5, 18, 7, 2.8)
            pen.rrect(6, 5.5, 11.5, 7, 2.6)
            pen.circle(7.2, 18, 2.4)
            pen.circle(16.8, 18, 2.4)
        },

        BuiltinIcon("mapPin", "Map Pin", .travel) { pen, _ in
            pen.curve { path in
                path.move(to: NSPoint(x: 12, y: 20.8))
                path.curve(to: NSPoint(x: 5.5, y: 10.5),
                           controlPoint1: NSPoint(x: 12, y: 14.5), controlPoint2: NSPoint(x: 5.5, y: 13))
                path.curve(to: NSPoint(x: 12, y: 5.5),
                           controlPoint1: NSPoint(x: 5.5, y: 8), controlPoint2: NSPoint(x: 9.5, y: 5.5))
                path.curve(to: NSPoint(x: 18.5, y: 10.5),
                           controlPoint1: NSPoint(x: 14.5, y: 5.5), controlPoint2: NSPoint(x: 18.5, y: 8))
                path.curve(to: NSPoint(x: 12, y: 20.8),
                           controlPoint1: NSPoint(x: 18.5, y: 13), controlPoint2: NSPoint(x: 12, y: 14.5))
            }
            pen.disc(12, 10.5, 2.2)
        },
    ]

    // MARK: - Home & Utilities (5)

    static let home: [BuiltinIcon] = [
        BuiltinIcon("homeIcon", "House", .home) { pen, _ in
            pen.poly([(12, 3.8), (3.5, 10.8), (20.5, 10.8)], closed: true)
            pen.rrect(5.5, 10.8, 13, 9.5, 1.4)
            pen.fillRRect(9.5, 15, 5, 5.3, 0.8)
        },

        BuiltinIcon("wifi", "Wi-Fi", .home) { pen, _ in
            pen.arc(12, 12, 8.5, from: 280, to: 80)
            pen.arc(12, 12, 5.6, from: 285, to: 75)
            pen.arc(12, 12, 2.8, from: 295, to: 65)
            pen.disc(12, 19, 1.3)
        },

        BuiltinIcon("battery", "Battery", .home) { pen, _ in
            pen.rrect(4, 7, 15, 10, 2.2)
            pen.fillRRect(19, 9.5, 2.2, 5, 0.8)
            pen.fillRRect(6, 9, 6, 6, 1)
        },

        BuiltinIcon("shield", "Shield", .home) { pen, _ in
            pen.poly([(12, 3.2), (20.6, 7), (20.6, 14), (12, 20.8), (3.4, 14), (3.4, 7)], closed: true)
        },

        BuiltinIcon("sun", "Sun", .home) { pen, _ in
            pen.circle(12, 12, 4.6)
            let rays = pen.with(width: 1.5)
            let nRays = 8
            for i in 0..<nRays {
                let angle = Double(i) * 2 * .pi / Double(nRays)
                rays.line(12 + cos(angle) * 5.5, 12 + sin(angle) * 5.5,
                          12 + cos(angle) * 8.2, 12 + sin(angle) * 8.2)
            }
        },
    ]

    // MARK: - Social (4)

    static let social: [BuiltinIcon] = [
        BuiltinIcon("person", "Person", .social) { pen, _ in
            pen.circle(12, 7.5, 3.4)
            pen.curve { path in
                path.move(to: NSPoint(x: 4, y: 21))
                path.curve(to: NSPoint(x: 20, y: 21),
                           controlPoint1: NSPoint(x: 4, y: 11.5), controlPoint2: NSPoint(x: 20, y: 11.5))
            }
        },

        BuiltinIcon("heart", "Heart", .social) { pen, _ in
            pen.curve { path in
                path.move(to: NSPoint(x: 12, y: 19.6))
                path.curve(to: NSPoint(x: 4.5, y: 11.5),
                           controlPoint1: NSPoint(x: 7.5, y: 16.8), controlPoint2: NSPoint(x: 4.5, y: 14.8))
                path.curve(to: NSPoint(x: 12, y: 7.5),
                           controlPoint1: NSPoint(x: 4.5, y: 8), controlPoint2: NSPoint(x: 9.5, y: 6.5))
                path.curve(to: NSPoint(x: 19.5, y: 11.5),
                           controlPoint1: NSPoint(x: 14.5, y: 6.5), controlPoint2: NSPoint(x: 19.5, y: 8))
                path.curve(to: NSPoint(x: 12, y: 19.6),
                           controlPoint1: NSPoint(x: 19.5, y: 14.8), controlPoint2: NSPoint(x: 16.5, y: 16.8))
            }
        },

        BuiltinIcon("star", "Star", .social) { pen, _ in
            let n = 5
            let outerR = 8.2
            let innerR = 3.8
            var points: [(Double, Double)] = []
            for i in 0..<(n * 2) {
                let r = i % 2 == 0 ? outerR : innerR
                let angle = (Double(i) * .pi / Double(n)) - .pi / 2
                points.append((12 + cos(angle) * r, 12 + sin(angle) * r))
            }
            pen.poly(points, closed: true)
        },

        BuiltinIcon("share", "Share", .social) { pen, _ in
            pen.circle(5.5, 14.5, 2.3)
            pen.circle(18.5, 7.5, 2.3)
            pen.circle(18.5, 17, 2.3)
            pen.line(7.6, 13.5, 16.4, 8.4)
            pen.line(7.8, 15.2, 16.6, 16.2)
        },
    ]
}
