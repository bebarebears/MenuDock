import AppKit

/// Answers one question for everything in MenuDock that runs on a timer: **is there a menu bar
/// anyone could be looking at right now?**
///
/// Three conditions make the answer no, and they are genuinely different events that a naive
/// implementation catches only one of:
///
/// - The **screens are asleep.** The obvious one.
/// - The **session is inactive** — fast user switching. Another account's menu bar is on the
///   display; ours is not, and it may not come back for hours.
/// - The **screen is locked.** `screensDidSleep` does not cover this: the display stays lit
///   showing the login window, so without it a timer runs all afternoon behind a lock screen.
///
/// Low Power Mode is tracked here too. It is not about visibility, but it arrives through the
/// same kind of notification and every timer in the app wants to react to it, so keeping the
/// observer in one place beats having each component wire up its own.
///
/// This is deliberately a shared service rather than logic duplicated per timer: it was written
/// twice before ``MetricsMonitor`` existed, and two copies of a rule that only pays off in states
/// that are awkward to reproduce is exactly the kind of thing that silently drifts.
@MainActor
final class DisplayActivityMonitor {

    /// True when the menu bar is on a screen someone could be looking at.
    private(set) var isDisplayActive = true

    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var screensAsleep = false
    private var sessionInactive = false
    private var screenLocked = false

    private var listeners: [UUID: () -> Void] = [:]

    /// Kept per notification centre, because each token may only be removed from the centre it
    /// came from.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter

        observe(workspace, NSWorkspace.screensDidSleepNotification, .screensAsleep(true))
        observe(workspace, NSWorkspace.screensDidWakeNotification, .screensAsleep(false))
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive(true))
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive(false))

        observe(.default, NSNotification.Name.NSProcessInfoPowerStateDidChange, .powerStateChanged)

        observeDistributed("com.apple.screenIsLocked", .screenLocked(true))
        observeDistributed("com.apple.screenIsUnlocked", .screenLocked(false))
    }

    isolated deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    // MARK: - Listeners

    /// Registers a callback fired whenever ``isDisplayActive`` or ``isLowPowerMode`` changes.
    ///
    /// Listeners are notified only on a genuine transition, not on every notification: the
    /// workspace posts sleep and wake events in pairs, and re-deciding twice would tear a timer
    /// down and rebuild it for nothing.
    func addListener(_ id: UUID, _ handler: @escaping () -> Void) {
        listeners[id] = handler
    }

    func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    // MARK: - Observation plumbing

    /// What a notification does to this monitor.
    ///
    /// A value rather than a closure because the observer block is `@Sendable` and runs outside
    /// the main actor: a closure that assigned to `screensAsleep` would be a data race the
    /// compiler is right to reject. Sending an enum across and switching on it inside the
    /// main-actor hop keeps every mutation where it belongs.
    private enum Effect: Sendable {
        case screensAsleep(Bool)
        case sessionInactive(Bool)
        case screenLocked(Bool)
        case powerStateChanged
    }

    private func apply(_ effect: Effect) {
        let wasActive = isDisplayActive
        let wasLowPower = isLowPowerMode

        switch effect {
        case .screensAsleep(let value): screensAsleep = value
        case .sessionInactive(let value): sessionInactive = value
        case .screenLocked(let value): screenLocked = value
        case .powerStateChanged: isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }

        isDisplayActive = !screensAsleep && !sessionInactive && !screenLocked

        guard isDisplayActive != wasActive || isLowPowerMode != wasLowPower else { return }
        for listener in listeners.values { listener() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ effect: Effect) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(effect) }
        }
        observers.append((center, token))
    }

    private func observeDistributed(_ name: String, _ effect: Effect) {
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(effect) }
        })
    }
}
