import AppKit
import Observation

/// Drives every animated menu bar icon from a single shared timer.
///
/// ## Why one timer, and why it is nearly free
///
/// The naive design gives each animated status item its own timer and redraws its glyph on
/// every tick. That is how a "lightweight utility" ends up visible in Activity Monitor. The cost
/// here is kept near zero by refusing to do work on four separate axes:
///
/// 1. **One timer for all items**, started only when something is actually animating and
///    invalidated the moment nothing is.
/// 2. **Frames are quantised and cached.** ``BuiltinIconCatalog/frameCount`` phases per loop
///    means each frame is drawn at most once, ever; steady-state animation is a dictionary
///    lookup plus an `NSImage` assignment.
/// 3. **Nothing runs when nothing can be seen.** The timer stops when the screens sleep, when
///    the session is switched away or the screen is locked — all three via
///    ``DisplayActivityMonitor`` — and when every animated item is occluded, which is what
///    happens the moment a fullscreen app hides the menu bar.
/// 4. **Less runs when the battery is doing the paying.** Low Power Mode halves the frame rate.
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
    /// assignment. Since the loops are 2.2–4.5s of eased, low-amplitude motion, 12fps is
    /// visually identical and proportionally cheaper. Subscribers additionally skip ticks
    /// where the quantised frame has not changed.
    private static let baseFrameRate: Double = 12

    /// Low Power Mode is the user saying "spend less". Halving the rate halves the recompositing
    /// that animation costs, and 6fps on eased motion this slow reads as slightly softer rather
    /// than choppy.
    private static let lowPowerFrameRate: Double = 6

    /// True when animated icons should actually move.
    private(set) var isAnimating = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var subscribers: [UUID: (TimeInterval) -> Void] = [:]
    /// Items whose status item is currently on screen. Absence means occluded, not unknown —
    /// see ``setVisible(_:isVisible:)``.
    @ObservationIgnored private var visibleSubscribers: Set<UUID> = []
    /// Screen sleep, fast user switching, lock state and Low Power Mode, shared with
    /// ``MetricsMonitor``.
    @ObservationIgnored private let display: DisplayActivityMonitor
    @ObservationIgnored private let displayListenerID = UUID()
    /// Kept per notification centre, because each token may only be removed from the centre it
    /// came from.
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The rate the live timer was created at, so a power-state change only rebuilds it when the
    /// rate actually differs.
    @ObservationIgnored private var timerFrameRate: Double = 0

    /// User preference. Combined with Reduce Motion to decide whether the timer may run.
    var animationEnabled = true {
        didSet { updateTimer() }
    }

    var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var lowPowerModeEnabled: Bool {
        display.isLowPowerMode
    }

    private var frameRate: Double {
        lowPowerModeEnabled ? Self.lowPowerFrameRate : Self.baseFrameRate
    }

    /// Why animation is currently off, for the settings UI to explain rather than leave the
    /// user wondering why their animated icon is a still frame.
    var suppressionReason: String? {
        if reduceMotionEnabled { return "Paused because Reduce Motion is on in System Settings." }
        if !animationEnabled { return "Animation is turned off in General settings." }
        return nil
    }

    /// Shown in settings so the halved frame rate reads as deliberate rather than as jank.
    var isThrottled: Bool {
        lowPowerModeEnabled && animationEnabled && !reduceMotionEnabled
    }

    init(display: DisplayActivityMonitor) {
        self.display = display

        // Screen sleep, user switching, lock and power state all arrive through the shared
        // monitor; only Reduce Motion is this class's own business.
        observe(NSWorkspace.shared.notificationCenter,
                NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)

        display.addListener(displayListenerID) { [weak self] in
            self?.updateTimer()
        }
    }

    isolated deinit {
        timer?.invalidate()
        display.removeListener(displayListenerID)
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    // MARK: - Observation plumbing

    /// Re-decides whether the timer should run when `name` is posted.
    ///
    /// The observer block is `@Sendable` and runs outside the main actor, so it hops before
    /// touching anything here — which is also why it carries no payload: everything this class
    /// reacts to is re-read from its source inside ``shouldRun``.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTimer() }
        }
        observers.append((center, token))
    }

    // MARK: - Subscription

    /// Registers a per-frame callback. Called by any status item whose icon animates.
    ///
    /// The tick carries the timestamp it was fired at so every subscriber derives its frame from
    /// one clock reading, rather than each calling `Date` and landing on marginally different
    /// phases of the same loop.
    func subscribe(_ id: UUID, tick: @escaping (TimeInterval) -> Void) {
        subscribers[id] = tick
        // Assume visible until told otherwise; a subscriber that never reports would otherwise
        // never animate.
        visibleSubscribers.insert(id)
        updateTimer()
    }

    func unsubscribe(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        visibleSubscribers.remove(id)
        updateTimer()
    }

    /// Reports whether a subscriber's status item is actually on screen.
    ///
    /// This is the difference between an idle MenuDock costing nothing and costing a few percent
    /// of a core forever: while a fullscreen app hides the menu bar there is no icon to see, and
    /// redrawing one is pure waste.
    func setVisible(_ id: UUID, isVisible: Bool) {
        guard subscribers[id] != nil else { return }
        let changed = isVisible
            ? visibleSubscribers.insert(id).inserted
            : visibleSubscribers.remove(id) != nil
        guard changed else { return }
        updateTimer()
    }

    // MARK: - Timer

    private var shouldRun: Bool {
        !visibleSubscribers.isEmpty
            && animationEnabled
            && !reduceMotionEnabled
            && display.isDisplayActive
    }

    private func updateTimer() {
        let wanted = shouldRun

        // Already running at the right rate — nothing to do.
        if wanted, timer != nil, timerFrameRate == frameRate {
            isAnimating = true
            return
        }

        timer?.invalidate()
        timer = nil

        if wanted {
            let rate = frameRate
            let timer = Timer(timeInterval: 1.0 / rate, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // `.common` keeps icons animating while a menu is open or a window is being
            // dragged; the default mode would freeze them exactly when they are being watched.
            //
            // A generous tolerance lets the system coalesce this timer with other work instead
            // of waking the CPU on its own schedule — the single cheapest thing available to a
            // repeating timer, and invisible at these frame rates.
            timer.tolerance = 1.0 / rate * 0.35
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            timerFrameRate = rate
        } else {
            timerFrameRate = 0
            // Settle every icon on its rest frame rather than freezing mid-motion.
            let now = Date.timeIntervalSinceReferenceDate
            for tick in subscribers.values { tick(now) }
        }

        isAnimating = wanted
    }

    private func tick() {
        // One clock reading for every subscriber, and none of the per-item `Date` calls the
        // subscribers used to make for themselves.
        let now = Date.timeIntervalSinceReferenceDate
        for tick in subscribers.values { tick(now) }
    }
}
