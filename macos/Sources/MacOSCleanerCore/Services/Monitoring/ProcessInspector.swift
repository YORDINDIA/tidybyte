import Darwin
import Foundation
import Security

/// Everything knowable about one process, for the inspector panel: identity
/// and code signature, parentage, resource totals, open files, listening
/// ports, and outbound connections. Read-only by design.
public struct ProcessInspection: Sendable, Equatable {
    public var pid: pid_t
    public var parentPID: pid_t
    public var parentName: String?
    public var children: [ProcessSample]
    public var commandLine: [String]
    public var executablePath: String?
    public var bundleID: String?
    public var version: String?
    public var startedAt: Date?
    public var cpuTimeSeconds: Double
    public var residentBytes: Int64
    public var footprintBytes: Int64
    public var diskReadBytes: Int64
    public var diskWrittenBytes: Int64
    public var signature: SignatureInfo?
    public var openFiles: [OpenFile]
    public var listeningPorts: [PortBinding]
    public var outboundConnections: [OutboundConnection] = []

    public struct SignatureInfo: Sendable, Equatable {
        public var isSigned: Bool
        public var isValid: Bool
        public var teamID: String?
        public var isSandboxed: Bool
        public var entitlements: [String: String]
    }

    public struct OpenFile: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public var path: String
        public var kind: String

        public init(path: String, kind: String) {
            self.path = path
            self.kind = kind
        }
    }

    public struct PortBinding: Sendable, Equatable, Identifiable {
        public var id: String { "\(pid)-\(port)-\(address)-\(kind)" }
        public var pid: pid_t
        public var port: Int
        public var address: String
        public var kind: String

        public init(pid: pid_t, port: Int, address: String, kind: String) {
            self.pid = pid
            self.port = port
            self.address = address
            self.kind = kind
        }
    }

    public struct OutboundConnection: Sendable, Equatable, Identifiable {
        public var id: String { "\(pid)-\(kind)-\(localAddress)-\(remoteAddress)" }
        public var pid: pid_t
        public var localAddress: String
        public var remoteAddress: String
        public var kind: String
        public var state: String?

        public init(pid: pid_t, localAddress: String, remoteAddress: String, kind: String, state: String? = nil) {
            self.pid = pid
            self.localAddress = localAddress
            self.remoteAddress = remoteAddress
            self.kind = kind
            self.state = state
        }
    }
}

public enum ProcessInspector {
    /// Builds the full inspection, verifying PID identity against `startedAt`
    /// before reading per-PID sockets/files.
    public static func inspect(_ sample: ProcessSample, all: [ProcessSample]) async -> ProcessInspection {
        let sameProcess = sample.startedAt.map { ProcessActions.liveStart(pid: sample.pid) == $0 } ?? true
        async let files: [ProcessInspection.OpenFile] = sameProcess ? openFiles(pid: sample.pid) : []
        async let ports: [ProcessInspection.PortBinding] = sameProcess ? listeningPorts(pid: sample.pid) : []
        async let outbound: [ProcessInspection.OutboundConnection] = sameProcess ? outboundConnections(pid: sample.pid) : []
        async let signature = codeSignatureDetached(sample: sample)
        let commandLine = if !sample.commandLine.isEmpty {
            sample.commandLine
        } else if sameProcess {
            ProcessProbe.commandLine(of: sample.pid) ?? []
        } else {
            [String]()
        }
        return ProcessInspection(
            pid: sample.pid,
            parentPID: sample.parentPID,
            parentName: all.first { $0.pid == sample.parentPID }?.name,
            children: all.filter { $0.parentPID == sample.pid },
            commandLine: commandLine,
            executablePath: sample.executablePath,
            bundleID: sample.bundleID,
            version: bundleVersion(sample: sample),
            startedAt: sample.startedAt,
            cpuTimeSeconds: sample.cpuTimeSeconds,
            residentBytes: sample.residentBytes,
            footprintBytes: sample.physFootprintBytes,
            diskReadBytes: sample.diskReadBytes,
            diskWrittenBytes: sample.diskWrittenBytes,
            signature: await signature,
            openFiles: await files,
            listeningPorts: await ports,
            outboundConnections: await outbound)
    }

    private static func codeSignatureDetached(sample: ProcessSample) async -> ProcessInspection.SignatureInfo? {
        await Task.detached(priority: .userInitiated) {
            Self.codeSignature(sample: sample)
        }.value
    }

    static func bundleVersion(sample: ProcessSample) -> String? {
        guard let bundlePath = sample.bundlePath, let bundle = Bundle(url: URL(fileURLWithPath: bundlePath)) else {
            return nil
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func codeSignature(sample: ProcessSample) -> ProcessInspection.SignatureInfo? {
        guard let path = sample.executablePath ?? sample.bundlePath else { return nil }
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return nil
        }
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: 0x01 | 0x02)
        guard SecCodeCopySigningInformation(code, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return ProcessInspection.SignatureInfo(
                isSigned: false, isValid: false, teamID: nil, isSandboxed: false, entitlements: [:])
        }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlementsData = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            ?? (info[kSecCodeInfoEntitlements as String] as? [String: Any])
        var entitlements: [String: String] = [:]
        for (key, value) in entitlementsData ?? [:] {
            entitlements[key] = "\(value)"
        }
        let sandboxed = entitlementsData?.keys.contains("com.apple.security.app-sandbox") == true
            || entitlementsData?.keys.contains("com.apple.security.app-sandbox.temporary-exception") == true
        let isValid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        return ProcessInspection.SignatureInfo(
            isSigned: true, isValid: isValid, teamID: teamID, isSandboxed: sandboxed,
            entitlements: entitlements)
    }

    static func openFiles(pid: pid_t) async -> [ProcessInspection.OpenFile] {
        guard let output = try? await SystemTool.run("/usr/sbin/lsof", arguments: [
            "-nP", "-p", String(pid)
        ]) else { return [] }
        return Self.parseOpenFiles(output, limit: 200)
    }

    public static func parseOpenFiles(_ output: String, limit: Int) -> [ProcessInspection.OpenFile] {
        var result: [ProcessInspection.OpenFile] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n").dropFirst() {
            guard result.count < limit else { break }
            let columns = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard columns.count >= 9 else { continue }
            let node = String(columns[7])
            let path = String(columns[8])
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            let kind: String = switch node {
            case "PIPE": String(localized: "Pipe", comment: "Open file kind")
            case "KQUEUE": String(localized: "Kqueue", comment: "Open file kind")
            case "unix": String(localized: "Unix socket", comment: "Open file kind")
            case "TCP", "UDP": String(localized: "Socket", comment: "Open file kind")
            default: String(localized: "File", comment: "Open file kind")
            }
            result.append(ProcessInspection.OpenFile(path: path, kind: kind))
        }
        return result
    }

    /// Listening TCP/UDP sockets owned strictly by `pid` (`-a` ANDs filters).
    static func listeningPorts(pid: pid_t) async -> [ProcessInspection.PortBinding] {
        guard let output = try? await SystemTool.run("/usr/sbin/lsof", arguments: [
            "-a", "-nP", "-p", String(pid), "-i", "-sTCP:LISTEN"
        ]) else { return [] }
        return Self.parsePortBindings(output)
    }

    static func outboundConnections(pid: pid_t) async -> [ProcessInspection.OutboundConnection] {
        guard let output = try? await SystemTool.run("/usr/sbin/lsof", arguments: [
            "-a", "-nP", "-p", String(pid), "-i"
        ]) else { return [] }
        return Self.parseOutboundConnections(output, limit: 100)
    }

    public static func parsePortBindings(_ output: String) -> [ProcessInspection.PortBinding] {
        var result: [ProcessInspection.PortBinding] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard columns.count >= 9 else { continue }
            let node = String(columns[7])
            let name = String(columns[8])
            guard node == "TCP" || node == "UDP", !name.contains("->") else { continue }
            if node == "TCP", name.contains("("), !name.contains("(LISTEN)") { continue }
            guard let (address, port) = DevEnvironmentProbe.lsofName(name[...]) else { continue }
            let id = "\(port)-\(address)-\(node)"
            guard seen.insert(id).inserted else { continue }
            result.append(
                ProcessInspection.PortBinding(pid: pid_t(columns[1]) ?? 0, port: port, address: address, kind: node))
        }
        return result.sorted { $0.port < $1.port }
    }

    public static func parseOutboundConnections(
        _ output: String, limit: Int = 100
    ) -> [ProcessInspection.OutboundConnection] {
        var result: [ProcessInspection.OutboundConnection] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n").dropFirst() {
            guard result.count < limit else { break }
            let columns = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard columns.count >= 9 else { continue }
            let node = String(columns[7])
            guard node == "TCP" || node == "UDP" else { continue }
            let rawName = String(columns[8])
            guard let arrow = rawName.range(of: "->") else { continue }
            let local = String(rawName[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(rawName[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            let remote: String
            let state: String?
            if let open = right.firstIndex(of: "("), let close = right.lastIndex(of: ")"), open < close {
                remote = String(right[..<open]).trimmingCharacters(in: .whitespaces)
                state = String(right[right.index(after: open)..<close])
            } else {
                remote = right
                state = nil
            }
            let pid = pid_t(columns[1]) ?? 0
            let key = "\(pid)-\(node)-\(local)-\(remote)"
            guard !remote.isEmpty, seen.insert(key).inserted else { continue }
            result.append(
                ProcessInspection.OutboundConnection(
                    pid: pid, localAddress: local, remoteAddress: remote, kind: node, state: state))
        }
        return result
    }
}

/// Quit and force-quit, verified against kernel start time before signalling.
public enum ProcessActions {
    @discardableResult
    public static func quit(pid: pid_t, confirmedStart: Date?) -> Bool {
        signal(pid, confirmedStart: confirmedStart, SIGTERM)
    }

    @discardableResult
    public static func forceQuit(pid: pid_t, confirmedStart: Date?) -> Bool {
        signal(pid, confirmedStart: confirmedStart, SIGKILL)
    }

    static func liveStart(pid: pid_t) -> Date? {
        guard let start = LibProc.startTime(pid: pid) else { return nil }
        return ProcessProbe.startDate(seconds: start.seconds, microseconds: start.microseconds)
    }

    private static func signal(_ pid: pid_t, confirmedStart: Date?, _ signal: Int32) -> Bool {
        guard pid > 0, let confirmedStart, liveStart(pid: pid) == confirmedStart else { return false }
        return kill(pid, signal) == 0
    }
}
