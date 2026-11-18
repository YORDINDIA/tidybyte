import Darwin
import Foundation
import MacOSCleanerCore

extension MCPKit {
    func toolScan(_ arguments: [String: Any]) async throws -> String {
        let rawPaths = try Self.stringArrayArgument(arguments, "paths") ?? []
        let expanded = rawPaths.map { ($0 as NSString).expandingTildeInPath }
        guard expanded.allSatisfy({ $0.hasPrefix("/") }) else { throw MCPError.invalidArgument("paths") }
        let policy = PathSafetyPolicy()
        let paths = try expanded.map { try Self.validatedScanRoot($0, policy: policy) }
        let strategyName = try Self.stringArgument(arguments, "duplicate_strategy")
        guard strategyName == nil || strategyName == "apfs_clone" || strategyName == "move_to_trash" else {
            throw MCPError.invalidArgument("duplicate_strategy")
        }
        let (outcome, plan) = try await orchestrator.scan(
            mode: paths.isEmpty ? .homeFolder : .selectedFolders,
            selectedFolders: paths,
            providerSettings: ProviderSettings(),
            includeAI: false,
            posture: .conservative,
            duplicateStrategy: Self.strategy(from: strategyName)
        )
        var filesByID: [String: FileRecord] = [:]
        var filesByParent: [String: [FileRecord]] = [:]
        for record in outcome.files {
            filesByID[record.id] = record
            let parentPath = record.url.deletingLastPathComponent().standardizedFileURL.path
            filesByParent[parentPath, default: []].append(record)
        }
        let state = ScanState(outcome: outcome, plan: plan, filesByID: filesByID, filesByParent: filesByParent)
        lastScan = state

        let duplicateFindings = outcome.findings.filter { $0.category == .duplicate }
        let duplicateBytes = plan.actions
            .filter { $0.actionType == .cloneDeduplicate || $0.actionType == .moveToTrash }
            .reduce(Int64(0)) { $0 + estimatedBytes(for: $1, in: state) }
        var lines = [
            "Scan finished: \(outcome.files.count) files looked at, "
                + "\(outcome.findings.count) findings (\(duplicateFindings.count) duplicate groups).",
            "Plan proposes \(plan.actions.count) actions reclaiming about \(duplicateBytes.formattedByteCount).",
            "Next: list_findings, then show_plan for a group, then check_finding before execute."
        ]
        for finding in duplicateFindings.prefix(10) {
            lines.append("- [\(Self.shortID(finding.id))] \(finding.summary) (\(finding.bytesReclaimable.formattedByteCount))")
        }
        return lines.joined(separator: "\n")
    }

    private static func validatedScanRoot(_ path: String, policy: PathSafetyPolicy) throws -> URL {
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard !policy.shouldSkipTraversal(of: resolved) else {
            throw MCPError.invalidArgument("paths")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MCPError.invalidArgument("paths")
        }
        var statInfo = Darwin.stat()
        let isLeafSymlink = lstat(url.path, &statInfo) == 0 && (statInfo.st_mode & S_IFMT) == S_IFLNK
        let standardized = url.standardizedFileURL
        // Preserve macOS /var/folders/... temp-path spelling unless the leaf itself is a symlink.
        if !isLeafSymlink && standardized.path.hasPrefix("/var/folders/") {
            return standardized
        }
        return resolved
    }

    func toolListFindings(_ arguments: [String: Any]) throws -> String {
        let query = (try Self.stringArgument(arguments, "query") ?? "").lowercased()
        let categoryRaw = try Self.stringArgument(arguments, "category")
        let categoryFilter: FindingCategory? = if let categoryRaw {
            if let parsed = FindingCategory(rawValue: categoryRaw) {
                parsed
            } else {
                throw MCPError.invalidArgument("category")
            }
        } else {
            nil
        }
        let limit = try Self.intArgument(arguments, "limit") ?? 20
        let offset = try Self.intArgument(arguments, "offset") ?? 0
        guard (1...200).contains(limit) else { throw MCPError.invalidArgument("limit") }
        guard offset >= 0 else { throw MCPError.invalidArgument("offset") }
        guard let lastScan else { throw MCPError.noScan }

        let matches = lastScan.outcome.findings.filter { finding in
            if let categoryFilter, finding.category != categoryFilter { return false }
            guard !query.isEmpty else { return true }
            return finding.summary.lowercased().contains(query)
                || finding.category.rawValue.lowercased().contains(query)
                || finding.category.displayName.lowercased().contains(query)
                || finding.targetFileIDs.contains {
                    lastScan.filesByID[$0]?.displayPath.lowercased().contains(query) == true
                }
        }
        guard !matches.isEmpty else { return "No findings match." }
        let page = Array(matches.dropFirst(offset).prefix(limit))
        guard !page.isEmpty else { return "No findings at offset \(offset) (total \(matches.count))." }
        var lines = ["\(matches.count) findings (showing \(offset + 1)-\(offset + page.count)):"]
        for finding in page {
            let paths = finding.targetFileIDs.prefix(3).compactMap { lastScan.filesByID[$0]?.displayPath }
            let extra = finding.targetFileIDs.count > 3 ? " (+\(finding.targetFileIDs.count - 3) more)" : ""
            let pathSummary = paths.isEmpty ? "" : " | files: \(paths.joined(separator: ", "))\(extra)"
            lines.append(
                "- [\(Self.shortID(finding.id))] [\(finding.category.rawValue)] \(finding.summary) "
                + "· \(finding.bytesReclaimable.formattedByteCount)\(pathSummary)")
        }
        return lines.joined(separator: "\n")
    }

    func toolShowPlan(_ arguments: [String: Any]) throws -> String {
        let findingID = try Self.validatedIDPrefix(Self.stringArgument(arguments, "finding_id"), allowNil: true)
        let limit = try Self.intArgument(arguments, "limit") ?? 20
        let offset = try Self.intArgument(arguments, "offset") ?? 0
        guard (1...200).contains(limit) else { throw MCPError.invalidArgument("limit") }
        guard offset >= 0 else { throw MCPError.invalidArgument("offset") }
        guard let lastScan else { throw MCPError.noScan }

        let actions = lastScan.plan.actions.filter { action in
            guard let findingID else { return true }
            return action.findingID?.hasPrefix(findingID) == true
        }
        guard !actions.isEmpty else { return "No plan actions for this query." }
        let page = Array(actions.dropFirst(offset).prefix(limit))
        guard !page.isEmpty else { return "No plan actions at offset \(offset) (total \(actions.count))." }
        var lines = ["\(actions.count) proposed actions (showing \(offset + 1)-\(offset + page.count)):"]
        for action in page {
            lines.append(formatPlanLine(action, in: lastScan))
        }
        return lines.joined(separator: "\n")
    }

    private func formatPlanLine(_ action: PlannedAction, in scan: ScanState) -> String {
        let targetBytes = estimatedBytes(for: action, in: scan)
        let label = action.actionType == .cloneDeduplicate
            ? "fold onto keeper (nothing deleted)"
            : action.actionType.rawValue
        let targetPaths = action.targets.prefix(4).compactMap { scan.filesByID[$0]?.displayPath }
        let moreCount = max(0, action.targets.count - targetPaths.count)
        let targetsPart = targetPaths.isEmpty ? "" : " | targets: \(targetPaths.joined(separator: ", "))"
            + (moreCount > 0 ? " (+\(moreCount) more)" : "")
        let keeperPart = action.destination.map { " | keeper: \($0.path)" } ?? ""
        return "- [\(Self.shortID(action.id))] \(label): \(action.targets.count) files, "
            + "\(targetBytes.formattedByteCount), risk \(action.risk.rawValue)\(keeperPart)\(targetsPart) · \(action.reason)"
    }

    func estimatedBytes(for action: PlannedAction, in scan: ScanState) -> Int64 {
        var total: Int64 = 0
        for id in action.targets {
            guard let record = scan.filesByID[id] else { continue }
            total += subtreeBytes(of: record, in: scan)
        }
        if total == 0, let findingID = action.findingID,
           let finding = scan.outcome.findings.first(where: { $0.id == findingID }) {
            return finding.bytesReclaimable
        }
        return total
    }

    private func subtreeBytes(of record: FileRecord, in scan: ScanState) -> Int64 {
        let direct = ReclaimableBytes.size(of: record, checkClones: false)
        if record.kind != .directory || record.rolledUpItemCount != nil || direct > 0 {
            return direct
        }
        let prefix = record.url.standardizedFileURL.path + "/"
        return scan.outcome.files.reduce(Int64(0)) { sum, item in
            guard item.kind == .regularFile,
                  item.url.standardizedFileURL.path.hasPrefix(prefix) else { return sum }
            return sum + ReclaimableBytes.size(of: item, checkClones: false)
        }
    }

    func scanSummaryResourceJSON() -> String {
        guard let lastScan else {
            return "{\"status\":\"no_scan\",\"note\":\"Call scan first to inspect findings and plan actions.\"}"
        }
        var categoryCounts: [String: Int] = [:]
        var reclaimable: Int64 = 0
        for finding in lastScan.outcome.findings {
            categoryCounts[finding.category.rawValue, default: 0] += 1
            reclaimable += finding.bytesReclaimable
        }
        let pendingCount = lastScan.plan.actions.filter {
            $0.userDecision == .undecided && $0.executedAt == nil
        }.count
        let payload: [String: Any] = [
            "status": "ready",
            "session_id": lastScan.outcome.session.id,
            "files_count": lastScan.outcome.files.filter { $0.kind != .directory }.count,
            "findings_count": lastScan.outcome.findings.count,
            "reclaimable_bytes": reclaimable,
            "categories": categoryCounts,
            "plan_actions_count": lastScan.plan.actions.count,
            "pending_actions_count": pendingCount
        ]
        guard let data = Self.dataForPayload(payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    func initializeResponse(id: Any, params: [String: Any]?) -> MCPResponse {
        let requested = params?["protocolVersion"] as? String
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.defaultProtocolVersion
        return MCPResponse(Self.responsePayload(id: id, result: [
            "protocolVersion": version,
            "capabilities": [
                "tools": [:] as [String: Any],
                "prompts": [:] as [String: Any],
                "resources": [:] as [String: Any]
            ],
            "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
            "instructions": """
            Local Mac cleanup and monitoring agent. A human approves every change: always call \
            execute without confirm first, show the plan, and only call execute with confirm: true \
            after the user agrees. Enforced policy: execute runs ONLY clone-fold actions (apfs_clone \
            strategy, deletes nothing). Destructive actions (trash, package-manager cleanups) are \
            refused here and must be approved in the Tidybyte app, where files stay recoverable in Trash.
            """
        ]))
    }

    func promptsGet(id: Any, params: [String: Any]?) -> MCPResponse {
        guard let name = params?["name"] as? String, !name.isEmpty else {
            return MCPResponse(Self.errorPayload(id: id, code: -32602, message: "Missing prompt name."))
        }
        var args: [String: String] = [:]
        if let rawArgs = params?["arguments"] as? [String: Any] {
            for (key, value) in rawArgs {
                if let str = value as? String { args[key] = str }
            }
        }
        guard let rendered = MCPPromptCatalog.get(name: name, arguments: args) else {
            return MCPResponse(Self.errorPayload(id: id, code: -32602, message: "Unknown prompt: \(name)."))
        }
        return MCPResponse(Self.responsePayload(id: id, result: rendered))
    }

    func resourcesRead(id: Any, params: [String: Any]?) async -> MCPResponse? {
        guard let uri = params?["uri"] as? String, !uri.isEmpty else {
            return MCPResponse(Self.errorPayload(id: id, code: -32602, message: "Missing resource uri."))
        }
        switch uri {
        case MCPResourceCatalog.scanSummaryURI:
            let text = scanSummaryResourceJSON()
            return MCPResponse(Self.responsePayload(id: id, result: [
                "contents": [["uri": uri, "mimeType": "application/json", "text": text]]
            ]))
        #if !APP_STORE
        case MCPResourceCatalog.monitorLiveURI:
            let text = await MonitorToolRouter.liveMonitorResourceJSON()
            if Task.isCancelled { return nil }
            return MCPResponse(Self.responsePayload(id: id, result: [
                "contents": [["uri": uri, "mimeType": "application/json", "text": text]]
            ]))
        #endif
        default:
            return MCPResponse(Self.errorPayload(id: id, code: -32602, message: "Unknown resource: \(uri)."))
        }
    }

    func dryRunMessage(pending: [PlannedAction], targetBytes: Int64, summaryText: String) -> String {
        let appOnly = pending.filter { $0.risk >= .high || $0.actionType != .cloneDeduplicate }
        let cloneOnly = pending.filter { $0.risk < .high && $0.actionType == .cloneDeduplicate }
        let guidance: String
        if appOnly.isEmpty {
            guidance = "Ask the user, then call execute again with confirm: true."
        } else if cloneOnly.isEmpty {
            let types = Array(Set(appOnly.map(\.actionType.rawValue))).sorted().joined(separator: ", ")
            guidance = "Note: \(appOnly.count) action(s) (\(types)) are destructive or high-risk and must be "
                + "reviewed and approved in the Tidybyte app (confirm: true over MCP will refuse them)."
        } else {
            let cloneIDs = cloneOnly.map { Self.shortID($0.id) }.joined(separator: ", ")
            guidance = "Note: \(appOnly.count) action(s) require the Tidybyte app; only the \(cloneOnly.count) "
                + "clone-fold action(s) [\(cloneIDs)] can run via execute with confirm: true."
        }
        return """
        Dry run. Nothing changed. Would run \(pending.count) actions affecting \(targetBytes.formattedByteCount):
        \(summaryText)
        \(guidance)
        """
    }

    func updatedPlanAfterExecution(
        plan: Plan, approved: [PlannedAction], summary: ExecutionSummary
    ) -> Plan {
        var updated = plan
        let stamped = Set(approved.map(\.id))
        let now = Date()
        for index in updated.actions.indices where stamped.contains(updated.actions[index].id) {
            let actionID = updated.actions[index].id
            if summary.failedActionIDs.contains(actionID) {
                updated.actions[index].status = .failed
                updated.actions[index].executedAt = nil
                updated.actions[index].userDecision = .undecided
            } else {
                updated.actions[index].executedAt = now
                updated.actions[index].status = .completed
                updated.actions[index].userDecision = .approved
            }
        }
        let allSettled = updated.actions.allSatisfy {
            $0.status == .completed || $0.status == .rejected || $0.status == .skipped
        }
        updated.status = allSettled ? .completed : .partiallyApproved
        return updated
    }
}
