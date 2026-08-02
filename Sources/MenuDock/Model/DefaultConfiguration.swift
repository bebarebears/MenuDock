import AppKit

/// What a brand-new install puts in the menu bar.
///
/// ## Why a fresh install is not empty
///
/// MenuDock has no Dock icon and no window. An empty first launch therefore shows the user
/// *nothing at all* — the app is running, it is working perfectly, and it is indistinguishable
/// from an app that failed to start. Even once Settings is found, an empty list cannot answer the
/// question that actually matters, which is not "how do I add an app" but "what can this thing
/// be". Five of these six items are kinds the user would otherwise have to find in the + menu to
/// discover: a folder, a group, the clipboard history, and a live gauge are not what "menu bar
/// launcher" leads anyone to expect.
///
/// So the defaults are a worked example. One of each interesting kind, arranged in the order they
/// are worth meeting, all of it removable in one click.
///
/// ## Everything here is checked against the actual machine
///
/// Every app is resolved through LaunchServices before it is written, and anything missing is
/// simply left out — a Mac without Mail gets a group without Mail, not a group with a dead entry
/// and a warning triangle. That check is the reason this is built at runtime rather than shipped
/// as a JSON file in the bundle, and it is worth the code: the first thing a new user sees cannot
/// be a broken icon.
nonisolated enum DefaultConfiguration {

    /// The stock apps offered as a starter group, in menu order.
    ///
    /// Chosen for being on every Mac and for being things people genuinely launch, which rules out
    /// both the utilities nobody opens on purpose and anything a user may have deleted. Finder
    /// leads because a group whose first entry is always launchable makes the group's *behaviour*
    /// obvious on the first click.
    private static let groupBundleIDs = [
        "com.apple.finder",     // Finder
        "com.apple.mail",       // Mail
        "com.apple.iCal",       // Calendar
        "com.apple.Notes",      // Notes
        "com.apple.MobileSMS",  // Messages
    ]

    /// macOS 26's Apps launcher. Absent on 14 and 15, which is what ``allApps`` falls back for.
    private static let appsLauncherBundleID = "com.apple.apps.launcher"
    private static let safariBundleID = "com.apple.Safari"
    private static let systemSettingsBundleID = "com.apple.systempreferences"

    static func make() -> Configuration {
        var configuration = Configuration()
        configuration.items = [
            allApps,
            clipboard,
            starterGroup,
            application(safariBundleID),
            application(systemSettingsBundleID, named: "Settings"),
            activity,
        ].compactMap { $0 }
        return configuration
    }

    // MARK: - Items

    /// One click to everything installed.
    ///
    /// macOS 26 has an app for exactly this, so that is what is used where it exists. On 14 and 15
    /// there is no such app and the closest equivalent is `/Applications` itself, opened in Finder
    /// — a different gesture reaching the same place, which is better than an item the older half
    /// of the supported range does not get at all.
    ///
    /// Both wear the `grid` glyph rather than an app icon or a folder, because what the item means
    /// is "all of them" in either case.
    private static var allApps: DockItem? {
        if let launcher = reference(forBundleID: appsLauncherBundleID) {
            return DockItem(kind: .application(AppEntry(app: launcher,
                                                        icon: .builtin(id: "grid"))))
        }

        let url = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard var reference = FolderReference(folderURL: url) else { return nil }
        // `displayName` gives "Applications"; the shorter word is what a menu bar tooltip wants.
        reference.name = "Apps"
        return DockItem(kind: .folder(FolderEntry(name: "Apps",
                                                  icon: .builtin(id: "grid"),
                                                  folders: [reference])))
    }

    private static var clipboard: DockItem {
        DockItem(kind: .clipboard(ClipboardEntry()))
    }

    /// The stock apps that exist on this Mac, behind one icon.
    ///
    /// Dropped entirely rather than shipped empty if none of them resolve — an icon that expands
    /// to nothing is worse than no icon.
    private static var starterGroup: DockItem? {
        let members = groupBundleIDs.compactMap(reference(forBundleID:)).map { AppEntry(app: $0) }
        guard !members.isEmpty else { return nil }
        return DockItem(kind: .group(GroupEntry(name: "Essentials",
                                                icon: .builtin(id: "stack"),
                                                members: members)))
    }

    private static func application(_ bundleID: String, named name: String? = nil) -> DockItem? {
        guard let reference = reference(forBundleID: bundleID) else { return nil }
        return DockItem(kind: .application(AppEntry(app: reference, customTitle: name)))
    }

    /// CPU and memory as load-coloured rings, captioned in full.
    ///
    /// Rings rather than the graph an added-by-hand gauge would default to: a ring is legible at
    /// a glance without any history to interpret, and paired with a caption it is self-explaining
    /// in a way a bare sparkline is not. Colour is on so the item does something visible the first
    /// time the machine gets busy, which is the whole point of putting it there.
    private static var activity: DockItem {
        DockItem(kind: .activity(ActivityEntry(gauges: [
            ActivityGauge(metric: .cpu, style: .ring, label: .full, coloring: .byLoad),
            ActivityGauge(metric: .memory, style: .ring, label: .full, coloring: .byLoad),
        ])))
    }

    // MARK: - Resolution

    /// A reference to an installed app, or `nil` if this Mac does not have it.
    private static func reference(forBundleID bundleID: String) -> AppReference? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return AppReference(applicationURL: url)
    }
}
