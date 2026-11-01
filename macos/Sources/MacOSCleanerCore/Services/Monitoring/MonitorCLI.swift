import Foundation

/// The `tidybyte monitor` command line: one-shot system readings as text
/// tables or JSON. Shares the app's probes, so the terminal and the AI
/// assistants see exactly what the window sees. No process is ever signalled
/// from the CLI — monitoring only.
public enum MonitorCLI {
    public static let usage = """
        Usage: tidybyte monitor <command> [--json]

        Commands:
          status    CPU, memory, disk, network, battery, sensors, uptime
          top       The busiest apps right now (default 10)
          ports     Listening servers, grouped by project, idle ones flagged
          agents    Running coding agents, their projects and children
          limits    Metered plan usage the local agent state knows about
        """

    /// Runs the monitor subcommand. Returns the process exit code.
    public static func run(_ arguments: [String]) async -> Int32 {
        let wantsJSON = arguments.contains("--json")
        let command = arguments.first { !$0.hasPrefix("--") }
        guard let command else {
            FileHandle.standardError.write(Data(usage.utf8))
            return 2
        }
        let snapshot = await oneShot()
        switch command {
        case "status":
            print(wantsJSON ? statusJSON(snapshot) : statusTable(snapshot))
        case "top":
            print(wantsJSON ? topJSON(snapshot) : topTable(snapshot))
        case "ports":
            print(wantsJSON ? portsJSON(snapshot) : portsTable(snapshot))
        case "agents":
            print(wantsJSON ? agentsJSON(snapshot) : agentsTable(snapshot))
        case "limits":
            print(wantsJSON ? limitsJSON(snapshot) : limitsTable(snapshot))
        case "help", "-h", "--help":
            print(usage)
        default:
            FileHandle.standardError.write(Data("Unknown command: \(command)\n\n\(usage)".utf8))
            return 2
        }
        return 0
    }

    /// One sampling pass, with the slow probes that make ports and agents
    /// meaningful. Cheap probes only would leave those lists empty. The
    /// engine stays lightweight: docker, bluetooth, and pmset can each take
    /// seconds, and a one-shot CLI run does not need them. Callers that only
    /// render status (no per-process detail) pass `includesSlowProbes: false`
    /// to skip the nettop/lsof round entirely.
    public static func oneShot(includesSlowProbes: Bool = true) async -> SystemSnapshot {
        let engine = MonitoringEngine(
            history: nil, alertEngine: nil, isLightweight: true, includesSlowProbes: includesSlowProbes)
        // Two ticks: the first establishes counter baselines, the second
        // produces real rates.
        _ = await engine.sample(interval: 1)
        var snapshot = await engine.sample(interval: 1)
        if snapshot.groups.isEmpty {
            snapshot.groups = AppProcessCatalog.group(snapshot.processes, mode: .byApp)
        }
        await engine.shutdown()
        return snapshot
    }

    // MARK: - Tables

    static func statusTable(_ snapshot: SystemSnapshot) -> String {
        var lines: [String] = []
        let userPercent = percentString(snapshot.cpu.userPercent)
        let systemPercent = percentString(snapshot.cpu.systemPercent)
        lines.append("CPU \(percentString(snapshot.cpu.usagePercent))  (user \(userPercent), system \(systemPercent))")
        let used = snapshot.memory.usedBytes.formattedByteCount
        let total = snapshot.memory.totalBytes.formattedByteCount
        let swap = snapshot.memory.swapUsedBytes.formattedByteCount
        lines.append("Memory \(used) of \(total), swap \(swap)")
        lines.append(
            "Disk read \(snapshot.disk.readBytesPerSecond.formattedByteRate), write \(snapshot.disk.writeBytesPerSecond.formattedByteRate)")
        let down = snapshot.network.downloadBytesPerSecond.formattedByteRate
        let up = snapshot.network.uploadBytesPerSecond.formattedByteRate
        lines.append("Network down \(down), up \(up)")
        lines.append("Load \(String(format: "%.2f", snapshot.cpu.loadAverage1)) (\(snapshot.cpu.logicalCoreCount) cores)")
        if let sensor = snapshot.sensors.first {
            lines.append("Temperature \(String(format: "%.0f", sensor.celsius))°C (\(sensor.name))")
        }
        if snapshot.power.hasBattery, let level = snapshot.power.level {
            let charging = snapshot.power.isCharging ? ", charging" : ""
            lines.append("Battery \(percentString(level * 100))\(charging)")
        }
        lines.append("Uptime \(snapshot.uptime.formattedDuration)")
        lines.append("Processes \(snapshot.processes.count) in \(snapshot.groups.count) apps")
        return lines.joined(separator: "\n")
    }

    static func topTable(_ snapshot: SystemSnapshot) -> String {
        let busiest = snapshot.busiest(metric: .cpu, limit: 10)
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

    static func portsTable(_ snapshot: SystemSnapshot) -> String {
        guard !snapshot.devServers.isEmpty else { return "No listening dev servers." }
        return renderTable(header: "PROJECT        PORT   PID     PROCESS        STATE", rows: snapshot.devServers.map { server in
            [
                column(server.project, width: 16),
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

    /// Pads to a column width but never truncates — an app longer than the
    /// column shifts the row instead of losing its identity.
    static func column(_ text: String, width: Int) -> String {
        text.count >= width ? text + "  " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    static func renderTable(header: String, rows: [String]) -> String {
        ([header] + rows).joined(separator: "\n")
    }

    static func percentString(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    // MARK: - JSON

    /// Sanitize-then-serialize through the shared Core pipeline: one NaN
    /// sensor reading must drop to 0, not make the whole payload print "{}".

    public static func statusJSON(_ snapshot: SystemSnapshot) -> String {
        encode([
            "cpu_percent": round1(snapshot.cpu.usagePercent),
            "cpu_user_percent": round1(snapshot.cpu.userPercent),
            "cpu_system_percent": round1(snapshot.cpu.systemPercent),
            "load_average_1m": round2(snapshot.cpu.loadAverage1),
            "cores": snapshot.cpu.logicalCoreCount,
            "memory_used_bytes": snapshot.memory.usedBytes,
            "memory_total_bytes": snapshot.memory.totalBytes,
            "swap_used_bytes": snapshot.memory.swapUsedBytes,
            "disk_read_bytes_per_second": round1(snapshot.disk.readBytesPerSecond),
            "disk_write_bytes_per_second": round1(snapshot.disk.writeBytesPerSecond),
            "network_download_bytes_per_second": round1(snapshot.network.downloadBytesPerSecond),
            "network_upload_bytes_per_second": round1(snapshot.network.uploadBytesPerSecond),
            "temperature_celsius": snapshot.sensors.first.map { round1($0.celsius) },
            "battery_percent": snapshot.power.level.map { round1($0 * 100) },
            "battery_charging": snapshot.power.isCharging,
            "uptime_seconds": Int(snapshot.uptime),
            "processes": snapshot.processes.count,
            "apps": snapshot.groups.count
        ])
    }

    public static func topJSON(_ snapshot: SystemSnapshot) -> String {
        encode(snapshot.busiest(metric: .cpu, limit: 10).map { group in
            [
                "app": group.name,
                "bundle_path": group.bundlePath,
                "cpu_percent": round1(group.cpuPercent),
                "memory_bytes": group.memoryBytes,
                "disk_bytes_per_second": round1(group.diskReadPerSecond + group.diskWritePerSecond),
                "network_bytes_per_second": round1(group.downloadPerSecond + group.uploadPerSecond),
                "pids": group.members.map { Int($0.pid) }
            ] as [String: Any?]
        })
    }

    public static func portsJSON(_ snapshot: SystemSnapshot) -> String {
        encode(snapshot.devServers.map { server in
            [
                "project": server.project,
                "project_root": server.projectRoot,
                "port": server.port,
                "pid": Int(server.pid),
                "process": server.processName,
                "idle": server.isIdle,
                "cpu_percent": round1(server.cpuPercent)
            ] as [String: Any?]
        })
    }

    public static func agentsJSON(_ snapshot: SystemSnapshot) -> String {
        encode(snapshot.agents.map { agent in
            [
                "agent": agent.kind.rawValue,
                "pid": Int(agent.id),
                "project_root": agent.projectRoot,
                "cpu_percent": round1(agent.cpuPercent),
                "children": agent.children.map { ["pid": Int($0.id), "name": $0.name] },
                "usage": agent.usage.map {
                    [
                        "plan": $0.planName,
                        "used_fraction": $0.usedFraction.map { round2($0) },
                        "resets_at": $0.resetsAt.map { Int($0.timeIntervalSince1970) }
                    ] as [String: Any?]
                }
            ] as [String: Any?]
        })
    }

    public static func limitsJSON(_ snapshot: SystemSnapshot) -> String {
        encode(snapshot.agents.compactMap(\.usage).map { usage in
            [
                "plan": usage.planName,
                "used_fraction": usage.usedFraction.map { round2($0) },
                "window": usage.window,
                "resets_at": usage.resetsAt.map { Int($0.timeIntervalSince1970) }
            ] as [String: Any?]
        })
    }

    static func encode(_ value: Any) -> String {
        guard let data = JSONSanitizing.data(value, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
