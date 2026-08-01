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
    let display: DisplayActivityMonitor
    let animator: IconAnimator
    let metrics: MetricsMonitor
    let installedApps: InstalledAppsIndex

    /// `display` is constructed first and injected into the two timer-driven services, so both
    /// answer "can anyone see the menu bar right now?" from the same observers rather than
    /// keeping separate copies of the same three booleans.
    init(
        store: ConfigurationStore = ConfigurationStore(),
        icons: IconLibrary = IconLibrary(),
        running: RunningAppsMonitor = RunningAppsMonitor(),
        display: DisplayActivityMonitor = DisplayActivityMonitor(),
        animator: IconAnimator? = nil,
        metrics: MetricsMonitor? = nil,
        installedApps: InstalledAppsIndex = InstalledAppsIndex()
    ) {
        self.store = store
        self.icons = icons
        self.running = running
        self.display = display
        self.animator = animator ?? IconAnimator(display: display)
        self.metrics = metrics ?? MetricsMonitor(display: display)
        self.installedApps = installedApps
    }
}
