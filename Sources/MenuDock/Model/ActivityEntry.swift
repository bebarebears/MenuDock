import Foundation

/// Decodes a string-backed enum, falling back for an absent key **and** for a value this build
/// does not recognise.
///
/// `decodeIfPresent` only covers the first of those, which is a trap: it reads as tolerant and
/// still throws `dataCorrupted` on an unknown raw value. Since `Codable` propagates that failure
/// all the way up, one gauge naming a metric from a newer MenuDock would fail the decode of the
/// *entire* configuration and quarantine the user's whole menu bar. Caught by the codec tests,
/// which is the only way this surfaces short of shipping a new metric.
nonisolated extension KeyedDecodingContainer {
    func decodeTolerantly<T>(_ type: T.Type, forKey key: Key, fallback: T) throws -> T
    where T: RawRepresentable, T.RawValue == String {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return fallback }
        return T(rawValue: raw) ?? fallback
    }
}

/// The four states `ProcessInfo.thermalState` reports, as a gauge value.
///
/// Deliberately the system's own four-valued signal rather than a temperature in degrees. The
/// honest reason is that there is no unprivileged, documented way to read a die temperature on
/// Apple Silicon — the routes that exist are private SMC or IOHID sensor clients that break
/// between releases — and a number scraped from one of those would look far more authoritative
/// than it is. What `thermalState` reports is better suited to a menu bar anyway: it is not "how
/// hot is the chip" but "how much is the system holding back because of heat", which is the part
/// that explains why the machine feels slow.
///
/// Mapped onto 0…1 so bars, rings and graphs can draw it against a fixed ceiling like any
/// percentage — but printed as its *name*, because "67%" of thermal pressure means nothing.
nonisolated enum ThermalLevel: Double, CaseIterable, Sendable {
    case nominal = 0
    case fair = 0.34
    case serious = 0.67
    case critical = 1

    /// The nearest level to an arbitrary gauge value, so history samples round-trip back to a
    /// name even though they are stored as plain doubles alongside every other metric.
    init(value: Double) {
        self = Self.allCases.min {
            abs($0.rawValue - value) < abs($1.rawValue - value)
        } ?? .nominal
    }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var displayName: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    /// Four characters at most, for the menu bar. Abbreviations of the system's own vocabulary
    /// rather than invented temperature words — this is not a thermometer.
    var compactName: String {
        switch self {
        case .nominal: "OK"
        case .fair: "Fair"
        case .serious: "Sers"
        case .critical: "Crit"
        }
    }
}

/// Which system counter a gauge shows.
///
/// The raw values are written to the configuration file, so they are stable slugs — renaming one
/// orphans every user who picked it. Display names are free to change.
nonisolated enum ActivityMetric: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case cpu
    case gpu
    case power
    case memory
    case networkDown
    case networkUp
    case diskRead
    case diskWrite
    case battery
    case thermal
    case diskFree

    var id: String { rawValue }

    /// What a value of this metric means, which decides how it is formatted and scaled.
    nonisolated enum Unit: Sendable {
        /// Already 0…1, and 1 is a real ceiling — so gauges are an absolute 0–100%.
        case percentage
        /// Bytes per second. Unbounded, so gauges scale themselves against what they have seen.
        case bytesPerSecond
        /// Watts. Also unbounded in principle, and wildly different between an Air and a Mac
        /// Pro, so it scales adaptively too rather than against a guessed maximum.
        case watts
        /// A small set of named states mapped onto 0…1 — thermal pressure being the only one.
        ///
        /// It behaves like a percentage for scaling (1 is a real ceiling) and like nothing else
        /// for formatting: the number is meaningless and the *name* of the state is the reading,
        /// so `compactString` prints a word rather than a figure.
        case level
    }

    var unit: Unit {
        switch self {
        case .cpu, .gpu, .memory, .battery, .diskFree: .percentage
        case .power: .watts
        case .networkDown, .networkUp, .diskRead, .diskWrite: .bytesPerSecond
        case .thermal: .level
        }
    }

    var displayName: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .power: "Power"
        case .memory: "Memory"
        case .networkDown: "Network Download"
        case .networkUp: "Network Upload"
        case .diskRead: "Disk Read"
        case .diskWrite: "Disk Write"
        case .battery: "Battery"
        case .thermal: "Thermal Pressure"
        case .diskFree: "Disk Free"
        }
    }

    /// One line for the metric picker, saying what the number actually measures.
    ///
    /// Worth spelling out for exactly the metrics whose name is ambiguous: "Power" is the SoC and
    /// not the wall, "Memory" is Activity Monitor's used figure and not "not free", and "Battery"
    /// is a charge level rather than a draw.
    var summary: String {
        switch self {
        case .cpu: "Whole-machine utilisation"
        case .gpu: "Graphics utilisation"
        case .power: "SoC package draw, in watts"
        case .memory: "In use, as Activity Monitor counts it"
        case .networkDown: "Bytes per second in"
        case .networkUp: "Bytes per second out"
        case .diskRead: "Bytes per second off storage"
        case .diskWrite: "Bytes per second onto storage"
        case .battery: "Charge remaining"
        case .thermal: "How hard the system is throttling"
        case .diskFree: "Space left on the startup volume"
        }
    }

    /// The SF Symbol that stands for this metric in Settings. Never drawn in the menu bar — the
    /// gauges are, and they are drawn by ``ActivityRenderer``.
    var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "cpu.fill"
        case .power: "bolt"
        case .memory: "memorychip"
        case .networkDown: "arrow.down.circle"
        case .networkUp: "arrow.up.circle"
        case .diskRead: "internaldrive"
        case .diskWrite: "internaldrive.fill"
        case .battery: "battery.75percent"
        case .thermal: "thermometer.medium"
        case .diskFree: "externaldrive.badge.checkmark"
        }
    }

    /// One or two characters, for a menu bar where every point of width is contested.
    var shortLabel: String {
        switch self {
        case .cpu: "C"
        case .gpu: "G"
        case .power: "W"
        case .memory: "M"
        case .networkDown: "↓"
        case .networkUp: "↑"
        case .diskRead: "R"
        case .diskWrite: "W"
        case .battery: "B"
        case .thermal: "T"
        case .diskFree: "D"
        }
    }

    var fullLabel: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .power: "PWR"
        case .memory: "RAM"
        case .networkDown: "NET ↓"
        case .networkUp: "NET ↑"
        case .diskRead: "DISK R"
        case .diskWrite: "DISK W"
        case .battery: "BATT"
        case .thermal: "TEMP"
        case .diskFree: "FREE"
        }
    }

    /// Whether this metric needs an adaptive scale. Percentages and levels do not — both are
    /// already 0…1 against a real ceiling; everything else has no natural maximum to draw against.
    var isRate: Bool {
        switch unit {
        case .percentage, .level: false
        case .bytesPerSecond, .watts: true
        }
    }

    /// The smallest full-scale value a rate gauge will scale itself to, in bytes/second.
    ///
    /// Without a floor, an adaptive graph of an idle interface renders sensor noise at full
    /// height — a 2 KB/s keepalive becomes a mountain range, and the user learns to distrust the
    /// display. With one, quiet stays visibly quiet and the scale only opens up when something
    /// real happens. Disk gets a higher floor than the network because an SSD's idle chatter is
    /// larger and its interesting range is an order of magnitude further up.
    var scaleFloor: Double {
        switch self {
        case .cpu, .gpu, .memory, .battery, .diskFree, .thermal: 1
        // An idle Apple Silicon machine draws 1–2 W and a busy one twenty times that, so a floor
        // in the middle keeps quiet looking quiet without flattening ordinary work.
        case .power: 10
        case .networkDown, .networkUp: 1_000_000
        case .diskRead, .diskWrite: 8_000_000
        }
    }

    /// Compact form for the menu bar: `42%`, `1.2M`, `840K`, `21W`, `Fair`.
    func compactString(_ value: Double) -> String {
        switch unit {
        case .percentage: "\(Int((value * 100).rounded()))%"
        case .bytesPerSecond: Self.compactRate(value)
        case .watts: Self.scaled(max(value, 0), "W")
        case .level: ThermalLevel(value: value).compactName
        }
    }

    /// Full form for the click-through menu, where there is room to be unambiguous.
    func verboseString(_ value: Double) -> String {
        switch unit {
        case .percentage:
            String(format: "%.1f%%", value * 100)
        case .bytesPerSecond:
            Self.verboseRate(value)
        case .watts:
            // Two decimals below 10 W, because the interesting range for an idle machine is
            // fractions of a watt and `2 W` would throw all of it away.
            value < 10
                ? String(format: "%.2f W", max(value, 0))
                : String(format: "%.1f W", value)
        case .level:
            ThermalLevel(value: value).displayName
        }
    }

    /// Every string ``compactString(_:)`` can return at its widest, for measuring a cell that
    /// must not change size as the value moves.
    ///
    /// Menu bar text is drawn with monospaced digits and its cell is sized from *these* rather
    /// than from the current value, so a gauge never changes width as the number moves. A status
    /// item that breathes in and out once a second drags every icon to its left along with it,
    /// which is far more distracting than a little unused space.
    ///
    /// A list rather than one string because the level unit prints *words*, and words are not
    /// monospaced — `Fair` and `Crit` are the same four characters and not the same width, so the
    /// only honest answer is "measure all of them and take the widest". The numeric units each
    /// contribute exactly one entry, which is why ``compactString(_:)`` goes to the trouble of
    /// never emitting a fifth character: the reserved cell is only as wide as the worst case, so
    /// every character the format can theoretically produce is dead space in every gauge that
    /// never produces it.
    var widestCompactStrings: [String] {
        switch unit {
        case .percentage: ["100%"]
        case .bytesPerSecond: ["999M"]
        case .watts: ["999W"]
        case .level: ThermalLevel.allCases.map(\.compactName)
        }
    }

    /// Four characters, always.
    ///
    /// Rates span five orders of magnitude, and the natural formatting — one decimal place, a
    /// unit suffix — needs six characters at its widest (`999.9M`). Since every numeric gauge is
    /// sized for the worst case so it cannot jitter, those two extra characters would be a
    /// permanent hole in the menu bar for the sake of precision nobody reads at a glance.
    /// Dropping the decimal above 10 keeps four characters sufficient and loses nothing:
    /// `12.3M` and `12M` say the same thing from two feet away.
    private static func compactRate(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value < 1_000 { return "0" }
        if value < 1_000_000 { return "\(min(Int(value / 1_000), 999))K" }
        if value < 1_000_000_000 { return scaled(value / 1_000_000, "M") }
        return scaled(value / 1_000_000_000, "G")
    }

    /// One mantissa plus a unit, in at most four characters.
    ///
    /// The subtlety is that **the decision has to be made on the rounded number, not the raw
    /// one.** Choosing the format by magnitude first and rounding second means 9,999,999 B/s
    /// takes the one-decimal branch, rounds to `10.0M`, and prints five characters — overflowing
    /// a cell measured for four. The same trap sits at every unit boundary, so this rounds first
    /// and then asks whether the result still fits, and clamps at 999 for the far end where
    /// there is no larger unit to promote to.
    private static func scaled(_ value: Double, _ unit: String) -> String {
        let oneDecimal = (value * 10).rounded() / 10
        if oneDecimal < 10 { return String(format: "%.1f%@", oneDecimal, unit) }
        return "\(min(Int(value.rounded()), 999))\(unit)"
    }

    private static func verboseRate(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        switch value {
        case ..<1_000:
            return "\(Int(value)) B/s"
        case ..<1_000_000:
            return String(format: "%.1f KB/s", value / 1_000)
        case ..<1_000_000_000:
            return String(format: "%.1f MB/s", value / 1_000_000)
        default:
            return String(format: "%.2f GB/s", value / 1_000_000_000)
        }
    }
}

// MARK: - Severity

/// How worrying a reading is, in three bands: the green / amber / red a coloured gauge draws in.
///
/// Three rather than a continuous gradient because a menu bar gauge is read in peripheral vision,
/// at a glance, from an arm's length away. A smooth hue ramp asks the eye to judge *which* orange
/// it is looking at, which nobody does; three well-separated colours ask only "is it the bad one",
/// which everybody does without meaning to.
nonisolated enum GaugeSeverity: Sendable, Hashable, CaseIterable {
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Moderate"
        case .high: "High"
        }
    }
}

/// Where one metric's bands fall, and which end of its range is the bad one.
///
/// The thresholds are **in the metric's own units** — a fraction for the percentages, watts for
/// power, bytes per second for the rates — because that is the only way they can mean anything.
/// A single shared "70% is amber" rule would be wrong for every metric at once: 70% memory is a
/// perfectly ordinary Tuesday, 70% battery is nothing to report, and 70% of an adaptive network
/// scale is a number about the last minute rather than about the machine.
nonisolated struct MetricThresholds: Sendable, Hashable {
    /// At or beyond this, the reading is amber.
    var medium: Double
    /// At or beyond this, the reading is red.
    var high: Double
    /// True when *small* values are the worrying ones — battery and free disk space, where the
    /// gauge fills up as things get better rather than worse.
    var isInverted: Bool = false
}

nonisolated extension ActivityMetric {

    /// The bands this metric's colours are drawn from.
    ///
    /// Chosen per metric from what the number does on a healthy machine rather than from round
    /// figures. CPU sits under half most of the time, so half is where "busy" starts; memory
    /// idles far higher and only means anything near the top; an Apple Silicon SoC idles at 1–2 W
    /// and tops out near 25, so its amber sits where a core has genuinely woken up. The rate
    /// metrics are the least meaningful of the set — "fast" depends entirely on the link — so
    /// their bands are set where traffic is at least visibly *happening* rather than at any claim
    /// about capacity.
    var thresholds: MetricThresholds {
        switch self {
        case .cpu, .gpu:
            MetricThresholds(medium: 0.50, high: 0.85)
        case .memory:
            MetricThresholds(medium: 0.70, high: 0.90)
        case .power:
            MetricThresholds(medium: 8, high: 18)
        case .networkDown, .networkUp:
            MetricThresholds(medium: 2_000_000, high: 20_000_000)
        case .diskRead, .diskWrite:
            MetricThresholds(medium: 20_000_000, high: 200_000_000)
        case .thermal:
            // The system's own boundaries: anything above nominal is worth amber, and `serious`
            // is the state at which macOS is actively throttling.
            MetricThresholds(medium: ThermalLevel.fair.rawValue,
                             high: ThermalLevel.serious.rawValue)
        case .battery:
            // Inverted: 20% is the level macOS itself starts warning at, and 10% is where it
            // stops asking politely.
            MetricThresholds(medium: 0.20, high: 0.10, isInverted: true)
        case .diskFree:
            // Inverted, and generous — macOS needs several gigabytes of headroom for swap and
            // snapshots, and a volume under a tenth free is where things start failing oddly.
            MetricThresholds(medium: 0.20, high: 0.10, isInverted: true)
        }
    }

    /// Which band a reading falls in.
    func severity(for value: Double) -> GaugeSeverity {
        let bands = thresholds
        if bands.isInverted {
            if value <= bands.high { return .high }
            if value <= bands.medium { return .medium }
            return .low
        }
        if value >= bands.high { return .high }
        if value >= bands.medium { return .medium }
        return .low
    }

    /// Plain-language description of the bands, for the settings pane.
    ///
    /// Shown because "colour by load" is otherwise a switch whose behaviour the user can only
    /// learn by waiting for their machine to get busy.
    var thresholdSummary: String {
        let bands = thresholds
        let medium = verboseString(bands.medium)
        let high = verboseString(bands.high)
        return bands.isInverted
            ? "Amber below \(medium), red below \(high)."
            : "Amber from \(medium), red from \(high)."
    }
}

/// How one metric is drawn.
nonisolated enum GaugeStyle: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// A filled sparkline of recent history.
    case graph
    /// A vertical level meter showing the current value only.
    case bar
    /// A circular arc gauge showing the current value only.
    case ring
    /// The value as text.
    case number

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .graph: "Graph"
        case .bar: "Bar"
        case .ring: "Ring"
        case .number: "Number"
        }
    }

    /// The SF Symbol that stands for this style in Settings' picker, where four labelled segments
    /// would not fit beside everything else a gauge row carries.
    var symbolName: String {
        switch self {
        case .graph: "chart.xyaxis.line"
        case .bar: "chart.bar.fill"
        case .ring: "circle.dashed"
        case .number: "number"
        }
    }

    /// Whether this style draws the history window or only the latest sample. Drives how much
    /// history the monitor is asked to keep, and whether a redraw is needed when the value has
    /// not visibly changed.
    var usesHistory: Bool { self == .graph }
}

/// Whether a gauge takes the menu bar's colour or picks its own from the reading.
nonisolated enum GaugeColoring: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// The default, and what every gauge did before this existed: black-on-transparent, flagged
    /// as a template, tinted by the menu bar exactly like the clock and the Wi-Fi icon.
    case monochrome
    /// Green, amber or red, from the metric's own ``ActivityMetric/thresholds``.
    ///
    /// Note what this costs, because it is not nothing: a coloured gauge cannot be a template
    /// image, so the *whole item* stops being tinted by the menu bar and has to be redrawn by
    /// hand when the system appearance changes. See ``ActivityRenderer`` for how one coloured
    /// gauge changes the drawing mode of every gauge beside it.
    case byLoad

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monochrome: "Menu bar"
        case .byLoad: "By load"
        }
    }

    var summary: String {
        switch self {
        case .monochrome: "Tints with the menu bar, like every system item."
        case .byLoad: "Green when quiet, amber when busy, red when it matters."
        }
    }
}

/// Whether a gauge is captioned, and how heavily.
nonisolated enum GaugeLabel: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case none
    case short
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None"
        case .short: "Short"
        case .full: "Full"
        }
    }

    func text(for metric: ActivityMetric) -> String? {
        switch self {
        case .none: nil
        case .short: metric.shortLabel
        case .full: metric.fullLabel
        }
    }
}

/// One metric plus how to draw it. Several of these sit side by side inside a single menu bar
/// item, which sizes itself to hold them all.
nonisolated struct ActivityGauge: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var metric: ActivityMetric = .cpu
    var style: GaugeStyle = .graph
    var label: GaugeLabel = .short
    var coloring: GaugeColoring = .monochrome

    private enum CodingKeys: String, CodingKey { case id, metric, style, label, coloring }

    init(id: UUID = UUID(),
         metric: ActivityMetric = .cpu,
         style: GaugeStyle = .graph,
         label: GaugeLabel = .short,
         coloring: GaugeColoring = .monochrome) {
        self.id = id
        self.metric = metric
        self.style = style
        self.label = label
        self.coloring = coloring
    }

    /// The style this metric reads best as, used when a gauge is created rather than edited.
    ///
    /// A percentage or a level has a fixed 0–100 range that a graph plots meaningfully against;
    /// a rate or a wattage does not, and its actual figure is the useful part.
    static func defaultStyle(for metric: ActivityMetric) -> GaugeStyle {
        switch metric.unit {
        case .percentage: .graph
        case .level: .bar
        case .bytesPerSecond, .watts: .number
        }
    }

    /// Decoded tolerantly, and that includes **unknown enum cases**, not just absent keys.
    ///
    /// A plain `decode(ActivityMetric.self)` throws on a raw value it does not recognise, which
    /// would mean a config touched by a future MenuDock — one that has learned to show, say, a
    /// temperature — fails to decode *in its entirety* on this build, quarantining the user's
    /// whole setup because of one gauge. Falling back to the default keeps every other item
    /// intact, which is the outcome that matters.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        metric = try container.decodeTolerantly(ActivityMetric.self, forKey: .metric, fallback: .cpu)
        style = try container.decodeTolerantly(GaugeStyle.self, forKey: .style, fallback: .graph)
        label = try container.decodeTolerantly(GaugeLabel.self, forKey: .label, fallback: .short)
        coloring = try container.decodeTolerantly(GaugeColoring.self, forKey: .coloring,
                                                  fallback: .monochrome)
    }
}

/// How often an Activity item re-reads the system.
nonisolated enum RefreshInterval: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case second
    case twoSeconds
    case fiveSeconds

    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .second: 1
        case .twoSeconds: 2
        case .fiveSeconds: 5
        }
    }

    var displayName: String {
        switch self {
        case .second: "Every second"
        case .twoSeconds: "Every 2 seconds"
        case .fiveSeconds: "Every 5 seconds"
        }
    }
}

/// A live system-activity readout occupying one menu bar slot.
///
/// ## Why one item holds many gauges
///
/// The alternative — one menu bar item per metric — is the obvious model and it is worse in
/// every way that matters here. macOS gives each `NSStatusItem` its own padding, so four
/// separate items cost far more menu bar width than four gauges sharing one; they can be
/// separated by other apps' items, breaking the visual grouping; and each would need its own
/// timer subscription and its own status item to reconcile. Grouping them means the item can
/// lay all its gauges out on one canvas and size itself to exactly what they need — which is
/// what makes the width automatic rather than a number the user has to guess at.
nonisolated struct ActivityEntry: Codable, Hashable, Sendable {
    var name: String = "Activity"
    var gauges: [ActivityGauge] = ActivityEntry.defaultGauges
    var interval: RefreshInterval = .second

    /// Lists the busiest processes in the click-through menu.
    ///
    /// On by default, and safe to be, because it costs **nothing at all** until the menu is
    /// actually open: unlike every other reading here, this one is not sampled on the timer. It
    /// cannot be — answering "what is using the CPU" means a `proc_pid_rusage` call for every
    /// process on the machine, which is five hundred syscalls and an order of magnitude more
    /// expensive than all the other samplers put together. Paying that once a second, forever, to
    /// populate a menu that is open for four seconds a day would be exactly the kind of monitor
    /// this app was written not to be. So it is sampled while the menu is up and not otherwise —
    /// see ``MetricsMonitor/setProcessSamplingEnabled(_:)``.
    var showsTopProcesses: Bool = true

    /// What a freshly added Activity item shows.
    ///
    /// Two gauges rather than one, and two *different styles*: the pair immediately demonstrates
    /// both the things a user cannot discover from a single default — that an item holds several
    /// metrics, and that each picks its own presentation.
    static let defaultGauges: [ActivityGauge] = [
        ActivityGauge(metric: .cpu, style: .graph, label: .short),
        ActivityGauge(metric: .memory, style: .bar, label: .short)
    ]

    private enum CodingKeys: String, CodingKey { case name, gauges, interval, showsTopProcesses }

    init(name: String = "Activity",
         gauges: [ActivityGauge] = ActivityEntry.defaultGauges,
         interval: RefreshInterval = .second,
         showsTopProcesses: Bool = true) {
        self.name = name
        self.gauges = gauges
        self.interval = interval
        self.showsTopProcesses = showsTopProcesses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Activity"
        // An explicitly empty gauge list is a legitimate state the user can reach in Settings,
        // so it is preserved rather than being refilled with defaults on the next launch.
        gauges = try container.decodeIfPresent([ActivityGauge].self, forKey: .gauges) ?? []
        interval = try container.decodeTolerantly(RefreshInterval.self, forKey: .interval,
                                                  fallback: .second)
        showsTopProcesses = try container
            .decodeIfPresent(Bool.self, forKey: .showsTopProcesses) ?? true
    }

    /// Every metric this item needs sampled. A set, because two gauges may legitimately show the
    /// same metric drawn two different ways, and the sampler should still only run once.
    var requiredMetrics: Set<ActivityMetric> {
        Set(gauges.map(\.metric))
    }

    /// Whether any gauge here draws in colour, which decides whether the whole item can be a
    /// template image. See ``ActivityRenderer``.
    var hasColouredGauge: Bool {
        gauges.contains { $0.coloring != .monochrome }
    }

    var effectiveTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Activity" : trimmed
    }
}
