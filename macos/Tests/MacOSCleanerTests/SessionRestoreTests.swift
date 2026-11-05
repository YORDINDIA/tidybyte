import Foundation
@testable import MacOSCleanerCore
import XCTest

/// Tests for last-session restore: the store APIs a relaunch uses to rebuild
/// the previous scan (latest finished session, per-session bulk loads, latest
/// plan, stale running-session retirement).
final class SessionRestoreTests: XCTestCase {
    private func makeSession(
        id: String, status: ScanSessionStatus, age: TimeInterval = 0
    ) -> ScanSession {
        var session = ScanSession(
            scanType: .selectedFolders,
            rootURLs: [URL(fileURLWithPath: "/tmp/restore-tests")],
            permissionsSnapshot: "test",
            status: status)
        session.id = id
        session.startedAt = Date().addingTimeInterval(-age - 60)
        session.completedAt = status == .running ? nil : Date().addingTimeInterval(-age)
        return session
    }

    private func makeFileRecord(scanSessionID: String, name: String) -> FileRecord {
        FileRecord(
            scanSessionID: scanSessionID,
            url: URL(fileURLWithPath: "/tmp/restore-tests/\(name)"),
            kind: .regularFile,
            sizeBytes: 4_096,
            source: .local
        )
    }

    func testLatestFinishedScanSessionSkipsRunningSessions() async throws {
        let store = try SQLiteStore.inMemory()
        try await store.saveScanSession(makeSession(id: "old-run", status: .completed, age: 600))
        try await store.saveScanSession(makeSession(id: "crashed-run", status: .running, age: 60))

        let latest = try await store.latestFinishedScanSession()

        XCTAssertEqual(latest?.id, "old-run", "A still-running session must never read as the last scan")
    }

    func testFailStaleRunningSessionsRetiresOnlyStaleRows() async throws {
        let store = try SQLiteStore.inMemory()
        try await store.saveScanSession(makeSession(id: "stale-run", status: .running, age: 3_600))
        // created_at records the first insert (the scan's start), so the
        // cutoff sits between the two inserts: stale-run predates it, the
        // fresh run does not.
        let cutoff = Date()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await store.saveScanSession(makeSession(id: "fresh-run", status: .running, age: 10))

        let retired = try await store.failStaleRunningSessions(olderThan: cutoff)

        XCTAssertEqual(retired, 1, "Only sessions older than the cutoff may be retired")
        // The retired session is now terminal, so it reads as the latest
        // finished session; the fresh running one is still skipped.
        let latest = try await store.latestFinishedScanSession()
        XCTAssertEqual(latest?.id, "stale-run")
        XCTAssertEqual(latest?.status, .failed)
    }

    /// The full relaunch path: persist a finished session the way the
    /// orchestrator does (session row carrying notices and package candidates,
    /// plus bulk rows and a plan with review decisions), then rebuild the
    /// outcome through the restore APIs and assert everything survives.
    func testRestoreRoundTripKeepsResultsAndDecisions() async throws {
        let store = try SQLiteStore.inMemory()
        var session = makeSession(id: "finished-run", status: .completed)
        let notice = ScanNotice(id: "notice-1", message: "Mail could not be read.")
        let candidate = PackageCleanupCandidate(
            id: "brew", title: "Brew cache", commandPath: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["cleanup", "--prune=all"], dryRunOutput: "1.2GB", risk: .medium, category: .packageManagerCleanup)
        session.notices = [notice]
        session.packageCandidates = [candidate]
        try await store.saveScanSession(session)

        let files = (0..<5).map { makeFileRecord(scanSessionID: session.id, name: "file-\($0).bin") }
        try await store.saveFileRecords(files)
        let finding = Finding(
            id: "finding-1", scanSessionID: session.id, category: .cache, severity: .low,
            confidence: 0.9, bytesReclaimable: 20_480, summary: "Caches",
            evidence: [:], targetFileIDs: files.map(\.id))
        try await store.saveFindings([finding])

        var plan = Plan.empty(sessionID: session.id)
        let action = PlannedAction(
            id: "action-1", planID: plan.id, actionType: .moveToTrash, targets: [files[0].id],
            destination: nil, status: .proposed, risk: .low, confidence: 0.8, reason: "test",
            userDecision: .approved, requiresExplicitConfirmation: true)
        plan.actions = [action]
        try await store.savePlan(plan)

        // Rebuild exactly like AppViewModel.restoreLastSession.
        let restoredSession = try await store.latestFinishedScanSession()
        let restoredFiles = try await store.loadFileRecords(for: session.id)
        let restoredFindings = try await store.loadFindings(for: session.id)
        let restoredPlan = try await store.latestPlan(for: session.id)

        XCTAssertEqual(restoredSession?.id, session.id)
        XCTAssertEqual(restoredSession?.notices?.first?.message, notice.message)
        XCTAssertEqual(restoredSession?.packageCandidates?.first?.title, "Brew cache")
        XCTAssertEqual(restoredFiles.count, files.count)
        XCTAssertEqual(restoredFindings.first?.targetFileIDs, files.map(\.id))
        let restoredAction = try XCTUnwrap(restoredPlan?.actions.first)
        XCTAssertEqual(restoredAction.userDecision, .approved)
        XCTAssertEqual(restoredAction.requiresExplicitConfirmation, true)
    }

    func testLatestPlanReturnsNewestPlanForSession() async throws {
        let store = try SQLiteStore.inMemory()
        let session = makeSession(id: "plan-session", status: .completed)
        try await store.saveScanSession(session)

        let older = Plan.empty(sessionID: session.id)
        try await store.savePlan(older)
        // savePlan upserts on id, so the newer plan needs a distinct id.
        var newer = Plan.empty(sessionID: session.id)
        newer.createdAt = older.createdAt.addingTimeInterval(5)
        try await store.savePlan(newer)

        let latest = try await store.latestPlan(for: session.id)
        XCTAssertEqual(latest?.id, newer.id)
    }

    /// Saves one of every auxiliary restore row (fingerprints, content
    /// summaries, projects, relationship edges, recommendations) for the
    /// session, stamped with its id.
    private func saveAuxiliaryRows(
        _ store: SQLiteStore, sessionID: String, fileIDs: [String], findingID: String
    ) async throws {
        try await store.saveFingerprints([
            FileFingerprint(
                fileID: fileIDs[0], sizeBytes: 4_096, quickHash: "quick-1", fullHash: nil,
                imagePerceptualHash: nil, videoKeyframeHashes: [], hashStatus: .hashed),
            FileFingerprint(
                fileID: fileIDs[1], sizeBytes: 8_192, quickHash: nil, fullHash: "full-2",
                imagePerceptualHash: "phash", videoKeyframeHashes: ["kf-1"], hashStatus: .fullHashConfirmed)
        ], scanSessionID: sessionID)
        try await store.saveContentSummaries([
            ContentSummary(
                fileID: fileIDs[0], textPreview: "hello", ocrText: nil, language: "en",
                detectedTopics: ["notes"], imageLabels: [], videoLabels: [], privacyLevel: .localOnly)
        ], scanSessionID: sessionID)
        try await store.saveProjects([
            ProjectUnit(
                id: "proj-1", name: "Tidybyte", rootURL: URL(fileURLWithPath: "/tmp/restore-tests"),
                projectType: "swift", confidence: 0.9, lastActivityAt: nil, manifestFiles: [],
                sourceFilesCount: 3, generatedFilesCount: 1, totalBytes: 12_288,
                reclaimableBytes: 4_096, status: .active)
        ], scanSessionID: sessionID)
        try await store.saveRelationshipEdges([
            RelationshipEdge(
                id: "edge-1", fromFileID: fileIDs[0], toFileID: fileIDs[1],
                edgeType: .generatedFrom, confidence: 0.8, evidence: "build output")
        ], scanSessionID: sessionID)
        try await store.saveRecommendations([
            Recommendation(
                id: "rec-1", findingID: findingID, actionType: .cloneDeduplicate,
                targetFileIDs: fileIDs, confidence: 0.7, risk: .low, reason: "duplicate pair",
                expectedBytesReclaimed: 4_096, requiresConfirmation: true, llmTraceID: nil,
                policyTraceID: nil)
        ], scanSessionID: sessionID)
    }

    /// The restore loaders the round-trip test above doesn't touch:
    /// fingerprints, content summaries, projects, relationship edges, and
    /// recommendations. All five feed the relaunch rebuild.
    func testRestoreLoadersRoundTripAuxiliaryRows() async throws {
        let store = try SQLiteStore.inMemory()
        let session = makeSession(id: "aux-run", status: .completed)
        try await store.saveScanSession(session)
        let files = (0..<2).map { makeFileRecord(scanSessionID: session.id, name: "aux-\($0).bin") }
        try await store.saveFileRecords(files)
        let fileIDs = files.map(\.id)
        let finding = Finding(
            id: "finding-aux", scanSessionID: session.id, category: .duplicate, severity: .low,
            confidence: 0.9, bytesReclaimable: 4_096, summary: "Duplicate pair",
            evidence: [:], targetFileIDs: fileIDs)
        try await store.saveFindings([finding])
        try await saveAuxiliaryRows(store, sessionID: session.id, fileIDs: fileIDs, findingID: finding.id)

        let fingerprints = try await store.loadFingerprints(forSession: session.id)
        XCTAssertEqual(fingerprints.count, 2)
        XCTAssertEqual(fingerprints.first { $0.fileID == fileIDs[1] }?.fullHash, "full-2")
        let summaries = try await store.loadContentSummaries(for: session.id)
        XCTAssertEqual(summaries.first?.textPreview, "hello")
        XCTAssertEqual(summaries.first?.privacyLevel, .localOnly)
        let projects = try await store.loadProjects(for: session.id)
        XCTAssertEqual(projects.first?.name, "Tidybyte")
        XCTAssertEqual(projects.first?.status, .active)
        let edges = try await store.loadRelationshipEdges(for: session.id)
        XCTAssertEqual(edges.first?.edgeType, .generatedFrom)
        XCTAssertEqual(edges.first?.toFileID, fileIDs[1])
        let recommendations = try await store.loadRecommendations(for: session.id)
        XCTAssertEqual(recommendations.first?.actionType, .cloneDeduplicate)
        XCTAssertNil(recommendations.first?.destination)
    }
}
