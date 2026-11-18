import Foundation
import MacOSCleanerCore

// MB-10: restores initiated outside the History view — the menu bar's
// "Undo Last Cleanup" — are routed through the same regret-reason prompt as
// an in-app History restore instead of silently restoring.

@MainActor
extension AppViewModel {
    /// Reasons offered when a person restores a change.
    enum RegretReason: String, CaseIterable {
        case neededLater = "Needed later"
        case misclassified = "Misclassified"
        case shouldHaveArchived = "Should have archived, not deleted"
        case wrongProject = "Wrong project"
        case tooAggressive = "Too aggressive"

        var title: String {
            switch self {
            case .neededLater: L10n.string("Needed later")
            case .misclassified: L10n.string("Misclassified")
            case .shouldHaveArchived: L10n.string("Should have archived, not deleted")
            case .wrongProject: L10n.string("Wrong project")
            case .tooAggressive: L10n.string("Too aggressive")
            }
        }
    }

    /// A restore waiting for the user's regret reason (or a skip).
    enum PendingUndoRestore: Identifiable {
        case systemRecord(UndoRecord)
        case mediaEvent(ActivityEvent)

        var id: String {
            switch self {
            case .systemRecord(let record):
                return "system-\(record.id)"
            case .mediaEvent(let event):
                let path = event.item.url?.absoluteString ?? event.id
                return "media-\(path)"
            }
        }

        var subject: String {
            switch self {
            case .systemRecord(let record):
                return record.restoreURL?.path ?? record.trashURL?.path ?? record.inverseAction.displayName
            case .mediaEvent(let event):
                return event.item.url?.path ?? event.item.name
            }
        }
    }

    // MARK: - Startup background sweeps

    func sweepInterruptedOperations() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let override = languageStore.activeOverride
            let graceCutoff = Date().addingTimeInterval(-300)
            do {
                let stale = try await store.loadStalePendingUndos(olderThan: graceCutoff)
                guard !stale.isEmpty else { return }
                let paths = stale.compactMap { $0.log?.beforeState["path"] }
                var message = stale.count == 1
                    ? L10n.string(
                        "A previous cleanup was interrupted; 1 operation may be incomplete.",
                        language: override
                    )
                    : L10n.format(
                        "A previous cleanup was interrupted; %lld operations may be incomplete.",
                        language: override,
                        stale.count
                    )
                if !paths.isEmpty {
                    let preview = paths.prefix(3).joined(separator: ", ")
                    let suffix = paths.count > 3 ? "…" : ""
                    message += " " + L10n.format(
                        "Affected: %@%@. Check the Trash and undo history.",
                        language: override,
                        preview,
                        suffix
                    )
                }
                logger.warning("Interrupted operations found at startup: \(paths.joined(separator: ", "), privacy: .public)")
                errorMessage = message
            } catch {
                logger.warning("Startup sweep failed: \(error.localizedDescription)")
            }
        }
    }

    /// Defers expired-record cleanup off the critical startup path.
    func scheduleDeferredMaintenance() {
        deferredMaintenanceTask?.cancel()
        deferredMaintenanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            guard !isScanning, !isExecuting, !cleanup.isBusy else { return }
            do {
                try await store.purgeOldData()
                undoRecords = try await store.loadUndoRecords()
            } catch {
                logger.warning("Deferred store maintenance failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - History, Timeline & Undo

    func historyOperation(id: String) async -> OperationLog? {
        try? await store.loadOperationLog(id: id)
    }

    func saveExecutionHistory(_ plan: Plan) async {
        let recordedActions = plan.actions.filter { $0.executedAt != nil }
        let recordedIDs = Set(recordedActions.map(\.id))
        historyActions = (recordedActions + historyActions.filter { !recordedIDs.contains($0.id) })
            .sorted { ($0.executedAt ?? .distantPast) > ($1.executedAt ?? .distantPast) }
        do {
            try await store.savePlan(plan)
        } catch {
            errorMessage = L10n.format(
                "Could not save completed changes in History: %@",
                language: languageStore.activeOverride,
                error.localizedDescription
            )
        }
    }

    func loadUndoHistory() async {
        isLoadingUndoHistory = true
        defer { isLoadingUndoHistory = false }
        do {
            undoRecords = try await store.loadUndoRecords()
            historyActions = try await store.loadRecentExecutedActions(limit: 200)
                .sorted { ($0.executedAt ?? .distantPast) > ($1.executedAt ?? .distantPast) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadStorageTimeline() async {
        timelineLoadsInFlight += 1
        isLoadingTimeline = true
        defer {
            timelineLoadsInFlight -= 1
            isLoadingTimeline = timelineLoadsInFlight > 0
        }
        do {
            let forecaster = SpaceForecaster(store: store)
            spaceForecast = try await forecaster.forecast(volumeURL: FileManager.default.homeDirectoryForCurrentUser)
            storageSnapshots = try await store.recentSnapshots(limit: 30)
            if olderSnapshotID == nil || newerSnapshotID == nil {
                olderSnapshotID = storageSnapshots.dropFirst().first?.id
                newerSnapshotID = storageSnapshots.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore(_ undo: UndoRecord) async {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Wait until the current scan or cleanup finishes.", language: override)
            return
        }
        do {
            let restored = try await undoService.restore(undo)
            undoRecords = undoRecords.map { $0.id == restored.id ? restored : $0 }
            statusMessage = L10n.string("Undo completed.", language: override)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreWithReason(_ undo: UndoRecord) async {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Wait until the current scan or cleanup finishes.", language: override)
            return
        }
        do {
            let restored = try await undoService.restore(undo, regretReason: selectedRegretReason)
            undoRecords = undoRecords.map { $0.id == restored.id ? restored : $0 }
            selectedRegretReason = nil
            statusMessage = L10n.string("Undo completed.", language: override)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Scan & permission notices

    func evaluateFullDiskAccessHint(scanOutcome: ScanOutcome, mode: ScanMode) {
        let broadModes: Set<ScanMode> = [.homeFolder, .developerCleanup]
        guard broadModes.contains(mode), !FullDiskAccess.isGranted() else {
            fullDiskAccessHint = nil
            return
        }
        let suspiciouslyEmpty = scanOutcome.findings.isEmpty && scanOutcome.files.count < 1_000
        guard suspiciouslyEmpty || scanOutcome.session.errorsCount > 0 else {
            fullDiskAccessHint = nil
            return
        }
        fullDiskAccessHint = L10n.string(
            "Tidybyte can't see Mail, Safari, and some app data. Turn on Full Disk Access to include them.",
            language: languageStore.activeOverride
        )
    }

    func dismissFullDiskAccessHint() { fullDiskAccessHint = nil }

    func dismissScanNotice(_ id: String) {
        dismissedScanNoticeIDs.insert(id)
        defaults.set(outcome?.session.id, forKey: SettingsKey.dismissedNoticeSession.rawValue)
        defaults.set(Array(dismissedScanNoticeIDs), forKey: SettingsKey.dismissedNoticeIDs.rawValue)
    }

    func loadDismissedNoticeIDs(sessionID: String) -> Set<String> {
        guard defaults.string(forKey: SettingsKey.dismissedNoticeSession.rawValue) == sessionID else { return [] }
        return Set(defaults.stringArray(forKey: SettingsKey.dismissedNoticeIDs.rawValue) ?? [])
    }

    var activeScanNotices: [ScanNotice] {
        guard let outcome else { return [] }
        return outcome.notices.filter { !dismissedScanNoticeIDs.contains($0.id) }
    }
}
