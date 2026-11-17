import Darwin
import Foundation
import MacOSCleanerCore

/// Tool errors surfaced to the agent as `isError` text results.
enum MCPError: Error, LocalizedError {
    case noScan
    case unknownTool(String)
    case unknownFinding(String)
    case unknownAction(String)
    case nothingToUndo(String)
    case highRiskRequiresApp
    case destructiveRequiresApp([String])
    case invalidIDPrefix
    case invalidArgument(String)
    case undoRequiresApp
    case ambiguousOperationID(String)
    case ambiguousActionID(String)
    case processNotFound(Int)

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
        case .invalidArgument(let name):
            "Argument \(name) has the wrong type or an unknown value."
        case .undoRequiresApp:
            "This undo moves an artifact to the Trash. It can only run in the Tidybyte app,"
                + " never through MCP."
        case .ambiguousOperationID(let id):
            "Id \(id) matches more than one recorded operation. Nothing changed."
        case .ambiguousActionID(let id):
            "Id \(id) matches more than one pending action. Nothing changed."
        case .processNotFound(let pid):
            "No live process found with PID \(pid)."
        }
    }
}

public struct MCPResponse: @unchecked Sendable {
    public let payload: [String: Any]
    init(_ payload: [String: Any]) {
        self.payload = payload
    }
}

/// The MCP server brain: JSON-RPC request → response dictionaries.
public actor MCPKit {
    static let serverName = AppIdentity.mcpServerName
    static let serverVersion = "1.0"
    static let defaultProtocolVersion = "2025-06-18"
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    static let minIDPrefixLength = 8

    struct ScanState {
        let outcome: ScanOutcome
        let plan: Plan
        let filesByID: [String: FileRecord]
        var filesByParent: [String: [FileRecord]] = [:]
    }

    private let store: SQLiteStore
    let orchestrator: ScanOrchestrator
    private let planner = PlannerAgent()
    private let executor: ActionExecutor
    private let undoService: UndoManagerService
    private let auditor = SafetyAuditor()
    var lastScan: ScanState?

    public init(store: SQLiteStore) {
        self.store = store
        let memory = MemoryEngine(store: store)
        self.orchestrator = ScanOrchestrator(store: store, memory: memory)
        self.executor = ActionExecutor(store: store)
        self.undoService = UndoManagerService(store: store, memory: memory)
    }

    // MARK: - JSON-RPC dispatch

    public func handle(request: sending [String: Any]) async -> MCPResponse? {
        guard let id = request["id"] else { return nil }
        guard (request["jsonrpc"] as? String) == "2.0" else {
            return MCPResponse(Self.errorPayload(id: id, code: -32600, message: "Invalid Request: jsonrpc must be \"2.0\""))
        }
        guard let method = request["method"] as? String else {
            return MCPResponse(Self.errorPayload(id: id, code: -32600, message: "Invalid Request"))
        }
        return await dispatchMethod(method, id: id, request: request)
    }

    private func dispatchMethod(_ method: String, id: Any, request: [String: Any]) async -> MCPResponse? {
        switch method {
        case "initialize":
            return initializeResponse(id: id, params: request["params"] as? [String: Any])
        case "ping":
            return MCPResponse(Self.responsePayload(id: id, result: [:]))
        case "tools/list":
            return MCPResponse(Self.responsePayload(
                id: id, result: ["tools": Self.toolDescriptions + MonitorToolRouter.toolDescriptions]))
        case "tools/call":
            return await toolsCall(id: id, request: request)
        case "prompts/list":
            return MCPResponse(Self.responsePayload(
                id: id, result: ["prompts": MCPPromptCatalog.promptDescriptions]))
        case "prompts/get":
            return promptsGet(id: id, params: request["params"] as? [String: Any])
        case "resources/list":
            return MCPResponse(Self.responsePayload(
                id: id, result: ["resources": MCPResourceCatalog.resourceDescriptions]))
        case "resources/read":
            return await resourcesRead(id: id, params: request["params"] as? [String: Any])
        default:
            return MCPResponse(Self.errorPayload(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func toolsCall(id: Any, request: [String: Any]) async -> MCPResponse? {
        let params = request["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        guard MCPCleanupTool(rawValue: name) != nil || MonitorToolRouter.handles(name: name) else {
            return MCPResponse(Self.errorPayload(id: id, code: -32602, message: "Unknown tool: \(name)."))
        }
        if let raw = params["arguments"], !(raw is [String: Any]) {
            return MCPResponse(Self.responsePayload(id: id, result: [
                "content": [["type": "text", "text": "Argument arguments must be an object."]],
                "isError": true
            ]))
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text = try await callTool(name: name, arguments: arguments)
            if Task.isCancelled { return nil }
            return MCPResponse(Self.responsePayload(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": false
            ]))
        } catch is CancellationError {
            return nil
        } catch {
            if Task.isCancelled { return nil }
            return MCPResponse(Self.responsePayload(id: id, result: [
                "content": [["type": "text", "text": error.localizedDescription]],
                "isError": true
            ]))
        }
    }

    // MARK: - Tools

    private func callTool(name: String, arguments: [String: Any]) async throws -> String {
        if let monitorRequest = try MonitorToolRouter.parseRequest(name: name, arguments: arguments) {
            return try await MonitorToolRouter.execute(monitorRequest)
        }
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

    private func toolCheckFinding(_ arguments: [String: Any]) async throws -> String {
        let id = try Self.validatedIDPrefix(Self.stringArgument(arguments, "finding_id"))
        guard let lastScan else { throw MCPError.noScan }
        guard let finding = lastScan.outcome.findings.first(where: { $0.id.hasPrefix(id) }) else {
            throw MCPError.unknownFinding(id)
        }
        var verified = 0
        var hashed = 0
        var missing: [String] = []
        var changed: [String] = []
        let scannedHash = finding.evidence["hash"]
        for fileID in finding.targetFileIDs {
            guard let record = lastScan.filesByID[fileID] else {
                missing.append(fileID)
                continue
            }
            switch await checkMember(record, scannedHash: scannedHash) {
            case .identical:
                verified += 1
                hashed += 1
            case .identityOnly:
                verified += 1
            case .missing:
                missing.append(record.displayPath)
            case .changed:
                changed.append(record.displayPath)
            }
        }
        return Self.checkReport(
            total: finding.targetFileIDs.count, verified: verified,
            hashed: scannedHash == nil ? nil : hashed, missing: missing, changed: changed)
    }

    static func pendingActions(in plan: Plan, requestedIDs: [String]?) throws -> [PlannedAction] {
        let open = plan.actions.filter { $0.userDecision == .undecided && $0.executedAt == nil }
        guard let requestedIDs else { return open }
        var pending: [PlannedAction] = []
        for prefix in requestedIDs {
            let matches = open.filter { $0.id.hasPrefix(prefix) }
            guard let match = matches.first, matches.count == 1 else {
                throw matches.isEmpty
                    ? MCPError.unknownAction(prefix)
                    : MCPError.ambiguousActionID(prefix)
            }
            if !pending.contains(where: { $0.id == match.id }) { pending.append(match) }
        }
        return pending
    }

    private func toolExecute(_ arguments: [String: Any]) async throws -> String {
        let confirm = try Self.boolArgument(arguments, "confirm") ?? false
        let requestedIDs = try Self.validatedIDPrefixes(Self.stringArrayArgument(arguments, "action_ids"))
        guard let lastScan else { throw MCPError.noScan }
        let pending = try Self.pendingActions(in: lastScan.plan, requestedIDs: requestedIDs)
        guard !pending.isEmpty else { throw MCPError.unknownAction("any") }

        let targetBytes = pending.reduce(Int64(0)) { $0 + estimatedBytes(for: $1, in: lastScan) }
        let summaryText = pending.map { action -> String in
            let label = action.actionType == .cloneDeduplicate
                ? "fold \(action.targets.count) files onto their keepers (nothing deleted)"
                : "\(action.actionType.rawValue): \(action.targets.count) files"
            return "- [\(Self.shortID(action.id))] \(label) · \(action.reason)"
        }.joined(separator: "\n")

        guard confirm else {
            return dryRunMessage(pending: pending, targetBytes: targetBytes, summaryText: summaryText)
        }

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
        let updatedPlan = updatedPlanAfterExecution(plan: lastScan.plan, approved: approved, summary: summary)
        self.lastScan = ScanState(
            outcome: lastScan.outcome, plan: updatedPlan,
            filesByID: lastScan.filesByID, filesByParent: lastScan.filesByParent)
        try await store.savePlan(updatedPlan)

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
        let id = try Self.validatedIDPrefix(Self.stringArgument(arguments, "operation_log_id"))
        let confirm = try Self.boolArgument(arguments, "confirm") ?? false
        var records = try await store.loadUndoRecords(operationLogID: id)
        if records.isEmpty {
            records = try await store.loadUndoRecords().filter { $0.operationLogID.hasPrefix(id) }
        }
        guard !records.isEmpty else { throw MCPError.nothingToUndo(id) }
        guard Set(records.map(\.operationLogID)).count == 1 else {
            throw MCPError.ambiguousOperationID(id)
        }
        let restorable = records.filter { $0.status == .available }
        guard !restorable.isEmpty else { throw MCPError.nothingToUndo(id) }
        guard restorable.allSatisfy({ Self.agentMayUndo($0.inverseAction) }) else {
            throw MCPError.undoRequiresApp
        }
        let paths = restorable.compactMap { $0.restoreURL?.path ?? $0.trashURL?.path }

        guard confirm else {
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

// MARK: - Payload, verification & argument helpers

extension MCPKit {
    static func responsePayload(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func errorPayload(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    public static func emit(_ payload: [String: Any]) {
        guard let data = dataForPayload(payload) else { return }
        emitRaw(data)
    }

    public static func dataForPayload(_ payload: [String: Any]) -> Data? {
        JSONSanitizing.data(payload, options: [.sortedKeys])
    }

    /// Writes one pre-serialized response frame using throwing `write(contentsOf:)`
    /// so EPIPE never triggers an uncatchable NSFileHandleOperationException.
    public static func emitRaw(_ data: Data) {
        var frame = data
        frame.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: frame)
    }

    static func strategy(from raw: String?) -> DuplicateStrategy {
        raw == "move_to_trash" ? .moveToTrash : .apfsClone
    }

    static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    static func validatedIDPrefix(_ raw: String?) throws -> String {
        guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, id.count >= minIDPrefixLength else {
            throw MCPError.invalidIDPrefix
        }
        return id
    }

    static func validatedIDPrefixes(_ raw: [String]?) throws -> [String]? {
        guard let raw else { return nil }
        return try raw.map { try validatedIDPrefix($0) }
    }

    static func validatedIDPrefix(_ raw: String?, allowNil: Bool) throws -> String? {
        guard let raw else {
            if allowNil { return nil }
            throw MCPError.invalidIDPrefix
        }
        return try validatedIDPrefix(raw)
    }

    private enum MemberCheck {
        case identical
        case identityOnly
        case missing
        case changed
    }

    /// Guards against symlinks and directories via `lstat` before verifying identity or hashing.
    private func checkMember(_ record: FileRecord, scannedHash: String?) async -> MemberCheck {
        var st = Darwin.stat()
        guard lstat(record.url.path, &st) == 0 else {
            return errno == ENOENT ? .missing : .changed
        }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            return .changed
        }
        if fileType == S_IFDIR || record.kind == .directory {
            guard fileType == S_IFDIR, record.kind == .directory else { return .changed }
            return await verifyIdentityOnly(record)
        }
        guard fileType == S_IFREG else { return .changed }
        return await verifyRegularFile(record, scannedHash: scannedHash)
    }

    private func verifyIdentityOnly(_ record: FileRecord) async -> MemberCheck {
        do {
            try await auditor.verifyTargetUnchanged(record)
            return .identityOnly
        } catch SafetyAuditError.targetVanished(_) {
            return .missing
        } catch {
            return .changed
        }
    }

    private func verifyRegularFile(_ record: FileRecord, scannedHash: String?) async -> MemberCheck {
        let identity = await verifyIdentityOnly(record)
        guard case .identityOnly = identity else { return identity }
        guard let scannedHash else { return .identityOnly }
        guard let hash = try? FingerprintService.fullHash(for: record.url), hash == scannedHash else {
            return .changed
        }
        return .identical
    }

    static func checkReport(total: Int, verified: Int, hashed: Int?, missing: [String], changed: [String]) -> String {
        var lines = [
            hashed.map {
                "Checked \(total) files: \($0) byte-identical to the scan (identity, size and SHA-256 match)."
            } ?? "Checked \(total) files: \(verified) match the scanned identity and size. "
                + "This finding has no content hash, so file bytes were not compared."
        ]
        if !missing.isEmpty {
            lines.append("Missing since the scan: \(missing.joined(separator: ", "))")
        }
        if !changed.isEmpty {
            lines.append("Changed since the scan (identity, size, modification time or contents): "
                + changed.joined(separator: ", "))
        }
        if missing.isEmpty && changed.isEmpty {
            lines.append("The plan is still safe to execute.")
        } else {
            lines.append("Re-scan before executing: the stale plan no longer matches the disk.")
        }
        return lines.joined(separator: "\n")
    }

    static func stringArgument(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let value = raw as? String else { throw MCPError.invalidArgument(key) }
        return value
    }

    static func stringArrayArgument(_ arguments: [String: Any], _ key: String) throws -> [String]? {
        guard let raw = arguments[key] else { return nil }
        guard let values = raw as? [String] else { throw MCPError.invalidArgument(key) }
        return values
    }

    static func intArgument(_ arguments: [String: Any], _ key: String) throws -> Int? {
        guard let raw = arguments[key] else { return nil }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = raw as? Int,
              Double(value) == number.doubleValue else {
            throw MCPError.invalidArgument(key)
        }
        return value
    }

    static func boolArgument(_ arguments: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = arguments[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw MCPError.invalidArgument(key)
        }
        return number.boolValue
    }

    static func agentMayUndo(_ inverse: ActionType) -> Bool {
        switch inverse {
        case .restore, .move, .rename, .tag, .unfoldClone:
            return true
        case .moveToTrash, .createAlias, .createSymlink, .archive, .offloadLocalCopy,
             .runProviderCleanup, .runPackageManagerCleanup, .inspectOnly, .cloneDeduplicate:
            return false
        }
    }
}
