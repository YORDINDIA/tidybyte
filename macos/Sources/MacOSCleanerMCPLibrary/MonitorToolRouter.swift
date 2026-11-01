import Foundation
import MacOSCleanerCore

/// The five read-only monitor tools. Kept out of MCPKit so the cleanup
/// dispatcher stays small; the agent-facing contract is unchanged apart from
/// these additions.
enum MonitorToolRouter {
    /// One tool: its descriptor, whether it needs the slow process probes
    /// (nettop, lsof — see `MonitorCLI.oneShot`), and how it renders a
    /// snapshot. Descriptor and routing both come from this table, so a
    /// rename updates both and can never degrade to an unknown-tool error.
    private struct Tool: Sendable {
        var name: String
        var description: String
        var needsSlowProbes: Bool
        var render: @Sendable (SystemSnapshot) -> String
    }

    private static let tools: [Tool] = [
        Tool(
            name: "monitor_status",
            description: "One-shot system monitor reading: CPU, memory, disk and network rates, load, "
                + "battery, uptime, process counts. Read-only.",
            needsSlowProbes: false,
            render: MonitorCLI.statusJSON),
        Tool(
            name: "monitor_top",
            description: "The busiest apps right now with CPU, memory, disk and network rates. Helpers are "
                + "grouped under their parent app. Read-only.",
            needsSlowProbes: true,
            render: MonitorCLI.topJSON),
        Tool(
            name: "monitor_ports",
            description: "Listening dev servers grouped by project, idle ones flagged. Read-only.",
            needsSlowProbes: true,
            render: MonitorCLI.portsJSON),
        Tool(
            name: "monitor_agents",
            description: "Running coding agents (Claude Code, Codex, Gemini CLI, ...), their projects, the "
                + "processes they started, and any local plan-usage data. Read-only.",
            needsSlowProbes: true,
            render: MonitorCLI.agentsJSON),
        Tool(
            name: "monitor_limits",
            description: "Metered plan usage the local agent state files know about, when present. Read-only.",
            needsSlowProbes: true,
            render: MonitorCLI.limitsJSON)
    ]

    /// Tool descriptors for tools/list, in contract order.
    static var toolDescriptions: [[String: Any]] {
        tools.map { MCPKit.tool($0.name, $0.description, [:]) }
    }

    /// Handles a monitor tool call, or returns nil for other tools. Sampling
    /// only: no tool here ever signals a process.
    static func handle(name: String) async -> String? {
        guard let tool = tools.first(where: { $0.name == name }) else { return nil }
        let snapshot = await sharedSnapshot(needsSlowProbes: tool.needsSlowProbes)
        return tool.render(snapshot)
    }

    // MARK: - Snapshot sharing

    /// Agents tend to call several monitor tools back to back, and each full
    /// sample costs two engine ticks plus a handful of process spawns (nettop,
    /// lsof). A short-TTL shared snapshot keeps a burst on one sample. Only
    /// full-detail snapshots enter the cache, so a cheap status sample can
    /// never stand in for a tool that needs the process detail.
    private static let shared = SnapshotCache()

    private static func sharedSnapshot(needsSlowProbes: Bool) async -> SystemSnapshot {
        if let cached = shared.get() {
            return cached
        }
        let snapshot = await MonitorCLI.oneShot(includesSlowProbes: needsSlowProbes)
        if needsSlowProbes {
            shared.store(snapshot)
        }
        return snapshot
    }

    /// The only mutable state is `entry`, guarded by the lock — hence the
    /// `@unchecked Sendable`.
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
