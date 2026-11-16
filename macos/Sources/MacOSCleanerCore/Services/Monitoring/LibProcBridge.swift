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
    /// units. The kernel returns CPU times in mach absolute time units. Those
    /// are nanoseconds only on Intel; Apple silicon runs a 125/3 timebase.
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
    }

    /// Reads the per-pid usage report. Returns nil when the process is gone or
    /// protected. Mach absolute time fields are converted with the timebase.
    static func usageReport(pid: pid_t) -> UsageReport? {
        var info = RUsageInfoV4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UnsafeMutableRawPointer.self, capacity: 1) { raw in
                procPIDRusage(pid, 4, raw)
            }
        }
        guard result == 0 else { return nil }
        let timebase = machTimebase()
        // Reading the raw ticks as nanoseconds made CPU time 42x too low on Apple silicon.
        let cpuNanoseconds = Double(info.userTime + info.systemTime) * Double(timebase.numer) / Double(timebase.denom)
        return UsageReport(
            cpuTimeSeconds: cpuNanoseconds / 1_000_000_000,
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
            energy: Double(info.billedEnergy))
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

    /// PROC_PIDTBSDINFO and the size of struct proc_bsdinfo. The start time is
    /// the last 16 bytes: pbi_start_tvsec at offset 120, pbi_start_tvusec at 128.
    /// Tests check both offsets against the kernel process table.
    static let procPIDTBSDInfo: Int32 = 3
    static let bsdInfoSize = 136

    /// The kernel start time of the live process at `pid`, or nil when it is gone
    /// or not visible to this user. The same p_start value the process table carries.
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
