import Foundation
import MacOSCleanerCore

/// Read-only monitoring MCP tools, gated out in sandboxed App Store builds.
enum MonitorToolRouter {
    static var toolDescriptions: [[String: Any]] {
        #if APP_STORE
        return []
        #else
        return descriptors
        #endif
    }

    static func handles(name: String) -> Bool {
        #if APP_STORE
        return false
        #else
        return supportedNames.contains(name)
        #endif
    }

    enum Request: Sendable {
        case status
        case top(sort: UsageMetric, limit: Int)
        case ports(idleOnly: Bool)
        case agents
        case limits
        case history(metric: String, range: String, appName: String?, span: TimeInterval)
        case inspect(pid: Int)
        case hardware
    }

    static func parseRequest(name: String, arguments: [String: Any]) throws -> Request? {
        #if APP_STORE
        return nil
        #else
        return try buildRequest(name: name, arguments: arguments)
        #endif
    }

    static func execute(_ request: Request) async throws -> String {
        #if APP_STORE
        throw MCPError.unknownTool("monitor")
        #else
        return try await runRequest(request)
        #endif
    }

    #if !APP_STORE
    static func liveMonitorResourceJSON() async -> String {
        let snapshot = await sharedSnapshot(needsSlowProbes: true)
        return hardwarePayloadJSON(snapshot: snapshot, includeTopAndPorts: true)
    }
    #endif
}

#if !APP_STORE
private extension MonitorToolRouter {
    static let supportedNames: Set<String> = [
        "monitor_status", "monitor_top", "monitor_ports", "monitor_agents",
        "monitor_limits", "monitor_history", "monitor_inspect", "monitor_hardware"
    ]

    static var descriptors: [[String: Any]] {
        [
            MCPKit.tool(
                "monitor_status",
                "One-shot system monitor reading: CPU, memory, pressure, disk and network rates, "
                    + "GPU, sensors, fans, battery, uptime, process counts. Read-only.",
                [:],
                annotations: MCPKit.readOnlyAnnotations
            ),
            MCPKit.tool(
                "monitor_top",
                "The busiest apps right now with CPU, memory, disk and network rates. Helpers are "
                    + "grouped under their parent app. Read-only.",
                [
                    "sort": MCPKit.string("Metric to sort by: cpu (default), memory, disk, network, or energy."),
                    "limit": MCPKit.integer("Maximum number of app groups to return (1-100, default 10).")
                ],
                annotations: MCPKit.readOnlyAnnotations
            ),
            MCPKit.tool(
                "monitor_ports",
                "Listening dev servers grouped by project, idle ones flagged. Read-only.",
                [
                    "idle_only": MCPKit.boolean("If true, return only idle listening dev servers.")
                ],
                annotations: MCPKit.readOnlyAnnotations
            ),
            MCPKit.tool(
                "monitor_agents",
                "Running coding agents (Claude Code, Codex, Gemini CLI, ...), their projects, the "
                    + "processes they started, and any local plan-usage data. Read-only.",
                [:],
                annotations: MCPKit.readOnlyAnnotations
            ),
            MCPKit.tool(
                "monitor_limits",
                "Metered plan usage the local agent state files know about, when present. Read-only.",
                [:],
                annotations: MCPKit.readOnlyAnnotations
            ),
            MCPKit.tool(
                "monitor_history",
                "Read stored historical time-series samples or hourly rollups from the monitor "
                    + "SQLite store. Read-only.",
                [
                    "metric": MCPKit.string(
                        "Metric key: cpu (default), memory, swap, disk, disk_read, disk_write, "
                            + "network, network_down, network_up, energy, battery, temperature, or gpu."),
                    "range": MCPKit.string("Lookback duration such as 1h, 6h, 24h (default), 7d, 30d, 1y."),
                    "app_name": MCPKit.string("Optional app display name for per-app history (cpu, memory, disk, network, energy).")
                ],
                annotations: MCPKit.readOnlyAnnotations
            ),
            MCPKit.tool(
                "monitor_inspect",
                "Inspect a single live process by PID: executable, command line, code signature, "
                    + "entitlements, open files, listening ports, outbound connections, and children. Read-only.",
                [
                    "pid": MCPKit.integer("Live process ID (> 0) to inspect.")
                ],
                required: ["pid"],
                annotations: MCPKit.readOnlyAnnotations
            ),
            MCPKit.tool(
                "monitor_hardware",
                "Full hardware telemetry snapshot: P/E core counts, memory pressure, thermal state, "
                    + "GPU utilization & memory, Neural Engine, SMC sensors, fans, battery health, "
                    + "hardware disk IOPS, audio devices, and Bluetooth accessories. Read-only.",
                [:],
                annotations: MCPKit.readOnlyAnnotations
            )
        ]
    }

    static func buildRequest(name: String, arguments: [String: Any]) throws -> Request? {
        switch name {
        case "monitor_status": return .status
        case "monitor_top": return try parseTop(arguments)
        case "monitor_ports": return .ports(idleOnly: try MCPKit.boolArgument(arguments, "idle_only") ?? false)
        case "monitor_agents": return .agents
        case "monitor_limits": return .limits
        case "monitor_history": return try parseHistory(arguments)
        case "monitor_inspect": return try parseInspect(arguments)
        case "monitor_hardware": return .hardware
        default: return nil
        }
    }

    static func runRequest(_ request: Request) async throws -> String {
        switch request {
        case .status:
            let snapshot = await sharedSnapshot(needsSlowProbes: false)
            return MonitorCLI.statusJSON(snapshot)
        case .top(let sort, let limit):
            let snapshot = await sharedSnapshot(needsSlowProbes: true)
            return MonitorCLI.topJSON(snapshot, sort: sort, limit: limit)
        case .ports(let idleOnly):
            let snapshot = await sharedSnapshot(needsSlowProbes: true)
            return MonitorCLI.portsJSON(snapshot, idleOnly: idleOnly)
        case .agents:
            let snapshot = await sharedSnapshot(needsSlowProbes: true)
            return MonitorCLI.agentsJSON(snapshot)
        case .limits:
            let snapshot = await sharedSnapshot(needsSlowProbes: true)
            return MonitorCLI.limitsJSON(snapshot)
        case .history(let metric, let range, let appName, let span):
            return await handleHistory(metric: metric, range: range, appName: appName, span: span)
        case .inspect(let pid):
            return try await handleInspect(pidValue: pid)
        case .hardware:
            return await handleHardware()
        }
    }

    static func parseTop(_ arguments: [String: Any]) throws -> Request {
        let sortRaw = (try MCPKit.stringArgument(arguments, "sort") ?? "cpu").lowercased()
        guard let sort = UsageMetric(rawValue: sortRaw) else {
            throw MCPError.invalidArgument("sort")
        }
        let limit = try MCPKit.intArgument(arguments, "limit") ?? 10
        guard (1...100).contains(limit) else {
            throw MCPError.invalidArgument("limit")
        }
        return .top(sort: sort, limit: limit)
    }

    static func parseHistory(_ arguments: [String: Any]) throws -> Request {
        let metric = (try MCPKit.stringArgument(arguments, "metric") ?? "cpu").lowercased()
        guard MonitorCLI.supportedHistoryMetrics.contains(metric) else {
            throw MCPError.invalidArgument("metric")
        }
        let rangeRaw = try MCPKit.stringArgument(arguments, "range") ?? "24h"
        guard let span = MonitorCLI.parseHistoryRange(rangeRaw) else {
            throw MCPError.invalidArgument("range")
        }
        let appName = try MCPKit.stringArgument(arguments, "app_name")
        if let appName, appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPError.invalidArgument("app_name")
        }
        if appName != nil, UsageMetric(rawValue: metric) == nil {
            throw MCPError.invalidArgument("metric")
        }
        return .history(metric: metric, range: rangeRaw, appName: appName, span: span)
    }

    static func parseInspect(_ arguments: [String: Any]) throws -> Request {
        guard let pidValue = try MCPKit.intArgument(arguments, "pid"), pidValue > 0 else {
            throw MCPError.invalidArgument("pid")
        }
        return .inspect(pid: pidValue)
    }

    static func handleHistory(metric: String, range: String, appName: String?, span: TimeInterval) async -> String {
        let end = Date()
        let start = end.addingTimeInterval(-span)
        let dbURL = historyDatabaseURL()
        let points: [MetricsHistoryStore.SeriesPoint]
        if FileManager.default.fileExists(atPath: dbURL.path),
           let store = try? MetricsHistoryStore(databaseURL: dbURL) {
            if let appName, let usageMetric = UsageMetric(rawValue: metric) {
                points = await store.appSeries(metric: usageMetric, appName: appName, from: start, to: end)
            } else {
                points = await store.series(metricKey: metric, from: start, to: end)
            }
        } else {
            points = []
        }
        return MonitorCLI.historyJSON(
            metric: metric, range: range, appName: appName, from: start, to: end, points: points)
    }

    static func handleInspect(pidValue: Int) async throws -> String {
        let pid = pid_t(pidValue)
        let probe = ProcessProbe()
        let all = await probe.sample(includeCommandLine: false)
        guard let sample = all.first(where: { $0.pid == pid }) else {
            throw MCPError.processNotFound(pidValue)
        }
        let inspection = await ProcessInspector.inspect(sample, all: all)
        return encodeInspectionJSON(inspection, sample: sample)
    }

    static func handleHardware() async -> String {
        let engine = MonitoringEngine(history: nil, alertEngine: nil, isLightweight: false, includesSlowProbes: false)
        async let bluetoothTask = BluetoothProbe.devices()
        async let powerTask = PowerProbe.reading()
        _ = await engine.sample(interval: 0.25, forceSlowProbes: false)
        try? await Task.sleep(for: .milliseconds(250))
        var snapshot = await engine.sample(interval: 0.25, forceSlowProbes: false)
        snapshot.bluetooth = await bluetoothTask
        snapshot.power = await powerTask
        await engine.shutdown()
        return hardwarePayloadJSON(snapshot: snapshot, includeTopAndPorts: false)
    }

    static func historyDatabaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["TIDYBYTE_HISTORY_DB"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return MetricsHistoryStore.defaultLocation()
    }

    static func encodeInspectionJSON(_ inspection: ProcessInspection, sample: ProcessSample) -> String {
        let iso = Date.ISO8601FormatStyle()
        let sigPayload: Any = inspection.signature.map { sig in
            [
                "is_signed": sig.isSigned,
                "is_valid": sig.isValid,
                "team_id": sig.teamID ?? NSNull(),
                "is_sandboxed": sig.isSandboxed,
                "entitlements_count": sig.entitlements.count
            ] as [String: Any]
        } ?? NSNull()
        let payload: [String: Any] = [
            "pid": Int(inspection.pid),
            "parent_pid": Int(inspection.parentPID),
            "parent_name": inspection.parentName ?? NSNull(),
            "name": sample.name,
            "state": sample.state.rawValue,
            "executable_path": inspection.executablePath ?? NSNull(),
            "bundle_id": inspection.bundleID ?? NSNull(),
            "version": inspection.version ?? NSNull(),
            "started_at": inspection.startedAt.map { iso.format($0) } ?? NSNull(),
            "cpu_time_seconds": (inspection.cpuTimeSeconds * 100).rounded() / 100,
            "resident_bytes": inspection.residentBytes,
            "footprint_bytes": inspection.footprintBytes,
            "disk_read_bytes": inspection.diskReadBytes,
            "disk_written_bytes": inspection.diskWrittenBytes,
            "thread_count": Int(sample.threadCount),
            "command_line": inspection.commandLine,
            "signature": sigPayload,
            "open_files": inspection.openFiles.prefix(50).map { ["path": $0.path, "kind": $0.kind] },
            "listening_ports": inspection.listeningPorts.map {
                ["port": $0.port, "address": $0.address, "kind": $0.kind]
            },
            "outbound_connections": inspection.outboundConnections.prefix(50).map {
                [
                    "kind": $0.kind,
                    "local": $0.localAddress,
                    "remote": $0.remoteAddress,
                    "state": jsonValue($0.state)
                ] as [String: Any]
            },
            "children": inspection.children.map {
                ["pid": Int($0.pid), "name": $0.name, "resident_bytes": $0.residentBytes]
            }
        ]
        return encodeJSON(payload)
    }

    static func hardwarePayloadJSON(snapshot: SystemSnapshot, includeTopAndPorts: Bool) -> String {
        var payload = coreHardwarePayload(snapshot)
        for (key, value) in peripheralHardwarePayload(snapshot) {
            payload[key] = value
        }
        if includeTopAndPorts {
            let round1 = { (value: Double) in (value * 10).rounded() / 10 }
            payload["top_apps"] = snapshot.busiest(metric: .cpu, limit: 10).map { group in
                [
                    "name": group.name,
                    "cpu_percent": round1(group.cpuPercent),
                    "memory_bytes": group.memoryBytes
                ] as [String: Any]
            }
            payload["dev_servers_count"] = snapshot.devServers.count
            payload["agents_count"] = snapshot.agents.count
        }
        return encodeJSON(payload)
    }

    private static func coreHardwarePayload(_ snapshot: SystemSnapshot) -> [String: Any] {
        let round1 = { (value: Double) in (value * 10).rounded() / 10 }
        let round2 = { (value: Double) in (value * 100).rounded() / 100 }
        let cpuPayload: [String: Any] = [
            "usage_percent": round1(snapshot.cpu.usagePercent),
            "user_percent": round1(snapshot.cpu.userPercent),
            "system_percent": round1(snapshot.cpu.systemPercent),
            "logical_cores": snapshot.cpu.logicalCoreCount,
            "physical_cores": snapshot.cpu.physicalCoreCount,
            "performance_cores": jsonValue(snapshot.cpu.performanceCoreCount),
            "efficiency_cores": jsonValue(snapshot.cpu.efficiencyCoreCount),
            "load_average_1m": round2(snapshot.cpu.loadAverage1),
            "load_average_5m": round2(snapshot.cpu.loadAverage5),
            "load_average_15m": round2(snapshot.cpu.loadAverage15)
        ]
        let memoryPayload: [String: Any] = [
            "total_bytes": snapshot.memory.totalBytes,
            "used_bytes": snapshot.memory.usedBytes,
            "app_bytes": snapshot.memory.appBytes,
            "wired_bytes": snapshot.memory.wiredBytes,
            "compressed_bytes": snapshot.memory.compressedBytes,
            "cached_bytes": snapshot.memory.cachedBytes,
            "swap_used_bytes": snapshot.memory.swapUsedBytes,
            "pressure": snapshot.memory.pressureLabel,
            "pressure_level": snapshot.memory.pressureLevel
        ]
        let diskPayload: [String: Any] = [
            "read_bytes_per_second": round1(snapshot.disk.readBytesPerSecond),
            "write_bytes_per_second": round1(snapshot.disk.writeBytesPerSecond),
            "read_iops": round1(snapshot.disk.readOperationsPerSecond),
            "write_iops": round1(snapshot.disk.writeOperationsPerSecond),
            "total_read_bytes": jsonValue(snapshot.disk.totalReadBytes),
            "total_write_bytes": jsonValue(snapshot.disk.totalWriteBytes)
        ]
        let networkPayload: [String: Any] = [
            "download_bytes_per_second": round1(snapshot.network.downloadBytesPerSecond),
            "upload_bytes_per_second": round1(snapshot.network.uploadBytesPerSecond),
            "primary_interface": jsonValue(snapshot.network.primaryInterface)
        ]
        return [
            "timestamp": Date.ISO8601FormatStyle().format(snapshot.timestamp),
            "thermal_pressure": snapshot.thermalPressure.rawValue,
            "cpu": cpuPayload,
            "memory": memoryPayload,
            "disk": diskPayload,
            "network": networkPayload
        ]
    }

    private static func peripheralHardwarePayload(_ snapshot: SystemSnapshot) -> [String: Any] {
        var result = graphicsAndSensorPayload(snapshot)
        for (key, value) in powerAndPeripheralPayload(snapshot) {
            result[key] = value
        }
        return result
    }

    private static func graphicsAndSensorPayload(_ snapshot: SystemSnapshot) -> [String: Any] {
        let round1 = { (value: Double) in (value * 10).rounded() / 10 }
        let gpus: [[String: Any]] = snapshot.gpu.devices.map { gpu in
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
        let neural: [String: Any] = [
            "is_apple_silicon": snapshot.neural.isAppleSilicon,
            "is_measurable": snapshot.neural.isMeasurable,
            "utilization_percent": jsonValue(snapshot.neural.utilizationPercent.map(round1))
        ]
        let sensors: [[String: Any]] = snapshot.sensors.map {
            ["key": $0.key, "name": $0.name, "celsius": round1($0.celsius)]
        }
        let fans: [[String: Any]] = snapshot.fans.map { fan in
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
        return [
            "gpu": gpus,
            "neural_engine": neural,
            "sensors": sensors,
            "fans": fans
        ]
    }

    private static func powerAndPeripheralPayload(_ snapshot: SystemSnapshot) -> [String: Any] {
        let round1 = { (value: Double) in (value * 10).rounded() / 10 }
        let round2 = { (value: Double) in (value * 100).rounded() / 100 }
        let power: [String: Any] = [
            "has_battery": snapshot.power.hasBattery,
            "level_percent": jsonValue(snapshot.power.level.map { round1($0 * 100) }),
            "is_charging": snapshot.power.isCharging,
            "is_plugged_in": snapshot.power.isPluggedIn,
            "is_charged": snapshot.power.isCharged,
            "cycle_count": jsonValue(snapshot.power.cycleCount),
            "health_percent": jsonValue(snapshot.power.healthFraction.map { round1($0 * 100) }),
            "temperature_celsius": jsonValue(snapshot.power.temperatureCelsius.map(round1)),
            "wattage": jsonValue(snapshot.power.wattage.map(round2)),
            "power_source": jsonValue(snapshot.power.powerSource),
            "assertions_count": snapshot.power.assertions.count
        ]
        let audio: [String: Any] = [
            "output_name": jsonValue(snapshot.audio.outputName),
            "output_volume": jsonValue(snapshot.audio.outputVolume.map(round2)),
            "output_muted": jsonValue(snapshot.audio.outputMuted),
            "input_name": jsonValue(snapshot.audio.inputName),
            "input_muted": jsonValue(snapshot.audio.inputMuted),
            "microphone_active": snapshot.audio.isMicrophoneActive
        ]
        let bluetooth: [[String: Any]] = snapshot.bluetooth.map { device in
            [
                "name": device.name,
                "kind": jsonValue(device.kind),
                "connected": device.isConnected,
                "battery_levels": device.batteryLevels
            ]
        }
        return [
            "power": power,
            "audio": audio,
            "bluetooth": bluetooth
        ]
    }

    private static func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    static func encodeJSON(_ value: Any) -> String {
        guard let data = JSONSanitizing.data(value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static let shared = SnapshotCache()

    static func sharedSnapshot(needsSlowProbes: Bool) async -> SystemSnapshot {
        if let cached = shared.get() {
            return cached
        }
        let snapshot = await MonitorCLI.oneShot(includesSlowProbes: needsSlowProbes)
        if needsSlowProbes {
            shared.store(snapshot)
        }
        return snapshot
    }

    private final class SnapshotCache: @unchecked Sendable {
        private struct Entry {
            var snapshot: SystemSnapshot
            var at: Date
        }

        private let lock = NSLock()
        private var entry: Entry?
        nonisolated private static let window: TimeInterval = 3

        func get(now: Date = Date()) -> SystemSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry, now.timeIntervalSince(entry.at) < Self.window else { return nil }
            return entry.snapshot
        }

        func store(_ snapshot: SystemSnapshot, now: Date = Date()) {
            lock.lock()
            defer { lock.unlock() }
            entry = Entry(snapshot: snapshot, at: now)
        }
    }
}
#endif
