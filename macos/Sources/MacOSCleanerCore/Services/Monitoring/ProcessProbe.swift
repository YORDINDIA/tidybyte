import Darwin
import Foundation
import os

/// One running process with the cumulative counters its resource usage report
/// provides. Rates (CPU percent, disk bytes per second, energy) are derived by
/// the probe by diffing consecutive samples.
public struct ProcessSample: Sendable, Equatable, Identifiable {
    public var id: pid_t { pid }
    public var pid: pid_t
    public var parentPID: pid_t
    public var name: String
    public var userID: uid_t
    public var state: State
    public var isKernelProcess: Bool
    public var startedAt: Date?
    public var executablePath: String?
    public var bundlePath: String?
    public var bundleID: String?
    public var bundleName: String?
    public var commandLine: [String]
    /// Cumulative CPU time in seconds, user plus system.
    public var cpuTimeSeconds: Double
    public var residentBytes: Int64
    public var virtualBytes: Int64
    public var physFootprintBytes: Int64
    public var diskReadBytes: Int64
    public var diskWrittenBytes: Int64
    public var pageIns: Int64
    public var wakeups: Int64
    public var threadCount: Int32
    /// Derived across the sample interval; zero on the first tick.
    public var cpuPercent: Double
    public var diskReadPerSecond: Double
    public var diskWritePerSecond: Double
    public var wakeupsPerSecond: Double
    /// Vendor energy accounting delta across the interval, in vendor units.
    public var energyDelta: Double
    /// Network rates merged in from the periodic nettop sample.
    public var networkUsage: ProcessNetworkUsage?

    public enum State: String, Sendable { case running, sleeping, stopped, zombie, unknown }

    public init(
        pid: pid_t, parentPID: pid_t = 0, name: String, userID: uid_t = 0, state: State = .unknown,
        isKernelProcess: Bool = false, startedAt: Date? = nil, executablePath: String? = nil,
        bundlePath: String? = nil, bundleID: String? = nil, bundleName: String? = nil,
        commandLine: [String] = [], cpuTimeSeconds: Double = 0, residentBytes: Int64 = 0,
        virtualBytes: Int64 = 0, physFootprintBytes: Int64 = 0, diskReadBytes: Int64 = 0,
        diskWrittenBytes: Int64 = 0, pageIns: Int64 = 0, wakeups: Int64 = 0, threadCount: Int32 = 0,
        cpuPercent: Double = 0, diskReadPerSecond: Double = 0, diskWritePerSecond: Double = 0,
        wakeupsPerSecond: Double = 0, energyDelta: Double = 0, networkUsage: ProcessNetworkUsage? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.userID = userID
        self.state = state
        self.isKernelProcess = isKernelProcess
        self.startedAt = startedAt
        self.executablePath = executablePath
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.bundleName = bundleName
        self.commandLine = commandLine
        self.cpuTimeSeconds = cpuTimeSeconds
        self.residentBytes = residentBytes
        self.virtualBytes = virtualBytes
        self.physFootprintBytes = physFootprintBytes
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.pageIns = pageIns
        self.wakeups = wakeups
        self.threadCount = threadCount
        self.cpuPercent = cpuPercent
        self.diskReadPerSecond = diskReadPerSecond
        self.diskWritePerSecond = diskWritePerSecond
        self.wakeupsPerSecond = wakeupsPerSecond
        self.energyDelta = energyDelta
        self.networkUsage = networkUsage
    }
}

/// Samples the process table with public system interfaces: the sysctl
/// kinfo_proc table for identity and parentage, and per-pid resource usage
/// reports (proc_pidinfo / proc_pid_rusage) for the cumulative counters that
/// turn into rates. Diffing happens inside the actor, which keeps the previous
/// tick's counters.
public actor ProcessProbe {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ProcessProbe")
    /// pid → cumulative counters from the previous tick.
    private var previousUsage: [pid_t: ProcessUsageCounters] = [:]
    /// pid → executable path cached across ticks. proc_pidpath is a
    /// KERN_PROCARGS read per pid otherwise, ~500 per tick at 1 Hz.
    private var executablePaths: [pid_t: String] = [:]
    private var previousTimestamp: Date?
    private var appResolver = AppIdentityResolver()

    struct ProcessUsageCounters: Sendable {
        var cpuTimeSeconds: Double
        var diskReadBytes: Int64
        var diskWrittenBytes: Int64
        var wakeups: Int64
        var energy: Double
    }

    public init() {}

    /// Samples every process. `includeCommandLine` fetches argv (a second
    /// sysctl per pid); the inspector needs it, the per-second tick does not.
    public func sample(includeCommandLine: Bool = false) -> [ProcessSample] {
        let entries = Self.kernelProcessTable()
        let now = Date()
        // KERN_BOOTTIME is constant for the session: one sysctl per sample,
        // not one per process.
        let bootDate = Self.bootDate()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(entries.count)
        var seen = Set<pid_t>()

        for entry in entries {
            let pid = pid_t(entry.kp_proc.p_pid)
            seen.insert(pid)
            var sample = baseSample(from: entry, pid: pid, bootDate: bootDate)
            applyUsageReport(to: &sample, now: now, bootDate: bootDate)
            if sample.executablePath == nil {
                // Only pids never seen before pay the proc_pidpath read.
                if let cached = executablePaths[pid] {
                    sample.executablePath = cached
                } else if let path = Self.executablePath(of: pid) {
                    executablePaths[pid] = path
                    sample.executablePath = path
                }
            }
            resolveBundleIdentity(for: &sample)
            if includeCommandLine, sample.commandLine.isEmpty {
                sample.commandLine = Self.commandLine(of: pid) ?? []
            }
            samples.append(sample)
        }

        // An empty table is a transient read failure, not mass process death;
        // wiping the counters then would make the next tick's rates wrong.
        if !samples.isEmpty {
            // Drop counters and cached paths of processes that exited so
            // reused pids cannot inherit stale state, and prune stale bundle
            // identities.
            previousUsage = previousUsage.filter { seen.contains($0.key) }
            executablePaths = executablePaths.filter { seen.contains($0.key) }
            appResolver.prune(keptPaths: Set(samples.compactMap(\.executablePath)))
            previousTimestamp = now
        }
        return samples
    }

    private func baseSample(from entry: kinfo_proc, pid: pid_t, bootDate: Date?) -> ProcessSample {
        let proc = entry.kp_proc
        let eproc = entry.kp_eproc
        let state: ProcessSample.State = switch Int32(proc.p_stat) {
        case SRUN: .running
        case SSLEEP: .sleeping
        case SSTOP: .stopped
        case SZOMB: .zombie
        default: .unknown
        }
        let started = Self.date(fromTimeInterval: proc.p_starttime, bootDate: bootDate)
        return ProcessSample(
            pid: pid,
            parentPID: pid_t(eproc.e_ppid),
            name: Self.displayName(proc: proc, pid: pid),
            userID: eproc.e_ucred.cr_uid,
            state: state,
            isKernelProcess: Int32(proc.p_flag) & P_SYSTEM != 0,
            startedAt: started,
            networkUsage: nil)
    }

    /// Merges the per-pid usage report and turns counter deltas into rates
    /// using the time since this pid's previous report.
    private func applyUsageReport(to sample: inout ProcessSample, now: Date, bootDate: Date?) {
        guard let usage = LibProc.usageReport(pid: sample.pid, bootDate: bootDate) else { return }
        let counters = ProcessUsageCounters(
            cpuTimeSeconds: usage.cpuTimeSeconds,
            diskReadBytes: usage.diskReadBytes,
            diskWrittenBytes: usage.diskWrittenBytes,
            wakeups: usage.wakeups,
            energy: usage.energy)
        sample.cpuTimeSeconds = usage.cpuTimeSeconds
        sample.residentBytes = usage.residentBytes
        sample.physFootprintBytes = usage.footprintBytes
        sample.diskReadBytes = usage.diskReadBytes
        sample.diskWrittenBytes = usage.diskWrittenBytes
        sample.pageIns = usage.pageIns
        sample.wakeups = usage.wakeups
        // The usage report does not carry thread or virtual-memory figures;
        // the task info block does, and protected processes simply report 0.
        if let task = LibProc.taskInfo(pid: sample.pid) {
            sample.threadCount = task.threadCount
            sample.virtualBytes = Int64(bitPattern: task.virtualSize)
        }
        if let start = usage.startedAt { sample.startedAt = start }

        if let previous = previousUsage[sample.pid] {
            let interval = max(0.001, previousTimestamp.map { now.timeIntervalSince($0) } ?? 1)
            let delta = Self.rates(from: previous, to: counters, interval: interval)
            sample.cpuPercent = delta.cpuPercent
            sample.diskReadPerSecond = delta.diskReadPerSecond
            sample.diskWritePerSecond = delta.diskWritePerSecond
            sample.wakeupsPerSecond = delta.wakeupsPerSecond
            sample.energyDelta = delta.energyDelta
        }
        previousUsage[sample.pid] = counters
    }

    private func resolveBundleIdentity(for sample: inout ProcessSample) {
        guard let path = sample.executablePath, sample.bundlePath == nil else { return }
        let identity = appResolver.identity(forExecutablePath: path)
        sample.bundlePath = identity?.bundlePath
        sample.bundleID = identity?.bundleID
        sample.bundleName = identity?.displayName
    }
}

// MARK: - Rate math (pure, testable)

extension ProcessProbe {
    struct UsageRates: Sendable, Equatable {
        var cpuPercent: Double
        var diskReadPerSecond: Double
        var diskWritePerSecond: Double
        var wakeupsPerSecond: Double
        var energyDelta: Double
    }

    /// Turns two cumulative counter snapshots into per-second rates. Counters
    /// that went backwards (pid reuse) produce zero rather than negative rates.
    static func rates(from previous: ProcessUsageCounters, to current: ProcessUsageCounters, interval: TimeInterval)
        -> UsageRates {
        let step = max(0.001, interval)
        func rate(_ previousValue: Double, _ currentValue: Double) -> Double {
            guard currentValue >= previousValue else { return 0 }
            return (currentValue - previousValue) / step
        }
        let cpuSeconds = rate(previous.cpuTimeSeconds, current.cpuTimeSeconds)
        return UsageRates(
            cpuPercent: min(100 * Double(ProcessInfo.processInfo.processorCount), cpuSeconds * 100),
            diskReadPerSecond: rate(Double(previous.diskReadBytes), Double(current.diskReadBytes)),
            diskWritePerSecond: rate(Double(previous.diskWrittenBytes), Double(current.diskWrittenBytes)),
            wakeupsPerSecond: rate(Double(previous.wakeups), Double(current.wakeups)),
            energyDelta: max(0, current.energy - previous.energy))
    }
}

// MARK: - System calls (pure-ish, testable with injected buffers)

extension ProcessProbe {
    /// The kernel process table, or an empty array if sysctl fails.
    static func kernelProcessTable() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the sizing call and the read. A failed
        // read leaves the required size in readSize; retry with it while it
        // actually grew, and give up on any other failure.
        for _ in 0..<3 {
            let stride = MemoryLayout<kinfo_proc>.stride
            var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 1)
            var readSize = entries.count * stride
            guard sysctl(&mib, 3, &entries, &readSize, nil, 0) == 0 else {
                guard readSize > entries.count * stride else { return [] }
                size = readSize
                continue
            }
            return Array(entries.prefix(readSize / stride))
        }
        return []
    }

    static func displayName(proc: extern_proc, pid: pid_t) -> String {
        let comm = withUnsafeBytes(of: proc.p_comm) { bytes -> String in
            let view = bytes.prefix(while: { $0 != 0 })
            return String(bytes: view, encoding: .utf8) ?? ""
        }
        if !comm.isEmpty { return comm }
        return executablePath(of: pid).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(pid)"
    }

    /// Absolute path of the executable, via libproc. Returns nil for processes
    /// this user cannot inspect (other users, sandboxed system services).
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// argv as the kernel recorded it at exec time, via KERN_PROCARGS2.
    static func commandLine(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = Data(count: size)
        var readSize = size
        let result = data.withUnsafeMutableBytes { pointer in
            sysctl(&mib, 3, pointer.baseAddress, &readSize, nil, 0)
        }
        guard result == 0, readSize >= MemoryLayout<Int32>.size else { return nil }
        return parseArguments(data.prefix(readSize))
    }

    /// KERN_PROCARGS2 layout: a native-endian int32 argc, the executable
    /// path, zero padding, then argv[0…argc-1] and finally the environment
    /// block. Returns argv without argv[0] duplicating the executable path.
    static func parseArguments(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        let argcSize = MemoryLayout<Int32>.size
        guard bytes.count > argcSize else { return [] }
        // Host (little-endian on Apple hardware) int32 argc, composed from
        // bytes so no force-unsafe pointer rebinding is needed.
        let argcBits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let argc = Int(Int32(bitPattern: argcBits))
        guard argc > 0, argc < 4096 else { return [] }
        var strings: [String] = []
        var index = argcSize
        while index < bytes.count {
            while index < bytes.count, bytes[index] == 0 { index += 1 }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            if index > start {
                strings.append(String(bytes: bytes[start..<index], encoding: .utf8) ?? "")
            }
            index += 1
        }
        // First string is the executable path; argv follows, argc entries.
        return Array(strings.dropFirst().prefix(argc))
    }

    /// Converts the kernel's boot-relative timeval into an absolute date.
    static func date(fromTimeInterval timeval: timeval, bootDate: Date?) -> Date? {
        guard timeval.tv_sec > 0 || timeval.tv_usec > 0 else { return nil }
        let seconds = Double(timeval.tv_sec) + Double(timeval.tv_usec) / 1_000_000
        // p_starttime is wall-clock based on this kernel generation; compare
        // against boot time rather than "now" so long uptime stays correct.
        guard let boot = bootDate else { return nil }
        return boot.addingTimeInterval(seconds)
    }

    public static func bootDate() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    public static func uptime(now: Date = .init()) -> TimeInterval {
        guard let boot = bootDate() else { return 0 }
        return now.timeIntervalSince(boot)
    }

    public struct LoadAverage: Sendable, Equatable {
        public var one = 0.0
        public var five = 0.0
        public var fifteen = 0.0
    }

    public static func loadAverage() -> LoadAverage {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return LoadAverage() }
        return LoadAverage(one: values[0], five: values[1], fifteen: values[2])
    }
}
