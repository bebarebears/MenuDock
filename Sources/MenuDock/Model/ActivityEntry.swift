import Foundation

/// Decodes a string-backed enum, falling back for an absent key **and** for a value this build
/// does not recognise.
///
/// `decodeIfPresent` only covers the first of those, which is a trap: it reads as tolerant and
/// still throws `dataCorrupted` on an unknown raw value. Since `Codable` propagates that failure
/// all the way up, one gauge naming a metric from a newer MenuDock would fail the decode of the
/// *entire* configuration and quarantine the user's whole menu bar. Caught by the codec tests,
/// which is the only way this surfaces short of shipping a new metric.
nonisolated fileprivate extension KeyedDecodingContainer {
    func decodeTolerantly<T>(_ type: T.Type, forKey key: Key, fallback: T) throws -> T
    where T: RawRepresentable, T.RawValue == String {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return fallback }
        return T(rawValue: raw) ?? fallback
    }
}

/// Which system counter a gauge shows.
///
/// The raw values are written to the configuration file, so they are stable slugs — renaming one
/// orphans every user who picked it. Display names are free to change.
nonisolated enum ActivityMetric: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case cpu
    case gpu
    case memory
    case networkDown
    case networkUp
    case diskRead
    case diskWrite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .networkDown: "Network Download"
        case .networkUp: "Network Upload"
        case .diskRead: "Disk Read"
        case .diskWrite: "Disk Write"
        }
    }

    /// One or two characters, for a menu bar where every point of width is contested.
    var shortLabel: String {
        switch self {
        case .cpu: "C"
        case .gpu: "G"
        case .memory: "M"
        case .networkDown: "↓"
        case .networkUp: "↑"
        case .diskRead: "R"
        case .diskWrite: "W"
        }
    }

    var fullLabel: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        case .networkDown: "NET ↓"
        case .networkUp: "NET ↑"
        case .diskRead: "DISK R"
        case .diskWrite: "DISK W"
        }
    }

    /// Percentages are already 0…1 and need no scaling; rates are unbounded bytes/second and do.
    var isRate: Bool {
        switch self {
        case .cpu, .gpu, .memory: false
        case .networkDown, .networkUp, .diskRead, .diskWrite: true
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
        case .cpu, .gpu, .memory: 1
        case .networkDown, .networkUp: 1_000_000
        case .diskRead, .diskWrite: 8_000_000
        }
    }

    /// Compact form for the menu bar: `42%`, `1.2M`, `840K`.
    func compactString(_ value: Double) -> String {
        guard isRate else { return "\(Int((value * 100).rounded()))%" }
        return Self.compactRate(value)
    }

    /// Full form for the click-through menu, where there is room to be unambiguous.
    func verboseString(_ value: Double) -> String {
        guard isRate else { return String(format: "%.1f%%", value * 100) }
        return Self.verboseRate(value)
    }

    /// The widest string ``compactString(_:)`` can return.
    ///
    /// Menu bar text is drawn with monospaced digits and its cell is sized from *this* rather
    /// than from the current value, so a gauge never changes width as the number moves. A status
    /// item that breathes in and out once a second drags every icon to its left along with it,
    /// which is far more distracting than a little unused space.
    ///
    /// Both forms are four characters wide, which is why ``compactString(_:)`` goes to the
    /// trouble of never emitting a fifth: the reserved cell is only as wide as the worst case,
    /// so every character the format can theoretically produce is dead space in every gauge that
    /// never produces it.
    var widestCompactString: String { isRate ? "999M" : "100%" }

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

    /// Whether this style draws the history window or only the latest sample. Drives how much
    /// history the monitor is asked to keep, and whether a redraw is needed when the value has
    /// not visibly changed.
    var usesHistory: Bool { self == .graph }
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

    private enum CodingKeys: String, CodingKey { case id, metric, style, label }

    init(id: UUID = UUID(),
         metric: ActivityMetric = .cpu,
         style: GaugeStyle = .graph,
         label: GaugeLabel = .short) {
        self.id = id
        self.metric = metric
        self.style = style
        self.label = label
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

    /// What a freshly added Activity item shows.
    ///
    /// Two gauges rather than one, and two *different styles*: the pair immediately demonstrates
    /// both the things a user cannot discover from a single default — that an item holds several
    /// metrics, and that each picks its own presentation.
    static let defaultGauges: [ActivityGauge] = [
        ActivityGauge(metric: .cpu, style: .graph, label: .short),
        ActivityGauge(metric: .memory, style: .bar, label: .short)
    ]

    private enum CodingKeys: String, CodingKey { case name, gauges, interval }

    init(name: String = "Activity",
         gauges: [ActivityGauge] = ActivityEntry.defaultGauges,
         interval: RefreshInterval = .second) {
        self.name = name
        self.gauges = gauges
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Activity"
        // An explicitly empty gauge list is a legitimate state the user can reach in Settings,
        // so it is preserved rather than being refilled with defaults on the next launch.
        gauges = try container.decodeIfPresent([ActivityGauge].self, forKey: .gauges) ?? []
        interval = try container.decodeTolerantly(RefreshInterval.self, forKey: .interval,
                                                  fallback: .second)
    }

    /// Every metric this item needs sampled. A set, because two gauges may legitimately show the
    /// same metric drawn two different ways, and the sampler should still only run once.
    var requiredMetrics: Set<ActivityMetric> {
        Set(gauges.map(\.metric))
    }

    var effectiveTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Activity" : trimmed
    }
}
