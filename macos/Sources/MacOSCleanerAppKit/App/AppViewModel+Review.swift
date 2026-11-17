import Foundation
import MacOSCleanerCore

// MARK: - Review flow helpers & decisions

/// Pure review-flow helpers and plan decision mutations used by the action
/// review UI (`ActionStackView`, `DuplicatesTabView`, and `NaturalLanguagePlanView`).
@MainActor
extension AppViewModel {
    private var findingCategories: [String: FindingCategory] {
        Dictionary((outcome?.findings ?? []).map { ($0.id, $0.category) }, uniquingKeysWith: { first, _ in first })
    }

    func actions(in destination: AppDestination) -> [PlannedAction] {
        let categories = findingCategories
        return (plan?.actions ?? []).filter {
            AppDestination.forCategory($0.findingID.flatMap { categories[$0] }) == destination
        }
    }

    var pendingBytesByDestination: [AppDestination: Int64] {
        let categories = findingCategories
        let files = filesByID
        var targets: [AppDestination: Set<String>] = [:]
        for action in plan?.actions ?? [] where action.executedAt == nil && action.userDecision != .rejected {
            let row = AppDestination.forCategory(action.findingID.flatMap { categories[$0] })
            targets[row, default: []].formUnion(action.targets)
        }
        let subtree = subtreeTotals
        return targets.mapValues { ids in
            let ordered = ids.compactMap { files[$0] }
                .sorted { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
            var coveredDirs: [String] = []
            var total: Int64 = 0
            for record in ordered {
                let path = record.url.standardizedFileURL.path
                guard !coveredDirs.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
                if record.kind == .directory || record.kind == .package {
                    coveredDirs.append(path)
                    total += ExploreSubtreeIndex.subtreeBytes(for: record, totals: subtree)
                } else {
                    total += ReclaimableBytes.size(of: record, checkClones: false)
                }
            }
            return total
        }
    }

    var visibleReviewActions: [PlannedAction] {
        Self.matchingActions(filter: reviewRiskFilter, in: actions(in: destination)).filter(actionMatchesSearch)
    }

    var selectedVisibleReviewAction: PlannedAction? {
        guard let id = selectedActionID else { return nil }
        if destination.isReview {
            return visibleReviewActions.first { $0.id == id }
        }
        if destination == .duplicates {
            return actions(in: .duplicates).first { actionMatchesSearch($0) && $0.id == id }
        }
        return nil
    }

    var selectedDuplicatePendingActions: [PlannedAction] {
        guard destination == .duplicates,
              let selected = selectedVisibleReviewAction,
              let findingID = selected.findingID else {
            return []
        }
        return (plan?.actions ?? []).filter { $0.findingID == findingID && $0.executedAt == nil }
    }

    func approveSelectedCommandTarget() {
        if destination == .duplicates {
            let actions = selectedDuplicatePendingActions.filter {
                $0.risk != .forbidden && $0.actionType.isExecutable
            }
            actions.forEach(approve)
            return
        }
        let targets = selectedReviewActionsInOrder.filter {
            $0.executedAt == nil && $0.risk != .forbidden && $0.actionType.isExecutable
        }
        if !targets.isEmpty {
            targets.forEach(approve)
        } else if let action = selectedVisibleReviewAction {
            approve(action)
        }
    }

    func rejectSelectedCommandTarget() {
        if destination == .duplicates {
            selectedDuplicatePendingActions.forEach(reject)
            return
        }
        let targets = selectedReviewActionsInOrder.filter { $0.executedAt == nil }
        if !targets.isEmpty {
            targets.forEach(reject)
        } else if let action = selectedVisibleReviewAction {
            reject(action)
        }
    }

    private var selectedReviewActionsInOrder: [PlannedAction] {
        guard destination.isReview, !selectedActionIDs.isEmpty else { return [] }
        return visibleReviewActions.filter { selectedActionIDs.contains($0.id) }
    }

    func showReviewAction(id: String) {
        reviewRiskFilter = nil
        searchText = ""
        selectedActionID = id
        selectedActionIDs = [id]
        let action = plan?.actions.first { $0.id == id }
        destination = AppDestination.forCategory(action?.findingID.flatMap { findingCategories[$0] })
        showsInspector = true
    }

    func approve(_ action: PlannedAction) {
        guard !isScanning, !isExecuting, !isPlanning else { return }
        updateAction(action.id) { item in
            item.userDecision = .approved
            item.status = .approved
            item.requiresExplicitConfirmation = true
        }
    }

    /// Swaps how one duplicate finding's pending actions resolve, sorting
    /// deterministically with descending risk so safest copies stay kept.
    func switchDuplicateResolution(forFinding findingID: String, to strategy: DuplicateStrategy) {
        guard var currentPlan = plan, !isScanning, !isExecuting, !isPlanning else { return }
        guard let finding = duplicateFindings.first(where: { $0.id == findingID }) else { return }
        let hasDecidedAction = currentPlan.actions.contains {
            $0.findingID == findingID && ($0.userDecision != .undecided || $0.executedAt != nil)
        }
        guard !hasDecidedAction else { return }
        currentPlan.actions.removeAll { $0.findingID == findingID }
        currentPlan.actions.append(contentsOf: PlannerAgent.duplicateResolutionActions(
            for: finding,
            filesByID: filesByID,
            strategy: strategy,
            planID: currentPlan.id
        ))
        currentPlan.actions.sort { lhs, rhs in
            if lhs.risk != rhs.risk { return lhs.risk > rhs.risk }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.id < rhs.id
        }
        refreshPlanEstimates(plan: &currentPlan)
        plan = currentPlan
        selectedActionID = currentPlan.actions.first { $0.findingID == findingID }?.id
        if let selected = selectedActionID { selectedActionIDs = [selected] }
        Task { [weak self] in
            do {
                try await self?.store.savePlan(currentPlan)
            } catch {
                self?.logger.warning("Plan persistence failed: \(error.localizedDescription)")
            }
        }
    }

    func reject(_ action: PlannedAction) {
        guard !isScanning, !isExecuting, !isPlanning else { return }
        updateAction(action.id) { item in
            item.userDecision = .rejected
            item.status = .rejected
        }
    }

    func alwaysDoThis(_ action: PlannedAction) async {
        guard !isScanning, !isExecuting, !isPlanning else { return }
        updateAction(action.id) { item in
            item.userDecision = .alwaysDoThis
            item.status = .approved
            item.requiresExplicitConfirmation = true
        }
        if let updated = plan?.actions.first(where: { $0.id == action.id }) {
            do {
                try await memory.learn(from: updated, filesByID: filesByID)
            } catch {
                errorMessage = L10n.format(
                    "Could not save your preference: %@",
                    language: languageStore.activeOverride,
                    error.localizedDescription
                )
            }
        }
    }

    func neverDoThisHere(_ action: PlannedAction) async {
        guard !isScanning, !isExecuting, !isPlanning else { return }
        updateAction(action.id) { item in
            item.userDecision = .neverDoThisHere
            item.status = .rejected
        }
        if let updated = plan?.actions.first(where: { $0.id == action.id }) {
            do {
                try await memory.learn(from: updated, filesByID: filesByID)
            } catch {
                errorMessage = L10n.format(
                    "Could not save your preference: %@",
                    language: languageStore.activeOverride,
                    error.localizedDescription
                )
            }
        }
    }

    @discardableResult
    func applyNaturalLanguageCommand() async -> Bool {
        let override = languageStore.activeOverride
        guard !Task.isCancelled, let currentPlan = plan,
              !naturalLanguageCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard claimPlanning() else {
            errorMessage = L10n.string("Wait for the current operation to finish before running a command.", language: override)
            return false
        }
        defer { releasePlanning() }
        let signature = executionPlanSignature
        let generation = scanGeneration
        let command = naturalLanguageCommand
        let updatedPlan = await planner.planForNaturalLanguageCommand(
            command, existingPlan: currentPlan, filesByID: filesByID
        )
        guard !Task.isCancelled, !isScanning, !isExecuting,
              generation == scanGeneration, signature == executionPlanSignature else {
            if !Task.isCancelled {
                errorMessage = L10n.string("The plan changed while Tidybyte was planning. Run the command again.", language: override)
            }
            return false
        }
        self.plan = updatedPlan
        schedulePlanPersistence()
        selectedActionID = updatedPlan.actions.first?.id
        selectedActionIDs = selectedActionID.map { [$0] } ?? []
        statusMessage = nlCommandStatusMessage(count: updatedPlan.actions.count, command: command, override: override)
        return true
    }

    private func nlCommandStatusMessage(count: Int, command: String, override: AppLanguage?) -> String {
        if count == 0 {
            return L10n.format(
                "No actions match '%@'. Try a different command or say 'everything' to restore.",
                language: override,
                command
            )
        }
        if count == 1 {
            return L10n.format("Command '%@' converted into 1 action.", language: override, command)
        }
        return L10n.format("Command '%@' converted into %lld actions.", language: override, command, count)
    }

    func applyCalibrationPreset(_ preset: String, ruleType: MemoryRuleType) async {
        do {
            try await memory.applyCalibrationPreference(preset, ruleType: ruleType)
            statusMessage = L10n.string("Preference saved.", language: languageStore.activeOverride)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateAction(_ id: String, update: (inout PlannedAction) -> Void) {
        guard var currentPlan = plan else { return }
        currentPlan.actions = currentPlan.actions.map { action in
            guard action.id == id else { return action }
            var changed = action
            update(&changed)
            return changed
        }
        let hasApproved = currentPlan.actions.contains {
            $0.userDecision == .approved || $0.userDecision == .alwaysDoThis
        }
        currentPlan.status = hasApproved ? .partiallyApproved : .proposed
        plan = currentPlan
        schedulePlanPersistence()
    }

    /// Stops any active system scan, execution, or media cleanup operation cleanly.
    func stopActiveWork() {
        if isScanning { cancelScan() }
        if isExecuting { cancelExecution() }
        if cleanup.isBusy { cleanup.cancel() }
    }

    func scanAll() {
        if cleanup.scope.roots.isEmpty, DistributionChannel.supportsAdvanced {
            cleanup.scope.mode = .fullMac
            cleanup.scope.roots = ReviewScope.presetFolders
                .map { ReviewSafety.userHome.appendingPathComponent($0) }
                .filter(Self.isLocalFolder)
        }
        cleanup.scan()
        guard DistributionChannel.supportsAdvanced else { return }
        if selectedMode == .selectedFolders && selectedFolders.isEmpty {
            selectedMode = .homeFolder
            saveSettings()
        }
        runScan()
    }

    static func isLocalFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey])
        return values?.isDirectory == true && values?.isSymbolicLink == false && values?.volumeIsLocal != false
    }

    static func matchingActions(filter: RiskLevel?, in actions: [PlannedAction]) -> [PlannedAction] {
        guard let filter else { return actions }
        return actions.filter { $0.risk == filter }
    }

    static func visibleUndecidedCount(actions: [PlannedAction], filter: RiskLevel?) -> Int {
        matchingActions(filter: filter, in: actions).filter { $0.userDecision == .undecided }.count
    }

    static func actionsToApprove(actions: [PlannedAction], filter: RiskLevel?) -> [PlannedAction] {
        matchingActions(filter: filter, in: actions).filter { $0.userDecision == .undecided }
    }

    static func undecidedActions(in actions: [PlannedAction]) -> [PlannedAction] {
        actions.filter { $0.userDecision == .undecided }
    }

    static func lowRiskUndecidedActions(in actions: [PlannedAction]) -> [PlannedAction] {
        actions.filter { $0.risk == .low && $0.userDecision == .undecided }
    }

    static var suggestionCommands: [String] {
        [
            L10n.string("safe caches"),
            L10n.string("old installers"),
            L10n.string("duplicate files"),
            L10n.string("project leftovers"),
            L10n.string("everything")
        ]
    }
}
