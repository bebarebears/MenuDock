import Foundation
import Observation

/// Samples the system counters behind every Activity item, from one timer, for exactly the
/// metrics that are on screen.
///
/// ## The four things that keep this near-free
///
/// 1. **One timer for every Activity item**, created only when something is subscribed and
///    invalidated the moment nothing is. A MenuDock with no Activity item does not sample, does
///    not schedule, and does not allocate a sampler.
/// 2. **Demand-gated samplers.** The union of every subscriber's metrics decides which samplers
///    exist at all. Show CPU and nothing else and the GPU, network and disk code never runs —
///    which matters, because those three are 90% of the per-tick cost (see ``SystemMetrics``).
///    Removing the last gauge that wanted a metric releases its sampler and its IOKit handles.
/// 3. **Nothing runs when nothing can be seen.** Shared with animated icons through
///    ``DisplayActivityMonitor``: screens asleep, session switched away, screen locked. Items
///    additionally report their own occlusion, which is what happens the moment a fullscreen app
///    hides the menu bar.
/// 4. **Less runs when the battery is paying.** Low Power Mode doubles the interval.
///
/// ## Why this is not `@Observable` state the menu bar reads
///
/// ``StatusItemCoordinator`` reconciles the whole menu bar whenever anything it observes
/// changes. If samples landed in observable properties it read, every tick would rebuild the
/// item list — a full diff, once a second, forever. Subscribers therefore get an explicit
/// callback and pull what they need. `generation` *is* observable, for the settings preview,
/// and is deliberately the only thing that is.
@MainActor
@Observable
final class MetricsMonitor {

    /// Incremented once per completed sample. The settings preview observes this to redraw; the
    /// menu bar does not observe anything here and is driven by ``Subscription/tick`` instead.
    private(set) var generation = 0

    /// How many samples of history are retained per metric.
    ///
    /// Sized for the widest graph a gauge can draw rather than for a duration: at the default
    /// cadence this is a minute, but the number that matters is that no sparkline is ever asked
    /// for more points than it has pixels to plot them in.
    static let historyLength = 60

    @ObservationIgnored private var subscribers: [UUID: Subscription] = [:]
    @ObservationIgnored private var history: [ActivityMetric: [Double]] = [:]
    /// The sentence some metrics have to add to their number — what the battery is doing, how
    /// many gigabytes "18% free" actually is. Kept beside the history rather than folded into it
    /// because it is text, it is not plottable, and only the menu and the tooltip ever read it.
    @ObservationIgnored private var details: [ActivityMetric: String] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var timerInterval: Double = 0

    @ObservationIgnored private let display: DisplayActivityMonitor
    @ObservationIgnored private let displayListenerID = UUID()

    // Samplers are created on demand and released when the last gauge wanting them goes away.
    @ObservationIgnored private var cpu: SystemMetrics.CPUSampler?
    @ObservationIgnored private var memory: SystemMetrics.MemorySampler?
    @ObservationIgnored private var gpu: SystemMetrics.GPUSampler?
    @ObservationIgnored private var power: SystemMetrics.PowerSampler?
    @ObservationIgnored private var network: SystemMetrics.NetworkSampler?
    @ObservationIgnored private var disk: SystemMetrics.DiskSampler?
    @ObservationIgnored private var battery: SystemMetrics.BatterySampler?
    @ObservationIgnored private var thermal: SystemMetrics.ThermalSampler?
    @ObservationIgnored private var diskSpace: SystemMetrics.DiskSpaceSampler?

    /// Alive only while an Activity menu that wants it is open. See
    /// ``setProcessSamplingEnabled(_:onUpdate:)``.
    @ObservationIgnored private var processes: SystemMetrics.ProcessSampler?
    @ObservationIgnored private var processUpdate: (() -> Void)?
    @ObservationIgnored private(set) var topProcesses: [SystemMetrics.ProcessSampler.Entry] = []

    /// How many processes the menu lists. Three is enough to answer "what is eating my battery"
    /// and short enough that the menu does not become a worse Activity Monitor.
    static let topProcessCount = 3

    private struct Subscription {
        var metrics: Set<ActivityMetric>
        var interval: RefreshInterval
        var isVisible: Bool
        /// Absolute time this subscriber was last told to redraw, so a slow item can share a
        /// fast timer without redrawing on every tick.
        var lastDelivery: TimeInterval
        var tick: () -> Void
    }

    init(display: DisplayActivityMonitor) {
        self.display = display
        display.addListener(displayListenerID) { [weak self] in
            self?.updateTimer()
        }
    }

    isolated deinit {
        timer?.invalidate()
        display.removeListener(displayListenerID)
    }

    // MARK: - Subscription

    /// Registers an item's demand for a set of metrics and a redraw callback.
    ///
    /// Called again with the same `id` whenever the item is edited, which is how a gauge being
    /// added or removed changes what gets sampled.
    func subscribe(
        _ id: UUID,
        metrics: Set<ActivityMetric>,
        interval: RefreshInterval,
        tick: @escaping () -> Void
    ) {
        let wasVisible = subscribers[id]?.isVisible ?? true
        subscribers[id] = Subscription(
            metrics: metrics,
            interval: interval,
            isVisible: wasVisible,
            // Zero rather than "now", so a newly added item draws on the very next tick instead
            // of waiting out a full interval showing nothing.
            lastDelivery: 0,
            tick: tick
        )
        updateSamplers()
        updateTimer()
    }

    func unsubscribe(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        updateSamplers()
        updateTimer()
    }

    /// Reports whether a subscriber's status item is actually on screen. See ``IconAnimator`` for
    /// why this is worth the bookkeeping.
    func setVisible(_ id: UUID, isVisible: Bool) {
        guard var subscription = subscribers[id], subscription.isVisible != isVisible else { return }
        subscription.isVisible = isVisible
        subscribers[id] = subscription
        updateTimer()
    }

    // MARK: - Reading

    /// Recent values for a metric, oldest first, in the metric's own units — 0…1 for the
    /// percentages, bytes per second for the rates.
    ///
    /// Raw rather than normalised on purpose: a graph scales itself against the peak of the very
    /// window it is drawing, which it can only do if it can see the window.
    func series(for metric: ActivityMetric) -> [Double] {
        history[metric] ?? []
    }

    /// The most recent value, or `nil` if the metric has not produced one yet.
    ///
    /// Rate metrics are `nil` for their first tick by construction — a rate needs two readings —
    /// so gauges have to be able to draw an "no value yet" state rather than assuming zero.
    func latest(for metric: ActivityMetric) -> Double? {
        history[metric]?.last
    }

    /// The sentence that goes beside a metric's number, for the metrics that have one: what the
    /// battery is doing, how much disk space "18% free" is in gigabytes. `nil` for the rest.
    func detail(for metric: ActivityMetric) -> String? {
        details[metric]
    }

    // MARK: - Processes

    /// Starts or stops sampling per-process CPU.
    ///
    /// Called by ``StatusItemController`` around the presentation of an Activity menu, and by
    /// nothing else. The asymmetry with every other metric here is deliberate and is explained in
    /// ``SystemMetrics/ProcessSampler``: this one costs a syscall per process on the machine, so
    /// it runs for the few seconds a menu is open rather than once a second forever.
    ///
    /// Switching it on takes the baseline immediately rather than waiting for the next tick, so
    /// the first real reading arrives one interval after the menu opens instead of two.
    ///
    /// - Parameter onUpdate: called after each pass that produced a new list. Deliberately its
    ///   own callback rather than riding on ``Subscription/tick``: an Activity item with no
    ///   gauges has no subscription at all, and its menu would sit on "Measuring…" forever.
    func setProcessSamplingEnabled(_ enabled: Bool, onUpdate: (() -> Void)? = nil) {
        guard enabled != (processes != nil) else { return }
        guard enabled else {
            processes = nil
            processUpdate = nil
            topProcesses = []
            updateTimer()
            return
        }
        let sampler = SystemMetrics.ProcessSampler()
        _ = sampler.sample(limit: Self.topProcessCount)
        processes = sampler
        processUpdate = onUpdate
        updateTimer()
    }

    /// True while the process sampler is alive, so the menu can say "Measuring…" rather than
    /// showing an empty section for the one interval before the first delta exists.
    var isSamplingProcesses: Bool { processes != nil }

    // MARK: - Samplers

    private var demandedMetrics: Set<ActivityMetric> {
        subscribers.values.reduce(into: Set<ActivityMetric>()) { $0.formUnion($1.metrics) }
    }

    /// Creates samplers that have become needed and releases ones that have not.
    ///
    /// Dropping a metric also drops its history, which is the honest behaviour: when a gauge is
    /// removed and re-added ten minutes later, the samples from before the gap describe a
    /// machine that no longer exists, and splicing them onto the new ones would draw a graph
    /// whose x-axis silently skips ten minutes.
    private func updateSamplers() {
        let demanded = demandedMetrics

        cpu = demanded.contains(.cpu) ? (cpu ?? SystemMetrics.CPUSampler()) : nil
        memory = demanded.contains(.memory) ? (memory ?? SystemMetrics.MemorySampler()) : nil
        gpu = demanded.contains(.gpu) ? (gpu ?? SystemMetrics.GPUSampler()) : nil
        power = demanded.contains(.power) ? (power ?? SystemMetrics.PowerSampler()) : nil
        battery = demanded.contains(.battery) ? (battery ?? SystemMetrics.BatterySampler()) : nil
        thermal = demanded.contains(.thermal) ? (thermal ?? SystemMetrics.ThermalSampler()) : nil
        diskSpace = demanded.contains(.diskFree)
            ? (diskSpace ?? SystemMetrics.DiskSpaceSampler())
            : nil

        let wantsNetwork = demanded.contains(.networkDown) || demanded.contains(.networkUp)
        network = wantsNetwork ? (network ?? SystemMetrics.NetworkSampler()) : nil

        let wantsDisk = demanded.contains(.diskRead) || demanded.contains(.diskWrite)
        disk = wantsDisk ? (disk ?? SystemMetrics.DiskSampler()) : nil

        for metric in history.keys where !demanded.contains(metric) {
            history.removeValue(forKey: metric)
            details.removeValue(forKey: metric)
        }
    }

    // MARK: - Timer

    private var visibleSubscribers: [Subscription] {
        subscribers.values.filter(\.isVisible)
    }

    /// The cadence the timer runs at: the fastest any visible item asked for, doubled when Low
    /// Power Mode is on.
    ///
    /// Items slower than this are not sampled less — they are *redrawn* less, in
    /// ``deliver(at:)``. Sampling at the fastest demanded rate and letting a 5-second gauge read
    /// the same shared history gives it a graph at full resolution for free.
    private var wantedInterval: Double? {
        guard display.isDisplayActive else { return nil }
        let subscribed = visibleSubscribers.map(\.interval.seconds).min()
        // An open menu listing processes needs a clock even when nothing is subscribed: an
        // Activity item with no gauges makes no demand for metrics, and its process list would
        // otherwise never get a second sample to compute a rate from. One second, because the
        // list is only up for as long as someone is looking at it.
        let wanted = processes != nil ? min(subscribed ?? 1, 1) : subscribed
        guard let wanted else { return nil }
        return wanted * (display.isLowPowerMode ? 2 : 1)
    }

    private func updateTimer() {
        guard let interval = wantedInterval else {
            timer?.invalidate()
            timer = nil
            timerInterval = 0
            return
        }

        // Already running at the right cadence — leave it alone rather than restarting it, which
        // would reset its phase and drop the partial interval already elapsed.
        if timer != nil, timerInterval == interval { return }

        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        // `.common` keeps gauges live while a menu is open or a window is being dragged. A
        // generous tolerance lets the system coalesce this wake-up with work it was going to do
        // anyway, which on a laptop is the difference between a timer that costs power and one
        // that mostly rides along with something else.
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = interval

        // The first sample of every rate metric only establishes a baseline, so take it
        // immediately instead of showing an empty gauge until the second tick.
        fire()
    }

    // MARK: - Sampling

    private func fire() {
        sample()
        generation &+= 1
        deliver(at: Date.timeIntervalSinceReferenceDate)
    }

    private func sample() {
        let demanded = demandedMetrics

        if demanded.contains(.cpu), var sampler = cpu {
            let value = sampler.sample()
            cpu = sampler
            record(value, for: .cpu)
        }
        if demanded.contains(.memory) {
            record(memory?.sample(), for: .memory)
        }
        if demanded.contains(.gpu) {
            record(gpu?.sample(), for: .gpu)
        }
        if demanded.contains(.power) {
            record(power?.sample(), for: .power)
        }
        if demanded.contains(.networkDown) || demanded.contains(.networkUp) {
            var sampler = network
            let reading = sampler?.sample()
            network = sampler
            record(reading?.down, for: .networkDown)
            record(reading?.up, for: .networkUp)
        }
        if demanded.contains(.diskRead) || demanded.contains(.diskWrite) {
            let reading = disk?.sample()
            record(reading?.read, for: .diskRead)
            record(reading?.written, for: .diskWrite)
        }
        if demanded.contains(.battery), let reading = battery?.sample() {
            record(reading.value, for: .battery)
            details[.battery] = reading.detail
        }
        if demanded.contains(.thermal) {
            record(thermal?.sample(), for: .thermal)
        }
        if demanded.contains(.diskFree), let reading = diskSpace?.sample() {
            record(reading.value, for: .diskFree)
            details[.diskFree] = reading.detail
        }

        // Off the demand-gating path entirely: nothing subscribes to this, an open menu switches
        // it on directly, and it is the one sampler expensive enough that its absence matters.
        if let processes, let entries = processes.sample(limit: Self.topProcessCount) {
            topProcesses = entries
            processUpdate?()
        }
    }

    /// Appends one reading, discarding the oldest once the window is full.
    ///
    /// A `nil` reading is dropped rather than stored as zero. The distinction is visible: a rate
    /// sampler returns `nil` for its first tick and whenever a reading cannot be trusted, and
    /// writing those in as zeroes would draw troughs the machine never had.
    private func record(_ value: Double?, for metric: ActivityMetric) {
        guard let value, value.isFinite else { return }
        var series = history[metric] ?? []
        series.append(value)
        if series.count > Self.historyLength {
            series.removeFirst(series.count - Self.historyLength)
        }
        history[metric] = series
    }

    /// Tells each visible subscriber whose own interval has elapsed to redraw.
    private func deliver(at now: TimeInterval) {
        for (id, subscription) in subscribers where subscription.isVisible {
            // A small slack, because a timer with tolerance fires slightly early as often as
            // late; without it a 2-second item sharing a 1-second timer would skip every other
            // delivery and update at 3 seconds.
            guard now - subscription.lastDelivery >= subscription.interval.seconds * 0.9 else {
                continue
            }
            subscribers[id]?.lastDelivery = now
            subscription.tick()
        }
    }
}
