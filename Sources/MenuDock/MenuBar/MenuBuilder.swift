import AppKit

/// Builds the `NSMenu` shown for a menu bar entry.
///
/// Menus are constructed on demand rather than cached, because their contents depend on
/// live state — whether the app is running decides if Quit and Hide appear at all. Building
/// a fresh menu on each open costs microseconds and removes any chance of offering "Quit"
/// for an app that exited a second ago.
struct MenuBuilder {
    let icons: IconLibrary
    let running: RunningAppsMonitor
    var openSettings: () -> Void
    var removeItem: (DockItem.ID) -> Void
    /// The profiles that exist and which is active, read fresh each time a menu is built — like
    /// everything else here, so a profile created a second ago is offered a second later.
    var profiles: () -> (all: [Profile], active: Profile.ID?) = { ([], nil) }
    var activateProfile: (Profile.ID?) -> Void = { _ in }

    // MARK: - Application items

    /// Right-click menu for a single-app entry. Left-click never reaches here: it launches.
    func contextMenu(for entry: AppEntry, itemID: DockItem.ID) -> NSMenu {
        let menu = NSMenu()
        let app = entry.app
        let isRunning = running.isRunning(app.bundleIdentifier)

        menu.addHeader(entry.displayTitle)

        menu.addAction(isRunning ? "Bring to Front" : "Open") {
            AppLauncher.open(app)
        }
        menu.addAction("Open New Instance") {
            AppLauncher.openNewInstance(app)
        }.asAlternate()

        if isRunning {
            menu.addItem(.separator())
            menu.addAction("Hide") { AppLauncher.hide(app) }
            menu.addAction("Quit") { AppLauncher.quit(app) }
            menu.addAction("Force Quit") { AppLauncher.quit(app, force: true) }.asAlternate()
        }

        menu.addItem(.separator())
        menu.addAction("Show in Finder") { AppLauncher.revealInFinder(app) }

        appendManagementSection(to: menu, itemID: itemID, removeTitle: "Remove from Menu Bar")
        return menu
    }

    // MARK: - Group items

    /// Left-click menu for a group: the expanding "folder" of apps.
    func groupMenu(for group: GroupEntry, itemID: DockItem.ID) -> NSMenu {
        let menu = NSMenu()
        menu.addHeader(group.name)

        if group.members.isEmpty {
            menu.addPlaceholder("No apps in this group")
        }

        for member in group.members {
            let app = member.app
            let isRunning = running.isRunning(app.bundleIdentifier)

            // Menu rows use a fixed 16pt icon regardless of the user's menu bar icon size —
            // this is a list, and it should match system menu metrics rather than the bar.
            let image = icons.image(for: member.icon, app: app, size: 16)

            let row = menu.addAction(member.displayTitle, image: image) {
                AppLauncher.open(app)
            }
            // A trailing bullet marks running apps: the Dock's dot has nowhere to live in a
            // text row, and `state = .on` would draw a checkmark that reads as "selected".
            if isRunning {
                row.attributedTitle = runningRowTitle(member.displayTitle)
            }
            row.submenu = memberSubmenu(for: member, isRunning: isRunning)
        }

        if group.members.contains(where: { !running.isRunning($0.app.bundleIdentifier) }) {
            menu.addItem(.separator())
            menu.addAction("Open All") {
                for member in group.members { AppLauncher.open(member.app) }
            }
        }

        appendManagementSection(to: menu, itemID: itemID, removeTitle: "Remove Group from Menu Bar")
        return menu
    }

    /// Right-click menu for a group icon — management only, so a mis-click never launches
    /// eight apps at once.
    func contextMenu(for group: GroupEntry, itemID: DockItem.ID) -> NSMenu {
        let menu = NSMenu()
        menu.addHeader(group.name)

        menu.addAction("Open All Apps") {
            for member in group.members { AppLauncher.open(member.app) }
        }

        let stillRunning = group.members.filter { running.isRunning($0.app.bundleIdentifier) }
        if !stillRunning.isEmpty {
            menu.addAction("Quit All Running Apps") {
                for member in stillRunning { AppLauncher.quit(member.app) }
            }
        }

        appendManagementSection(to: menu, itemID: itemID, removeTitle: "Remove Group from Menu Bar")
        return menu
    }

    // MARK: - Activity items

    /// The menu for an Activity item: every gauge's current reading spelled out in full, then a
    /// way through to the app that shows the rest.
    ///
    /// The strip in the menu bar is deliberately terse — four characters for a rate, no units —
    /// because that is what fits. This is where the terseness gets paid back: `11.9 MB/s` rather
    /// than `11.9M`, and the metric's real name rather than a one-letter caption.
    ///
    /// The reading rows stay **live** while the menu is open; see
    /// ``updateActivityReadings(in:value:)`` for how, and why the rows are laid out on a tab stop.
    func activityMenu(
        for entry: ActivityEntry,
        itemID: DockItem.ID,
        readings: [ActivityMetric: Double?],
        details: [ActivityMetric: String] = [:],
        processes: [SystemMetrics.ProcessSampler.Entry] = []
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addHeader(entry.effectiveTitle)

        if entry.gauges.isEmpty {
            menu.addPlaceholder("No metrics in this item")
        }

        // Deduplicated, because two gauges may draw the same metric two different ways and one
        // reading listed twice reads as a bug.
        var listed: [ActivityMetric] = []
        for gauge in entry.gauges where !listed.contains(gauge.metric) {
            listed.append(gauge.metric)
        }

        let tab = Self.readingTabLocation(for: listed)
        for metric in listed {
            let item = NSMenuItem(title: metric.displayName, action: nil, keyEquivalent: "")
            item.isEnabled = false
            // Tags the row as a live reading. Safe alongside `addAction`'s use of the same
            // property to anchor a closure: these rows are disabled and have no action, so the
            // two meanings can never land on the same item.
            item.representedObject = metric
            item.attributedTitle = Self.readingTitle(
                metric: metric,
                value: readings[metric].flatMap { $0 },
                tab: tab
            )
            menu.addItem(item)

            // A second, quieter line for the metrics whose number does not say enough on its
            // own: what the battery is actually doing, how many gigabytes "18% free" is. Only
            // battery and free space have one, so most menus gain no rows at all.
            if let detail = details[metric] {
                let note = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
                note.isEnabled = false
                note.tag = Self.detailRowTag
                note.representedObject = metric
                note.attributedTitle = Self.detailTitle(detail)
                menu.addItem(note)
            }
        }

        if entry.showsTopProcesses {
            appendProcessSection(to: menu, processes: processes)
        }

        menu.addItem(.separator())
        menu.addAction("Open Activity Monitor") {
            AppLauncher.openActivityMonitor()
        }

        appendManagementSection(to: menu, itemID: itemID, removeTitle: "Remove from Menu Bar")
        return menu
    }

    /// Rewrites the live rows of an already-open Activity menu.
    ///
    /// `StatusItemController.present(_:)` blocks on `performClick` for the whole tracking
    /// session, so a menu built once would show the readings frozen at the instant it was
    /// clicked — while the icon beside it carried on updating, which is exactly how you notice.
    /// The metrics timer runs in the `.common` run loop mode and therefore keeps firing during
    /// tracking, so the fix is to let that tick reach in here and rewrite the titles; AppKit
    /// redraws an open menu when its items' titles change.
    static func updateActivityReadings(
        in menu: NSMenu,
        value: (ActivityMetric) -> Double?,
        detail: (ActivityMetric) -> String? = { _ in nil },
        processes: [SystemMetrics.ProcessSampler.Entry] = []
    ) {
        let metrics = menu.items.compactMap { item -> ActivityMetric? in
            guard item.tag != detailRowTag else { return nil }
            return item.representedObject as? ActivityMetric
        }

        if !metrics.isEmpty {
            let tab = readingTabLocation(for: metrics)
            for item in menu.items {
                guard let metric = item.representedObject as? ActivityMetric else { continue }
                if item.tag == detailRowTag {
                    // A detail that has gone away — a battery unplugged mid-menu — leaves the row
                    // in place with its text blanked rather than removing it, because mutating a
                    // menu's item list while it is being tracked resizes it under the cursor.
                    item.attributedTitle = detailTitle(detail(metric) ?? " ")
                } else {
                    item.attributedTitle = readingTitle(metric: metric, value: value(metric),
                                                        tab: tab)
                }
            }
        }

        updateProcessRows(in: menu, processes: processes)
    }

    // MARK: Top processes

    /// Marks the quieter second line under a reading.
    private static let detailRowTag = 0x4D_44_01
    /// Base tag for the process rows; the row's index is added to it.
    private static let processRowTag = 0x4D_44_10

    /// Adds the "what is using the CPU" section, as a fixed number of rows.
    ///
    /// **Fixed** matters more than it looks. A menu sizes itself to its widest row when it opens
    /// and AppKit will happily resize it afterwards, so a section that grew from one row to three
    /// as the first samples arrived — or whose rows widened when a longer process name took the
    /// lead — would jump under the cursor a second after the user clicked. So the rows are all
    /// created up front, the value is pinned to a tab stop, and the name is truncated to a fixed
    /// budget rather than being allowed to set the menu's width.
    private func appendProcessSection(
        to menu: NSMenu,
        processes: [SystemMetrics.ProcessSampler.Entry]
    ) {
        menu.addItem(.separator())
        menu.addHeader("Using the most CPU")

        for index in 0..<MetricsMonitor.topProcessCount {
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.isEnabled = false
            row.tag = Self.processRowTag + index
            row.attributedTitle = Self.processTitle(
                processes.indices.contains(index) ? processes[index] : nil,
                isFirstRow: index == 0
            )
            menu.addItem(row)
        }
    }

    private static func updateProcessRows(
        in menu: NSMenu,
        processes: [SystemMetrics.ProcessSampler.Entry]
    ) {
        for item in menu.items {
            let index = item.tag - processRowTag
            guard index >= 0, index < MetricsMonitor.topProcessCount else { continue }
            item.attributedTitle = processTitle(
                processes.indices.contains(index) ? processes[index] : nil,
                isFirstRow: index == 0
            )
        }
    }

    /// One process row: a truncated name, then its share of a core on a tab stop.
    ///
    /// The share is expressed the way Activity Monitor expresses it — 100% is one core, so a
    /// process saturating four of them reads as 400%. That is unintuitive the first time and
    /// correct every time after, and inventing a different convention for the same number in a
    /// menu that offers to open Activity Monitor would be worse.
    private static func processTitle(
        _ entry: SystemMetrics.ProcessSampler.Entry?,
        isFirstRow: Bool
    ) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: processTabLocation)]

        guard let entry else {
            // Only the first row explains itself. Three identical "Measuring…" lines would read
            // as three things happening rather than one.
            let text = isFirstRow ? "Measuring…" : " "
            return NSAttributedString(string: text, attributes: [
                .font: font,
                .paragraphStyle: style,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }

        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let result = NSMutableAttributedString(
            string: "\(truncate(entry.name, to: processNameBudget, font: font))\t",
            attributes: [.font: font, .paragraphStyle: style]
        )
        result.append(NSAttributedString(
            string: String(format: "%.1f%%", entry.share * 100),
            attributes: [
                .font: digits,
                .paragraphStyle: style,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return result
    }

    /// Points allowed for a process name before it is truncated.
    private static let processNameBudget: CGFloat = 190

    private static var processTabLocation: CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let widest = "9999.9%".size(withAttributes: [.font: digits]).width
        return (processNameBudget + 24 + widest).rounded(.up)
    }

    /// Shortens a name to fit a pixel budget, with an ellipsis.
    ///
    /// By measurement rather than by character count, because "Google Chrome Helper (Renderer)"
    /// and "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW" are the same length and nothing like the same width.
    private static func truncate(_ name: String, to budget: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard name.size(withAttributes: attributes).width > budget else { return name }

        var trimmed = name
        while !trimmed.isEmpty,
              (trimmed + "…").size(withAttributes: attributes).width > budget {
            trimmed.removeLast()
        }
        return trimmed + "…"
    }

    private static func detailTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// One reading row: the metric's name, then its value right-aligned on a tab stop.
    ///
    /// The tab stop is not decoration. A menu sizes itself to its widest row, so with plainly
    /// concatenated text a value going from `9.3%` to `19.3%` would widen the whole menu *under
    /// the cursor* once a second. Pinning the value column to a position computed from the
    /// widest string any of these metrics can produce makes the menu a fixed size for as long as
    /// it is open, and lines the numbers up as a column while it is at it.
    private static func readingTitle(
        metric: ActivityMetric,
        value: Double?,
        tab: CGFloat
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tab)]

        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(
            string: "\(metric.displayName)\t",
            attributes: [.font: font, .paragraphStyle: style]
        )
        result.append(NSAttributedString(
            string: value.map { metric.verboseString($0) } ?? "—",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
                .paragraphStyle: style,
                .foregroundColor: value == nil
                    ? NSColor.tertiaryLabelColor
                    : NSColor.labelColor,
            ]
        ))
        return result
    }

    /// Where the value column ends: the widest metric name here, plus a gap, plus the widest
    /// value any of them could ever print.
    private static func readingTabLocation(for metrics: [ActivityMetric]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)

        let widestName = metrics
            .map { $0.displayName.size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // Not the current values: the point is a column that cannot move, so it is measured
        // against the longest string `verboseString` is capable of returning, for every unit —
        // including the level unit, whose values are words rather than numbers.
        let widestValue = (["100.0%", "999.99 GB/s", "999.9 W"]
            + ThermalLevel.allCases.map(\.displayName))
            .map { $0.size(withAttributes: [.font: digits]).width }
            .max() ?? 0

        return (widestName + 26 + widestValue).rounded(.up)
    }

    // MARK: - Clipboard items

    /// Right-click menu for the Clipboard icon. Left-click never reaches here: it drops the
    /// history panel, which is the item's whole purpose.
    ///
    /// Deliberately management only. The history itself lives in the panel — a menu cannot show
    /// thumbnails, cannot be searched, and cannot be cycled with the shortcut — so duplicating a
    /// few rows here would create a second, worse way to reach the same thing.
    func contextMenu(
        for entry: ClipboardEntry,
        itemID: DockItem.ID,
        history: ClipboardHistoryStore,
        clearHistory: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addHeader(entry.effectiveTitle)

        let count = history.items.count
        if count == 0 {
            menu.addPlaceholder("Nothing copied yet")
        } else {
            menu.addPlaceholder(count == 1 ? "1 item stored" : "\(count) items stored")
        }

        menu.addItem(.separator())
        menu.addAction("Clear History…") {
            // Confirmed, because it is the one irreversible thing this item can do and the menu
            // row sits one slip away from "Remove from Menu Bar".
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = count == 1
                ? "Delete the 1 item in your clipboard history?"
                : "Delete all \(count) items in your clipboard history?"
            alert.informativeText = "This cannot be undone. The Clipboard item stays in your "
                + "menu bar and carries on recording."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            // Escape and Return both land on Cancel unless the user goes looking for Delete.
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            clearHistory()
        }
        .isEnabled = count > 0

        appendManagementSection(to: menu, itemID: itemID, removeTitle: "Remove from Menu Bar")
        return menu
    }

    // MARK: - Folder items

    /// Left-click menu for a folder item holding several folders: one row per folder, so the
    /// user picks which window they want. Never shown for a single-folder item — that one opens
    /// straight away, which is the whole point of putting it in the menu bar.
    func folderMenu(for entry: FolderEntry, itemID: DockItem.ID) -> NSMenu {
        let menu = NSMenu()
        menu.addHeader(entry.effectiveTitle)

        if entry.folders.isEmpty {
            menu.addPlaceholder("No folders in this item")
        }

        for folder in entry.folders {
            let row = menu.addAction(folder.name, image: folderRowIcon(folder)) {
                AppLauncher.openFolder(folder)
            }
            // Deliberately **no submenu** on these rows. AppKit never fires a menu item's action
            // when the item has a submenu — it opens the submenu instead — so attaching one here
            // would silently make every row in this menu do nothing on click. The per-folder
            // extras live in the right-click menu, where they are not competing with the one
            // action this menu exists to offer.
            //
            // A missing folder stays clickable: the alert explains what happened, which is more
            // useful than a greyed-out row the user cannot ask a question of.
            if folder.resolvedURL == nil {
                row.attributedTitle = missingRowTitle(folder.name)
            }
        }

        if entry.folders.count > 1 {
            menu.addItem(.separator())
            menu.addAction("Open All Folders") {
                for folder in entry.folders { AppLauncher.openFolder(folder) }
            }
        }

        appendManagementSection(to: menu, itemID: itemID, removeTitle: "Remove from Menu Bar")
        return menu
    }

    /// Right-click menu for a folder item.
    func contextMenu(for entry: FolderEntry, itemID: DockItem.ID) -> NSMenu {
        let menu = NSMenu()
        menu.addHeader(entry.effectiveTitle)

        if let folder = entry.folders.first, entry.folders.count == 1 {
            menu.addAction("Open in Finder") { AppLauncher.openFolder(folder) }
            menu.addAction("Open in New Window") { AppLauncher.openFolderInNewWindow(folder) }
                .asAlternate()
            menu.addAction("Reveal in Enclosing Folder") { AppLauncher.revealFolder(folder) }
            menu.addItem(.separator())
            menu.addAction("Copy Path") { AppLauncher.copyPath(folder) }
        } else if !entry.folders.isEmpty {
            menu.addAction("Open All Folders") {
                for folder in entry.folders { AppLauncher.openFolder(folder) }
            }
            menu.addItem(.separator())
            // Submenus are fine *here*: this is the management menu, so a row is a heading for
            // the actions beneath it rather than an action of its own.
            for folder in entry.folders {
                let row = menu.addAction(folder.name, image: folderRowIcon(folder)) {
                    AppLauncher.openFolder(folder)
                }
                row.submenu = folderSubmenu(for: folder)
            }
        } else {
            menu.addPlaceholder("No folders in this item")
        }

        appendManagementSection(to: menu, itemID: itemID, removeTitle: "Remove from Menu Bar")
        return menu
    }

    private func folderSubmenu(for folder: FolderReference) -> NSMenu {
        let menu = NSMenu()
        menu.addAction("Open in Finder") { AppLauncher.openFolder(folder) }
        menu.addAction("Open in New Window") { AppLauncher.openFolderInNewWindow(folder) }
        menu.addAction("Reveal in Enclosing Folder") { AppLauncher.revealFolder(folder) }
        menu.addItem(.separator())
        menu.addAction("Copy Path") { AppLauncher.copyPath(folder) }
        return menu
    }

    /// Finder's own icon for the folder, which carries the tag colour and any custom icon the
    /// user set — far more recognisable in a list than a generic folder glyph repeated N times.
    private func folderRowIcon(_ folder: FolderReference) -> NSImage {
        let image: NSImage
        if let url = folder.resolvedURL {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "questionmark.folder",
                            accessibilityDescription: nil) ?? NSImage()
        }
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    private func missingRowTitle(_ title: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title)
        result.append(NSAttributedString(
            string: "  (missing)",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        ))
        return result
    }

    private func memberSubmenu(for member: AppEntry, isRunning: Bool) -> NSMenu {
        let menu = NSMenu()
        let app = member.app

        menu.addAction(isRunning ? "Bring to Front" : "Open") { AppLauncher.open(app) }
        if isRunning {
            menu.addAction("Hide") { AppLauncher.hide(app) }
            menu.addAction("Quit") { AppLauncher.quit(app) }
        }
        menu.addItem(.separator())
        menu.addAction("Show in Finder") { AppLauncher.revealInFinder(app) }
        return menu
    }

    private func runningRowTitle(_ title: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title)
        result.append(NSAttributedString(
            string: "  •",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        ))
        return result
    }

    // MARK: - Shared

    /// The footer every menu shares. Kept in one place so Settings and Quit never drift
    /// between an app item's menu and a group's.
    private func appendManagementSection(to menu: NSMenu, itemID: DockItem.ID, removeTitle: String) {
        menu.addItem(.separator())
        menu.addAction(removeTitle) { removeItem(itemID) }
        appendProfileSection(to: menu)
        menu.addItem(.separator())
        menu.addAction("MenuDock Settings…", keyEquivalent: ",", modifiers: .command) {
            openSettings()
        }
        menu.addAction("Quit MenuDock", keyEquivalent: "q", modifiers: .command) {
            NSApp.terminate(nil)
        }
    }

    /// The profile switcher, on every item's menu.
    ///
    /// On *every* item rather than on one designated switcher, because there is no designated
    /// item — a menu bar may hold nothing but apps, and the whole point of a profile is that the
    /// item you would have put the switcher on might be the one it hides. Absent entirely until a
    /// profile exists, so nobody who has not asked for the feature ever sees it.
    ///
    /// A submenu rather than inline rows: the management section is already four rows long, and
    /// six profiles would make the ordinary "remove this / open settings" menu twice its size.
    private func appendProfileSection(to menu: NSMenu) {
        let (all, active) = profiles()
        guard !all.isEmpty else { return }

        menu.addItem(.separator())

        let submenu = NSMenu()
        let everything = submenu.addAction("All Items") { activateProfile(nil) }
        everything.state = active == nil ? .on : .off

        submenu.addItem(.separator())
        for profile in all {
            let row = submenu.addAction(profile.effectiveName,
                                        image: NSImage(systemSymbolName: profile.symbolName,
                                                       accessibilityDescription: nil)) {
                activateProfile(profile.id)
            }
            row.state = profile.id == active ? .on : .off
        }

        let title = all.first { $0.id == active }?.effectiveName ?? "All Items"
        let row = NSMenuItem(title: "Profile: \(title)", action: nil, keyEquivalent: "")
        row.submenu = submenu
        menu.addItem(row)
    }
}
