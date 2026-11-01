import Darwin
import Foundation
import Security

/// Everything knowable about one process, for the inspector panel: identity
/// and code signature, parentage, resource totals, open files, and listening
/// ports. Read-only by design — quitting lives in ProcessActions and always
/// asks first.
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
        /// Includes the protocol: one process bound to the same address:port
        /// over TCP and UDP is two rows, and duplicate ForEach IDs crash.
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
}

public enum ProcessInspector {
    /// Builds the full inspection. The lsof calls are the slow part (tens of
    /// milliseconds); the inspector is on-demand, so that is fine.
    public static func inspect(_ sample: ProcessSample, all: [ProcessSample]) async -> ProcessInspection {
        async let files = openFiles(pid: sample.pid)
        async let ports = listeningPorts(pid: sample.pid)
        async let signature = codeSignatureDetached(sample: sample)
        let inspection = ProcessInspection(
            pid: sample.pid,
            parentPID: sample.parentPID,
            parentName: all.first { $0.pid == sample.parentPID }?.name,
            children: all.filter { $0.parentPID == sample.pid },
            commandLine: sample.commandLine.isEmpty ? ProcessProbe.commandLine(of: sample.pid) ?? [] : sample.commandLine,
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
            listeningPorts: await ports)
        return inspection
    }

    /// Signature validation (SecStaticCodeCheckValidity) touches disk and the
    /// security daemon enough to stall the cooperative pool, so it runs on a
    /// dedicated detached task.
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

    /// Code signature and sandbox state via the Security framework, with the
    /// entitlement dictionary when the process exposes it.
    static func codeSignature(sample: ProcessSample) -> ProcessInspection.SignatureInfo? {
        guard let path = sample.executablePath ?? sample.bundlePath else { return nil }
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return nil
        }
        var infoCF: CFDictionary?
        // kSecCSSigningInformation | kSecCSRequirementInformation from
        // SecCodeSigning.h; Swift does not import those option constants.
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
        // Validity check: the signature exists; deep validation is skipped for
        // system paths to keep the inspector fast and non-intrusive.
        var isValid = false
        if #available(macOS 12.0, *) {
            isValid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        }
        return ProcessInspection.SignatureInfo(
            isSigned: true, isValid: isValid, teamID: teamID, isSandboxed: sandboxed,
            entitlements: entitlements)
    }

    /// Open files and sockets from lsof, limited so a busy server cannot
    /// flood the inspector.
    static func openFiles(pid: pid_t) async -> [ProcessInspection.OpenFile] {
        guard let output = try? await SystemTool.run("/usr/sbin/lsof", arguments: [
            "-nP", "-p", String(pid)
        ]) else { return [] }
        return Self.parseOpenFiles(output, limit: 200)
    }

    /// Parses the per-process lsof table. Pure and testable. The NAME column
    /// (index 8) is split last so paths containing spaces survive whole.
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

    /// TCP and UDP bindings of one process.
    static func listeningPorts(pid: pid_t) async -> [ProcessInspection.PortBinding] {
        guard let output = try? await SystemTool.run("/usr/sbin/lsof", arguments: [
            "-nP", "-p", String(pid), "-i"
        ]) else { return [] }
        return Self.parsePortBindings(output)
    }

    public static func parsePortBindings(_ output: String) -> [ProcessInspection.PortBinding] {
        var result: [ProcessInspection.PortBinding] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 9 else { continue }
            let node = String(columns[7])
            // The shared lsof NAME parser: last colon, digits after it.
            guard node == "TCP" || node == "UDP",
                let (address, port) = DevEnvironmentProbe.lsofName(String(columns[8])[...]) else { continue }
            let id = "\(port)-\(address)-\(node)"
            guard seen.insert(id).inserted else { continue }
            result.append(
                ProcessInspection.PortBinding(pid: pid_t(columns[1]) ?? 0, port: port, address: address, kind: node))
        }
        return result.sorted { $0.port < $1.port }
    }
}

/// Quit and force-quit. Deliberately separate from the inspector: every call
/// goes through the confirm-dialog policy in the UI layer, and force-quit is
/// always the second, explicit step.
public enum ProcessActions {
    /// SIGTERM first. Returns false when the process was already gone or the
    /// pid is not a real process id (pid 0 would signal the process group).
    @discardableResult
    public static func quit(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, SIGTERM) == 0
    }

    /// SIGKILL. The UI asks before calling this.
    @discardableResult
    public static func forceQuit(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, SIGKILL) == 0
    }
}
