import Foundation
import MacOSCleanerCore

extension MCPKit {
    func toolScan(_ arguments: [String: Any]) async throws -> String {
        // A string or an empty path would widen the scan (an empty path is the
        // working directory), so both are rejected instead of ignored.
        // Relative paths such as "." resolve against the server's working directory,
        // so each path must be absolute after tilde expansion.
        let rawPaths = try Self.stringArrayArgument(arguments, "paths") ?? []
        let expanded = rawPaths.map { ($0 as NSString).expandingTildeInPath }
        guard expanded.allSatisfy({ $0.hasPrefix("/") }) else { throw MCPError.invalidArgument("paths") }
        let paths = expanded.map { URL(fileURLWithPath: $0) }
        let strategyName = try Self.stringArgument(arguments, "duplicate_strategy")
        guard strategyName == nil || strategyName == "apfs_clone" || strategyName == "move_to_trash" else {
            throw MCPError.invalidArgument("duplicate_strategy")
        }
        // Local-only and AI-off by construction: MCP never uploads content.
        let (outcome, plan) = try await orchestrator.scan(
            mode: paths.isEmpty ? .homeFolder : .selectedFolders,
            selectedFolders: paths,
            providerSettings: ProviderSettings(),
            includeAI: false,
            posture: .conservative,
            duplicateStrategy: Self.strategy(from: strategyName)
        )
        var filesByID: [String: FileRecord] = [:]
        for record in outcome.files {
            filesByID[record.id] = record
        }
        lastScan = ScanState(outcome: outcome, plan: plan, filesByID: filesByID)

        let duplicateFindings = outcome.findings.filter { $0.category == .duplicate }
        let duplicateBytes = plan.actions
            .filter { $0.actionType == .cloneDeduplicate || $0.actionType == .moveToTrash }
            .reduce(Int64(0)) { total, action in
                total + action.targets.reduce(Int64(0)) { sum, id in sum + (filesByID[id]?.sizeBytes ?? 0) }
            }
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

}
