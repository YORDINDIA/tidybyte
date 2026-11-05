import Darwin
import Foundation

/// Host-wide CPU and memory readings from mach statistics. Pure functions so
/// tests can feed synthetic tick pairs.
public enum HostProbes {
    /// Cumulative CPU tick counts across all cores.
    public struct CPUTicks: Sendable, Equatable {
        public var user: UInt64
        public var system: UInt64
        public var idle: UInt64
        public var nice: UInt64

        public init(user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }

        public var total: UInt64 { user + system + idle + nice }
    }

    /// CPU split derived from two tick snapshots. The first ever sample has no
    /// previous tick set to diff against and reports zeros.
    public static func cpuReading(ticks: CPUTicks, previous: CPUTicks?, logicalCores: Int) -> CPUReading {
        let load = ProcessProbe.loadAverage()
        // Apple silicon: performance and efficiency cores in a 2:1-ish split;
        // the split is cosmetic context, so the estimate stays simple.
        let physical = max(1, logicalCores / 2)
        guard let previous, ticks.total > previous.total else {
            return CPUReading(
                loadAverage1: load.one, loadAverage5: load.five, loadAverage15: load.fifteen,
                logicalCoreCount: logicalCores,
                physicalCoreCount: physical)
        }
        func delta(_ key: KeyPath<CPUTicks, UInt64>) -> Double {
            let current = Double(ticks[keyPath: key])
            let before = Double(previous[keyPath: key])
            return max(0, current - before)
        }
        let totalTicks = max(1, Double(ticks.total) - Double(previous.total))
        let user = delta(\.user) / totalTicks * 100
        let system = delta(\.system) / totalTicks * 100
        let idle = delta(\.idle) / totalTicks * 100
        return CPUReading(
            usagePercent: min(100, user + system),
            userPercent: user,
            systemPercent: system,
            idlePercent: idle,
            loadAverage1: load.one,
            loadAverage5: load.five,
            loadAverage15: load.fifteen,
            logicalCoreCount: logicalCores,
            physicalCoreCount: physical)
    }

    /// Current cumulative tick counts for every core, summed.
    public static func cpuTicks() -> CPUTicks {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var ticks = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &ticks) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return CPUTicks() }
        return CPUTicks(
            user: UInt64(ticks.cpu_ticks.0),
            system: UInt64(ticks.cpu_ticks.1),
            idle: UInt64(ticks.cpu_ticks.2),
            nice: UInt64(ticks.cpu_ticks.3))
    }

    public static var logicalCoreCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// Cumulative VM counters between which rates are computed.
    public struct MemoryCounters: Sendable, Equatable {
        public var swapIns: Int64
        public var swapOuts: Int64
        public var pageIns: Int64
        public var pageOuts: Int64
    }

    /// One memory sample plus the counters it was derived from.
    public struct MemorySample: Sendable {
        public var reading: MemoryReading
        public var counters: MemoryCounters
    }

    /// Memory figures with Activity Monitor's arithmetic (see SystemStatus)
    /// plus swap and page activity rates across the sample interval.
    public static func memoryReading(previous: MemoryCounters?, interval: TimeInterval) -> MemorySample {
        let empty = MemorySample(reading: MemoryReading(), counters: MemoryCounters(swapIns: 0, swapOuts: 0, pageIns: 0, pageOuts: 0))
        guard let stats = SystemStatus.vmStatistics64() else { return empty }
        let pageSize = Int64(getpagesize())
        let page = { (value: UInt32) in Int64(value) * pageSize }
        let counters = MemoryCounters(
            swapIns: Int64(stats.swapins), swapOuts: Int64(stats.swapouts),
            pageIns: Int64(stats.pageins), pageOuts: Int64(stats.pageouts))
        func rate(_ current: Int64, _ before: Int64?) -> Double {
            guard let before, interval > 0 else { return 0 }
            let delta = current - before
            return delta > 0 ? Double(delta) / interval : 0
        }
        let swapUsage = SystemStatus.swapUsed()
        let reading = MemoryReading(
            totalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            usedBytes: page(stats.internal_page_count) + page(stats.wire_count) + page(stats.compressor_page_count),
            appBytes: page(stats.internal_page_count),
            wiredBytes: page(stats.wire_count),
            compressedBytes: page(stats.compressor_page_count),
            cachedBytes: page(stats.external_page_count) + page(stats.purgeable_count),
            swapUsedBytes: swapUsage,
            swapInPerSecond: rate(counters.swapIns, previous?.swapIns),
            swapOutPerSecond: rate(counters.swapOuts, previous?.swapOuts),
            pageInPerSecond: rate(counters.pageIns, previous?.pageIns),
            pageOutPerSecond: rate(counters.pageOuts, previous?.pageOuts),
            pressureLevel: Int(pressureLevel()))
        return MemorySample(reading: reading, counters: counters)
    }

    /// kern.memorystatus_vm_pressure_level is answered by this macOS's kernel:
    /// `sysctl kern.memorystatus_vm_pressure_level` returned 1 on macOS 26
    /// (Darwin 25.6.0, arm64), so the sysctl stays the source of truth and the
    /// failure fallback (1, "normal") only covers kernels that drop the key.
    static func pressureLevel() -> Int32 {
        Int32(SystemStatus.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
    }
}

/// Interface throughput from the kernel route table (NET_RT_IF_LIST2).
public enum NetworkProbe {
    // Route-table constants that are C preprocessor macros in route.h.
    static let netRTIFList2: Int32 = 6
    static let rtmIfInfo2: UInt8 = 0x12
    /// A real RTM_IFINFO2 message on Darwin: the 32-byte if_msghdr2 header,
    /// the if_data64 block, and the link-level sockaddr the kernel appends
    /// (verified against a live NET_RT_IF_LIST2 dump: every IFINFO2 message
    /// is 180 bytes). The walk requires this stride before it parses.
    static let ifInfo2Stride = 180

    /// Cumulative byte/byte counters per interface.
    public struct InterfaceCounters: Sendable, Equatable {
        public var name: String
        public var receivedBytes: Int64
        public var sentBytes: Int64

        public init(name: String, receivedBytes: Int64, sentBytes: Int64) {
            self.name = name
            self.receivedBytes = receivedBytes
            self.sentBytes = sentBytes
        }
    }

    /// Reads the route table once, skipping loopback interfaces. The engine
    /// calls this a single time per tick and diffs the snapshots itself, so
    /// there is never a second walk.
    public static func sampleCounters() -> [InterfaceCounters] {
        // NET_RT_IF_LIST2 sits in the fifth slot of a six-element mib; longer
        // mibs fail with EINVAL on real kernels.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, netRTIFList2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var data = Data(count: size)
        var readSize = size
        let result = data.withUnsafeMutableBytes { pointer in
            sysctl(&mib, 6, pointer.baseAddress, &readSize, nil, 0)
        }
        guard result == 0 else { return [] }
        return parseInterfaceList(Data(data.prefix(readSize)))
    }

    /// Walks the packed route messages. Pure so the parser is testable.
    /// Short messages and non-IFINFO2 messages are skipped; the walk stops
    /// only on a zero length or a message that overruns the buffer.
    static func parseInterfaceList(_ data: Data) -> [InterfaceCounters] {
        var counters: [String: InterfaceCounters] = [:]
        var offset = 0
        let bytes = [UInt8](data)
        while offset + Self.ifInfo2Stride <= bytes.count {
            let messageLength = Int(readUInt16(bytes, offset))
            guard messageLength > 0 else { break }
            guard offset + messageLength <= bytes.count else { break }
            if messageLength >= Self.ifInfo2Stride, readUInt8(bytes, offset + 3) == Self.rtmIfInfo2 {
                if let entry = parseIfMsghdr2(bytes, offset: offset) {
                    counters[entry.name] = entry
                }
            }
            offset += messageLength
        }
        return Array(counters.values)
    }

    private static func parseIfMsghdr2(_ bytes: [UInt8], offset: Int) -> InterfaceCounters? {
        // Host byte order throughout, verified field by field against
        // net/if.h's if_msghdr2 and net/if_var.h's if_data64:
        //   msglen@0(u16) version@2 type@3 ifm_addrs@4(i32) ifm_flags@8(i32)
        //   ifm_index@12(u16) snd_len@16 … ifm_timer@28,
        //   ifm_data (if_data64) at +32, whose counters start at +16:
        //   baudrate@16, ipackets@24, …, ibytes@64, obytes@72 — so on the
        //   message ibytes sits at +96 and obytes at +104.
        let index = Int(readUInt16(bytes, offset + 12))
        guard index > 0 else { return nil }
        let flags = readUInt32(bytes, offset + 8)
        // IFF_LOOPBACK.
        guard flags & 0x8 == 0 else { return nil }
        let dataStart = offset + 32
        func counter(_ offsetInData: Int) -> Int64 {
            Int64(bitPattern: readUInt64(bytes, dataStart + offsetInData))
        }
        return InterfaceCounters(
            name: interfaceName(index),
            receivedBytes: counter(64),
            sentBytes: counter(72))
    }

    /// The kernel's name for an interface index (en0…), or "if%d" when the
    /// index has no mapping on this system.
    static func interfaceName(_ index: Int) -> String {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &buffer) != nil else {
            return String(format: "if%d", index)
        }
        let characters = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        // Kernel interface names are ASCII; an undecodable one falls back to
        // the index form rather than guessing.
        return String(bytes: characters, encoding: .utf8) ?? String(format: "if%d", index)
    }

    /// Diffs two counter snapshots into rates plus boot-to-now totals.
    /// Pure: `current` comes from one `sampleCounters()` call per tick.
    public static func reading(
        previous: [InterfaceCounters]?, current: [InterfaceCounters], interval: TimeInterval
    ) -> NetworkReading {
        func total(_ key: KeyPath<InterfaceCounters, Int64>) -> Int64 {
            current.reduce(0) { $0 + $1[keyPath: key] }
        }
        var downloadPerSecond: Double = 0
        var uploadPerSecond: Double = 0
        if let previous, interval > 0 {
            let before = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            for entry in current {
                guard let old = before[entry.name] else { continue }
                downloadPerSecond += max(0, Double(entry.receivedBytes - old.receivedBytes) / interval)
                uploadPerSecond += max(0, Double(entry.sentBytes - old.sentBytes) / interval)
            }
        }
        return NetworkReading(
            downloadBytesPerSecond: downloadPerSecond,
            uploadBytesPerSecond: uploadPerSecond,
            totalDownloadBytes: total(\.receivedBytes),
            totalUploadBytes: total(\.sentBytes))
    }

    private static func readUInt8(_ bytes: [UInt8], _ offset: Int) -> UInt8 { bytes[offset] }

    // Host (little-endian on Apple hardware) integer reads.
    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(readUInt32(bytes, offset)) | UInt64(readUInt32(bytes, offset + 4)) << 32
    }
}
