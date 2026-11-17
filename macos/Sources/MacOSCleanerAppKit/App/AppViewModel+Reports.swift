import AppKit
import Foundation
import MacOSCleanerCore

// Report and database export actions, kept out of AppViewModel.swift to stay within its length budget.

@MainActor
extension AppViewModel {
    func openLatestReport() {
        guard let reportURL = generatedReportURL else {
            errorMessage = L10n.string("No report generated yet.", language: languageStore.activeOverride)
            return
        }
        NSWorkspace.shared.open(reportURL)
        statusMessage = L10n.string("Opened last report.", language: languageStore.activeOverride)
    }

    func generateReport(to directory: URL? = nil) async {
        guard let outcome, let currentPlan = plan else {
            statusMessage = L10n.string("Run a scan first to generate a report.", language: languageStore.activeOverride)
            return
        }
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Wait until the current scan or cleanup finishes.", language: languageStore.activeOverride)
            return
        }
        do {
            let reportDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(AppIdentity.reportsFolderName, isDirectory: true)
            generatedReportURL = try await reportGenerator.generateCleanupReport(
                outcome: outcome, plan: currentPlan, destination: reportDirectory)
            statusMessage = L10n.string("Local PDF report generated.", language: languageStore.activeOverride)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The default export name. ISO dates: the numeric style contains "/" in en_US, which is not a valid file name.
    static func databaseExportFileName(on date: Date) -> String {
        "MacOSCleaner-\(date.formatted(.iso8601.year().month().day())).sqlite"
    }

    func exportDatabase() async {
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Cannot export while a scan or execution is in progress.", language: languageStore.activeOverride)
            return
        }
        do {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Self.databaseExportFileName(on: Date())
            panel.allowedContentTypes = [.data]
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
                errorMessage = L10n.string(
                    "The database could not be exported: no window is available to attach the save panel to.",
                    language: languageStore.activeOverride
                )
                return
            }
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let destination = panel.url else { return }
            guard !isScanning, !isExecuting else {
                errorMessage = L10n.string(
                    "Cannot export while a scan or execution is in progress.",
                    language: languageStore.activeOverride
                )
                return
            }
            try await store.exportCopy(to: destination)
            statusMessage = L10n.string("Database exported successfully.", language: languageStore.activeOverride)
        } catch {
            errorMessage = L10n.format(
                "Failed to export database: %@",
                language: languageStore.activeOverride,
                error.localizedDescription
            )
        }
    }

    // MARK: - Dashboard rollup & approved action execution

    var dashboardSections: [(FindingCategory, Int64)] {
        guard let outcome else { return [] }
        let files = filesByID
        func targetPaths(_ finding: Finding) -> [String] {
            finding.targetFileIDs.compactMap { files[$0]?.url.standardizedFileURL.path }
        }
        var bytesByCategory: [FindingCategory: Int64] = [:]
        for (category, group) in Dictionary(grouping: outcome.findings, by: \.category) {
            func depth(_ finding: Finding) -> Int {
                targetPaths(finding).first.map { URL(fileURLWithPath: $0).pathComponents.count } ?? 99
            }
            let ordered = group.sorted { depth($0) < depth($1) }
            var coveredDirs: [String] = []
            var total: Int64 = 0
            for finding in ordered {
                let paths = targetPaths(finding)
                if paths.allSatisfy({ path in coveredDirs.contains { path.hasPrefix($0 + "/") } }) {
                    continue
                }
                total += finding.bytesReclaimable
                for path in paths
                where files[finding.targetFileIDs.first ?? ""]?.kind == .directory
                    || files[finding.targetFileIDs.first ?? ""]?.kind == .package {
                    coveredDirs.append(path)
                }
            }
            bytesByCategory[category] = total
        }
        return bytesByCategory.sorted { $0.value > $1.value }
    }

    #if DEBUG
    func executeApprovedActions() async { await executeApprovedActions(allowingRiskUpTo: .forbidden) }
    #endif

    func executeConfirmedRequest(_ request: ExecutionRequest, packageCommandsOnly: Bool = false) async {
        guard request.isCurrent(in: self) else {
            errorMessage = L10n.string(
                "The plan changed. Review the current actions and confirm again.",
                language: languageStore.activeOverride
            )
            return
        }
        let ids = Self.confirmedActionIDs(in: request.actions, packageCommandsOnly: packageCommandsOnly)
        await executeApprovedActions(allowingRiskUpTo: request.maximumRisk, confirmedActionIDs: ids)
    }

    private func executeApprovedActions(
        allowingRiskUpTo maximumRisk: RiskLevel,
        confirmedActionIDs: Set<String>? = nil
    ) async {
        let override = languageStore.activeOverride
        guard let outcome, let currentPlan = plan, !isScanning, !isExecuting, !isPlanning else { return }
        let approved = currentPlan.actions.filter {
            ($0.userDecision == .approved || $0.userDecision == .alwaysDoThis)
                && (confirmedActionIDs?.contains($0.id) ?? true)
        }
        let executableActions = approved.filter { $0.risk <= maximumRisk && $0.actionType.isExecutable }
        guard !executableActions.isEmpty else {
            reportNoExecutableActions(reviewOnlyCount: approved.filter { !$0.actionType.isExecutable }.count, override: override)
            return
        }
        isExecuting = true
        lastExecutionActionIDs = Set(executableActions.map(\.id))
        executionTotalActions = executableActions.count
        executionCompletedActions = 0
        executionProgress = 0
        statusMessage = L10n.format("Executing %@ actions...", language: override, executionLabel(forRiskLimit: maximumRisk))
        plan?.status = .executing
        let summary = await executor.execute(
            actions: executableActions,
            filesByID: filesByID,
            packageCandidates: outcome.packageCandidates,
            progress: { [weak self] completed in
                await MainActor.run {
                    guard let self else { return }
                    self.executionCompletedActions = completed
                    self.executionProgress = Double(completed) / Double(max(1, self.executionTotalActions))
                }
            }
        )
        await finalizeExecution(summary: summary, currentPlan: currentPlan, maximumRisk: maximumRisk, override: override)
    }

    private func reportNoExecutableActions(reviewOnlyCount: Int, override: AppLanguage?) {
        if reviewOnlyCount > 0 {
            statusMessage = reviewOnlyCount == 1
                ? L10n.string("1 approved action is review-only and was not executed.", language: override)
                : L10n.format("%lld approved actions are review-only and were not executed.", language: override, reviewOnlyCount)
        } else {
            statusMessage = L10n.string("No approved actions in the selected risk band to execute.", language: override)
        }
    }

    private func finalizeExecution(
        summary: ExecutionSummary,
        currentPlan: Plan,
        maximumRisk: RiskLevel,
        override: AppLanguage?
    ) async {
        executionCompletedActions = executionTotalActions
        executionProgress = 1
        executionSummary = summary
        undoRecords = summary.undoRecords + undoRecords
        let completedIDs = Set(summary.logs.map(\.plannedActionID))
        let failedIDs = summary.failedActionIDs
        var updatedPlan = self.plan ?? currentPlan
        let approvedIDs = Set(currentPlan.actions.filter {
            ($0.userDecision == .approved || $0.userDecision == .alwaysDoThis)
                && $0.executedAt == nil && $0.status != .completed && $0.status != .failed
        }.map(\.id))
        updatedPlan.actions = updatedPlan.actions.map { action in
            var changed = action
            if completedIDs.contains(action.id) || failedIDs.contains(action.id) {
                changed.status = failedIDs.contains(action.id) ? .failed : .completed
                changed.executedAt = Date()
            }
            return changed
        }
        let executedByID = Dictionary(
            updatedPlan.actions.filter { $0.executedAt != nil }.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        updatedPlan.originalActions = updatedPlan.originalActions?.map { executedByID[$0.id] ?? $0 }
        let unresolvedIDs = approvedIDs.subtracting(completedIDs).subtracting(failedIDs)
        updatedPlan.status = unresolvedIDs.isEmpty && summary.failures.isEmpty ? .completed : .partiallyApproved
        self.plan = updatedPlan
        await saveExecutionHistory(updatedPlan)
        isExecuting = false
        statusMessage = executionStatusText(
            summary: summary, unresolvedEmpty: unresolvedIDs.isEmpty, maximumRisk: maximumRisk, override: override
        )
        if summary.requiresRescan {
            errorMessage = L10n.string(
                "Some actions need a fresh review: file identities changed since the scan. Run a new scan, then re-approve those actions.",
                language: override
            )
        }
        do {
            try await memory.detectPatterns(from: currentPlan.actions, filesByID: filesByID)
        } catch {
            logger.warning("Pattern detection failed: \(error.localizedDescription)")
        }
    }

    private func executionStatusText(
        summary: ExecutionSummary,
        unresolvedEmpty: Bool,
        maximumRisk: RiskLevel,
        override: AppLanguage?
    ) -> String {
        guard summary.failures.isEmpty else {
            return L10n.string("Some actions failed. Review the execution summary.", language: override)
        }
        if unresolvedEmpty {
            return L10n.string("All selected approved actions completed.", language: override)
        }
        if maximumRisk == .low {
            return L10n.string("Safe actions completed. Higher-risk approved actions are still pending.", language: override)
        }
        return L10n.string("Execution completed with pending approved actions.", language: override)
    }

    func approvedActions(for maximumRisk: RiskLevel = .forbidden) -> [PlannedAction] {
        guard let currentPlan = plan else { return [] }
        return currentPlan.actions.filter { action in
            (action.userDecision == .approved || action.userDecision == .alwaysDoThis) && action.risk <= maximumRisk
        }
    }

    func executionLabel(forRiskLimit maximumRisk: RiskLevel) -> String {
        let override = languageStore.activeOverride
        return switch maximumRisk {
        case .low: L10n.string("low-risk", language: override)
        case .medium: L10n.string("medium-risk and below", language: override)
        case .high: L10n.string("high-risk and below", language: override)
        case .forbidden: L10n.string("approved", language: override)
        }
    }
}
