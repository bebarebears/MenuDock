import Darwin
import Foundation
import IOKit

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

    // MARK: - Shared

    private static func clamp01(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

private func clamp01(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : 0
}
