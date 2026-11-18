import Foundation

/// The `tidybyte monitor` command line: one-shot system readings and stored
/// history as text tables or JSON. Monitoring only — never signals processes.
public enum MonitorCLI {
    public static let usage = """
        Usage: tidybyte monitor <command> [options]

        Commands:
          status    CPU, memory, pressure, disk, network, GPU, battery, sensors, fans, uptime
          top       The busiest apps right now [--sort cpu|memory|disk|network|energy] [--limit N]
          ports     Listening servers, grouped by project [--idle-only]
          agents    Running coding agents, their projects and children
          limits    Metered plan usage the local agent state knows about
          history   Stored metric history [--metric cpu] [--range 24h]

        Options:
          --json    Render machine-readable JSON
          -h, --help
        """

    public static let supportedHistoryMetrics: Set<String> = [
        "cpu", "memory", "swap", "disk", "disk_read", "disk_write",
        "network", "network_down", "network_up", "energy", "battery", "temperature", "gpu"
    ]

    /// Runs the monitor subcommand. Help and invalid subcommands return
    /// immediately before running any hardware probes.
    public static func run(_ arguments: [String]) async -> Int32 {
        if arguments.contains("-h") || arguments.contains("--help") {
            print(usage)
            return 0
        }
        guard let command = firstPositionalCommand(in: arguments) else {
            writeStderr(usage + "\n")
            return 2
        }
        if command == "help" {
            print(usage)
            return 0
        }
        let wantsJSON = arguments.contains("--json")
        if command == "history" {
            return await runHistory(arguments: arguments, wantsJSON: wantsJSON)
        }
        guard let parsed = parseLiveCommand(command: command, arguments: arguments) else {
            return 2
        }
        let snapshot = await oneShot(includesSlowProbes: parsed.needsSlowProbes)
        print(renderLiveCommand(command: command, snapshot: snapshot, options: parsed, wantsJSON: wantsJSON))
        return 0
    }

    private static func renderLiveCommand(
        command: String, snapshot: SystemSnapshot, options: LiveOptions, wantsJSON: Bool
    ) -> String {
        switch command {
        case "status":
            return wantsJSON ? statusJSON(snapshot) : statusTable(snapshot)
        case "top":
            return wantsJSON
                ? topJSON(snapshot, sort: options.sort, limit: options.limit)
                : topTable(snapshot, sort: options.sort, limit: options.limit)
        case "ports":
            return wantsJSON
                ? portsJSON(snapshot, idleOnly: options.idleOnly)
                : portsTable(snapshot, idleOnly: options.idleOnly)
        case "agents":
            return wantsJSON ? agentsJSON(snapshot) : agentsTable(snapshot)
        case "limits":
            return wantsJSON ? limitsJSON(snapshot) : limitsTable(snapshot)
        default:
            return ""
        }
    }

    private struct LiveOptions {
        var needsSlowProbes: Bool
        var sort: UsageMetric = .cpu
        var limit = 10
        var idleOnly = false
    }

    private static func firstPositionalCommand(in arguments: [String]) -> String? {
        var skipNext = false
        for arg in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--sort" || arg == "--limit" || arg == "--metric" || arg == "--range" {
                skipNext = true
                continue
            }
            if !arg.hasPrefix("-") { return arg }
        }
        return nil
    }

    private static func parseLiveCommand(command: String, arguments: [String]) -> LiveOptions? {
        switch command {
        case "status":
            return LiveOptions(needsSlowProbes: false)
        case "top":
            let sortRaw = optionValue("--sort", in: arguments) ?? "cpu"
            guard let sort = UsageMetric(rawValue: sortRaw) else {
                writeStderr("Invalid --sort value: \(sortRaw). Expected cpu, memory, disk, network, or energy.\n")
                return nil
            }
            let limitRaw = optionValue("--limit", in: arguments)
            let limit = limitRaw.flatMap(Int.init) ?? 10
            if limitRaw != nil && limit < 1 {
                writeStderr("Invalid --limit value.\n")
                return nil
            }
            return LiveOptions(needsSlowProbes: true, sort: sort, limit: min(max(1, limit), 100))
        case "ports":
            return LiveOptions(needsSlowProbes: true, idleOnly: arguments.contains("--idle-only"))
        case "agents", "limits":
            return LiveOptions(needsSlowProbes: true)
        default:
            writeStderr("Unknown command: \(command)\n\n\(usage)\n")
            return nil
        }
    }

    private static func optionValue(_ flag: String, in arguments: [String]) -> String? {
        if let eqArg = arguments.first(where: { $0.hasPrefix(flag + "=") }) {
            return String(eqArg.dropFirst(flag.count + 1))
        }
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func writeStderr(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }

    /// One sampling pass with a 1-second baseline window so CPU, disk, and
    /// network counters produce real rates instead of millisecond noise.
    public static func oneShot(includesSlowProbes: Bool = true) async -> SystemSnapshot {
        let engine = MonitoringEngine(
            history: nil, alertEngine: nil, isLightweight: true, includesSlowProbes: includesSlowProbes)
        _ = await engine.sample(interval: 1, forceSlowProbes: includesSlowProbes)
        try? await Task.sleep(for: .seconds(1))
        var snapshot = await engine.sample(interval: 1, forceSlowProbes: includesSlowProbes)
        if snapshot.groups.isEmpty {
            snapshot.groups = AppProcessCatalog.group(snapshot.processes, mode: .byApp)
        }
        await engine.shutdown()
        return snapshot
    }
}

// MARK: - History subcommand

extension MonitorCLI {
    public static func parseHistoryRange(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 2, let unit = trimmed.last,
              let count = Double(trimmed.dropLast()), count > 0 else { return nil }
        switch unit {
        case "m": return count * 60
        case "h": return count * 3600
        case "d": return count * 86_400
        case "y": return count * 365 * 86_400
        default: return nil
        }
    }

    private static func runHistory(arguments: [String], wantsJSON: Bool) async -> Int32 {
        let metric = (optionValue("--metric", in: arguments) ?? "cpu").lowercased()
        guard supportedHistoryMetrics.contains(metric) else {
            writeStderr("Unknown metric: \(metric)\n")
            return 2
        }
        let rangeRaw = optionValue("--range", in: arguments) ?? "24h"
        guard let span = parseHistoryRange(rangeRaw) else {
            writeStderr("Invalid range: \(rangeRaw). Examples: 1h, 24h, 7d, 30d, 1y.\n")
            return 2
        }
        let end = Date()
        let start = end.addingTimeInterval(-span)
        let dbURL = MetricsHistoryStore.defaultLocation()
        let points: [MetricsHistoryStore.SeriesPoint]
        if FileManager.default.fileExists(atPath: dbURL.path),
           let store = try? MetricsHistoryStore(databaseURL: dbURL) {
            points = await store.series(metricKey: metric, from: start, to: end)
        } else {
            points = []
        }
        print(wantsJSON
            ? historyJSON(metric: metric, range: rangeRaw, from: start, to: end, points: points)
            : historyTable(metric: metric, range: rangeRaw, points: points))
        return 0
    }

    static func historyTable(metric: String, range: String, points: [MetricsHistoryStore.SeriesPoint]) -> String {
        guard !points.isEmpty else {
            return "No history recorded for \(metric) in the last \(range)."
        }
        let iso = Date.ISO8601FormatStyle()
        return renderTable(
            header: "TIMESTAMP                 AVERAGE      PEAK",
            rows: points.suffix(60).map { point in
                let peak = point.peak.map { String(format: "%8.2f", $0) } ?? "—"
                return "\(iso.format(point.timestamp))  \(String(format: "%10.2f", point.average))  \(peak)"
            })
    }

    public static func historyJSON(
        metric: String, range: String, appName: String? = nil, from: Date, to: Date,
        points: [MetricsHistoryStore.SeriesPoint]
    ) -> String {
        let iso = Date.ISO8601FormatStyle()
        let encodedPoints: [[String: Any]] = points.map { point in
            [
                "timestamp": Int(point.timestamp.timeIntervalSince1970),
                "iso8601": iso.format(point.timestamp),
                "average": round2(point.average),
                "peak": jsonValue(point.peak.map(round2))
            ]
        }
        var payload: [String: Any] = [
            "metric": metric,
            "range": range,
            "from_timestamp": Int(from.timeIntervalSince1970),
            "to_timestamp": Int(to.timeIntervalSince1970),
            "count": points.count,
            "points": encodedPoints
        ]
        if let appName { payload["app_name"] = appName }
        if points.isEmpty { payload["note"] = "No stored history samples found for this window." }
        return encode(payload)
    }
}

// MARK: - Tables & JSON

extension MonitorCLI {
    static func statusTable(_ snapshot: SystemSnapshot) -> String {
        var lines: [String] = []
        let userPercent = percentString(snapshot.cpu.userPercent)
        let systemPercent = percentString(snapshot.cpu.systemPercent)
        lines.append("CPU \(percentString(snapshot.cpu.usagePercent))  (user \(userPercent), system \(systemPercent))")
        let used = snapshot.memory.usedBytes.formattedByteCount
        let total = snapshot.memory.totalBytes.formattedByteCount
        let swap = snapshot.memory.swapUsedBytes.formattedByteCount
        lines.append("Memory \(used) of \(total), swap \(swap), pressure \(snapshot.memory.pressureLabel)")
        lines.append("Thermal pressure \(snapshot.thermalPressure.rawValue)")
        lines.append(
            "Disk read \(snapshot.disk.readBytesPerSecond.formattedByteRate), write \(snapshot.disk.writeBytesPerSecond.formattedByteRate)")
        let down = snapshot.network.downloadBytesPerSecond.formattedByteRate
        let up = snapshot.network.uploadBytesPerSecond.formattedByteRate
        let iface = snapshot.network.primaryInterface.map { " (\($0))" } ?? ""
        lines.append("Network down \(down), up \(up)\(iface)")
        lines.append("Load \(String(format: "%.2f", snapshot.cpu.loadAverage1)) (\(snapshot.cpu.logicalCoreCount) cores)")
        for gpu in snapshot.gpu.devices {
            let util = gpu.utilizationPercent.map { String(format: " %.0f%%", $0) } ?? ""
            lines.append("GPU \(gpu.name)\(util)")
        }
        if let sensor = snapshot.sensors.first {
            lines.append("Temperature \(String(format: "%.0f", sensor.celsius))°C (\(sensor.name))")
        }
        for fan in snapshot.fans {
            lines.append("Fan \(fan.name) \(Int(fan.rpm.rounded())) RPM")
        }
        if snapshot.power.hasBattery, let level = snapshot.power.level {
            let charging = snapshot.power.isCharging ? ", charging" : ""
            lines.append("Battery \(percentString(level * 100))\(charging)")
        }
        lines.append("Uptime \(snapshot.uptime.formattedDuration)")
        lines.append("Processes \(snapshot.processes.count) in \(snapshot.groups.count) apps")
        return lines.joined(separator: "\n")
    }

    static func topTable(_ snapshot: SystemSnapshot, sort: UsageMetric = .cpu, limit: Int = 10) -> String {
        let busiest = snapshot.busiest(metric: sort, limit: limit)
        return renderTable(header: "APP                CPU%   MEMORY    DISK/S     NET/S", rows: busiest.map { group in
            [
                column(group.name, width: 16),
                String(format: "%5.1f", group.cpuPercent),
                group.memoryBytes.formattedByteCount.padding(toLength: 9, withPad: " ", startingAt: 0),
                (group.diskReadPerSecond + group.diskWritePerSecond).formattedByteRate
                    .padding(toLength: 10, withPad: " ", startingAt: 0),
                (group.downloadPerSecond + group.uploadPerSecond).formattedByteRate
            ].joined(separator: "  ")
        })
    }

    static func portsTable(_ snapshot: SystemSnapshot, idleOnly: Bool = false) -> String {
        let servers = idleOnly ? snapshot.devServers.filter(\.isIdle) : snapshot.devServers
        guard !servers.isEmpty else {
            return idleOnly ? "No idle listening dev servers." : "No listening dev servers."
        }
        return renderTable(
            header: "PROJECT         ADDRESS          PORT   PID     PROCESS        STATE",
            rows: servers.map { server in
                [
                    column(server.project, width: 16),
                    column(server.address, width: 15),
                    String(server.port).padding(toLength: 6, withPad: " ", startingAt: 0),
                    String(server.pid).padding(toLength: 7, withPad: " ", startingAt: 0),
                    column(server.processName, width: 14),
                    server.isIdle ? "idle" : "active"
                ].joined(separator: "  ")
            })
    }

    static func agentsTable(_ snapshot: SystemSnapshot) -> String {
        guard !snapshot.agents.isEmpty else { return "No coding agents running." }
        return renderTable(header: "AGENT          PID     CPU%   PROJECT", rows: snapshot.agents.map { agent in
            [
                column(agent.kind.displayName, width: 14),
                String(agent.id).padding(toLength: 7, withPad: " ", startingAt: 0),
                String(format: "%5.1f", agent.cpuPercent),
                agent.projectRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
            ].joined(separator: "  ")
        })
    }

    static func limitsTable(_ snapshot: SystemSnapshot) -> String {
        let withUsage = snapshot.agents.compactMap(\.usage)
        guard !withUsage.isEmpty else { return "No local plan-usage data found." }
        return withUsage.map { usage in
            var line = "\(usage.planName):"
            if let fraction = usage.usedFraction {
                line += " \(percentString(fraction * 100)) used"
            }
            if let resets = usage.resetsAt {
                line += ", resets \(resets.formatted(date: .abbreviated, time: .shortened))"
            }
            return line
        }.joined(separator: "\n")
    }

    static func column(_ text: String, width: Int) -> String {
        text.count >= width ? text + "  " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    static func renderTable(header: String, rows: [String]) -> String {
        ([header] + rows).joined(separator: "\n")
    }

    static func percentString(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    public static func statusJSON(_ snapshot: SystemSnapshot) -> String {
        var payload: [String: Any] = [
            "cpu_percent": round1(snapshot.cpu.usagePercent),
            "cpu_user_percent": round1(snapshot.cpu.userPercent),
            "cpu_system_percent": round1(snapshot.cpu.systemPercent),
            "load_average_1m": round2(snapshot.cpu.loadAverage1),
            "cores": snapshot.cpu.logicalCoreCount,
            "physical_cores": snapshot.cpu.physicalCoreCount,
            "performance_cores": jsonValue(snapshot.cpu.performanceCoreCount),
            "efficiency_cores": jsonValue(snapshot.cpu.efficiencyCoreCount),
            "memory_used_bytes": snapshot.memory.usedBytes,
            "memory_total_bytes": snapshot.memory.totalBytes,
            "swap_used_bytes": snapshot.memory.swapUsedBytes,
            "pressure": snapshot.memory.pressureLabel,
            "memory_pressure_level": snapshot.memory.pressureLevel,
            "thermal_pressure": snapshot.thermalPressure.rawValue,
            "disk_read_bytes_per_second": round1(snapshot.disk.readBytesPerSecond),
            "disk_write_bytes_per_second": round1(snapshot.disk.writeBytesPerSecond),
            "disk_read_iops": round1(snapshot.disk.readOperationsPerSecond),
            "disk_write_iops": round1(snapshot.disk.writeOperationsPerSecond),
            "network_download_bytes_per_second": round1(snapshot.network.downloadBytesPerSecond),
            "network_upload_bytes_per_second": round1(snapshot.network.uploadBytesPerSecond),
            "primary_interface": jsonValue(snapshot.network.primaryInterface),
            "temperature_celsius": jsonValue(snapshot.sensors.first.map { round1($0.celsius) }),
            "battery_percent": jsonValue(snapshot.power.level.map { round1($0 * 100) }),
            "battery_charging": snapshot.power.isCharging,
            "uptime_seconds": Int(snapshot.uptime),
            "processes": snapshot.processes.count,
            "apps": snapshot.groups.count
        ]
        payload["gpu"] = snapshot.gpu.devices.map(gpuPayload)
        payload["sensors"] = snapshot.sensors.map { ["key": $0.key, "name": $0.name, "celsius": round1($0.celsius)] }
        payload["fans"] = snapshot.fans.map(fanPayload)
        return encode(payload)
    }

    private static func gpuPayload(_ gpu: GPUDeviceReading) -> [String: Any] {
        [
            "name": gpu.name,
            "vendor": gpu.vendor,
            "utilization_percent": jsonValue(gpu.utilizationPercent.map(round1)),
            "renderer_utilization_percent": jsonValue(gpu.rendererUtilizationPercent.map(round1)),
            "tiler_utilization_percent": jsonValue(gpu.tilerUtilizationPercent.map(round1)),
            "core_count": jsonValue(gpu.coreCount),
            "in_use_memory_bytes": jsonValue(gpu.inUseMemoryBytes),
            "allocated_memory_bytes": jsonValue(gpu.allocatedMemoryBytes),
            "memory_limit_bytes": jsonValue(gpu.memoryLimitBytes),
            "is_low_power": gpu.isLowPower
        ]
    }

    private static func fanPayload(_ fan: FanReading) -> [String: Any] {
        [
            "id": fan.id,
            "name": fan.name,
            "rpm": round1(fan.rpm),
            "minimum_rpm": round1(fan.minimumRPM),
            "maximum_rpm": round1(fan.maximumRPM),
            "target_rpm": jsonValue(fan.targetRPM.map(round1)),
            "user_controllable": fan.isUserControllable
        ]
    }

    public static func topJSON(_ snapshot: SystemSnapshot, sort: UsageMetric = .cpu, limit: Int = 10) -> String {
        encode(snapshot.busiest(metric: sort, limit: limit).map { group in
            [
                "app": group.name,
                "bundle_path": jsonValue(group.bundlePath),
                "cpu_percent": round1(group.cpuPercent),
                "memory_bytes": group.memoryBytes,
                "disk_bytes_per_second": round1(group.diskReadPerSecond + group.diskWritePerSecond),
                "network_bytes_per_second": round1(group.downloadPerSecond + group.uploadPerSecond),
                "pids": group.members.map { Int($0.pid) }
            ]
        })
    }

    public static func portsJSON(_ snapshot: SystemSnapshot, idleOnly: Bool = false) -> String {
        let servers = idleOnly ? snapshot.devServers.filter(\.isIdle) : snapshot.devServers
        return encode(servers.map { server in
            [
                "project": server.project,
                "project_root": jsonValue(server.projectRoot),
                "address": server.address,
                "port": server.port,
                "pid": Int(server.pid),
                "process": server.processName,
                "idle": server.isIdle,
                "cpu_percent": round1(server.cpuPercent)
            ]
        })
    }

    public static func agentsJSON(_ snapshot: SystemSnapshot) -> String {
        encode(snapshot.agents.map { agent in
            let usagePayload: Any = agent.usage.map {
                [
                    "plan": $0.planName,
                    "used_fraction": jsonValue($0.usedFraction.map(round2)),
                    "resets_at": jsonValue($0.resetsAt.map { Int($0.timeIntervalSince1970) })
                ]
            } ?? NSNull()
            return [
                "agent": agent.kind.rawValue,
                "pid": Int(agent.id),
                "project_root": jsonValue(agent.projectRoot),
                "cpu_percent": round1(agent.cpuPercent),
                "children": agent.children.map { ["pid": Int($0.id), "name": $0.name] },
                "usage": usagePayload
            ]
        })
    }

    public static func limitsJSON(_ snapshot: SystemSnapshot) -> String {
        encode(snapshot.agents.compactMap(\.usage).map { usage in
            [
                "plan": usage.planName,
                "used_fraction": jsonValue(usage.usedFraction.map(round2)),
                "window": jsonValue(usage.window),
                "resets_at": jsonValue(usage.resetsAt.map { Int($0.timeIntervalSince1970) })
            ]
        })
    }

    static func jsonValue<T>(_ optional: T?) -> Any {
        optional ?? NSNull()
    }

    static func encode(_ value: Any) -> String {
        guard let data = JSONSanitizing.data(value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
