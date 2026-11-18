import Darwin
import Foundation
import IOKit
import SystemConfiguration

/// Host-wide CPU, memory, and hardware disk readings from mach/IOKit. Pure
/// functions where possible so tests can feed synthetic tick pairs.
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

    public static let logicalCoreCount: Int = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
    public static let physicalCoreCount: Int? = sysctlInt("hw.physicalcpu")
    public static let performanceCoreCount: Int? = sysctlInt("hw.perflevel0.physicalcpu")
    public static let efficiencyCoreCount: Int? = sysctlInt("hw.perflevel1.physicalcpu")

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    /// CPU split derived from two tick snapshots. The first ever sample has no
    /// previous tick set to diff against and reports zeros.
    public static func cpuReading(ticks: CPUTicks, previous: CPUTicks?, logicalCores: Int) -> CPUReading {
        let load = ProcessProbe.loadAverage()
        let physical = physicalCoreCount ?? max(1, logicalCores / 2)
        guard let previous, ticks.total > previous.total else {
            return CPUReading(
                loadAverage1: load.one, loadAverage5: load.five, loadAverage15: load.fifteen,
                logicalCoreCount: logicalCores,
                physicalCoreCount: physical,
                performanceCoreCount: performanceCoreCount,
                efficiencyCoreCount: efficiencyCoreCount)
        }
        func delta(_ key: KeyPath<CPUTicks, UInt64>) -> Double {
            max(0, Double(ticks[keyPath: key]) - Double(previous[keyPath: key]))
        }
        let totalTicks = max(1, Double(ticks.total) - Double(previous.total))
        let user = (delta(\.user) + delta(\.nice)) / totalTicks * 100
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
            physicalCoreCount: physical,
            performanceCoreCount: performanceCoreCount,
            efficiencyCoreCount: efficiencyCoreCount)
    }

    /// Current cumulative tick counts for every core, summed.
    public static func cpuTicks() -> CPUTicks {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var ticks = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &ticks) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return CPUTicks() }
        return CPUTicks(
            user: UInt64(ticks.cpu_ticks.0),
            system: UInt64(ticks.cpu_ticks.1),
            idle: UInt64(ticks.cpu_ticks.2),
            nice: UInt64(ticks.cpu_ticks.3))
    }

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

    private static func vmStatistics(host: host_t) -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// Memory figures with Activity Monitor's arithmetic (app memory excludes
    /// purgeable pages) plus swap and page activity rates.
    public static func memoryReading(previous: MemoryCounters?, interval: TimeInterval) -> MemorySample {
        let empty = MemorySample(reading: MemoryReading(), counters: MemoryCounters(swapIns: 0, swapOuts: 0, pageIns: 0, pageOuts: 0))
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard let stats = vmStatistics(host: host) else { return empty }
        var rawPageSize: vm_size_t = 0
        let pageSize = (host_page_size(host, &rawPageSize) == KERN_SUCCESS && rawPageSize > 0)
            ? Int64(rawPageSize) : Int64(getpagesize())
        let page = { (value: UInt32) in Int64(value) * pageSize }
        let counters = MemoryCounters(
            swapIns: Int64(stats.swapins), swapOuts: Int64(stats.swapouts),
            pageIns: Int64(stats.pageins), pageOuts: Int64(stats.pageouts))
        func rate(_ current: Int64, _ before: Int64?) -> Double {
            guard let before, interval > 0 else { return 0 }
            let delta = current - before
            return delta > 0 ? Double(delta) / interval : 0
        }
        let appBytes = max(0, page(stats.internal_page_count) - page(stats.purgeable_count))
        let wiredBytes = page(stats.wire_count)
        let compressedBytes = page(stats.compressor_page_count)
        let reading = MemoryReading(
            totalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            usedBytes: appBytes + wiredBytes + compressedBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedBytes: page(stats.external_page_count) + page(stats.purgeable_count),
            swapUsedBytes: SystemStatus.swapUsed(),
            swapInPerSecond: rate(counters.swapIns, previous?.swapIns),
            swapOutPerSecond: rate(counters.swapOuts, previous?.swapOuts),
            pageInPerSecond: rate(counters.pageIns, previous?.pageIns),
            pageOutPerSecond: rate(counters.pageOuts, previous?.pageOuts),
            pressureLevel: Int(pressureLevel()))
        return MemorySample(reading: reading, counters: counters)
    }

    static func pressureLevel() -> Int32 {
        Int32(SystemStatus.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
    }
}

/// Hardware block-storage throughput and IOPS from IOKit `IOBlockStorageDriver`.
public enum DiskProbe {
    public struct DiskCounters: Sendable, Equatable {
        public var readBytes: Int64
        public var writeBytes: Int64
        public var readOperations: Int64
        public var writeOperations: Int64

        public init(readBytes: Int64 = 0, writeBytes: Int64 = 0, readOperations: Int64 = 0, writeOperations: Int64 = 0) {
            self.readBytes = readBytes
            self.writeBytes = writeBytes
            self.readOperations = readOperations
            self.writeOperations = writeOperations
        }
    }

    public static func sampleCounters() -> DiskCounters? {
        guard let iterator = IOKitSupport.Iterator(serviceName: "IOBlockStorageDriver") else { return nil }
        defer { IOObjectRelease(iterator.object) }
        var total = DiskCounters()
        var foundAny = false
        while let entry = iterator.next() {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(
                entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            foundAny = true
            total.readBytes += (stats["Bytes (Read)"] as? NSNumber)?.int64Value ?? 0
            total.writeBytes += (stats["Bytes (Write)"] as? NSNumber)?.int64Value ?? 0
            total.readOperations += (stats["Operations (Read)"] as? NSNumber)?.int64Value ?? 0
            total.writeOperations += (stats["Operations (Write)"] as? NSNumber)?.int64Value ?? 0
        }
        return foundAny ? total : nil
    }

    public static func reading(previous: DiskCounters?, current: DiskCounters, interval: TimeInterval) -> DiskIOReading {
        func rate(_ now: Int64, _ before: Int64?) -> Double {
            guard let before, interval > 0, now >= before else { return 0 }
            return Double(now - before) / interval
        }
        return DiskIOReading(
            readBytesPerSecond: rate(current.readBytes, previous?.readBytes),
            writeBytesPerSecond: rate(current.writeBytes, previous?.writeBytes),
            readOperationsPerSecond: rate(current.readOperations, previous?.readOperations),
            writeOperationsPerSecond: rate(current.writeOperations, previous?.writeOperations),
            totalReadBytes: current.readBytes,
            totalWriteBytes: current.writeBytes)
    }
}

/// Interface throughput from the kernel route table (NET_RT_IF_LIST2).
public enum NetworkProbe {
    static let netRTIFList2: Int32 = 6
    static let rtmIfInfo2: UInt8 = 0x12
    static let ifInfo2Stride = 180
    private static let virtualOverlayPrefixes = ["utun", "bridge", "ap", "llw", "awdl"]

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

    /// Reads the route table once, retrying if the table grows (`ENOMEM`).
    public static func sampleCounters() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, netRTIFList2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        for _ in 0..<5 {
            var data = Data(count: size)
            var readSize = size
            let result = data.withUnsafeMutableBytes { pointer in
                sysctl(&mib, 6, pointer.baseAddress, &readSize, nil, 0)
            }
            if result == 0 {
                return parseInterfaceList(Data(data.prefix(readSize)))
            }
            if errno == ENOMEM {
                size = max(readSize, size * 2)
                continue
            }
            return []
        }
        return []
    }

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
        let index = Int(readUInt16(bytes, offset + 12))
        guard index > 0 else { return nil }
        let flags = readUInt32(bytes, offset + 8)
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

    static func interfaceName(_ index: Int) -> String {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &buffer) != nil else {
            return String(format: "if%d", index)
        }
        let characters = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(bytes: characters, encoding: .utf8) ?? String(format: "if%d", index)
    }

    static func isVirtualOverlayInterface(_ name: String) -> Bool {
        virtualOverlayPrefixes.contains { name.hasPrefix($0) }
    }

    static func activePrimaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "com.sakshammittal.tidybyte.network" as CFString, nil, nil) else {
            return nil
        }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let iface = dict["PrimaryInterface"] as? String, !iface.isEmpty {
                return iface
            }
        }
        return nil
    }

    private static func resolvePrimaryInterface(in physical: [InterfaceCounters]) -> String? {
        if let active = activePrimaryInterface(),
           !isVirtualOverlayInterface(active),
           physical.contains(where: { $0.name == active }) {
            return active
        }
        let enInterfaces = physical.filter { $0.name.hasPrefix("en") }
        let pool = enInterfaces.isEmpty ? physical : enInterfaces
        return pool.max { ($0.receivedBytes + $0.sentBytes) < ($1.receivedBytes + $1.sentBytes) }?.name
    }

    /// Diffs two counter snapshots into rates plus boot-to-now totals,
    /// excluding virtual tunnel/bridge overlays so VPN + Wi-Fi never double-count.
    public static func reading(
        previous: [InterfaceCounters]?, current: [InterfaceCounters], interval: TimeInterval
    ) -> NetworkReading {
        let physical = current.filter { !isVirtualOverlayInterface($0.name) }
        let totalDown = physical.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let totalUp = physical.reduce(Int64(0)) { $0 + $1.sentBytes }
        var downloadPerSecond: Double = 0
        var uploadPerSecond: Double = 0
        if let previous, interval > 0 {
            let before = Dictionary(
                previous.filter { !isVirtualOverlayInterface($0.name) }.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first })
            for entry in physical {
                guard let old = before[entry.name] else { continue }
                downloadPerSecond += max(0, Double(entry.receivedBytes - old.receivedBytes) / interval)
                uploadPerSecond += max(0, Double(entry.sentBytes - old.sentBytes) / interval)
            }
        }
        return NetworkReading(
            downloadBytesPerSecond: downloadPerSecond,
            uploadBytesPerSecond: uploadPerSecond,
            totalDownloadBytes: totalDown,
            totalUploadBytes: totalUp,
            primaryInterface: resolvePrimaryInterface(in: physical))
    }

    private static func readUInt8(_ bytes: [UInt8], _ offset: Int) -> UInt8 { bytes[offset] }

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
