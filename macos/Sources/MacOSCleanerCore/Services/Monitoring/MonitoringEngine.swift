import Foundation
import os

/// UserDefaults-backed settings for the monitoring feature. All values have
/// defaults so the engine runs before Settings is ever opened.
@MainActor
public final class MonitoringSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Seconds between ticks. Faster means smoother charts and more battery.
    public var intervalSeconds: Double {
        get { defaults.object(forKey: MonitoringKeys.intervalSeconds) as? Double ?? 2 }
        set { defaults.set(newValue, forKey: MonitoringKeys.intervalSeconds) }
    }

    /// Days of history kept. The engine prunes beyond this.
    public var historyRetentionDays: Int {
        get { defaults.object(forKey: MonitoringKeys.historyRetentionDays) as? Int ?? 365 }
        set { defaults.set(newValue, forKey: MonitoringKeys.historyRetentionDays) }
    }

    public var isAlertsEnabled: Bool {
        get { defaults.object(forKey: MonitoringKeys.alertsEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertsEnabled) }
    }

    /// Sustained CPU percentage that triggers an alert.
    public var alertCPUPercent: Double {
        get { defaults.object(forKey: MonitoringKeys.alertCPUPercent) as? Double ?? 70 }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertCPUPercent) }
    }

    public var alertCPUWindowMinutes: Double {
        get { defaults.object(forKey: MonitoringKeys.alertCPUWindowMinutes) as? Double ?? 10 }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertCPUWindowMinutes) }
    }

    /// Memory growth over an hour that triggers an alert.
    public var alertMemoryGrowthBytes: Int64 {
        get { defaults.object(forKey: MonitoringKeys.alertMemoryGrowthBytes) as? Int64 ?? 1_500_000_000 }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertMemoryGrowthBytes) }
    }

    public var alertDiskBytesPerSecond: Double {
        get { defaults.object(forKey: MonitoringKeys.alertDiskBytesPerSecond) as? Double ?? 80_000_000 }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertDiskBytesPerSecond) }
    }

    public var alertNetworkBytesPerSecond: Double {
        get { defaults.object(forKey: MonitoringKeys.alertNetworkBytesPerSecond) as? Double ?? 50_000_000 }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertNetworkBytesPerSecond) }
    }

    public var isCompactDensity: Bool {
        get { defaults.bool(forKey: MonitoringKeys.density) }
        set { defaults.set(newValue, forKey: MonitoringKeys.density) }
    }

    public var usesColorblindPalette: Bool {
        get { defaults.bool(forKey: MonitoringKeys.colorblindPalette) }
        set { defaults.set(newValue, forKey: MonitoringKeys.colorblindPalette) }
    }

    /// Whether the combined menu bar panel extra is inserted. Unset mirrors
    /// the scenes' `true` default.
    public var isMenuBarPanelEnabled: Bool {
        defaults.object(forKey: MonitoringKeys.menuBarPanelEnabled) as? Bool ?? true
    }

    /// True when any per-metric menu bar extra is enabled, so the engine can
    /// tell whether any surface is showing monitor data.
    public var hasEnabledMenuBarMetric: Bool {
        MonitoringKeys.menuBarMetrics.contains {
            defaults.object(forKey: $0.key) as? Bool ?? $0.defaultEnabled
        }
    }
}

/// The sampling loop. One tick gathers the cheap probes every interval and
/// rotates the expensive ones (lsof, docker, bluetooth, per-process network)
/// on slower cadences, then publishes the snapshot and hands it to the
/// history store and alert engine.
public actor MonitoringEngine {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "MonitoringEngine")

    private let processProbe = ProcessProbe()
    private let sensors = SMCSensors()
    private let history: MetricsHistoryStore?
    private let alertEngine: AlertEngine?
    /// Lightweight mode (the CLI) skips the probes that can take seconds —
    /// docker, bluetooth, pmset — so `monitor status` stays snappy.
    private let isLightweight: Bool
    /// False drops the per-process detail round (nettop, dev servers, agent
    /// sessions) that tools like `monitor status` never read.
    private let includesSlowProbes: Bool

    private var previousCPUTicks: HostProbes.CPUTicks?
    private var previousMemoryCounters: HostProbes.MemoryCounters?
    private var previousNetworkCounters: [NetworkProbe.InterfaceCounters]?
    private var previousTimestamp: Date?
    private var cachedBluetooth: [BluetoothDeviceReading] = []
    private var cachedNetworkPerProcess: [pid_t: ProcessNetworkUsage] = [:]
    private var cachedContainers: [ContainerReading] = []
    private var cachedAgents: [AgentSessionReading] = []
    private var cachedDevServers: [DevServerReading] = []
    private var cachedPower = PowerReading()
    private var lastRecordAt: Date?

    /// Days of history the store keeps; Settings keeps this in sync.
    public var historyRetentionDays: Int = 365

    /// Settings-driven retention; called from the UI each tick.
    public func setRetentionDays(_ days: Int) {
        historyRetentionDays = max(MetricsHistoryStore.minimumRetentionDays, days)
    }

    /// Slow-path counters; each expensive probe runs this many ticks apart.
    private var tickCounter = 0

    public init(
        history: MetricsHistoryStore?, alertEngine: AlertEngine?, isLightweight: Bool = false,
        includesSlowProbes: Bool = true
    ) {
        self.history = history
        self.alertEngine = alertEngine
        self.isLightweight = isLightweight
        self.includesSlowProbes = includesSlowProbes
    }

    /// Grouping granularity the user picked; the model keeps it in sync.
    public var groupingMode: AppProcessCatalog.GroupingMode = .byApp

    /// The UI calls this when the grouping picker changes; the next tick (and
    /// every tick after) groups under the new mode.
    public func setGroupingMode(_ mode: AppProcessCatalog.GroupingMode) {
        groupingMode = mode
    }

    /// One full sample. `tick` controls slow-path cadence; tests can drive it.
    public func sample(interval: TimeInterval) async -> SystemSnapshot {
        tickCounter += 1
        let processes = await processProbe.sample()
        let now = Date()
        let elapsed = previousTimestamp.map { max(0.001, now.timeIntervalSince($0)) } ?? interval

        let cpuTicks = HostProbes.cpuTicks()
        let cpu = HostProbes.cpuReading(
            ticks: cpuTicks, previous: previousCPUTicks, logicalCores: HostProbes.logicalCoreCount)
        previousCPUTicks = cpuTicks

        let memory = HostProbes.memoryReading(previous: previousMemoryCounters, interval: elapsed)
        previousMemoryCounters = memory.counters

        // One route-table read per tick: sample here, diff the snapshots.
        let networkCounters = NetworkProbe.sampleCounters()
        let network = NetworkProbe.reading(
            previous: previousNetworkCounters, current: networkCounters, interval: elapsed)
        previousNetworkCounters = networkCounters
        previousTimestamp = now

        // System-wide disk rate: the sum of per-process rusage deltas is the
        // honest public-API approximation of disk activity.
        let diskRate = DiskActivity.rate(processes: processes)

        await refreshSlowPaths(processes: processes)

        let groups = AppProcessCatalog.group(processes, mode: groupingMode, networkUsage: cachedNetworkPerProcess)
        let snapshot = SystemSnapshot(
            timestamp: now,
            interval: elapsed,
            cpu: cpu,
            memory: memory.reading,
            disk: DiskIOReading(
                readBytesPerSecond: diskRate.read, writeBytesPerSecond: diskRate.write,
                totalReadBytes: nil, totalWriteBytes: nil),
            network: network,
            gpu: GPUReading(devices: GPUProbe.devices()),
            neural: NeuralEngineProbe.reading(),
            power: cachedPower,
            sensors: await sensors.temperatures(),
            fans: await sensors.fans(),
            audio: AudioProbe.reading(),
            bluetooth: cachedBluetooth,
            processes: processes,
            groups: groups,
            devServers: cachedDevServers,
            agents: cachedAgents,
            containers: cachedContainers,
            uptime: ProcessProbe.uptime(now: now))

        await publish(snapshot, now: now)
        return snapshot
    }

    /// Hands one snapshot to the history store and the alert engine. History
    /// records at most every 15 seconds (charts stay coarse anyway), while
    /// retention pruning runs every tick and self-throttles to daily.
    private func publish(_ snapshot: SystemSnapshot, now: Date) async {
        if let history {
            let shouldRecord = lastRecordAt.map { now.timeIntervalSince($0) >= 15 } ?? true
            if shouldRecord {
                lastRecordAt = now
                await history.record(snapshot)
            }
            await history.pruneIfExpired(retentionDays: historyRetentionDays, now: now)
        }
        if let alertEngine {
            await alertEngine.evaluate(snapshot)
        }
    }

    /// Expensive probes run on rotating cadences so no tick pays for all of
    /// them: network per process and ports every 8 ticks, power every 15,
    /// docker every 15, bluetooth every 30. Lightweight mode (the CLI) drops
    /// docker and bluetooth entirely and reads power without pmset.
    private func refreshSlowPaths(processes: [ProcessSample]) async {
        if includesSlowProbes, tickCounter % 8 == 1 {
            async let network: Void = refreshNetworkPerProcess(processes)
            async let devServers: Void = refreshDevServers(processes: processes)
            async let agents: Void = refreshAgents(processes: processes)
            _ = await (network, devServers, agents)
        }
        if tickCounter % 15 == 1 {
            cachedPower = isLightweight ? await PowerProbe.batteryReading() : await PowerProbe.reading()
        }
        // Docker and system_profiler each take seconds; refresh them in an
        // actor-isolated task so the sampling actor stays free while the
        // probe awaits and the tick cadence never hiccups.
        if tickCounter % 15 == 2, !isLightweight {
            Task { cachedContainers = await ContainerProbe.containers() }
        }
        if tickCounter % 30 == 3, !isLightweight {
            Task { cachedBluetooth = await BluetoothProbe.devices() }
        }
    }

    private func refreshNetworkPerProcess(_ processes: [ProcessSample]) async {
        guard let output = try? await SystemTool.run("/usr/bin/nettop", arguments: [
            "-P", "-x", "-L", "1"
        ]) else { return }
        let rates = Self.parseNettopCSV(output)
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(grouping: processes, by: { $0.name })
        var merged: [pid_t: ProcessNetworkUsage] = [:]
        for row in rates {
            let usage = ProcessNetworkUsage(
                downloadPerSecond: row.downloadPerSecond, uploadPerSecond: row.uploadPerSecond)
            // The nettop identifier carries the pid; match on it first.
            if let pid = row.pid, let match = byPID[pid] {
                merged[match.pid] = usage
                continue
            }
            // Name fallback (pid truncated or process gone): attach to at
            // most one same-named candidate, never the whole fleet.
            guard let candidate = byName[row.name]?.first, merged[candidate.pid] == nil else { continue }
            merged[candidate.pid] = usage
        }
        cachedNetworkPerProcess = merged
    }

    /// One nettop row: the process name, the pid when the identifier carried
    /// one, and the two rate columns.
    public struct NettopRow: Sendable, Equatable {
        public var name: String
        public var pid: pid_t?
        public var downloadPerSecond: Double
        public var uploadPerSecond: Double
    }

    /// nettop logging mode is CSV with a header row: time, then per-process
    /// rows of `name.pid,bytes_in,bytes_out` style columns. This is a best
    /// effort parser over the stable `-P -x -L 1` shape.
    public static func parseNettopCSV(_ output: String) -> [NettopRow] {
        var result: [NettopRow] = []
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return result }
        // Header-driven layout: time, process ("name.pid"), then byte
        // counters. Rate columns win when nettop emits them.
        let header = lines[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        func column(_ candidates: [String]) -> Int? {
            candidates.compactMap { header.firstIndex(of: $0) }.first
        }
        let processIndex = column(["process"]) ?? 1
        let inIndex = column(["bytes_in_per_s", "bytes_in"]) ?? 2
        let outIndex = column(["bytes_out_per_s", "bytes_out"]) ?? 3
        for line in lines.dropFirst() {
            let columns = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count > max(inIndex, outIndex, processIndex) else { continue }
            let identifier = columns[processIndex]
            // "Safari.123" → name "Safari", pid 123; a name that does not end
            // in a numeric pid stays whole.
            var name = identifier
            var pid: pid_t?
            if let lastDot = identifier.lastIndex(of: ".") {
                let suffix = identifier[identifier.index(after: lastDot)...]
                if let value = pid_t(suffix), suffix.allSatisfy(\.isNumber) {
                    pid = value
                    name = String(identifier[identifier.startIndex..<lastDot])
                }
            }
            guard let bytesIn = Double(columns[inIndex]), let bytesOut = Double(columns[outIndex]) else {
                continue
            }
            result.append(
                NettopRow(
                    name: name, pid: pid,
                    downloadPerSecond: bytesIn, uploadPerSecond: bytesOut))
        }
        return result
    }

    private func refreshDevServers(processes: [ProcessSample]) async {
        cachedDevServers = await DevEnvironmentProbe.servers(processes: processes)
    }

    private func refreshAgents(processes: [ProcessSample]) async {
        let workingDirectories = await DevEnvironmentProbe.workingDirectories(
            pids: Set(processes.filter { AgentProbe.kind(of: $0) != nil }.map(\.pid)))
        cachedAgents = await AgentProbe.sessions(processes: processes, workingDirectories: workingDirectories)
    }

    /// Restores fan control the session changed; called on app quit.
    public func shutdown() async {
        await sensors.restoreFanControl()
    }

    /// Re-groups a snapshot's processes under a new granularity without a new
    /// tick, so the table updates the moment the picker changes.
    public func regroup(
        snapshot: SystemSnapshot, mode: AppProcessCatalog.GroupingMode
    ) async -> SystemSnapshot? {
        guard !snapshot.processes.isEmpty else { return nil }
        var updated = snapshot
        updated.groups = AppProcessCatalog.group(
            snapshot.processes, mode: mode, networkUsage: cachedNetworkPerProcess)
        return updated
    }
}

/// System-wide disk rate from per-process disk counters.
enum DiskActivity {
    static func rate(processes: [ProcessSample]) -> (read: Double, write: Double) {
        let read = processes.reduce(0.0) { $0 + max(0, $1.diskReadPerSecond) }
        let write = processes.reduce(0.0) { $0 + max(0, $1.diskWritePerSecond) }
        return (read, write)
    }
}
