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

    public var intervalSeconds: Double {
        get { defaults.object(forKey: MonitoringKeys.intervalSeconds) as? Double ?? MonitoringDefaults.intervalSeconds }
        set { defaults.set(newValue, forKey: MonitoringKeys.intervalSeconds) }
    }

    public var historyRetentionDays: Int {
        get { defaults.object(forKey: MonitoringKeys.historyRetentionDays) as? Int ?? MonitoringDefaults.historyRetentionDays }
        set { defaults.set(newValue, forKey: MonitoringKeys.historyRetentionDays) }
    }

    public var isAlertsEnabled: Bool {
        get { defaults.object(forKey: MonitoringKeys.alertsEnabled) as? Bool ?? MonitoringDefaults.alertsEnabled }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertsEnabled) }
    }

    /// Sustained system-CPU share (0...100%, normalized by logical cores).
    public var alertCPUPercent: Double {
        get { defaults.object(forKey: MonitoringKeys.alertCPUPercent) as? Double ?? MonitoringDefaults.alertCPUPercent }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertCPUPercent) }
    }

    public var alertCPUWindowMinutes: Double {
        get { defaults.object(forKey: MonitoringKeys.alertCPUWindowMinutes) as? Double ?? MonitoringDefaults.alertCPUWindowMinutes }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertCPUWindowMinutes) }
    }

    public var alertMemoryGrowthBytes: Int64 {
        get { defaults.object(forKey: MonitoringKeys.alertMemoryGrowthBytes) as? Int64 ?? Int64(MonitoringDefaults.alertMemoryGrowthBytes) }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertMemoryGrowthBytes) }
    }

    public var alertDiskBytesPerSecond: Double {
        get { defaults.object(forKey: MonitoringKeys.alertDiskBytesPerSecond) as? Double ?? MonitoringDefaults.alertDiskBytesPerSecond }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertDiskBytesPerSecond) }
    }

    public var alertNetworkBytesPerSecond: Double {
        get {
            defaults.object(forKey: MonitoringKeys.alertNetworkBytesPerSecond) as? Double
                ?? MonitoringDefaults.alertNetworkBytesPerSecond
        }
        set { defaults.set(newValue, forKey: MonitoringKeys.alertNetworkBytesPerSecond) }
    }

    public var isCompactDensity: Bool {
        get { defaults.bool(forKey: MonitoringKeys.density) }
        set { defaults.set(newValue, forKey: MonitoringKeys.density) }
    }

    public var isMenuBarPanelEnabled: Bool {
        defaults.object(forKey: MonitoringKeys.menuBarPanelEnabled) as? Bool ?? MonitoringDefaults.menuBarPanelEnabled
    }

    public var hasEnabledMenuBarMetric: Bool {
        MonitoringKeys.menuBarMetrics.contains {
            defaults.object(forKey: $0.key) as? Bool ?? $0.defaultEnabled
        }
    }
}

/// The sampling loop. One tick gathers the cheap probes every interval and
/// schedules expensive ones (nettop, lsof, docker, bluetooth, pmset) behind
/// `RefreshGate`s on slower cadences so fast ticks never stall.
public actor MonitoringEngine {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "MonitoringEngine")

    private let processProbe = ProcessProbe()
    private let sensors = SMCSensors()
    private let history: MetricsHistoryStore?
    private let alertEngine: AlertEngine?
    private let isLightweight: Bool
    private let includesSlowProbes: Bool

    private var previousCPUTicks: HostProbes.CPUTicks?
    private var previousMemoryCounters: HostProbes.MemoryCounters?
    private var previousDiskCounters: DiskProbe.DiskCounters?
    private var previousNetworkCounters: [NetworkProbe.InterfaceCounters]?
    private var previousNettopByPID: [pid_t: NettopSample] = [:]
    private var previousTimestamp: Date?
    private var cachedBluetooth: [BluetoothDeviceReading] = []
    private var cachedNetworkPerProcess: [pid_t: ProcessNetworkUsage] = [:]
    private var cachedContainers: [ContainerReading] = []
    private var cachedAgents: [AgentSessionReading] = []
    private var cachedDevServers: [DevServerReading] = []
    private var cachedPower = PowerReading()
    private var lastRecordAt: Date?
    private var slowProcessRefresh = RefreshGate()
    private var powerRefresh = RefreshGate()
    private var containerRefresh = RefreshGate()
    private var bluetoothRefresh = RefreshGate()

    private struct NettopSample {
        var totalIn: Int64
        var totalOut: Int64
        var at: Date
        var startedAt: Date?
    }

    public var historyRetentionDays: Int = MonitoringDefaults.historyRetentionDays

    public func setRetentionDays(_ days: Int) {
        historyRetentionDays = max(MetricsHistoryStore.minimumRetentionDays, days)
    }

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

    public var groupingMode: AppProcessCatalog.GroupingMode = .byApp

    public func setGroupingMode(_ mode: AppProcessCatalog.GroupingMode) {
        groupingMode = mode
    }

    /// One full sample. `forceSlowProbes` awaits slow process probes inline for
    /// one-shot CLI/MCP calls; continuous UI ticks leave it false.
    public func sample(interval: TimeInterval, forceSlowProbes: Bool = false) async -> SystemSnapshot {
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

        let disk = sampleDisk(processes: processes, interval: elapsed)

        let networkCounters = NetworkProbe.sampleCounters()
        let network = NetworkProbe.reading(
            previous: previousNetworkCounters, current: networkCounters, interval: elapsed)
        previousNetworkCounters = networkCounters
        previousTimestamp = now

        await refreshSlowPaths(processes: processes, forceSlowProbes: forceSlowProbes)

        let groups = AppProcessCatalog.group(processes, mode: groupingMode, networkUsage: cachedNetworkPerProcess)
        let snapshot = SystemSnapshot(
            timestamp: now,
            interval: elapsed,
            cpu: cpu,
            memory: memory.reading,
            disk: disk,
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
            uptime: ProcessProbe.uptime(now: now),
            thermalPressure: Self.currentThermalPressure())

        await publish(snapshot, now: now)
        return snapshot
    }

    private func sampleDisk(processes: [ProcessSample], interval: TimeInterval) -> DiskIOReading {
        if let counters = DiskProbe.sampleCounters() {
            let reading = DiskProbe.reading(previous: previousDiskCounters, current: counters, interval: interval)
            previousDiskCounters = counters
            return reading
        }
        let diskRate = DiskActivity.rate(processes: processes)
        return DiskIOReading(
            readBytesPerSecond: diskRate.read,
            writeBytesPerSecond: diskRate.write,
            totalReadBytes: nil,
            totalWriteBytes: nil)
    }

    private static func currentThermalPressure() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

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

    private func refreshSlowPaths(processes: [ProcessSample], forceSlowProbes: Bool) async {
        if forceSlowProbes {
            if includesSlowProbes {
                async let net: Void = refreshNetworkPerProcess(processes)
                async let ports: Void = refreshDevServers(processes: processes)
                async let agents: Void = refreshAgents(processes: processes)
                async let power: PowerReading = isLightweight ? PowerProbe.batteryReading() : PowerProbe.reading()
                _ = await (net, ports, agents)
                cachedPower = await power
            } else {
                cachedPower = await PowerProbe.batteryReading()
            }
            return
        }
        if includesSlowProbes, tickCounter % 8 == 1, slowProcessRefresh.begin() {
            Task {
                defer { slowProcessRefresh.end() }
                async let net: Void = refreshNetworkPerProcess(processes)
                async let ports: Void = refreshDevServers(processes: processes)
                async let agents: Void = refreshAgents(processes: processes)
                _ = await (net, ports, agents)
            }
        }
        if tickCounter % 15 == 1, powerRefresh.begin() {
            Task {
                defer { powerRefresh.end() }
                cachedPower = isLightweight ? await PowerProbe.batteryReading() : await PowerProbe.reading()
            }
        }
        if tickCounter % 15 == 2, !isLightweight, containerRefresh.begin() {
            Task {
                defer { containerRefresh.end() }
                if let latest = await ContainerProbe.fetchContainers() {
                    cachedContainers = latest
                }
            }
        }
        if tickCounter % 30 == 3, !isLightweight, bluetoothRefresh.begin() {
            Task {
                defer { bluetoothRefresh.end() }
                cachedBluetooth = await BluetoothProbe.devices()
            }
        }
    }

    private func refreshNetworkPerProcess(_ processes: [ProcessSample]) async {
        let nettopURL = URL(fileURLWithPath: "/usr/bin/nettop")
        guard FileManager.default.isExecutableFile(atPath: nettopURL.path) else { return }
        let run = await ProcessRunner.run(nettopURL, arguments: ["-P", "-x", "-L", "1"], timeout: 5)
        guard run.exitCode == 0, !run.stdout.isEmpty else { return }
        let now = Date()
        let rows = Self.parseNettopCSV(run.stdout)
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(grouping: processes, by: { $0.name })
        var merged: [pid_t: ProcessNetworkUsage] = [:]
        var cumulativeTotals: [pid_t: (inBytes: Int64, outBytes: Int64)] = [:]

        for row in rows {
            if row.isRateSample {
                applyRateRow(row, byPID: byPID, byName: byName, merged: &merged)
                continue
            }
            guard let pid = row.pid, byPID[pid] != nil,
                  let totalIn = row.totalBytesIn, let totalOut = row.totalBytesOut else { continue }
            let existing = cumulativeTotals[pid] ?? (0, 0)
            cumulativeTotals[pid] = (existing.inBytes + totalIn, existing.outBytes + totalOut)
        }
        applyCumulativeTotals(cumulativeTotals, byPID: byPID, at: now, merged: &merged)
        cachedNetworkPerProcess = merged
    }

    private func applyRateRow(
        _ row: NettopRow, byPID: [pid_t: ProcessSample],
        byName: [String: [ProcessSample]], merged: inout [pid_t: ProcessNetworkUsage]
    ) {
        let usage = ProcessNetworkUsage(downloadPerSecond: row.downloadPerSecond, uploadPerSecond: row.uploadPerSecond)
        if let pid = row.pid, let match = byPID[pid] {
            merged[match.pid] = usage
        } else if let candidate = byName[row.name]?.first, merged[candidate.pid] == nil {
            merged[candidate.pid] = usage
        }
    }

    private func applyCumulativeTotals(
        _ cumulativeTotals: [pid_t: (inBytes: Int64, outBytes: Int64)],
        byPID: [pid_t: ProcessSample], at now: Date, merged: inout [pid_t: ProcessNetworkUsage]
    ) {
        guard !cumulativeTotals.isEmpty else { return }
        var nextSamples: [pid_t: NettopSample] = [:]
        for (pid, totals) in cumulativeTotals {
            let startedAt = byPID[pid]?.startedAt
            nextSamples[pid] = NettopSample(totalIn: totals.inBytes, totalOut: totals.outBytes, at: now, startedAt: startedAt)
            guard let previous = previousNettopByPID[pid],
                  let start = startedAt, previous.startedAt == start,
                  totals.inBytes >= previous.totalIn, totals.outBytes >= previous.totalOut else { continue }
            let elapsed = now.timeIntervalSince(previous.at)
            guard elapsed > 0.05 else { continue }
            merged[pid] = ProcessNetworkUsage(
                downloadPerSecond: Double(totals.inBytes - previous.totalIn) / elapsed,
                uploadPerSecond: Double(totals.outBytes - previous.totalOut) / elapsed)
        }
        previousNettopByPID = nextSamples
    }

    private func refreshDevServers(processes: [ProcessSample]) async {
        cachedDevServers = await DevEnvironmentProbe.servers(processes: processes)
    }

    private func refreshAgents(processes: [ProcessSample]) async {
        let workingDirectories = await DevEnvironmentProbe.workingDirectories(
            pids: Set(processes.filter { AgentProbe.kind(of: $0) != nil }.map(\.pid)))
        cachedAgents = await AgentProbe.sessions(processes: processes, workingDirectories: workingDirectories)
    }

    public func shutdown() async {
        await sensors.restoreFanControl()
    }

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

// MARK: - Nettop CSV parsing

extension MonitoringEngine {
    public struct NettopRow: Sendable, Equatable {
        public var name: String
        public var pid: pid_t?
        public var downloadPerSecond: Double
        public var uploadPerSecond: Double
        public var totalBytesIn: Int64?
        public var totalBytesOut: Int64?
        public var isRateSample: Bool

        public init(
            name: String, pid: pid_t?, downloadPerSecond: Double, uploadPerSecond: Double,
            totalBytesIn: Int64? = nil, totalBytesOut: Int64? = nil, isRateSample: Bool = false
        ) {
            self.name = name
            self.pid = pid
            self.downloadPerSecond = downloadPerSecond
            self.uploadPerSecond = uploadPerSecond
            self.totalBytesIn = totalBytesIn
            self.totalBytesOut = totalBytesOut
            self.isRateSample = isRateSample
        }
    }

    public static func parseNettopCSV(_ output: String) -> [NettopRow] {
        var result: [NettopRow] = []
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return result }
        let header = csvFields(lines[0])
        func column(_ candidates: [String]) -> Int? {
            candidates.compactMap { header.firstIndex(of: $0) }.first
        }
        let processIndex = column(["process"]) ?? 1
        let rateInIndex = column(["bytes_in_per_s"])
        let rateOutIndex = column(["bytes_out_per_s"])
        let totalInIndex = column(["bytes_in"])
        let totalOutIndex = column(["bytes_out"])
        let hasRates = rateInIndex != nil && rateOutIndex != nil
        let primaryIn = rateInIndex ?? totalInIndex ?? 2
        let primaryOut = rateOutIndex ?? totalOutIndex ?? 3

        for line in lines.dropFirst() {
            let fields = csvFields(line)
            let extra = fields.count - header.count
            guard extra >= 0, processIndex + extra < fields.count else { continue }
            func field(_ column: Int) -> String {
                let target = column + extra
                return target < fields.count ? fields[target] : ""
            }
            guard let inVal = Double(field(primaryIn)), let outVal = Double(field(primaryOut)) else { continue }
            let identifier = fields[processIndex...(processIndex + extra)].joined(separator: ",")
            var name = identifier
            var pid: pid_t?
            if let lastDot = identifier.lastIndex(of: ".") {
                let suffix = identifier[identifier.index(after: lastDot)...]
                if let value = pid_t(suffix), !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                    pid = value
                    name = String(identifier[identifier.startIndex..<lastDot])
                }
            }
            let totalIn = totalInIndex.flatMap { Int64(field($0)) } ?? (hasRates ? nil : Int64(inVal))
            let totalOut = totalOutIndex.flatMap { Int64(field($0)) } ?? (hasRates ? nil : Int64(outVal))
            result.append(
                NettopRow(
                    name: name, pid: pid,
                    downloadPerSecond: inVal, uploadPerSecond: outVal,
                    totalBytesIn: totalIn, totalBytesOut: totalOut, isRateSample: hasRates))
        }
        return result
    }

    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        current.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct RefreshGate {
    private(set) var isBusy = false

    mutating func begin() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    mutating func end() {
        isBusy = false
    }
}

enum DiskActivity {
    static func rate(processes: [ProcessSample]) -> (read: Double, write: Double) {
        let read = processes.reduce(0.0) { $0 + max(0, $1.diskReadPerSecond) }
        let write = processes.reduce(0.0) { $0 + max(0, $1.diskWritePerSecond) }
        return (read, write)
    }
}
