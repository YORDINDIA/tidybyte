import Foundation
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore
import XCTest

/// Apps + Insights audit evidence (2026-11-04): behavior tests for the two
/// assigned open stories that lacked real coverage.
///
/// - EX-18: executing an approved plan must feed `MemoryEngine.detectPatterns`
///   (the call lives in `AppViewModel.executeApprovedActions`; the existing
///   MemoryEngine tests cover the engine itself, never the call site).
/// - AI-08: a scan with AI enabled and a failing gateway must still complete
///   with rule-based local results.
///
/// Safety rules mirror `AppViewModelTests`: tiny temp fixtures, isolated
/// defaults, in-memory store, `.tag` execution only (no Trash).
@MainActor
final class AppsInsightsEvidenceTests: XCTestCase {

    // MARK: - Helpers (mirrors AppViewModelTests' private harness)

    private func makeDefaultsSuite() -> UserDefaults {
        makeIsolatedDefaults()
    }

    private func makeModel() throws -> (model: AppViewModel, store: SQLiteStore) {
        let store = try SQLiteStore.inMemory()
        let memory = MemoryEngine(store: store)
        let orchestrator = ScanOrchestrator(store: store, memory: memory)
        let executor = TestFixtures.makeExecutor(store: store)
        let undo = UndoManagerService(store: store, memory: memory)
        let model = AppViewModel(
            store: store,
            keychain: KeychainStore(inMemory: true),
            memory: memory,
            orchestrator: orchestrator,
            executor: executor,
            undoService: undo,
            reportGenerator: ReportGenerator(store: store),
            notifications: NotificationScheduler(),
            planner: PlannerAgent(),
            defaults: makeDefaultsSuite()
        )
        return (model, store)
    }

    /// Tiny scan root: cache folder, old download, and a duplicate pair.
    private func makeScanFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppsInsightsAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Caches/App", isDirectory: true), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(
            to: root.appendingPathComponent("Caches/App/cache.bin"))
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let installer = downloads.appendingPathComponent("old-installer.dmg")
        try Data("%PDF-1.4 fixture".utf8).write(to: installer)
        try FileManager.default.setAttributes(
            [.modificationDate: Calendar.current.date(byAdding: .day, value: -45, to: Date())!],
            ofItemAtPath: installer.path)
        try Data("same-payload".utf8).write(to: downloads.appendingPathComponent("duplicate-a.txt"))
        try Data("same-payload".utf8).write(to: downloads.appendingPathComponent("duplicate-b.txt"))
        return root
    }

    private func runScanOnFixture(_ model: AppViewModel, root: URL) async -> Bool {
        model.selectedMode = .selectedFolders
        model.selectedFolders = [root]
        model.runScan()
        let deadline = Date().addingTimeInterval(20)
        var settled = false
        while Date() < deadline {
            if model.plan != nil || model.errorMessage != nil { settled = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if settled {
            let clearDeadline = Date().addingTimeInterval(20)
            while Date() < clearDeadline, model.isScanning {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return settled
    }

    // MARK: - EX-18: pattern detection runs after execution

    func testExecutionRunsPatternDetectionAndCreatesLearnedRule() async throws {
        // Given a scanned plan with three always-do-this tag decisions on files
        // in the same directory — exactly the shape detectPatterns() turns into
        // a learned rule when the execution path feeds it the plan.
        let (model, store) = try makeModel()
        let root = try makeScanFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = await runScanOnFixture(model, root: root)
        XCTAssertTrue(completed)
        let outcome = try XCTUnwrap(model.outcome)
        let names = ["duplicate-a.txt", "duplicate-b.txt", "old-installer.dmg"]
        var actions: [PlannedAction] = []
        for (index, name) in names.enumerated() {
            let file = try XCTUnwrap(outcome.files.first { $0.fileName == name }, "missing fixture file \(name)")
            actions.append(PlannedAction(
                id: "learn-\(index)", planID: "learn-plan", actionType: .tag, targets: [file.id],
                destination: nil, status: .proposed, risk: .low, confidence: 0.9,
                reason: "EX-18 fixture", userDecision: .alwaysDoThis, executedAt: nil, findingID: nil
            ))
        }
        model.plan = Plan(
            id: "learn-plan", scanSessionID: outcome.session.id, createdAt: Date(),
            status: .proposed, summary: "EX-18 fixture", estimatedReclaimableBytes: 0,
            estimatedFilesAffected: actions.count, riskBreakdown: [.low: actions.count],
            actions: actions
        )

        // When the user executes the approved plan
        let request = try XCTUnwrap(ExecutionRequest(model: model, maximumRisk: .low))
        await model.executeConfirmedRequest(request)
        XCTAssertNotNil(model.executionSummary, "Execution must complete for the test to exercise the post-execution path")

        // Then the execution path ran detectPatterns: the store now holds a
        // learned "always" rule for the repeated same-directory decisions.
        let rules = try await store.loadMemoryRules()
        let learned = rules.filter { $0.source == "learned decision" && $0.ruleType == .always }
        XCTAssertFalse(learned.isEmpty, "Executing an approved plan must feed detectPatterns (EX-18)")
    }

    // MARK: - AI-08: scan completes with local results when AI fails

    func testScanCompletesWithLocalResultsWhenAIFails() async throws {
        // Given AI enabled in a non-local privacy mode with no stored key for
        // the (non-default) provider: the gateway throws missingAPIKey mid-scan.
        let (model, _) = try makeModel()
        let root = try makeScanFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        model.includeAI = true
        // A non-default provider name skips the legacy-keychain fallback, so
        // the lookup cannot reach the operator's real keychain or the network.
        model.providerSettings.providerName = "audit-test-provider"
        model.providerSettings.privacyMode = .metadataOnlyAI

        // When a scan runs
        let completed = await runScanOnFixture(model, root: root)

        // Then the scan still completes rule-based: local results, a plan, and
        // no failure state — the AI failure must not block the workspace.
        XCTAssertTrue(completed, "The scan must complete despite the AI failure")
        XCTAssertNotNil(model.outcome, "Local scan results must exist")
        XCTAssertNotNil(model.plan, "A rule-based plan must be assembled")
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.errorMessage, "AI failure must not surface as a scan error")
    }
}
