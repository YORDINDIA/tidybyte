import Darwin
import Foundation

/// Swift declarations for the libproc calls the monitor needs. These symbols
/// ship in libSystem and are declared in the SDK's libproc.h / sys/resource.h;
/// Swift cannot see the C headers, so the ABI-stable struct layouts are
/// mirrored here exactly as the SDK defines them (see `sys/resource.h`,
/// `struct rusage_info_v4`, and libproc.h `PROC_PIDTASKINFO`).
enum LibProc {
    /// Flavor for proc_pidinfo asking for the task info block.
    static let procPIDTaskInfo: Int32 = 4

    /// proc_taskinfo as the SDK defines it: eighteen 64-bit counters.
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

    /// The subset of `rusage_info_v4` the monitor reads, converted to friendly
    /// units. The kernel returns times in nanoseconds.
    struct UsageReport {
        var cpuTimeSeconds: Double
        var residentBytes: Int64
        var footprintBytes: Int64
        var lifetimeMaxFootprintBytes: Int64
        var intervalMaxFootprintBytes: Int64
        var diskReadBytes: Int64
        var diskWrittenBytes: Int64
        var pageIns: Int64
        var wakeups: Int64
        var energy: Double
        var startedAt: Date?
    }

    /// Reads the per-pid usage report. Returns nil when the process is gone or
    /// protected. `mach_absolute_time` fields are converted with the timebase
    /// and the caller's boot date — one KERN_BOOTTIME sysctl per sample, not
    /// one per process.
    static func usageReport(pid: pid_t, bootDate: Date?) -> UsageReport? {
        var info = RUsageInfoV4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UnsafeMutableRawPointer.self, capacity: 1) { raw in
                procPIDRusage(pid, 4, raw)
            }
        }
        guard result == 0 else { return nil }
        let timebase = machTimebase()
        return UsageReport(
            cpuTimeSeconds: Double(info.userTime + info.systemTime) / 1_000_000_000,
            residentBytes: Int64(bitPattern: info.residentSize),
            footprintBytes: Int64(bitPattern: info.footprint),
            lifetimeMaxFootprintBytes: Int64(bitPattern: info.lifetimeMaxFootprint),
            intervalMaxFootprintBytes: Int64(bitPattern: info.intervalMaxFootprint),
            diskReadBytes: Int64(bitPattern: info.diskRead),
            diskWrittenBytes: Int64(bitPattern: info.diskWrite),
            pageIns: Int64(bitPattern: info.pageIns),
            wakeups: Int64(bitPattern: info.idleWakeups + info.interruptWakeups),
            // billedEnergy is already an energy reading in vendor units, not
            // a floating-point bit pattern; bit-casting it produced nonsense.
            energy: Double(info.billedEnergy),
            startedAt: date(fromMachAbsTime: info.startAbsTime, timebase: timebase, bootDate: bootDate))
    }

    /// Reads the task info block (thread count, page faults). Returns nil when
    /// the pid is gone or the caller cannot inspect it.
    static func taskInfo(pid: pid_t) -> TaskInfo? {
        var info = TaskInfo()
        let size = Int32(MemoryLayout<TaskInfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UnsafeMutableRawPointer.self, capacity: 1) { raw in
                procPIDInfo(pid, procPIDTaskInfo, 0, raw, size)
            }
        }
        guard written == size else { return nil }
        return info
    }

    static func machTimebase() -> (numer: UInt32, denom: UInt32) {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return (base.numer, base.denom)
    }

    static func date(fromMachAbsTime absTime: UInt64, timebase: (numer: UInt32, denom: UInt32), bootDate: Date?) -> Date? {
        guard absTime > 0, let boot = bootDate else { return nil }
        let nanoseconds = absTime * UInt64(timebase.numer) / UInt64(timebase.denom)
        return boot.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
    }
}

/// `struct rusage_info_v4` from the SDK, mirrored field for field. The uuid is
/// skipped by keeping its 16 bytes as a padding prefix so the offsets match.
struct RUsageInfoV4 {
    // The 16 uuid bytes, kept as 2-member tuples so the ABI offsets match
    // struct rusage_info_v4 while staying inside lint limits.
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

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(_ pid: pid_t, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("proc_pidinfo")
private func procPIDInfo(
    _ pid: pid_t, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ bufferSize: Int32) -> Int32
