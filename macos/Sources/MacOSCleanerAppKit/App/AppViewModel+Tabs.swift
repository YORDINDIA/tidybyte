import Foundation
import MacOSCleanerCore

// MARK: - Top-level tabs

/// Tab, uninstall-staging, and snapshot-diff behavior for AppViewModel.
@MainActor
extension AppViewModel {

    var duplicateFindings: [Finding] {
        (outcome?.findings ?? []).filter { $0.category == .duplicate }
    }

    func loadInstalledApplications() async {
        guard !isLoadingApplications else { return }
        isLoadingApplications = true
        defer { isLoadingApplications = false }
        let service = ApplicationFootprintService()
        installedApplications = await service.enumerateInstalledApplications()
        if installedApplications.isEmpty {
            statusMessage = L10n.string(
                "No applications found in /Applications or ~/Applications.",
                language: languageStore.activeOverride
            )
        }
    }

    func loadFootprint(for app: InstalledApplication) async {
        guard footprintItemsByAppID[app.id] == nil else { return }
        let service = ApplicationFootprintService()
        let items = await service.footprintItems(for: app)
        footprintItemsByAppID[app.id] = items
    }

    /// Stages a complete uninstall for an app into the review plan as
    /// Trash-first recommendations.
    func stageUninstall(for app: InstalledApplication) async {
        guard !stagedUninstallAppIDs.contains(app.id) else { return }
        let staged = await stage(name: app.name) { service, sessionID in
            try await service.stagedUninstall(for: app, sessionID: sessionID)
        }
        if staged { stagedUninstallAppIDs.insert(app.id) }
    }

    /// Adds a user launch agent's plist to Leftovers. It stops at next login.
    @discardableResult
    func stageRemoval(of item: LaunchItem) async -> Bool {
        guard item.canRemove else { return false }
        let override = languageStore.activeOverride
        return await stage(name: item.label) { service, sessionID in
            await service.stagedRemoval(
                of: [item.url],
                summary: L10n.format("Login item %@", language: override, item.label),
                reason: L10n.string(
                    "Moves the launch agent to Trash. It stops running at your next login. Restore it from History.",
                    language: override
                ),
                sessionID: sessionID
            )
        }
    }

    /// Creates the standalone session that staged actions attach to when no scan exists.
    private func startStandaloneReview(for name: String) async -> Bool {
        let session = ScanSession(
            scanType: .selectedFolders, rootURLs: [], permissionsSnapshot: "staged", status: .completed)
        do {
            try await store.saveScanSession(session)
        } catch {
            errorMessage = L10n.format(
                "Could not start a review for %@: %@",
                language: languageStore.activeOverride,
                name,
                error.localizedDescription
            )
            return false
        }
        outcome = .standalone(session: session)
        plan = .empty(sessionID: session.id)
        return true
    }

    @discardableResult
    private func stage(
        name: String,
        _ build: (ApplicationFootprintService, String) async throws -> StagedUninstall
    ) async -> Bool {
        let override = languageStore.activeOverride
        guard claimPlanning() else {
            statusMessage = L10n.string("Finish the current operation first, then try again.", language: override)
            return false
        }
        defer { releasePlanning() }
        if outcome == nil || plan == nil {
            guard await startStandaloneReview(for: name) else { return false }
        }
        guard let scan = outcome, let currentPlan = plan else { return false }
        let signature = executionPlanSignature
        do {
            let staged = try await build(ApplicationFootprintService(), scan.session.id)
            return await commitStagedUninstall(
                staged,
                name: name,
                into: scan,
                plan: currentPlan,
                signature: signature
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func commitStagedUninstall(
        _ staged: StagedUninstall,
        name: String,
        into scan: ScanOutcome,
        plan currentPlan: Plan,
        signature: Data?
    ) async -> Bool {
        let override = languageStore.activeOverride
        guard !staged.files.isEmpty else {
            errorMessage = L10n.format(
                "Nothing removable found for %@. It may be missing or protected.",
                language: override,
                name
            )
            return false
        }
        var updatedPlan = currentPlan
        var mergedFilesByID = filesByID
        for file in staged.files { mergedFilesByID[file.id] = file }
        let appended = await planner.appendRecommendations(
            staged.recommendations,
            to: updatedPlan,
            filesByID: mergedFilesByID
        )
        guard !Task.isCancelled, signature == executionPlanSignature else {
            statusMessage = L10n.format("%@ could not be added because the plan changed. Try again.", language: override, name)
            return false
        }
        guard !appended.isEmpty else {
            statusMessage = L10n.format("%@ is already in Leftovers.", language: override, name)
            return false
        }
        var updatedScan = scan
        updatedScan.files.append(contentsOf: staged.files)
        updatedScan.findings.append(contentsOf: staged.findings)
        updatedPlan.actions.append(contentsOf: appended)
        updatedPlan.originalActions?.append(contentsOf: appended)
        refreshPlanEstimates(plan: &updatedPlan, filesByID: mergedFilesByID)
        outcome = updatedScan
        plan = updatedPlan
        selectedActionID = appended.last?.id
        if let lastID = appended.last?.id { selectedActionIDs = [lastID] }
        statusMessage = L10n.format("Added %@ to Leftovers for review.", language: override, name)
        schedulePlanPersistence()
        return true
    }

    /// Starts or stops watching /Applications for removed apps.
    func setRemovalWatching(_ enabled: Bool) {
        guard DistributionChannel.supportsAdvanced, enabled else {
            removalWatcher?.stop()
            removalWatcher = nil
            return
        }
        guard removalWatcher == nil else { return }
        let watcher = ApplicationRemovalWatcher { [weak self] app in
            guard let self else { return }
            removedApplications[app.id] = app
            Task { await self.notifyRemoval(of: app) }
        }
        watcher.start()
        removalWatcher = watcher
    }

    private func notifyRemoval(of app: InstalledApplication) async {
        guard !ApplicationRemovalWatcher.isApplicationStillInstalled(
            bundleIdentifier: app.id,
            previousURL: app.bundleURL
        ) else {
            removedApplications.removeValue(forKey: app.id)
            return
        }
        let service = ApplicationFootprintService()
        guard await service.footprintItems(for: app).contains(where: { $0.confidence == .certain }) else { return }
        await notifications.scheduleLeftoversNotification(
            appName: app.name, bundleID: app.id, bundlePath: app.bundleURL.path)
    }

    /// Notification tap: stage what the removed app left behind and show it.
    func reviewLeftovers(ofRemovedApp bundleID: String, name: String, bundlePath: String) async {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard !ApplicationRemovalWatcher.isApplicationStillInstalled(
            bundleIdentifier: bundleID,
            previousURL: bundleURL
        ) else {
            removedApplications.removeValue(forKey: bundleID)
            statusMessage = L10n.format(
                "%@ is still installed; leftover cleanup skipped.",
                language: languageStore.activeOverride,
                name
            )
            return
        }
        let app = removedApplications[bundleID] ?? InstalledApplication(
            id: bundleID, name: name, bundleURL: bundleURL,
            bundleIdentifier: bundleID, bundleSizeBytes: 0)
        await stageUninstall(for: app)
        if let id = selectedActionID { showReviewAction(id: id) } else { destination = .leftovers }
    }

    func refreshPlanEstimates(plan: inout Plan, filesByID: [String: FileRecord]? = nil) {
        let resolved = filesByID ?? self.filesByID
        plan.estimatedReclaimableBytes = Set(plan.actions.flatMap(\.targets))
            .compactMap { resolved[$0].map { ReclaimableBytes.size(of: $0, checkClones: false) } }
            .reduce(Int64(0), +)
        plan.estimatedFilesAffected = Set(plan.actions.flatMap(\.targets)).count
        plan.riskBreakdown = Dictionary(grouping: plan.actions, by: \.risk).mapValues(\.count)
    }

    // MARK: - Snapshots tab

    func loadSnapshotHistory() async {
        guard !isLoadingSnapshots else { return }
        isLoadingSnapshots = true
        defer { isLoadingSnapshots = false }
        do {
            storageSnapshots = try await store.recentSnapshots(limit: 30)
            if olderSnapshotID == nil || newerSnapshotID == nil {
                olderSnapshotID = storageSnapshots.dropFirst().first?.id
                newerSnapshotID = storageSnapshots.first?.id
            }
            await refreshSnapshotDiff()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSnapshotDiff() async {
        snapshotDiffError = nil
        guard let olderID = olderSnapshotID, let newerID = newerSnapshotID else {
            snapshotDiff = nil
            return
        }
        do {
            let service = SnapshotService(store: store)
            snapshotDiff = try await service.diffSnapshot(olderID: olderID, newerID: newerID)
        } catch {
            snapshotDiff = nil
            snapshotDiffError = error.localizedDescription
        }
    }
}
