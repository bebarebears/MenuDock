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
    func activityMenu(
        for entry: ActivityEntry,
        itemID: DockItem.ID,
        readings: [ActivityMetric: Double?]
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addHeader(entry.effectiveTitle)

        if entry.gauges.isEmpty {
            menu.addPlaceholder("No metrics in this item")
        }

        // Deduplicated, because two gauges may draw the same metric two different ways and one
        // reading listed twice reads as a bug.
        var listed: Set<ActivityMetric> = []
        for gauge in entry.gauges where listed.insert(gauge.metric).inserted {
            let value = readings[gauge.metric].flatMap { $0 }
            let text = value.map { gauge.metric.verboseString($0) } ?? "—"
            menu.addPlaceholder("\(gauge.metric.displayName)   \(text)")
        }

        menu.addItem(.separator())
        menu.addAction("Open Activity Monitor") {
            AppLauncher.openActivityMonitor()
        }

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
        menu.addItem(.separator())
        menu.addAction("MenuDock Settings…", keyEquivalent: ",", modifiers: .command) {
            openSettings()
        }
        menu.addAction("Quit MenuDock", keyEquivalent: "q", modifiers: .command) {
            NSApp.terminate(nil)
        }
    }
}
