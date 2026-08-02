import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Raw readings of the system counters behind an Activity item.
///
/// ## Why these APIs and not the obvious ones
///
/// Everything here is a **kernel counter read**, never a subprocess and never a poll of a
/// higher-level framework. Shelling out to `ps`, `top`, `netstat` or `ioreg` once a second is the
/// standard way this feature gets written and it is the reason menu bar monitors have a
/// reputation for costing more than the thing they measure: a `fork`/`exec` pair is somewhere
/// between two and four orders of magnitude more expensive than the `mach_msg` it wraps.
///
/// Each sampler is a small value or object owning only the previous reading, because every
/// interesting number here is a **rate** — CPU ticks, bytes on a wire, bytes to a disk are all
/// monotonically increasing totals, and the useful quantity is the difference between two of
/// them divided by the time between. That is also why the first sample of any rate metric
/// returns `nil`: there is nothing to subtract from yet, and inventing a zero would draw a
/// misleading trough on the graph for one tick.
///
/// ## Costs
///
/// Measured on an M5, release build, sampling once a second — so these are cold-cache costs at
/// the cadence the feature actually runs at, not a back-to-back microbenchmark:
///
/// | Sampler | Mean | Worst seen |
/// |---|---|---|
/// | Memory | 10 µs | 20 µs |
/// | CPU | 26 µs | 69 µs |
/// | Disk | 77 µs | 192 µs |
/// | Network | 102 µs | 157 µs |
/// | GPU | 172 µs | 252 µs |
///
/// All five together are ~0.39 ms, which at the default one-second cadence is **0.04% of one
/// core**. The two expensive ones are the two that walk data structures rather than reading a
/// counter — `getifaddrs` builds a linked list of every address on every interface, and the
/// GPU's `PerformanceStatistics` fetch materialises a whole `CFDictionary`. Both are still an
/// order of magnitude cheaper than the process spawn they replace.
///
/// See ``MetricsMonitor`` for the demand-gating that means you only pay for the samplers whose
/// output is actually on screen.
enum SystemMetrics {

    // MARK: - CPU

    /// Whole-machine CPU utilisation, from the kernel's aggregate tick counters.
    ///
    /// `host_statistics(HOST_CPU_LOAD_INFO)` rather than `host_processor_info`: the latter is
    /// what every tutorial reaches for, and it allocates a per-core array that the caller must
    /// hand back with `vm_deallocate`. We want one number for the whole machine, so the
    /// pre-aggregated call is both cheaper and impossible to leak.
    struct CPUSampler {
        private var previous: (busy: Double, total: Double)?

        /// Utilisation in 0…1 over the interval since the last call, or `nil` on the first.
        mutating func sample() -> Double? {
            var info = host_cpu_load_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
            )

            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }

            let user = Double(info.cpu_ticks.0)
            let system = Double(info.cpu_ticks.1)
            let idle = Double(info.cpu_ticks.2)
            let nice = Double(info.cpu_ticks.3)

            let busy = user + system + nice
            let total = busy + idle

            defer { previous = (busy, total) }
            guard let previous else { return nil }

            let deltaTotal = total - previous.total
            // A zero delta means two samples landed inside one tick period. Reporting 0% would
            // punch a false trough in the graph, so the caller is told there is no news instead.
            guard deltaTotal > 0 else { return nil }

            return clamp01((busy - previous.busy) / deltaTotal)
        }
    }

    // MARK: - Memory

    /// Fraction of physical memory in use, matching Activity Monitor's "Memory Used".
    ///
    /// That figure is *not* "everything that is not free": macOS deliberately leaves very little
    /// memory free, filling it with a file cache it can evict at no cost. Counting that as used
    /// would pin the gauge near 100% on a healthy machine and tell the user nothing. The number
    /// Activity Monitor shows — and the one reproduced here — is app memory (internal pages that
    /// are not purgeable), plus wired pages the kernel cannot page out, plus whatever the
    /// compressor is holding.
    struct MemorySampler {
        /// Asked of the host rather than read from `vm_kernel_page_size`, which is a mutable
        /// global the concurrency checker rightly refuses. This is also the more correct
        /// question: it returns the unit the `vm_statistics64` counters are denominated in.
        private let pageSize: Double = {
            var size: vm_size_t = 0
            guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS else { return 4096 }
            return Double(size)
        }()
        private let physical = Double(ProcessInfo.processInfo.physicalMemory)

        func sample() -> Double? {
            var info = vm_statistics64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
            )

            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            guard result == KERN_SUCCESS, physical > 0 else { return nil }

            let appPages = Double(info.internal_page_count) - Double(info.purgeable_count)
            let pages = appPages + Double(info.wire_count) + Double(info.compressor_page_count)
            return clamp01(pages * pageSize / physical)
        }
    }

    // MARK: - GPU

    /// GPU utilisation, read straight out of the IORegistry.
    ///
    /// The accelerator publishes a `PerformanceStatistics` dictionary whose `Device Utilization %`
    /// key is the same number Activity Monitor's GPU History window plots. There is no public
    /// framework for this — Metal exposes no utilisation counter — so the registry is the only
    /// route, and it is a read-only property fetch requiring no entitlement or permission.
    ///
    /// The matching service is looked up once and held, because `IOServiceGetMatchingServices`
    /// walks the registry and is the expensive half of the operation; re-reading a property from
    /// a handle we already own is not.
    final class GPUSampler {
        private var service: io_object_t = 0

        /// `isolated` so it may read the main-actor-isolated handle it has to release; a plain
        /// `deinit` on a main-actor type is itself nonisolated and cannot.
        isolated deinit {
            if service != 0 { IOObjectRelease(service) }
        }

        func sample() -> Double? {
            if service == 0 { service = Self.findAccelerator() }
            guard service != 0 else { return nil }

            guard let statistics = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else {
                // The accelerator went away — an eGPU unplugged, or a driver restart. Drop the
                // stale handle so the next call re-matches rather than failing forever.
                IOObjectRelease(service)
                service = 0
                return nil
            }

            guard let utilisation = statistics["Device Utilization %"] as? NSNumber else {
                return nil
            }
            return clamp01(utilisation.doubleValue / 100)
        }

        /// Matches `IOAccelerator`, which every concrete driver class inherits from — the Apple
        /// Silicon `AGXAccelerator*` families and the discrete/Intel ones alike. Matching the
        /// concrete class name would tie this to one GPU generation.
        private static func findAccelerator() -> io_object_t {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
            ) == KERN_SUCCESS else { return 0 }
            defer { IOObjectRelease(iterator) }

            // First match wins. On a multi-GPU Mac that is the one the registry lists first,
            // which is the built-in; summing utilisation across dissimilar GPUs would produce a
            // percentage of nothing in particular.
            let service = IOIteratorNext(iterator)
            while case let extra = IOIteratorNext(iterator), extra != 0 {
                IOObjectRelease(extra)
            }
            return service
        }
    }

    // MARK: - Power

    /// Package power draw in watts — CPU plus GPU plus the Neural Engine.
    ///
    /// ## Where the number comes from
    ///
    /// Apple Silicon publishes per-block **energy accumulators** through IOReport, in an
    /// `"Energy Model"` channel group. Each channel is a monotonically increasing joule count;
    /// power is the difference between two reads divided by the time between them. These are the
    /// same counters `powermetrics` reports, which is the point: it is a measurement off the
    /// SoC's own power-management hardware, not an estimate derived from utilisation.
    ///
    /// ## Why not the alternatives
    ///
    /// - **`powermetrics`** is the obvious source and it is unusable here: it refuses to run
    ///   without root, so a menu bar app would need a privileged helper to read a number.
    /// - **Battery current × voltage** is fully public API and reads **zero on AC power** —
    ///   `InstantAmperage` is battery flow, not consumption. Useless for a plugged-in laptop or
    ///   any desktop.
    /// - **`AdapterDetails.Watts`** is the charger's negotiated *rating* (50 W here), not draw.
    /// - **SMC keys** like `PSTR` do carry total system power, but the classic `AppleSMC` user
    ///   client is not exposed under that class on current Apple Silicon.
    ///
    /// ## What it does and does not include
    ///
    /// This is **SoC package power**, not wall power. It excludes the display, SSD, Wi-Fi and
    /// anything on USB, so it reads lower than a socket meter — on an M5 Air, roughly 1–2 W idle
    /// and 20–26 W with every core busy. That is the honest scope of what is measurable without
    /// elevated privileges, and it is the number that actually moves when *your* work does.
    ///
    /// ## On depending on a private library
    ///
    /// `libIOReport.dylib` is not API. It is loaded with `dlopen` and every symbol is resolved
    /// individually, so if it moves or changes shape the sampler reports "no reading" and the
    /// gauge draws its empty state — the app does not fail to launch and nothing else is
    /// affected. That degradation path is the whole reason this is done by hand rather than by
    /// linking against it.
    final class PowerSampler {
        /// Resolved entry points, or `nil` if this system does not provide them.
        private let io = IOReport()
        private var subscription: AnyObject?
        private var channels: CFMutableDictionary?
        private var previous: (samples: CFDictionary, time: TimeInterval)?
        /// Set once the library or the channel group turns out to be unavailable, so a machine
        /// without it stops paying for the attempt on every tick.
        private var unavailable = false

        /// Watts since the last call, or `nil` on the first call and where unavailable.
        func sample() -> Double? {
            guard !unavailable, let io else { unavailable = true; return nil }

            if subscription == nil {
                guard let group = io.copyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?
                    .takeRetainedValue() else {
                    unavailable = true
                    return nil
                }
                var subscribed: Unmanaged<CFMutableDictionary>?
                guard let created = io.createSubscription(nil, group, &subscribed, 0, nil)?
                    .takeRetainedValue() else {
                    unavailable = true
                    return nil
                }
                subscription = created
                // The subscription reports on the channels it actually took, which may be a
                // subset of those asked for; sampling the original set would read nothing.
                channels = subscribed?.takeRetainedValue() ?? group
            }

            guard let subscription, let channels,
                  let current = io.createSamples(subscription, channels, nil)?.takeRetainedValue()
            else { return nil }

            let now = Date.timeIntervalSinceReferenceDate
            defer { previous = (current, now) }
            guard let previous else { return nil }

            let elapsed = now - previous.time
            guard elapsed > 0.001,
                  let delta = io.createSamplesDelta(previous.samples, current, nil)?
                    .takeRetainedValue()
            else { return nil }

            return joules(in: delta, io: io) / elapsed
        }

        /// Sums the energy of the three blocks that make up package power.
        ///
        /// The channel list is **hierarchical** — `ECPU0…5` roll into `ECPU`, `ECPU` and `PCPU`
        /// roll into `CPU Energy` — so adding everything up would count the same joules three
        /// times. One channel is chosen per block, preferring the rolled-up one, and each block
        /// contributes at most once. Names differ between chip generations, hence the fallbacks.
        private func joules(in delta: CFDictionary, io: IOReport) -> Double {
            var cpu: Double?
            var cpuParts = 0.0
            var gpu: Double?
            var gpuFallback: Double?
            var ane: Double?

            io.iterate(delta) { channel in
                guard let rawName = io.channelName(channel)?.takeUnretainedValue() as String?
                else { return 0 }
                let unit = io.channelUnit(channel)?.takeUnretainedValue() as String? ?? ""
                let energy = Self.joules(io.integerValue(channel, 0), unit: unit)

                switch rawName {
                case "CPU Energy": cpu = energy
                case "ECPU", "PCPU": cpuParts += energy
                case "GPU Energy": gpu = energy
                case "GPU": gpuFallback = energy
                case "ANE", "ANE Energy": ane = energy
                default: break
                }
                return 0
            }

            return (cpu ?? cpuParts) + (gpu ?? gpuFallback ?? 0) + (ane ?? 0)
        }

        private static func joules(_ value: Int64, unit: String) -> Double {
            switch unit {
            case "nJ": Double(value) / 1e9
            case "uJ": Double(value) / 1e6
            case "mJ": Double(value) / 1e3
            default: Double(value)
            }
        }
    }

    /// The handful of `libIOReport.dylib` entry points the power sampler needs.
    ///
    /// Resolved one at a time so a partial match fails cleanly rather than crashing on the first
    /// call into a symbol that was not there.
    private struct IOReport {
        typealias CopyChannelsInGroup =
            @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
        typealias CreateSubscription =
            @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                            UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                            UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
        typealias CreateSamples =
            @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        typealias CreateSamplesDelta =
            @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64
        typealias Iterate =
            @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void

        let copyChannelsInGroup: CopyChannelsInGroup
        let createSubscription: CreateSubscription
        let createSamples: CreateSamples
        let createSamplesDelta: CreateSamplesDelta
        let channelName: ChannelString
        let channelUnit: ChannelString
        let integerValue: IntegerValue
        let iterate: Iterate

        init?() {
            guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
            func symbol<T>(_ name: String, _ type: T.Type) -> T? {
                guard let pointer = dlsym(handle, name) else { return nil }
                return unsafeBitCast(pointer, to: type)
            }
            guard
                let a = symbol("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
                let b = symbol("IOReportCreateSubscription", CreateSubscription.self),
                let c = symbol("IOReportCreateSamples", CreateSamples.self),
                let d = symbol("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
                let e = symbol("IOReportChannelGetChannelName", ChannelString.self),
                let f = symbol("IOReportChannelGetUnitLabel", ChannelString.self),
                let g = symbol("IOReportSimpleGetIntegerValue", IntegerValue.self),
                let h = symbol("IOReportIterate", Iterate.self)
            else { return nil }

            copyChannelsInGroup = a
            createSubscription = b
            createSamples = c
            createSamplesDelta = d
            channelName = e
            channelUnit = f
            integerValue = g
            iterate = h
        }
    }

    // MARK: - Network

    /// Bytes per second in and out, summed over the machine's real interfaces.
    ///
    /// The kernel's per-interface byte counters are 32-bit and therefore wrap, which is normally
    /// a source of one absurd spike per 4 GB transferred. Holding the running total as `UInt32`
    /// and subtracting with `&-` makes the wrap a non-event: the arithmetic is modulo 2³², and
    /// the true delta is exact as long as under 4 GB moved between two samples — 32 Gbit/s at the
    /// one-second cadence, which no Mac interface can reach.
    struct NetworkSampler {
        private var previous: (received: UInt32, sent: UInt32, time: TimeInterval)?

        /// Interfaces that carry traffic already counted elsewhere, or none at all.
        ///
        /// `awdl`/`llw` are AirDrop and low-latency WLAN, both riding the Wi-Fi radio that `en0`
        /// already reports; `anpi` and `ap` are internal Apple links. Counting them double-counts.
        private static let ignoredPrefixes = ["lo", "awdl", "llw", "anpi", "ap", "gif", "stf"]

        /// Rates in bytes/second, or `nil` on the first call and on any reading that cannot be
        /// trusted.
        mutating func sample() -> (down: Double, up: Double)? {
            guard let totals = Self.interfaceTotals() else { return nil }
            let now = Date.timeIntervalSinceReferenceDate

            defer { previous = (totals.received, totals.sent, now) }
            guard let previous else { return nil }

            let elapsed = now - previous.time
            guard elapsed > 0.001 else { return nil }

            let down = Double(totals.received &- previous.received) / elapsed
            let up = Double(totals.sent &- previous.sent) / elapsed

            // An interface disappearing mid-flight — a dock unplugged, a VPN torn down — removes
            // its lifetime total from the sum and yields a delta that looks like a terabyte in
            // one second. Discard rather than draw it; the next sample re-baselines.
            let ceiling = 12.5e9
            guard down < ceiling, up < ceiling else { return nil }

            return (down, up)
        }

        private static func interfaceTotals() -> (received: UInt32, sent: UInt32)? {
            var head: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&head) == 0, let head else { return nil }
            defer { freeifaddrs(head) }

            var received: UInt32 = 0
            var sent: UInt32 = 0

            for interface in sequence(first: head, next: \.pointee.ifa_next) {
                let entry = interface.pointee
                guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
                guard entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
                guard let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else {
                    continue
                }

                let name = String(cString: entry.ifa_name)
                guard !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }

                received = received &+ data.pointee.ifi_ibytes
                sent = sent &+ data.pointee.ifi_obytes
            }

            return (received, sent)
        }
    }

    // MARK: - Disk

    /// Bytes per second read from and written to physical storage.
    ///
    /// `IOBlockStorageDriver` sits below the filesystem, so this is real device traffic rather
    /// than reads the unified buffer cache served without touching the disk — which is the
    /// number worth showing, and the one Activity Monitor's Disk tab reports.
    final class DiskSampler {
        private var services: [io_object_t] = []
        private var previous: (read: UInt64, written: UInt64, time: TimeInterval)?

        isolated deinit { releaseServices() }

        private func releaseServices() {
            for service in services { IOObjectRelease(service) }
            services = []
        }

        func sample() -> (read: Double, written: Double)? {
            if services.isEmpty { services = Self.findDrives() }
            guard !services.isEmpty else { return nil }

            var read: UInt64 = 0
            var written: UInt64 = 0
            var sawAny = false

            for service in services {
                guard let statistics = IORegistryEntryCreateCFProperty(
                    service, "Statistics" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any] else { continue }

                sawAny = true
                read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }

            // Every handle we hold is dead: a volume was ejected, or the registry was rebuilt.
            // Re-enumerate on the next call rather than reporting a permanent zero.
            guard sawAny else {
                releaseServices()
                previous = nil
                return nil
            }

            let now = Date.timeIntervalSinceReferenceDate
            defer { previous = (read, written, now) }
            guard let previous else { return nil }

            let elapsed = now - previous.time
            guard elapsed > 0.001 else { return nil }

            // A drive appearing between samples raises the totals by its whole lifetime count.
            // Unsigned subtraction would wrap that into a colossal rate, so a decrease — which a
            // 64-bit counter cannot legitimately produce — is treated as a re-baseline.
            guard read >= previous.read, written >= previous.written else { return nil }

            return (Double(read - previous.read) / elapsed,
                    Double(written - previous.written) / elapsed)
        }

        private static func findDrives() -> [io_object_t] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
            ) == KERN_SUCCESS else { return [] }
            defer { IOObjectRelease(iterator) }

            var found: [io_object_t] = []
            while case let service = IOIteratorNext(iterator), service != 0 {
                found.append(service)
            }
            return found
        }
    }

    // MARK: - Battery

    /// Charge level, plus the sentence that goes in the menu — charging state and time remaining.
    ///
    /// ## Why `IOPowerSources` rather than the registry
    ///
    /// This is the one metric here with a real public API, and it is worth using: `IOPSCopy…`
    /// reads the same power-source dictionary the system's own battery menu reads, including the
    /// estimator's time-remaining figure. Going to `AppleSmartBattery` in the IORegistry — which
    /// is the usual route in code like this — gets the raw capacity registers and *not* the
    /// estimate, which would then have to be reinvented badly from the current draw. macOS
    /// already smooths that over minutes of history; there is nothing to gain by guessing at it.
    ///
    /// ## Machines with no battery
    ///
    /// A Mac mini, Studio, Pro or iMac has no internal battery, so this reports `nil` forever and
    /// the gauge draws its empty state. That is the honest outcome — the alternative, reporting
    /// 100%, would be a gauge that looks like it is working and is lying — and Settings says so
    /// in words rather than leaving a permanently blank gauge to be interpreted.
    struct BatterySampler {

        /// Charge as a fraction, and a description of what the battery is doing.
        func sample() -> (value: Double?, detail: String?) {
            guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                    as? [CFTypeRef]
            else { return (nil, nil) }

            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
                // Skip a UPS or a Bluetooth mouse, both of which turn up in this list.
                guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else {
                    continue
                }

                let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
                let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
                guard let current, let maximum, maximum > 0 else { continue }

                return (clamp01(current / maximum), detail(from: description))
            }
            return (nil, nil)
        }

        /// "Charging · 1:24 to full", "3:47 remaining", "Charged", "On AC power".
        ///
        /// The estimator returns −1 for "not known yet", which it does for a minute or two after
        /// every plug and unplug while it re-learns the rate. Saying so — rather than printing a
        /// nonsense duration or nothing at all — is why this distinguishes the cases.
        private func detail(from description: [String: Any]) -> String {
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false

            if isCharged { return "Charged" }

            if isCharging {
                let minutes = (description[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue ?? -1
                return minutes > 0
                    ? "Charging · \(Self.duration(minutes)) to full"
                    : "Charging"
            }

            if onAC { return "On AC power" }

            let minutes = (description[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue ?? -1
            return minutes > 0 ? "\(Self.duration(minutes)) remaining" : "On battery"
        }

        private static func duration(_ minutes: Int) -> String {
            String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
    }

    // MARK: - Thermal

    /// Thermal pressure, from `ProcessInfo`.
    ///
    /// The cheapest sampler here by a wide margin — a property read on a value the system keeps
    /// current for its own purposes — and the only one that is entirely public API. See
    /// ``ThermalLevel`` for why this and not a temperature in degrees.
    struct ThermalSampler {
        func sample() -> Double? {
            ThermalLevel(ProcessInfo.processInfo.thermalState).rawValue
        }
    }

    // MARK: - Disk space

    /// Free space on the startup volume, as a fraction, plus the figure in bytes for the menu.
    ///
    /// ## Which "free" this is
    ///
    /// `volumeAvailableCapacityForImportantUsageKey`, not `volumeAvailableCapacityKey`. The two
    /// differ by a lot on any Mac with Time Machine local snapshots — the plain key reports what
    /// is free *right now*, while the important-usage key reports what the system would make
    /// available by purging snapshots and caches, which is the number Finder shows and therefore
    /// the number the user will compare this against. Reporting the smaller one would have the
    /// gauge in the red while Finder says there is 200 GB free.
    ///
    /// ## Why this is a "level" and not a rate
    ///
    /// Everything else in this file is a difference between two readings. This is not: free space
    /// is a quantity, so a single call answers it and there is no first-sample `nil` to explain.
    /// It is also the slowest-moving thing MenuDock draws, which is why the result is cached for
    /// a few seconds — a `statfs` on every tick to watch a number that changes hourly is the sort
    /// of thing that makes a monitor cost more than what it monitors.
    final class DiskSpaceSampler {
        private var cached: (value: Double, detail: String, time: TimeInterval)?

        /// How long a reading stands. Chosen to be far longer than any refresh interval and far
        /// shorter than a user would notice: emptying the Trash updates the gauge within a
        /// half-minute, and a downloading file moves it in steps rather than smoothly.
        private static let validity: TimeInterval = 20

        func sample() -> (value: Double?, detail: String?) {
            let now = Date.timeIntervalSinceReferenceDate
            if let cached, now - cached.time < Self.validity {
                return (cached.value, cached.detail)
            }

            let volume = URL(fileURLWithPath: NSHomeDirectory())
            guard let values = try? volume.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
            ]),
                let free = values.volumeAvailableCapacityForImportantUsage,
                let total = values.volumeTotalCapacity, total > 0
            else { return (nil, nil) }

            let fraction = clamp01(Double(free) / Double(total))
            let detail = "\(Self.bytes(Double(free))) free of \(Self.bytes(Double(total)))"
            cached = (fraction, detail, now)
            return (fraction, detail)
        }

        /// Decimal gigabytes, matching what Finder and the storage pane report. Binary units
        /// would be more defensible and would disagree with every other number the user can see.
        private static func bytes(_ value: Double) -> String {
            value >= 1e12
                ? String(format: "%.2f TB", value / 1e12)
                : String(format: "%.1f GB", value / 1e9)
        }
    }

    // MARK: - Processes

    /// The busiest processes on the machine, by CPU time accumulated between two calls.
    ///
    /// ## This one is genuinely expensive, and that shapes everything about it
    ///
    /// Every other sampler in this file reads one counter, or one dictionary. This one asks the
    /// kernel a question **per process**: `proc_listpids` to enumerate, then a `proc_pid_rusage`
    /// for each of the four to six hundred processes on an ordinary Mac. That is two orders of
    /// magnitude more syscalls than the whole rest of the file put together, and it is why this
    /// is not on the timer — ``MetricsMonitor`` only runs it while an Activity menu is actually
    /// open. See ``ActivityEntry/showsTopProcesses``.
    ///
    /// ## Why `proc_pid_rusage` and not `task_info`
    ///
    /// The textbook approach is `task_for_pid` followed by `task_info(TASK_BASIC_INFO)`, and it
    /// does not work: `task_for_pid` on another process requires either root or the
    /// `com.apple.system-task-ports` entitlement, so an ordinary app gets `KERN_FAILURE` for
    /// everything it did not spawn. `proc_pid_rusage` needs neither — it answers for any process
    /// owned by the same user, which is precisely the set the user cares about. Processes owned
    /// by root or another user are skipped rather than reported as zero, because "the CPU is
    /// busy and nothing is using it" is worse than an honest omission.
    ///
    /// ## Why the numbers do not add up to the CPU gauge
    ///
    /// They cannot, and should not be expected to. The CPU gauge is whole-machine utilisation
    /// including the kernel and every other user's work; this is the share attributable to this
    /// user's processes. On a busy machine the difference is `kernel_task` and the daemons.
    final class ProcessSampler {

        struct Entry: Sendable, Hashable {
            let pid: pid_t
            let name: String
            /// Share of one core, so two fully busy threads read as 2.0. Matches the convention
            /// Activity Monitor's "% CPU" column uses, where 100% is one core.
            let share: Double
        }

        /// Cumulative CPU nanoseconds per pid at the last call.
        private var previous: [pid_t: UInt64] = [:]
        private var previousTime: TimeInterval?

        /// Drops the baseline, so the next call establishes a fresh one.
        ///
        /// Called when sampling is switched off. Without it, a menu opened an hour after the last
        /// one would compute its first "rate" over that entire hour — a process that used a
        /// steady 100% for one minute of it would show as 1.7%, which is not wrong so much as
        /// meaningless.
        func reset() {
            previous.removeAll(keepingCapacity: true)
            previousTime = nil
        }

        /// The `limit` busiest processes, or `nil` on the first call after a reset.
        func sample(limit: Int) -> [Entry]? {
            let now = Date.timeIntervalSinceReferenceDate
            guard let pids = Self.allPIDs() else { return nil }

            var current: [pid_t: UInt64] = [:]
            current.reserveCapacity(pids.count)
            var deltas: [(pid: pid_t, nanoseconds: UInt64)] = []

            for pid in pids where pid > 0 {
                guard let nanoseconds = Self.cpuNanoseconds(of: pid) else { continue }
                current[pid] = nanoseconds
                // A pid absent from the previous pass is a process that has just started. It has
                // no delta to report, and crediting it with its whole lifetime CPU would put
                // every freshly launched app straight to the top of the list.
                guard let before = previous[pid], nanoseconds > before else { continue }
                deltas.append((pid, nanoseconds - before))
            }

            defer {
                previous = current
                previousTime = now
            }
            guard let previousTime, case let elapsed = now - previousTime, elapsed > 0.05 else {
                return nil
            }

            return deltas
                .sorted { $0.nanoseconds > $1.nanoseconds }
                .prefix(limit)
                .map { Entry(pid: $0.pid,
                             name: Self.name(of: $0.pid),
                             share: Double($0.nanoseconds) / 1e9 / elapsed) }
        }

        /// Every pid on the machine.
        ///
        /// Called twice: once with a null buffer to learn the size, once to fill it. The size can
        /// grow between the two calls, so the buffer is over-allocated and the *returned* byte
        /// count decides how much of it is real — reading the whole buffer would report stale
        /// pids from a previous pass as live processes.
        private static func allPIDs() -> [pid_t]? {
            let sizing = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard sizing > 0 else { return nil }

            let capacity = Int(sizing) / MemoryLayout<pid_t>.size + 32
            var pids = [pid_t](repeating: 0, count: capacity)
            let written = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress,
                              Int32(buffer.count * MemoryLayout<pid_t>.size))
            }
            guard written > 0 else { return nil }
            return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size))
        }

        /// User plus system CPU time consumed since the process started, in nanoseconds.
        private static func cpuNanoseconds(of pid: pid_t) -> UInt64? {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            // Non-zero for anything this user does not own, which is expected and common.
            guard result == 0 else { return nil }
            return info.ri_user_time &+ info.ri_system_time
        }

        /// The name to show. Only ever called for the handful of processes that made the cut.
        ///
        /// `NSRunningApplication` first, because it knows the *localised* name a user would
        /// recognise — "Google Chrome" where `proc_name` gives the executable, which for a helper
        /// is a truncated "Google Chrome He". Falls back to the executable for everything without
        /// a bundle, which is most of what is running.
        private static func name(of pid: pid_t) -> String {
            if let app = NSRunningApplication(processIdentifier: pid),
               let name = app.localizedName, !name.isEmpty {
                return name
            }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return "PID \(pid)" }
            return String(cString: buffer)
        }
    }

    // MARK: - Shared

    private static func clamp01(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

private func clamp01(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : 0
}
