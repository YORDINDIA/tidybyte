import Foundation
import MacOSCleanerCore

/// Tool errors surfaced to the agent as `isError` text results.
enum MCPError: Error, LocalizedError {
    case noScan
    case unknownTool(String)
    case unknownFinding(String)
    case unknownAction(String)
    case nothingToUndo(String)
    /// High-risk destructive actions never execute through MCP — the user
    /// must run those in the app where the explicit-confirmation flow lives.
    case highRiskRequiresApp
    /// Destructive actions (everything except the non-deleting APFS fold)
    /// never execute through MCP. A client's "confirm" flag is the connecting
    /// agent's say-so, not a human approval, so irreversible work is refused
    /// here by code, not just by the instructions prose.
    case destructiveRequiresApp([String])
    /// An id argument was missing or shorter than the 8-character short ids
    /// the server emits; an empty prefix would match everything.
    case invalidIDPrefix

    var errorDescription: String? {
        switch self {
        case .noScan:
            "No scan yet. Call scan first."
        case .unknownTool(let name):
            "Unknown tool: \(name)."
        case .unknownFinding(let id):
            "No finding with id \(id) in the last scan."
        case .unknownAction(let id):
            "No pending action with id \(id) in the last plan."
        case .nothingToUndo(let id):
            "No undoable record for operation \(id)."
        case .highRiskRequiresApp:
            "This action is high risk and destructive; it can only be approved in the"
                + " Tidybyte app, never through MCP."
        case .destructiveRequiresApp(let types):
            "These actions change or delete files (\(types.joined(separator: ", "))) and can only"
                + " be approved in the Tidybyte app, never through MCP. Only the"
                + " clone-fold action (apfs_clone strategy, deletes nothing) executes here."
        case .invalidIDPrefix:
            "Missing id argument, or shorter than the 8-character ids the server emits."
        }
    }
}

/// A JSON-RPC response dictionary. `@unchecked Sendable` because the payload
/// holds only JSON-serializable values (strings, numbers, booleans, arrays,
/// dictionaries of the same) and is never mutated after the handler builds it.
public struct MCPResponse: @unchecked Sendable {
    public let payload: [String: Any]
    init(_ payload: [String: Any]) {
        self.payload = payload
    }
}

/// The MCP server brain: JSON-RPC request → response dictionaries. Deliberately
/// transport-agnostic (stdio lives in main.swift) so unit tests can drive
/// `handle(request:)` directly. An actor: the stdio loop still processes one
/// request at a time, but isolation does not depend on that caller discipline,
/// and every service it touches is an actor too.
public actor MCPKit {
    static let serverName = AppIdentity.mcpServerName
    static let serverVersion = "1.0"
    static let defaultProtocolVersion = "2025-06-18"
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    /// Short ids surfaced to agents are 8 characters; a shorter id argument is
    /// ambiguous (an empty prefix would match every record).
    static let minIDPrefixLength = 8

    struct ScanState {
        let outcome: ScanOutcome
        let plan: Plan
        let filesByID: [String: FileRecord]
    }

    private let store: SQLiteStore
    /// Scans run here; the cleanup tools reach into it.
    let orchestrator: ScanOrchestrator
    private let planner = PlannerAgent()
    private let executor: ActionExecutor
    private let undoService: UndoManagerService
    var lastScan: ScanState?

    public init(store: SQLiteStore) {
        self.store = store
        let memory = MemoryEngine(store: store)
        self.orchestrator = ScanOrchestrator(store: store, memory: memory)
        self.executor = ActionExecutor(store: store)
        self.undoService = UndoManagerService(store: store, memory: memory)
    }

    // MARK: - JSON-RPC dispatch

    /// Handles one decoded JSON-RPC request. Returns nil for notifications
    /// (requests without an id get no response, per the MCP transport rules).
    public func handle(request: [String: Any]) async -> MCPResponse? {
        // Notifications (no id) get no response — even malformed ones. JSON-RPC
        // forbids replying to a notification, so the id check must come first;
        // otherwise a method-less notification would draw an error reply.
        guard let id = request["id"] else { return nil }
        guard let method = request["method"] as? String else {
            return MCPResponse(Self.errorPayload(id: id, code: -32600, message: "Invalid Request"))
        }
        switch method {
        case "initialize":
            let params = request["params"] as? [String: Any]
            // Respond with a version the server actually speaks when the
            // client requests an unknown one, per the MCP negotiation rules.
            let requested = params?["protocolVersion"] as? String
            let version = requested.flatMap { requested in
                Self.supportedProtocolVersions.contains(requested) ? requested : nil
            } ?? Self.defaultProtocolVersion
            return MCPResponse(Self.responsePayload(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
                "instructions": """
                Local Mac cleanup agent. A human approves every change: always call execute without \
                confirm first, show the plan, and only call execute with confirm: true after the user \
                agrees. Enforced policy: execute runs ONLY clone-fold actions (apfs_clone strategy, \
                deletes nothing). Destructive actions (trash, package-manager cleanups) are refused \
                here and must be approved in the Tidybyte app, where files stay recoverable in Trash.
                """
            ]))
        case "ping":
            return MCPResponse(Self.responsePayload(id: id, result: [:]))
        case "tools/list":
            return MCPResponse(Self.responsePayload(
                    id: id, result: ["tools": Self.toolDescriptions + MonitorToolRouter.toolDescriptions]))
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await callTool(name: name, arguments: arguments)
                return MCPResponse(Self.responsePayload(id: id, result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false
                ]))
            } catch {
                return MCPResponse(Self.responsePayload(id: id, result: [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true
                ]))
            }
        default:
            return MCPResponse(Self.errorPayload(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Tools

    private func callTool(name: String, arguments: [String: Any]) async throws -> String {
        if let monitorResult = await MonitorToolRouter.handle(name: name) { return monitorResult }

        guard let tool = MCPCleanupTool(rawValue: name) else { throw MCPError.unknownTool(name) }
        switch tool {
        case .scan: return try await toolScan(arguments)
        case .listFindings: return try toolListFindings(arguments)
        case .showPlan: return try toolShowPlan(arguments)
        case .checkFinding: return try await toolCheckFinding(arguments)
        case .execute: return try await toolExecute(arguments)
        case .history: return try await toolHistory()
        case .undo: return try await toolUndo(arguments)
        }
    }

    private func toolListFindings(_ arguments: [String: Any]) throws -> String {
        guard let lastScan else { throw MCPError.noScan }
        let query = (arguments["query"] as? String ?? "").lowercased()
        let limit = max(1, (arguments["limit"] as? Int) ?? 20)
        let matches = lastScan.outcome.findings.filter { finding in
            query.isEmpty
                || finding.summary.lowercased().contains(query)
                || finding.targetFileIDs.contains {
                    lastScan.filesByID[$0]?.displayPath.lowercased().contains(query) == true
                }
        }
        guard !matches.isEmpty else { return "No findings match." }
        var lines = ["\(matches.count) findings (showing up to \(limit)):"]
        for finding in matches.prefix(limit) {
            lines.append("- [\(Self.shortID(finding.id))] \(finding.summary) · \(finding.bytesReclaimable.formattedByteCount)")
        }
        return lines.joined(separator: "\n")
    }

    private func toolShowPlan(_ arguments: [String: Any]) throws -> String {
        guard let lastScan else { throw MCPError.noScan }
        let findingID = try Self.validatedIDPrefix(arguments["finding_id"] as? String, allowNil: true)
        let actions = lastScan.plan.actions.filter { action in
            guard let findingID else { return true }
            return action.findingID?.hasPrefix(findingID) == true
        }
        guard !actions.isEmpty else { return "No plan actions for this query." }
        var lines = ["\(actions.count) proposed actions:"]
        for action in actions {
            let targetBytes = action.targets
                .compactMap { lastScan.filesByID[$0]?.sizeBytes }
                .reduce(Int64(0), +)
            let label = action.actionType == .cloneDeduplicate
                ? "fold onto keeper (nothing deleted)"
                : action.actionType.rawValue
            lines.append(
                "- [\(Self.shortID(action.id))] \(label): \(action.targets.count) files, "
                + "\(targetBytes.formattedByteCount), risk \(action.risk.rawValue) · \(action.reason)"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Live re-verification: every file in the group must still exist, still
    /// carry the scanned identity, and still hash to the scanned SHA-256 —
    /// a stale plan never gets executed on changed files.
    private func toolCheckFinding(_ arguments: [String: Any]) async throws -> String {
        guard let lastScan else { throw MCPError.noScan }
        let id = try Self.validatedIDPrefix(arguments["finding_id"] as? String)
        guard let finding = lastScan.outcome.findings.first(where: { $0.id.hasPrefix(id) }) else {
            throw MCPError.unknownFinding(id)
        }
        var present = 0
        var identical = 0
        var missing: [String] = []
        var changed: [String] = []
        let scannedHash = finding.evidence["hash"]
        for fileID in finding.targetFileIDs {
            guard let record = lastScan.filesByID[fileID] else { continue }
            switch checkMember(record, scannedHash: scannedHash) {
            case .identical:
                present += 1
                identical += 1
            case .resized:
                present += 1
                changed.append(record.displayPath)
            case .missing:
                missing.append(record.displayPath)
            }
        }
        var lines = [
            "Checked \(finding.targetFileIDs.count) files: \(present) present and correct size, "
                + "\(identical) byte-identical to the scan."
        ]
        if !missing.isEmpty {
            lines.append("Missing or resized since the scan: \(missing.joined(separator: ", "))")
        }
        if !changed.isEmpty {
            lines.append("Contents changed since the scan: \(changed.joined(separator: ", "))")
        }
        if missing.isEmpty && changed.isEmpty {
            lines.append("The plan is still safe to execute.")
        } else {
            lines.append("Re-scan before executing: the stale plan no longer matches the disk.")
        }
        return lines.joined(separator: "\n")
    }

    /// Outcome of re-reading one finding member from disk.
    private enum MemberCheck {
        case identical
        case resized
        case missing
    }

    /// Re-reads one file: present, correct size, and (for exact-duplicate
    /// findings, where every member shares one hash) byte-identical.
    private func checkMember(_ record: FileRecord, scannedHash: String?) -> MemberCheck {
        let attributes = try? FileManager.default.attributesOfItem(atPath: record.url.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.int64Value
        guard FileManager.default.fileExists(atPath: record.url.path),
              let scannedSize = record.identity.sizeBytes,
              currentSize == scannedSize else {
            return .missing
        }
        guard let hash = try? FingerprintService.fullHash(for: record.url) else {
            return .resized
        }
        if let scannedHash {
            return hash == scannedHash ? .identical : .resized
        }
        return .identical
    }

    private func toolExecute(_ arguments: [String: Any]) async throws -> String {
        guard let lastScan else { throw MCPError.noScan }
        let confirm = arguments["confirm"] as? Bool == true
        let requestedIDs = try Self.validatedIDPrefixes(arguments["action_ids"] as? [String])
        let pending = lastScan.plan.actions.filter { action in
            action.userDecision == .undecided && action.executedAt == nil
                && (requestedIDs == nil || requestedIDs?.contains(where: { action.id.hasPrefix($0) }) == true)
        }
        guard !pending.isEmpty else { throw MCPError.unknownAction(requestedIDs?.joined(separator: ", ") ?? "any") }

        let targetBytes = pending.reduce(Int64(0)) { total, action in
            total + action.targets.reduce(Int64(0)) { sum, id in
                sum + (lastScan.filesByID[id]?.sizeBytes ?? 0)
            }
        }
        let summaryText = pending.map { action -> String in
            let label = action.actionType == .cloneDeduplicate
                ? "fold \(action.targets.count) files onto their keepers (nothing deleted)"
                : "\(action.actionType.rawValue): \(action.targets.count) files"
            return "- \(label) · \(action.reason)"
        }.joined(separator: "\n")

        guard confirm else {
            // The dry run is read-only and stays available for destructive
            // plans: it shows the plan and points at the app that must do it.
            return """
            Dry run. Nothing changed. Would \(pending.count) actions affecting \(targetBytes.formattedByteCount):
            \(summaryText)
            Ask the user, then call execute again with confirm: true.
            """
        }

        // ENFORCED policy, not prose: a client-supplied "confirm" flag is the
        // connecting agent's say-so, never proof a human saw anything. Only
        // the non-deleting clone fold may execute here; everything destructive
        // (trash, package-manager cleanups, high risk of any kind) requires
        // the app's explicit-confirmation flow.
        if pending.contains(where: { $0.risk >= .high }) {
            throw MCPError.highRiskRequiresApp
        }
        let destructiveTypes = Set(pending.filter { $0.actionType != .cloneDeduplicate }.map(\.actionType.rawValue))
        if !destructiveTypes.isEmpty {
            throw MCPError.destructiveRequiresApp(Array(destructiveTypes).sorted())
        }

        var approved: [PlannedAction] = []
        for action in pending {
            var approvedAction = action
            approvedAction.userDecision = .approved
            approvedAction.status = .approved
            approved.append(approvedAction)
        }
        let summary = await executor.execute(actions: approved, filesByID: lastScan.filesByID)
        // Stamp the in-memory plan so a second confirmed execute can never
        // re-run the same actions (the executor's idempotency guard reads
        // executedAt off the plan).
        var plan = lastScan.plan
        let stamped = Set(approved.map(\.id))
        for index in plan.actions.indices where stamped.contains(plan.actions[index].id) {
            plan.actions[index].executedAt = Date()
            plan.actions[index].status = summary.failedActionIDs.contains(plan.actions[index].id)
                ? .failed : .completed
        }
        self.lastScan = ScanState(outcome: lastScan.outcome, plan: plan, filesByID: lastScan.filesByID)
        var lines = [
            "Executed \(approved.count) actions: \(summary.undoRecords.count) undo records created, "
                + "\(summary.failures.count) failures."
        ]
        for failure in summary.failures.prefix(10) {
            lines.append("! \(failure)")
        }
        return lines.joined(separator: "\n")
    }

    private func toolHistory() async throws -> String {
        // The store returns records newest-first already.
        let records = Array(try await store.loadUndoRecords().prefix(20))
        guard !records.isEmpty else { return "No recorded operations yet." }
        var lines = ["Last \(records.count) operations (newest first):"]
        for record in records {
            let path = record.restoreURL?.path ?? record.trashURL?.path ?? "?"
            lines.append(
                "- op [\(record.operationLogID.prefix(8))] \(record.inverseAction.rawValue)"
                    + " \(path) · \(record.status.rawValue)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func toolUndo(_ arguments: [String: Any]) async throws -> String {
        // Without this guard a missing id ("") prefix-matches every recorded
        // operation and a confirmed call would bulk-restore all of them.
        let id = try Self.validatedIDPrefix(arguments["operation_log_id"] as? String)
        var records = try await store.loadUndoRecords(operationLogID: id)
        if records.isEmpty {
            // History lists 8-character prefixes; resolve those against full ids.
            records = try await store.loadUndoRecords().filter { $0.operationLogID.hasPrefix(id) }
        }
        let restorable = records.filter { $0.status == .available }
        guard !restorable.isEmpty else { throw MCPError.nothingToUndo(id) }
        let paths = restorable.compactMap { $0.restoreURL?.path ?? $0.trashURL?.path }

        guard arguments["confirm"] as? Bool == true else {
            return """
            Dry run. Nothing changed. Undoing operation \(id) would restore \(restorable.count) items:
            \(paths.joined(separator: "\n"))
            Ask the user, then call undo again with confirm: true.
            """
        }
        var restored = 0
        var failures: [String] = []
        for record in restorable {
            do {
                _ = try await undoService.restore(record)
                restored += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        var lines = ["Restored \(restored) of \(restorable.count) items."]
        failures.prefix(10).forEach { lines.append("! \($0)") }
        return lines.joined(separator: "\n")
    }

}

// Tool catalog, JSON-schema builders and JSON-RPC payload helpers live outside
// the main class body.
extension MCPKit {
    // MARK: - Payload helpers

    static func responsePayload(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func errorPayload(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// Serializes and prints one response line. Sorted keys keep the output
    /// stable for tests. Writes through FileHandle (not `print`) because
    /// stdio pipes are block-buffered — a buffered response would strand the
    /// client waiting for a line that never arrives.
    public static func emit(_ payload: [String: Any]) {
        guard let data = dataForPayload(payload) else {
            return
        }
        emitRaw(data)
    }

    /// JSONSerialization raises Objective-C exceptions for invalid payloads —
    /// NaN or infinity doubles, non-property-list values — and `try?` cannot
    /// catch those: one non-finite monitor reading aborted the whole server
    /// (see the crash reports). The sanitize-then-validate order lives in
    /// Core's JSONSanitizing, shared with the monitor CLI.
    public static func dataForPayload(_ payload: [String: Any]) -> Data? {
        JSONSanitizing.data(payload, options: [.sortedKeys])
    }

    /// Writes one pre-serialized response frame (Sendable across task
    /// boundaries, which raw `[String: Any]` dictionaries are not).
    public static func emitRaw(_ data: Data) {
        FileHandle.standardOutput.write(Data((String(decoding: data, as: UTF8.self) + "\n").utf8))
    }

    static func strategy(from raw: String?) -> DuplicateStrategy {
        raw == "move_to_trash" ? .moveToTrash : .apfsClone
    }

    static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    /// Id arguments must be at least `minIDPrefixLength` characters: the dry
    /// runs and history list 8-character short ids, and an empty (or very
    /// short) prefix would silently match everything.
    static func validatedIDPrefix(_ raw: String?) throws -> String {
        guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw MCPError.invalidIDPrefix
        }
        if id.count < minIDPrefixLength {
            throw MCPError.invalidIDPrefix
        }
        return id
    }

    /// Same gate for a list of id arguments: nil means "no filter".
    static func validatedIDPrefixes(_ raw: [String]?) throws -> [String]? {
        guard let raw else { return nil }
        return try raw.map { try validatedIDPrefix($0) }
    }

    /// Same gate for optional id arguments: nil means "no filter", but an
    /// empty string would be a match-everything prefix, so it is rejected.
    static func validatedIDPrefix(_ raw: String?, allowNil: Bool) throws -> String? {
        guard let raw else {
            if allowNil { return nil }
            throw MCPError.invalidIDPrefix
        }
        return try validatedIDPrefix(raw)
    }

}
