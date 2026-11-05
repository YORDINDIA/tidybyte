import Foundation

// Readings for the developer-facing surfaces: dev servers, coding agents,
// and containers. Split out of SystemSnapshot.swift to keep both files small.

// MARK: - Dev servers

public struct DevServerReading: Sendable, Equatable, Identifiable {
    public var id: String { "\(pid)-\(port)-\(address)" }
    public var project: String
    public var projectRoot: String?
    public var port: Int
    public var address: String
    public var pid: pid_t
    public var processName: String
    /// Listening but doing no work: a server someone forgot about.
    public var isIdle: Bool
    public var cpuPercent: Double

    public init(
        project: String, projectRoot: String? = nil, port: Int, address: String, pid: pid_t,
        processName: String, isIdle: Bool = false, cpuPercent: Double = 0
    ) {
        self.project = project
        self.projectRoot = projectRoot
        self.port = port
        self.address = address
        self.pid = pid
        self.processName = processName
        self.isIdle = isIdle
        self.cpuPercent = cpuPercent
    }
}

// MARK: - Coding agents

public struct AgentSessionReading: Sendable, Equatable, Identifiable {
    public var id: pid_t
    public var kind: AgentKind
    public var processName: String
    public var startedAt: Date?
    public var projectRoot: String?
    public var cpuPercent: Double
    public var cpuTimeSeconds: Double
    public var children: [AgentChildReading]
    public var usage: AgentUsageReading?

    public init(
        id: pid_t, kind: AgentKind, processName: String, startedAt: Date? = nil,
        projectRoot: String? = nil, cpuPercent: Double = 0, cpuTimeSeconds: Double = 0,
        children: [AgentChildReading] = [], usage: AgentUsageReading? = nil
    ) {
        self.id = id
        self.kind = kind
        self.processName = processName
        self.startedAt = startedAt
        self.projectRoot = projectRoot
        self.cpuPercent = cpuPercent
        self.cpuTimeSeconds = cpuTimeSeconds
        self.children = children
        self.usage = usage
    }
}

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, gemini, cursor, copilot, aider, opencode, amp, droid, kimi, qwen, other

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .cursor: "Cursor Agent"
        case .copilot: "GitHub Copilot"
        case .aider: "Aider"
        case .opencode: "OpenCode"
        case .amp: "Amp"
        case .droid: "Droid"
        case .kimi: "Kimi"
        case .qwen: "Qwen Code"
        case .other: String(localized: "Coding agent", comment: "Generic coding agent name")
        }
    }
}

public struct AgentChildReading: Sendable, Equatable, Identifiable {
    public var id: pid_t
    public var name: String
    public var cpuPercent: Double

    public init(id: pid_t, name: String, cpuPercent: Double = 0) {
        self.id = id
        self.name = name
        self.cpuPercent = cpuPercent
    }
}

/// What an agent's local state says about a metered plan. Read from local
/// files only; when nothing local reports usage this stays nil.
public struct AgentUsageReading: Sendable, Equatable {
    public var planName: String
    /// 0…1 of the current window consumed.
    public var usedFraction: Double?
    public var window: String?
    public var resetsAt: Date?

    public init(planName: String, usedFraction: Double? = nil, window: String? = nil, resetsAt: Date? = nil) {
        self.planName = planName
        self.usedFraction = usedFraction
        self.window = window
        self.resetsAt = resetsAt
    }
}

// MARK: - Containers

public struct ContainerReading: Sendable, Equatable, Identifiable {
    public var id: String { containerID }
    public var containerID: String
    public var name: String
    public var image: String
    public var state: String
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public var memoryLimitBytes: Int64?
    public var networkRxBytes: Int64
    public var networkTxBytes: Int64
    public var ports: [String]

    public init(
        containerID: String, name: String, image: String, state: String, cpuPercent: Double = 0,
        memoryBytes: Int64 = 0, memoryLimitBytes: Int64? = nil, networkRxBytes: Int64 = 0,
        networkTxBytes: Int64 = 0, ports: [String] = []
    ) {
        self.containerID = containerID
        self.name = name
        self.image = image
        self.state = state
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
        self.ports = ports
    }
}
