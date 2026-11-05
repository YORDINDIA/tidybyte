import Foundation

/// Listens on TCP/UDP ports, the processes behind them, and the dev servers
/// among them grouped by the project directory each process was started in.
/// An idle server — listening but burning no CPU — gets flagged, because a
/// forgotten dev server is the thing people actually want this list for.
public enum DevEnvironmentProbe {
    /// Runs `lsof` for listeners and working directories, then classifies.
    /// `processes` supplies names and CPU rates so nothing is re-probed.
    public static func servers(processes: [ProcessSample]) async -> [DevServerReading] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let listeners = await listeners()
        let projects = await workingDirectories(pids: Set(listeners.map(\.pid)))
        var seen = Set<String>()
        var readings: [DevServerReading] = []
        for listener in listeners {
            let id = "\(listener.pid)-\(listener.port)"
            guard seen.insert(id).inserted else { continue }
            let process = byPID[listener.pid]
            let project = Self.project(for: listener, workingDirectory: projects[listener.pid], process: process)
            readings.append(
                DevServerReading(
                    project: project.name,
                    projectRoot: project.root,
                    port: listener.port,
                    address: listener.address,
                    pid: listener.pid,
                    processName: process?.name ?? listener.command,
                    isIdle: (process?.cpuPercent ?? 0) < Self.idleCPUPercent,
                    cpuPercent: process?.cpuPercent ?? 0))
        }
        return readings.sorted { $0.project < $1.project }
    }

    /// Below this CPU rate a listening server counts as idle.
    static let idleCPUPercent: Double = 2

    public struct TCPListener: Sendable, Equatable {
        public var pid: pid_t
        public var command: String
        public var port: Int
        public var address: String

        public init(pid: pid_t, command: String, port: Int, address: String) {
            self.pid = pid
            self.command = command
            self.port = port
            self.address = address
        }
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN`; one line per listening socket.
    static func listeners() async -> [TCPListener] {
        guard let output = try? await SystemTool.run("/usr/sbin/lsof", arguments: [
            "-nP", "-iTCP", "-sTCP:LISTEN"
        ]) else { return [] }
        return parseListeners(output)
    }

    /// Parses the lsof table. Pure and testable. The NAME column (index 8) is
    /// split last so names containing spaces survive whole.
    public static func parseListeners(_ output: String) -> [TCPListener] {
        var result: [TCPListener] = []
        for line in output.split(separator: "\n").dropFirst() {
            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            let columns = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME — TYPE is
            // IPv4/IPv6, NODE is TCP.
            guard columns.count >= 9, columns[4] == "IPv4" || columns[4] == "IPv6",
                columns[7] == "TCP", let pid = pid_t(columns[1]), let port = parsePort(columns[8]) else {
                continue
            }
            let name = String(columns[8])
            result.append(
                TCPListener(
                    pid: pid,
                    command: String(columns[0]),
                    port: port,
                    address: Self.address(of: name)))
        }
        return result
    }

    /// Splits an lsof NAME column into its address and port: "*:5173" and
    /// "127.0.0.1:8080 (LISTEN)" both parse; a name without a trailing port
    /// is nil. Shared with the inspector's port bindings.
    static func lsofName(_ name: Substring) -> (address: String, port: Int)? {
        guard let colon = name.lastIndex(of: ":"), colon > name.startIndex else { return nil }
        // lsof may append " (LISTEN)"; take the digits before any space.
        let digits = name[name.index(after: colon)...].prefix { $0.isNumber }
        guard let port = Int(digits) else { return nil }
        return (String(name[name.startIndex..<colon]), port)
    }

    /// "*:5173" → 5173, "127.0.0.1:8080 (LISTEN)" → 8080.
    static func parsePort(_ name: Substring) -> Int? {
        lsofName(name)?.port
    }

    /// Working directories of the given pids, so servers can be attributed to
    /// the project folder they were launched from. The pids go on the command
    /// line in chunks, so the scan touches only those processes instead of
    /// every process on the machine.
    static func workingDirectories(pids: Set<pid_t>) async -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let sorted = pids.sorted()
        var result: [pid_t: String] = [:]
        let chunkSize = 64
        for start in stride(from: 0, to: sorted.count, by: chunkSize) {
            let chunk = sorted[start..<min(start + chunkSize, sorted.count)]
            let pidList = chunk.map(String.init).joined(separator: ",")
            guard let output = try? await SystemTool.run("/usr/sbin/lsof", arguments: [
                "-a", "-p", pidList, "-d", "cwd", "-Fn", "-nP"
            ]) else { continue }
            for (pid, directory) in parseWorkingDirectories(output, pids: pids) {
                result[pid] = directory
            }
        }
        return result
    }

    /// lsof -F0 format: `p<pid>` starts a record, `n<path>` is the directory.
    public static func parseWorkingDirectories(_ output: String, pids: Set<pid_t>) -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        var currentPID: pid_t = 0
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            guard line.count > 1 else { continue }
            let tag = line.first!
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                currentPID = pid_t(value.trimmingCharacters(in: .whitespaces)) ?? 0
            case "n":
                if pids.contains(currentPID), value.hasPrefix("/") {
                    result[currentPID] = value
                }
            default:
                break
            }
        }
        return result
    }

    /// A dev server belongs to the project whose folder it runs in; the name
    /// is the last meaningful path component.
    static func project(
        for listener: TCPListener, workingDirectory: String?, process: ProcessSample?
    ) -> (name: String, root: String?) {
        guard let directory = workingDirectory, directory.hasPrefix("/") else {
            return (listener.command, nil)
        }
        var url = URL(fileURLWithPath: directory)
        // Skip inside src/packages/apps folders to find the repo root when
        // the server was started from a subfolder.
        var candidate = url
        while candidate.pathComponents.count > 2 {
            if isProjectMarker(directory: candidate.path) {
                url = candidate
                break
            }
            guard candidate.pathComponents.count > 1 else { break }
            candidate.deleteLastPathComponent()
        }
        let name = url.lastPathComponent.isEmpty ? listener.command : url.lastPathComponent
        return (name, url.path)
    }

    static func isProjectMarker(directory: String) -> Bool {
        let manager = FileManager.default
        let markers = [".git", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Gemfile", "Makefile", "pubspec.yaml"]
        return markers.contains { manager.fileExists(atPath: directory + "/" + $0) }
    }
}

extension DevEnvironmentProbe {
    /// The host part of an lsof socket name: everything before the final
    /// colon, with any " (LISTEN)"-style suffix already excluded.
    public static func address(of name: String) -> String {
        guard let colon = name.lastIndex(of: ":"), colon > name.startIndex else { return name }
        return String(name[name.startIndex..<colon])
    }
}

/// Docker containers with live resource figures. Absent Docker Desktop is an
/// empty list, never an error — plenty of Macs run none.
public enum ContainerProbe {
    public static func containers() async -> [ContainerReading] {
        guard let docker = dockerBinary() else { return [] }
        guard let listOutput = try? await SystemTool.run(docker, arguments: [
            "ps", "--format", "{{json .}}"
        ]) else { return [] }
        let listed = parseContainerList(listOutput)
        guard !listed.isEmpty,
            let statsOutput = try? await SystemTool.run(docker, arguments: [
                "stats", "--no-stream", "--format", "{{json .}}"
            ]) else {
            return listed.map { item in
                ContainerReading(
                    containerID: item.id, name: item.name, image: item.image, state: item.state,
                    ports: item.ports)
            }
        }
        let stats = parseStats(statsOutput)
        return listed.map { item in
            guard let stat = stats[item.name] ?? stats[item.id] else {
                return ContainerReading(
                    containerID: item.id, name: item.name, image: item.image, state: item.state,
                    ports: item.ports)
            }
            return ContainerReading(
                containerID: item.id, name: item.name, image: item.image, state: item.state,
                cpuPercent: stat.cpuPercent,
                memoryBytes: stat.memoryBytes, memoryLimitBytes: stat.memoryLimitBytes,
                networkRxBytes: stat.networkRxBytes, networkTxBytes: stat.networkTxBytes,
                ports: item.ports)
        }
    }

    static func dockerBinary() -> String? {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct ListedContainer: Sendable, Equatable {
        public var id: String
        public var name: String
        public var image: String
        public var state: String
        public var ports: [String]
    }

    /// `docker ps --format {{json .}}` — one JSON object per line.
    public static func parseContainerList(_ output: String) -> [ListedContainer] {
        output.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let id = (object["ID"] as? String) ?? (object["Id"] as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let names = (object["Names"] as? String) ?? ""
            let portsText = (object["Ports"] as? String) ?? ""
            return ListedContainer(
                id: id,
                name: names.components(separatedBy: ",").first ?? id,
                image: (object["Image"] as? String) ?? "",
                state: (object["State"] as? String) ?? "",
                ports: portsText.split(separator: ", ").map(String.init))
        }
    }

    public struct ContainerStats: Sendable, Equatable {
        public var cpuPercent: Double = 0
        public var memoryBytes: Int64 = 0
        public var memoryLimitBytes: Int64?
        public var networkRxBytes: Int64 = 0
        public var networkTxBytes: Int64 = 0
    }

    /// `docker stats --no-stream --format {{json .}}` — one object per line,
    /// sizes and rates as human strings ("45.2MB", "0.15%").
    public static func parseStats(_ output: String) -> [String: ContainerStats] {
        var result: [String: ContainerStats] = [:]
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var stats = ContainerStats()
            stats.cpuPercent = Self.parsePercentString(object["CPUPerc"] as? String)
            let memory = object["MemUsage"] as? String ?? ""
            let parts = memory.components(separatedBy: " / ")
            stats.memoryBytes = parseSizeString(parts.first)
            if parts.count > 1 { stats.memoryLimitBytes = parseSizeString(parts.last) }
            let network = object["NetIO"] as? String ?? ""
            let networkParts = network.components(separatedBy: " / ")
            stats.networkRxBytes = parseSizeString(networkParts.first)
            if networkParts.count > 1 { stats.networkTxBytes = parseSizeString(networkParts.last) }
            let id = (object["ID"] as? String) ?? ""
            let name = (object["Name"] as? String) ?? ""
            if !id.isEmpty { result[id] = stats }
            if !name.isEmpty { result[name] = stats }
        }
        return result
    }

    static func parsePercentString(_ text: String?) -> Double {
        guard let text else { return 0 }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        return Double(digits) ?? 0
    }

    /// "45.2MB" → bytes; "1.234GB", "512kB", "1.5GiB" all handled.
    public static func parseSizeString(_ text: String?) -> Int64 {
        guard let text else { return 0 }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return 0 }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        return Self.clampedBytes(value: value, unit: unit)
    }

    /// docker stats prints decimal units (1 GB = 10^9); the iB forms are
    /// binary. Anything unrecognized counts as bytes. Absurd values clamp to
    /// Int64 bounds instead of trapping the conversion.
    private static func clampedBytes(value: Double, unit: String) -> Int64 {
        let multiplier: Double = switch unit {
        case "gb": 1_000_000_000
        case "mb": 1_000_000
        case "kb": 1_000
        case "gib": 1024 * 1024 * 1024
        case "mib": 1024 * 1024
        case "kib": 1024
        case "b": 1
        default: 1
        }
        let product = value * multiplier
        guard product.isFinite else { return 0 }
        return product >= Double(Int64.max) ? Int64.max : Int64(product)
    }
}
