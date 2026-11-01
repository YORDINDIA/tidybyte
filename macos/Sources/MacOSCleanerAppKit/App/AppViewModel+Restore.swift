import Foundation
import MacOSCleanerCore
import os

/// Session restore: rebuilds the last finished scan from the store so
/// reopening the app shows the same results and review decisions instead of
/// an empty workspace. Lives outside AppViewModel.swift to keep that type
/// within its lint length budget.
@MainActor
extension AppViewModel {
    private static let restoreLogger = Logger(
        subsystem: AppIdentity.bundleIdentifier, category: "SessionRestore")

    /// No-op when a scan already produced in-memory results (this launch's
    /// own scan always wins over a restored one).
    func restoreLastSession() async {
        guard outcome == nil, plan == nil else { return }
        do {
            // A session still marked running belongs to a crashed or killed
            // process (this app's previous launch, or a parallel tool that
            // died). Retire stale ones first so they are never restored and
            // purgeOldData can clean them later; a concurrent app's fresh
            // session stays untouched behind the cutoff.
            try await store.failStaleRunningSessions(olderThan: Date().addingTimeInterval(-600))
            guard let session = try await store.latestFinishedScanSession() else { return }
            guard let restoredOutcome = try await loadRestoredOutcome(for: session) else { return }
            let restoredPlan = try await store.latestPlan(for: session.id)
            apply(restoredOutcome, plan: restoredPlan, session: session)
            let scannedAt = session.completedAt ?? session.startedAt
            statusMessage = String(
                localized: "Restored your last scan from \(scannedAt.formatted(date: .abbreviated, time: .shortened)).",
                comment: "Startup restore of the previous scan's results")
            Self.restoreLogger.info(
                "Restored scan session \(session.id) (\(restoredOutcome.files.count) files, \(restoredOutcome.findings.count) findings)")
        } catch {
            // A failed restore must never block startup: log it and leave the
            // fresh-launch state in place.
            Self.restoreLogger.warning("Session restore failed: \(error.localizedDescription)")
        }
    }

    /// Bulk rows for one session. Nil when the scan persisted none — a
    /// cancelled or failed run keeps only its small session row, so there is
    /// nothing to restore and onboarding stays as-is.
    private func loadRestoredOutcome(for session: ScanSession) async throws -> ScanOutcome? {
        let files = try await store.loadFileRecords(for: session.id)
        let findings = try await store.loadFindings(for: session.id)
        guard !files.isEmpty || !findings.isEmpty else { return nil }
        return ScanOutcome(
            session: session,
            files: files,
            fingerprints: try await store.loadFingerprints(forSession: session.id),
            contentSummaries: try await store.loadContentSummaries(for: session.id),
            projects: try await store.loadProjects(for: session.id),
            edges: try await store.loadRelationshipEdges(for: session.id),
            findings: findings,
            recommendations: try await store.loadRecommendations(for: session.id),
            snapshot: try await store.recentSnapshots(limit: 1).first ?? StorageSnapshot(
                id: UUID().uuidString,
                createdAt: session.completedAt ?? session.startedAt,
                totalBytes: session.totalBytesSeen,
                bytesByCategory: [:],
                bytesByRootPath: [:],
                bytesByProject: [:],
                removedBytesThroughApp: 0),
            packageCandidates: session.packageCandidates ?? [],
            wasCancelled: session.status == .cancelled,
            notices: session.notices ?? [])
    }

    /// Installs the restored state — the same shape as a finished scan's
    /// epilogue, minus the toasts and notifications.
    private func apply(_ restoredOutcome: ScanOutcome, plan restoredPlan: Plan?, session: ScanSession) {
        outcome = restoredOutcome
        plan = restoredPlan
        reviewRiskFilter = nil
        // Land on the first action still awaiting a decision, if any.
        selectedActionID = restoredPlan?.actions.first(where: { $0.executedAt == nil })?.id
            ?? restoredPlan?.actions.first?.id
        showOnboarding = false
        dismissedScanNoticeIDs = loadDismissedNoticeIDs(sessionID: session.id)
    }
}
