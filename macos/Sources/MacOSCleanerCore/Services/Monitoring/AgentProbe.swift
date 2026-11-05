import Foundation

/// Watches coding agents as processes: which CLIs are running, which project
/// they were started in, what they spawned, and what their local state says
/// about metered plan usage. Detection is by executable and command-line
/// patterns; usage readers are strictly read-only and honestly say "unknown"
/// when an agent keeps nothing local.
public enum AgentProbe {
    /// Sessions = agent root processes; children = everything they started.
    public static func sessions(processes: [ProcessSample], workingDirectories: [pid_t: String]) async
        -> [AgentSessionReading] {
        let roots = processes.filter { Self.kind(of: $0) != nil }
        var sessions: [AgentSessionReading] = []
        for root in roots {
            let kind = Self.kind(of: root) ?? .other
            let descendants = Self.descendants(of: root, in: processes)
            var usage: AgentUsageReading?
            if let reader = Self.usageReader(for: kind) {
                if let cached = usageCache.cached(pid: root.pid, kind: kind) {
                    usage = cached
                } else {
                    usage = await reader()
                    usageCache.store(usage, pid: root.pid, kind: kind)
                }
            }
            sessions.append(
                AgentSessionReading(
                    id: root.pid,
                    kind: kind,
                    processName: root.name,
                    startedAt: root.startedAt,
                    projectRoot: workingDirectories[root.pid],
                    cpuPercent: root.cpuPercent,
                    cpuTimeSeconds: root.cpuTimeSeconds,
                    children: descendants.map { sample in
                        AgentChildReading(id: sample.pid, name: sample.name, cpuPercent: sample.cpuPercent)
                    },
                    usage: usage))
        }
        return sessions.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Classifies a process as a coding agent, or nil.
    public static func kind(of process: ProcessSample) -> AgentKind? {
        if let bundleID = process.bundleID {
            if let kind = kindFromBundleID(bundleID) { return kind }
        }
        if let path = process.executablePath {
            if let kind = kindFromCommand(path) { return kind }
        }
        return kindFromCommand(process.name)
    }

    static func kindFromBundleID(_ bundleID: String) -> AgentKind? {
        let lowered = bundleID.lowercased()
        for (pattern, kind) in bundleIDPatterns where lowered.contains(pattern) {
            return kind
        }
        return nil
    }

    static func kindFromCommand(_ command: String) -> AgentKind? {
        let lowered = command.lowercased()
        let fileName = lowered.split(separator: "/").last.map(String.init) ?? lowered
        for (pattern, kind) in commandPatterns where fileName == pattern || fileName.hasPrefix(pattern) {
            return kind
        }
        return nil
    }

    static let commandPatterns: [(String, AgentKind)] = [
        ("claude", .claude), ("codex", .codex), ("gemini", .gemini), ("cursor-agent", .cursor),
        ("copilot", .copilot), ("aider", .aider), ("opencode", .opencode), ("amp", .amp),
        ("droid", .droid), ("kimi", .kimi), ("qwen", .qwen)
    ]

    static let bundleIDPatterns: [(String, AgentKind)] = [
        ("claude", .claude), ("openai.codex", .codex), ("google.gemini", .gemini),
        ("github.copilot", .copilot)
    ]

    /// Direct and indirect children, excluding the agent's own kind (an agent
    /// spawning another agent would otherwise recurse forever).
    static func descendants(of root: ProcessSample, in processes: [ProcessSample]) -> [ProcessSample] {
        let byParent = Dictionary(grouping: processes, by: { $0.parentPID })
        var result: [ProcessSample] = []
        var queue = byParent[root.pid] ?? []
        var visited = Set<pid_t>([root.pid])
        while let current = queue.popLast() {
            guard visited.insert(current.pid).inserted else { continue }
            result.append(current)
            queue.append(contentsOf: byParent[current.pid] ?? [])
        }
        return result.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// The read-only local usage reader for an agent, when its CLI keeps
    /// metered-plan state on disk. Nothing here talks to the network.
    static func usageReader(for kind: AgentKind) -> (() async -> AgentUsageReading?)? {
        switch kind {
        case .claude: { await ClaudeUsageReader.read() }
        case .codex: { await CodexUsageReader.read() }
        default: nil
        }
    }

    /// Usage readers spawn `/usr/bin/sqlite3` or read files; the underlying
    /// snapshot moves on hour-scale windows, so each reading is reused for a
    /// few minutes instead of paying a process launch every slow tick.
    /// Keyed by (pid, kind) so a reused pid cannot inherit another session's
    /// plan state.
    private struct UsageCacheKey: Hashable {
        var pid: pid_t
        var kind: AgentKind
    }

    /// The only mutable state is `entries`, guarded by the lock — hence the
    /// `@unchecked Sendable`.
    private final class UsageCache: @unchecked Sendable {
        private struct Entry {
            var reading: AgentUsageReading?
            var at: Date
        }

        private let lock = NSLock()
        private var entries: [UsageCacheKey: Entry] = [:]
        nonisolated private static let window: TimeInterval = 180

        func cached(pid: pid_t, kind: AgentKind, now: Date = Date()) -> AgentUsageReading? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[UsageCacheKey(pid: pid, kind: kind)],
                now.timeIntervalSince(entry.at) < Self.window else { return nil }
            return entry.reading
        }

        func store(_ reading: AgentUsageReading?, pid: pid_t, kind: AgentKind, now: Date = Date()) {
            lock.lock()
            defer { lock.unlock() }
            entries[UsageCacheKey(pid: pid, kind: kind)] = Entry(reading: reading, at: now)
            // Drop expired entries (including exited sessions) so the table
            // stays bounded.
            entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.window }
        }
    }

    private static let usageCache = UsageCache()
}

/// Reads Claude Code's local OAuth usage snapshot from its state store when
/// present. The file is protected from cleanup by PathSafetyPolicy; this only
/// ever reads it. Absence → nil.
enum ClaudeUsageReader {
    static func read() async -> AgentUsageReading? {
        let store = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/__store.db")
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        // The store is SQLite; ask the bundled sqlite3 CLI rather than linking
        // another connection in. Failure is fine — usage stays "unknown".
        guard let output = try? await SystemTool.run("/usr/bin/sqlite3", arguments: [
            store.path, "SELECT value FROM keyvalue WHERE key LIKE '%rate_limit%' LIMIT 1;"
        ]) else { return nil }
        return Self.parse(output)
    }

    /// One format style, reused: allocating an ISO8601DateFormatter per
    /// parsed line shows up in profiles, and the format-style value is
    /// Sendable so strict concurrency is happy too.
    private static let iso8601Style = Date.ISO8601FormatStyle()

    /// The snapshot is JSON with a utilization and reset time; parse loosely
    /// so schema changes degrade to nil instead of crashing. `hasUnwrapped`
    /// allows exactly one unwrap of the stored-as-string form so malformed
    /// input like `{"a":}` cannot recurse forever.
    static func parse(_ raw: String, hasUnwrapped: Bool = false) -> AgentUsageReading? {
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Some snapshots are stored as a JSON string inside the value.
            guard !hasUnwrapped, let inner = extractJSONString(from: raw), inner != raw,
                let parsed = parse(inner, hasUnwrapped: true) else { return nil }
            return parsed
        }
        var reading = AgentUsageReading(planName: String(localized: "Claude plan"))
        if let utilization = object["utilization"] as? Double {
            reading.usedFraction = min(1, utilization > 1 ? utilization / 100 : utilization)
        } else if let current = object["current_usage"] as? Double,
            let limit = object["usage_limit"] as? Double, limit > 0 {
            reading.usedFraction = min(1, current / limit)
        }
        if let window = object["rate_limit_tier"] as? String ?? object["window"] as? String {
            reading.window = window
        }
        if let reset = object["resets_at"] as? Double {
            reading.resetsAt = Date(timeIntervalSince1970: reset)
        } else if let resetISO = object["resets_at"] as? String {
            reading.resetsAt = try? Self.iso8601Style.parse(resetISO)
        }
        return reading.usedFraction == nil && reading.resetsAt == nil ? nil : reading
    }

    static func extractJSONString(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end else { return nil }
        return String(raw[start...end])
    }
}

/// Codex keeps rate-limit snapshots in its session directory; same rules as
/// Claude: local files only, nil when absent.
enum CodexUsageReader {
    static func read() async -> AgentUsageReading? {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        let candidates = ["rate_limits.json", "usage.json"]
        for name in candidates {
            let url = directory.appendingPathComponent(name)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let reading = ClaudeUsageReader.parse(raw) {
                var adjusted = reading
                adjusted.planName = String(localized: "Codex plan")
                return adjusted
            }
        }
        return nil
    }
}
