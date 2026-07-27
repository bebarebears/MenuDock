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
