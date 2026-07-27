import AppKit
import Observation

/// Tracks which bundle identifiers currently have a running process.
///
/// The naive approach — polling `NSWorkspace.runningApplications` on a timer — is exactly the
/// kind of thing that makes a "lightweight utility" show up in Activity Monitor. Instead we
/// hold a set that is seeded once at launch and then kept current by two workspace
/// notifications. Idle cost is zero; the app wakes only when some application on the system
/// actually starts or stops.
///
/// Only the identifiers MenuDock is displaying are tracked, so a busy system launching
/// unrelated processes does not churn observers.
@Observable
final class RunningAppsMonitor {
    /// Bundle identifiers with at least one running instance, restricted to `trackedIdentifiers`.
    private(set) var runningIdentifiers: Set<String> = []

    @ObservationIgnored private var trackedIdentifiers: Set<String> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter

        // `Notification` is not `Sendable`, so the identifier is extracted inside the
        // (nonisolated) observer block and only a `String` crosses onto the main actor.
        // Passing the notification itself would be a data-race diagnostic under Swift 6.
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let identifier = Self.bundleIdentifier(from: note) else { return }
            MainActor.assumeIsolated { self?.handle(identifier: identifier, launched: true) }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let identifier = Self.bundleIdentifier(from: note) else { return }
            MainActor.assumeIsolated { self?.handle(identifier: identifier, launched: false) }
        })
    }

    /// `isolated` so it may touch main-actor state; a plain `deinit` on a main-actor type is
    /// itself nonisolated and cannot read `observers`.
    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    private nonisolated static func bundleIdentifier(from notification: Notification) -> String? {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier
    }

    /// Narrows tracking to the identifiers currently on the menu bar and re-seeds state.
    /// Called whenever the configuration changes.
    func track(_ identifiers: Set<String>) {
        guard identifiers != trackedIdentifiers else { return }
        trackedIdentifiers = identifiers
        reseed()
    }

    func isRunning(_ bundleIdentifier: String) -> Bool {
        runningIdentifiers.contains(bundleIdentifier)
    }

    /// Full rescan. Used on launch and whenever the tracked set changes — cheap enough at
    /// these cadences (a single array walk over ~100 processes), and it guarantees we cannot
    /// drift out of sync with reality if a notification is ever missed.
    private func reseed() {
        let live = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        runningIdentifiers = live.intersection(trackedIdentifiers)
    }

    private func handle(identifier: String, launched: Bool) {
        guard trackedIdentifiers.contains(identifier) else { return }

        if launched {
            runningIdentifiers.insert(identifier)
        } else {
            // A second instance may still be alive, so confirm rather than assuming.
            if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
                runningIdentifiers.remove(identifier)
            }
        }
    }
}
