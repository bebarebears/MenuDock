import AppKit
import Observation

/// Drives every animated menu bar icon from a single shared timer.
///
/// ## Why one timer, and why it is nearly free
///
/// The naive design gives each animated status item its own timer and redraws its glyph on
/// every tick. That is how a "lightweight utility" ends up visible in Activity Monitor. Three
/// things keep the cost near zero here:
///
/// 1. **One timer for all items**, started only when something is actually animating and
///    invalidated the moment nothing is.
/// 2. **Frames are quantised and cached.** ``BuiltinIconCatalog/frameCount`` phases per loop
///    means each frame is drawn at most once, ever; steady-state animation is a dictionary
///    lookup plus an `NSImage` assignment.
/// 3. **Nothing runs when nothing can be seen** — the timer stops when the screens sleep and
///    restarts on wake.
///
/// Animation is also suppressed entirely when the system's Reduce Motion accessibility setting
/// is on. That setting exists because moving UI causes genuine discomfort for some people, and
/// a permanently-visible menu bar is the worst possible place to ignore it.
@MainActor
@Observable
final class IconAnimator {

    /// 12fps.
    ///
    /// Chosen by measurement, not taste: at 15fps a single animated icon cost ~2.9% CPU,
    /// essentially all of it AppKit recompositing the menu bar on each `button.image`
    /// assignment. Since the loops are 2.4–4.5s of eased, low-amplitude motion, 12fps is
    /// visually identical and proportionally cheaper. Subscribers additionally skip ticks
    /// where the quantised frame has not changed.
    private static let tickInterval: TimeInterval = 1.0 / 12.0

    /// True when animated icons should actually move.
    private(set) var isAnimating = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var subscribers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// User preference. Combined with Reduce Motion to decide whether the timer may run.
    var animationEnabled = true {
        didSet { updateTimer() }
    }

    var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Why animation is currently off, for the settings UI to explain rather than leave the
    /// user wondering why their animated icon is a still frame.
    var suppressionReason: String? {
        if reduceMotionEnabled { return "Paused because Reduce Motion is on in System Settings." }
        if !animationEnabled { return "Animation is turned off in General settings." }
        return nil
    }

    init() {
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTimer() }
        })

        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.updateTimer()
            }
        })

        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = false
                self?.updateTimer()
            }
        })
    }

    isolated deinit {
        timer?.invalidate()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers { workspace.removeObserver(observer) }
    }

    // MARK: - Subscription

    /// Registers a per-frame callback. Called by any status item whose icon animates.
    func subscribe(_ id: UUID, tick: @escaping () -> Void) {
        subscribers[id] = tick
        updateTimer()
    }

    func unsubscribe(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        updateTimer()
    }

    // MARK: - Timer

    private var shouldRun: Bool {
        !subscribers.isEmpty && animationEnabled && !reduceMotionEnabled && !screensAsleep
    }

    private func updateTimer() {
        guard shouldRun != (timer != nil) else {
            isAnimating = shouldRun
            return
        }

        if shouldRun {
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // `.common` keeps icons animating while a menu is open or a window is being
            // dragged; the default mode would freeze them exactly when they are being watched.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            // Settle every icon on its rest frame rather than freezing mid-motion.
            for tick in subscribers.values { tick() }
        }

        isAnimating = shouldRun
    }

    private func tick() {
        for tick in subscribers.values { tick() }
    }
}
