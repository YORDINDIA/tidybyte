import Foundation
import MacOSCleanerCore
import os

/// Session restore: rebuilds the last finished scan from the store so
/// reopening the app shows the same results and review decisions instead of
/// an empty workspace.
@MainActor
extension AppViewModel {
    private static let restoreLogger = Logger(
        subsystem: AppIdentity.bundleIdentifier, category: "SessionRestore")

    /// No-op when a scan already produced in-memory results (this launch's
    /// own scan always wins over a restored one).
    func restoreLastSession() async {
        guard outcome == nil, plan == nil else { return }
        do {
            try await store.failStaleRunningSessions(olderThan: Date().addingTimeInterval(-600))
            guard let session = try await store.latestFinishedScanSession() else { return }
            guard let restoredOutcome = try await loadRestoredOutcome(for: session) else { return }
            let restoredPlan = try await store.latestPlan(for: session.id)
            apply(restoredOutcome, plan: restoredPlan, session: session)
            let scannedAt = session.completedAt ?? session.startedAt
            let formattedTime = scannedAt.formatted(date: .abbreviated, time: .shortened)
            statusMessage = L10n.format(
                "Restored your last scan from %@.",
                language: languageStore.activeOverride,
                formattedTime
            )
            Self.restoreLogger.info(
                "Restored scan session \(session.id) (\(restoredOutcome.files.count) files, \(restoredOutcome.findings.count) findings)")
        } catch {
            Self.restoreLogger.warning("Session restore failed: \(error.localizedDescription)")
        }
    }

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

    private func apply(_ restoredOutcome: ScanOutcome, plan restoredPlan: Plan?, session: ScanSession) {
        outcome = restoredOutcome
        plan = restoredPlan
        reviewRiskFilter = nil
        selectedActionID = restoredPlan?.actions.first(where: { $0.executedAt == nil })?.id
            ?? restoredPlan?.actions.first?.id
        selectedActionIDs = selectedActionID.map { [$0] } ?? []
        markOnboardingImplicitlyDismissed()
        dismissedScanNoticeIDs = loadDismissedNoticeIDs(sessionID: session.id)
    }
}
