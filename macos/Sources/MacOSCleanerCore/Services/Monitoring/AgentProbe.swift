import Foundation

/// Watches coding agents as processes: which CLIs are running, which project
/// they were started in, what they spawned, and what their local state says
/// about metered plan usage. Detection is by executable and command-line
/// patterns; usage readers are strictly read-only.
public enum AgentProbe {
    public static func sessions(processes: [ProcessSample], workingDirectories: [pid_t: String]) async
        -> [AgentSessionReading] {
        let roots = processes.filter { Self.kind(of: $0) != nil }
        var sessions: [AgentSessionReading] = []
        for root in roots {
            let kind = Self.kind(of: root) ?? .other
            let descendants = Self.descendants(of: root, in: processes)
            var usage: AgentUsageReading?
            if let reader = Self.usageReader(for: kind) {
                if let cached = usageCache.cached(pid: root.pid, kind: kind, startedAt: root.startedAt) {
                    usage = cached
                } else {
                    usage = await reader()
                    usageCache.store(usage, pid: root.pid, kind: kind, startedAt: root.startedAt)
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

    public static func kind(of process: ProcessSample) -> AgentKind? {
        if let bundleID = process.bundleID, let kind = kindFromBundleID(bundleID) {
            return kind
        }
        if let path = process.executablePath, let kind = kindFromCommand(path) {
            return kind
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
        let lowered = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fileName = lowered.split(separator: "/").last.map(String.init) ?? lowered
        guard !fileName.isEmpty else { return nil }
        for (pattern, kind) in commandPatterns where matchesCommand(fileName, pattern: pattern) {
            return kind
        }
        return nil
    }

    private static func matchesCommand(_ fileName: String, pattern: String) -> Bool {
        fileName == pattern
            || fileName.hasPrefix(pattern + "-")
            || fileName.hasPrefix(pattern + "_")
            || fileName.hasPrefix(pattern + ".")
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

    /// Direct and indirect children, excluding other agent roots.
    static func descendants(of root: ProcessSample, in processes: [ProcessSample]) -> [ProcessSample] {
        let byParent = Dictionary(grouping: processes, by: { $0.parentPID })
        var result: [ProcessSample] = []
        var queue = byParent[root.pid] ?? []
        var visited = Set<pid_t>([root.pid])
        while let current = queue.popLast() {
            guard visited.insert(current.pid).inserted else { continue }
            guard Self.kind(of: current) == nil else { continue }
            result.append(current)
            queue.append(contentsOf: byParent[current.pid] ?? [])
        }
        return result.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    static func usageReader(for kind: AgentKind) -> (() async -> AgentUsageReading?)? {
        switch kind {
        case .claude: { await ClaudeUsageReader.read() }
        case .codex: { await CodexUsageReader.read() }
        default: nil
        }
    }

    private struct UsageCacheKey: Hashable {
        var pid: pid_t
        var kind: AgentKind
        var startedAt: Date?
    }

    private final class UsageCache: @unchecked Sendable {
        private struct Entry {
            var reading: AgentUsageReading?
            var at: Date
        }

        private let lock = NSLock()
        private var entries: [UsageCacheKey: Entry] = [:]
        nonisolated private static let window: TimeInterval = 180

        /// Double optional distinguishes cache miss (`nil`) from cached absent (`.some(nil)`).
        func cached(pid: pid_t, kind: AgentKind, startedAt: Date?, now: Date = Date()) -> AgentUsageReading?? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[UsageCacheKey(pid: pid, kind: kind, startedAt: startedAt)],
                  now.timeIntervalSince(entry.at) < Self.window else { return nil }
            return .some(entry.reading)
        }

        func store(_ reading: AgentUsageReading?, pid: pid_t, kind: AgentKind, startedAt: Date?, now: Date = Date()) {
            lock.lock()
            defer { lock.unlock() }
            entries[UsageCacheKey(pid: pid, kind: kind, startedAt: startedAt)] = Entry(reading: reading, at: now)
            entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.window }
        }
    }

    private static let usageCache = UsageCache()
}

/// Reads Claude Code's local usage snapshot from its local config/SQLite files.
enum ClaudeUsageReader {
    static func read() async -> AgentUsageReading? {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        for filename in ["rate_limits.json", "usage.json", "policy-limits.json"] {
            let url = directory.appendingPathComponent(filename)
            if let raw = try? String(contentsOf: url, encoding: .utf8),
               let parsed = Self.parse(raw) {
                return parsed
            }
        }
        let store = directory.appendingPathComponent("__store.db")
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        guard let output = try? await SystemTool.run("/usr/bin/sqlite3", arguments: [
            "-readonly", "-cmd", ".timeout 1000", store.path,
            "SELECT value FROM keyvalue WHERE key LIKE '%rate_limit%' LIMIT 1;"
        ]) else { return nil }
        return Self.parse(output)
    }

    private static let iso8601Style = Date.ISO8601FormatStyle()

    static func parse(_ raw: String, hasUnwrapped: Bool = false) -> AgentUsageReading? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            guard !hasUnwrapped, let inner = extractJSONString(from: raw), inner != raw,
                  let parsed = parse(inner, hasUnwrapped: true) else { return nil }
            return parsed
        }
        let target = unwrapNestedUsageObject(object)
        var reading = AgentUsageReading(planName: String(localized: "Claude plan"))
        if let utilization = numericValue("utilization", in: target) ?? numericValue("used_percent", in: target) {
            reading.usedFraction = min(1, max(0, utilization > 1 ? utilization / 100 : utilization))
        } else if let current = numericValue("current_usage", in: target),
                  let limit = numericValue("usage_limit", in: target), limit > 0 {
            reading.usedFraction = min(1, max(0, current / limit))
        }
        if let window = (target["rate_limit_tier"] as? String) ?? (target["window"] as? String) {
            reading.window = window
        } else if let minutes = numericValue("window_minutes", in: target), minutes > 0 {
            reading.window = "\(Int(minutes))m"
        }
        if let reset = numericValue("resets_at", in: target) {
            reading.resetsAt = Date(timeIntervalSince1970: reset)
        } else if let resetISO = target["resets_at"] as? String {
            reading.resetsAt = try? Self.iso8601Style.parse(resetISO)
        }
        return reading.usedFraction == nil && reading.resetsAt == nil ? nil : reading
    }

    private static func numericValue(_ key: String, in object: [String: Any]) -> Double? {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func unwrapNestedUsageObject(_ object: [String: Any]) -> [String: Any] {
        if let payload = object["payload"] as? [String: Any] {
            return unwrapNestedUsageObject(payload)
        }
        if let rateLimits = object["rate_limits"] as? [String: Any] {
            return unwrapNestedUsageObject(rateLimits)
        }
        for key in ["primary", "five_hour", "seven_day"] {
            if let nested = object[key] as? [String: Any] { return nested }
        }
        return object
    }

    static func extractJSONString(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end else { return nil }
        return String(raw[start...end])
    }
}

/// Reads Codex's local rate-limit snapshots from `~/.codex` files or recent session logs.
enum CodexUsageReader {
    static func read() async -> AgentUsageReading? {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        for name in ["rate_limits.json", "usage.json"] {
            let url = directory.appendingPathComponent(name)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let reading = ClaudeUsageReader.parse(raw) {
                var adjusted = reading
                adjusted.planName = String(localized: "Codex plan")
                return adjusted
            }
        }
        return readLatestSessionRateLimits(in: directory.appendingPathComponent("sessions"))
    }

    private static func readLatestSessionRateLimits(in sessionsDir: URL) -> AgentUsageReading? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sessionsDir.path),
              let enumerator = manager.enumerator(
                  at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]) else { return nil }
        var newest: (url: URL, modified: Date)?
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            if newest == nil || modified > newest?.modified ?? .distantPast {
                newest = (url, modified)
            }
        }
        guard let targetURL = newest?.url,
              let handle = try? FileHandle(forReadingFrom: targetURL) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let tailOffset = fileSize > 65_536 ? fileSize - 65_536 : 0
        try? handle.seek(toOffset: tailOffset)
        guard let tailData = try? handle.readToEnd(),
              let text = String(data: tailData, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            if let reading = ClaudeUsageReader.parse(String(line)) {
                var adjusted = reading
                adjusted.planName = String(localized: "Codex plan")
                return adjusted
            }
        }
        return nil
    }
}
