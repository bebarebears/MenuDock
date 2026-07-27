import AppKit

/// The object graph, assembled once at launch.
///
/// Explicit construction rather than singletons: every service here touches global system
/// state (the menu bar, the filesystem, the running-app list), and being able to build a
/// second environment pointed at a temporary directory is what makes any of it testable.
@MainActor
final class AppEnvironment {
    let store: ConfigurationStore
    let icons: IconLibrary
    let running: RunningAppsMonitor
    let animator: IconAnimator
    let installedApps: InstalledAppsIndex

    init(
        store: ConfigurationStore = ConfigurationStore(),
        icons: IconLibrary = IconLibrary(),
        running: RunningAppsMonitor = RunningAppsMonitor(),
        animator: IconAnimator = IconAnimator(),
        installedApps: InstalledAppsIndex = InstalledAppsIndex()
    ) {
        self.store = store
        self.icons = icons
        self.running = running
        self.animator = animator
        self.installedApps = installedApps
    }
}
