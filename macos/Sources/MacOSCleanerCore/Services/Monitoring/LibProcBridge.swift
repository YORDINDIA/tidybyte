import Darwin
import Foundation

/// Swift declarations for the libproc calls the monitor needs. These symbols
/// ship in libSystem and are declared in the SDK's libproc.h / sys/resource.h;
/// Swift cannot see the C headers directly, so the ABI-stable struct layouts
/// are mirrored here (`rusage_info_v4`, `rusage_info_v6`, `PROC_PIDTASKINFO`).
enum LibProc {
    static let procPIDTaskInfo: Int32 = 4
    static let rusageFlavorV4: Int32 = 4
    static let rusageFlavorV6: Int32 = 6

    struct TaskInfo {
        var virtualSize: UInt64 = 0
        var residentSize: UInt64 = 0
        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var threadsUser: UInt64 = 0
        var threadsSystem: UInt64 = 0
        var policy: Int32 = 0
        var faults: Int32 = 0
        var pageins: Int32 = 0
        var cowFaults: Int32 = 0
        var messagesSent: Int32 = 0
        var messagesReceived: Int32 = 0
        var syscallsMach: Int32 = 0
        var syscallsUnix: Int32 = 0
        var contextSwitches: Int32 = 0
        var threadCount: Int32 = 0
        var numRunning: Int32 = 0
        var priority: Int32 = 0
    }

    struct UsageReport {
        var cpuTimeSeconds: Double
        var pCoreTimeSeconds: Double?
        var residentBytes: Int64
        var footprintBytes: Int64
        var lifetimeMaxFootprintBytes: Int64
        var intervalMaxFootprintBytes: Int64
        var diskReadBytes: Int64
        var diskWrittenBytes: Int64
        var pageIns: Int64
        var wakeups: Int64
        var energy: Double
        var energyNanojoules: UInt64?
    }

    private static let cachedTimebase: (numer: UInt32, denom: UInt32) = machTimebase()

    /// Reads the per-pid usage report, preferring `rusage_info_v6` for nanojoule
    /// energy and P-core accounting and falling back to `rusage_info_v4`.
    static func usageReport(pid: pid_t) -> UsageReport? {
        var v6 = RUsageInfoV6()
        let v6Status = withUnsafeMutableBytes(of: &v6) { raw in
            procPIDRusage(pid, rusageFlavorV6, raw.baseAddress)
        }
        if v6Status == 0 {
            return makeReport(v4: v6.v4, v6: v6)
        }
        var v4 = RUsageInfoV4()
        let v4Status = withUnsafeMutableBytes(of: &v4) { raw in
            procPIDRusage(pid, rusageFlavorV4, raw.baseAddress)
        }
        guard v4Status == 0 else { return nil }
        return makeReport(v4: v4, v6: nil)
    }

    private static func makeReport(v4 info: RUsageInfoV4, v6: RUsageInfoV6?) -> UsageReport {
        let timebase = cachedTimebase
        let scale = Double(timebase.numer) / Double(max(1, timebase.denom)) / 1_000_000_000
        let cpuSeconds = Double(info.userTime + info.systemTime) * scale
        let pCoreSeconds = v6.map { Double($0.userPTime + $0.systemPTime) * scale }
        let energyNJ = v6.flatMap { $0.energyNanojoules > 0 ? $0.energyNanojoules : nil }
        let energy = info.billedEnergy > 0
            ? Double(info.billedEnergy)
            : Double(energyNJ ?? 0) / 1_000_000.0
        return UsageReport(
            cpuTimeSeconds: cpuSeconds,
            pCoreTimeSeconds: pCoreSeconds,
            residentBytes: Int64(bitPattern: info.residentSize),
            footprintBytes: Int64(bitPattern: info.footprint),
            lifetimeMaxFootprintBytes: Int64(bitPattern: info.lifetimeMaxFootprint),
            intervalMaxFootprintBytes: Int64(bitPattern: info.intervalMaxFootprint),
            diskReadBytes: Int64(bitPattern: info.diskRead),
            diskWrittenBytes: Int64(bitPattern: info.diskWrite),
            pageIns: Int64(bitPattern: info.pageIns),
            wakeups: Int64(bitPattern: info.idleWakeups + info.interruptWakeups),
            energy: energy,
            energyNanojoules: energyNJ)
    }

    /// Reads the task info block (thread count, page faults). Returns nil when
    /// the pid is gone or the caller cannot inspect it.
    static func taskInfo(pid: pid_t) -> TaskInfo? {
        var info = TaskInfo()
        let size = Int32(MemoryLayout<TaskInfo>.size)
        let written = withUnsafeMutableBytes(of: &info) { raw in
            procPIDInfo(pid, procPIDTaskInfo, 0, raw.baseAddress, size)
        }
        guard written == size else { return nil }
        return info
    }

    static let procPIDTBSDInfo: Int32 = 3
    static let bsdInfoSize = 136

    static func startTime(pid: pid_t) -> (seconds: Int64, microseconds: Int64)? {
        var raw = [UInt8](repeating: 0, count: bsdInfoSize)
        let written = raw.withUnsafeMutableBytes { buffer in
            procPIDInfo(pid, procPIDTBSDInfo, 0, buffer.baseAddress, Int32(bsdInfoSize))
        }
        guard written == Int32(bsdInfoSize) else { return nil }
        return raw.withUnsafeBytes { bytes in
            (seconds: Int64(bitPattern: bytes.loadUnaligned(fromByteOffset: 120, as: UInt64.self)),
             microseconds: Int64(bitPattern: bytes.loadUnaligned(fromByteOffset: 128, as: UInt64.self)))
        }
    }

    static func machTimebase() -> (numer: UInt32, denom: UInt32) {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return (base.numer, base.denom)
    }
}

/// `struct rusage_info_v4` from the SDK (296 bytes), mirrored field for field.
struct RUsageInfoV4 {
    var uuidPaddingA: (UInt8, UInt8) = (0, 0)
    var uuidPaddingB: (UInt8, UInt8) = (0, 0)
    var uuidPaddingC: (UInt8, UInt8) = (0, 0)
    var uuidPaddingD: (UInt8, UInt8) = (0, 0)
    var uuidPaddingE: (UInt8, UInt8) = (0, 0)
    var uuidPaddingF: (UInt8, UInt8) = (0, 0)
    var uuidPaddingG: (UInt8, UInt8) = (0, 0)
    var uuidPaddingH: (UInt8, UInt8) = (0, 0)
    var userTime: UInt64 = 0
    var systemTime: UInt64 = 0
    var idleWakeups: UInt64 = 0
    var interruptWakeups: UInt64 = 0
    var pageIns: UInt64 = 0
    var wiredSize: UInt64 = 0
    var residentSize: UInt64 = 0
    var footprint: UInt64 = 0
    var startAbsTime: UInt64 = 0
    var exitAbsTime: UInt64 = 0
    var childUserTime: UInt64 = 0
    var childSystemTime: UInt64 = 0
    var childIdleWakeups: UInt64 = 0
    var childInterruptWakeups: UInt64 = 0
    var childPageIns: UInt64 = 0
    var childElapsedAbsTime: UInt64 = 0
    var diskRead: UInt64 = 0
    var diskWrite: UInt64 = 0
    var qosDefaultTime: UInt64 = 0
    var qosMaintenanceTime: UInt64 = 0
    var qosBackgroundTime: UInt64 = 0
    var qosUtilityTime: UInt64 = 0
    var qosLegacyTime: UInt64 = 0
    var qosUserInitiatedTime: UInt64 = 0
    var qosUserInteractiveTime: UInt64 = 0
    var billedSystemTime: UInt64 = 0
    var servicedSystemTime: UInt64 = 0
    var logicalWrites: UInt64 = 0
    var lifetimeMaxFootprint: UInt64 = 0
    var instructions: UInt64 = 0
    var cycles: UInt64 = 0
    var billedEnergy: UInt64 = 0
    var servicedEnergy: UInt64 = 0
    var intervalMaxFootprint: UInt64 = 0
    var runnableTime: UInt64 = 0
}

/// `struct rusage_info_v6` from the SDK (464 bytes): v4 prefix + Apple Silicon
/// P-core, nanojoule energy, neural footprint, and page-cache counters.
struct RUsageInfoV6 {
    var v4 = RUsageInfoV4()
    var flags: UInt64 = 0
    var userPTime: UInt64 = 0
    var systemPTime: UInt64 = 0
    var pInstructions: UInt64 = 0
    var pCycles: UInt64 = 0
    var energyNanojoules: UInt64 = 0
    var pEnergyNanojoules: UInt64 = 0
    var secureTimeInSystem: UInt64 = 0
    var securePTimeInSystem: UInt64 = 0
    var neuralFootprint: UInt64 = 0
    var lifetimeMaxNeuralFootprint: UInt64 = 0
    var intervalMaxNeuralFootprint: UInt64 = 0
    var conclaveFootprint: UInt64 = 0
    var pageWaitTimeMach: UInt64 = 0
    var pageCacheHits: UInt64 = 0
    var reserved0: UInt64 = 0
    var reserved1: UInt64 = 0
    var reserved2: UInt64 = 0
    var reserved3: UInt64 = 0
    var reserved4: UInt64 = 0
    var reserved5: UInt64 = 0
}

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(_ pid: pid_t, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("proc_pidinfo")
private func procPIDInfo(
    _ pid: pid_t, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ bufferSize: Int32) -> Int32
