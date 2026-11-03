import Foundation
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore
import XCTest

/// M2 reliability evidence (2026-11-04): regression tests for the known open
/// items — MB-10 (menu-bar undo must ask why), UN-09 (skip-reason restore
/// records no regret rule), PR-18 (review controls are no-ops while
/// scanning), and the DP-04/05/06 store-fallback ladder.
@MainActor
final class M2ReliabilityEvidenceTests: XCTestCase {
    // MARK: - Shared harness

    private struct PrimaryUnavailable: Error {}

    private struct Harness {
        let model: AppViewModel
        let store: SQLiteStore
        let undo: UndoManagerService
    }

    private func makeDefaultsSuite() -> UserDefaults {
        makeIsolatedDefaults()
    }

    private func makeModel(store: SQLiteStore? = nil) throws -> Harness {
        let resolvedStore = try store ?? SQLiteStore.inMemory()
        let memory = MemoryEngine(store: resolvedStore)
        let undo = UndoManagerService(store: resolvedStore, memory: memory)
        let model = AppViewModel(
            store: resolvedStore,
            keychain: KeychainStore(inMemory: true),
            memory: memory,
            orchestrator: ScanOrchestrator(store: resolvedStore, memory: memory),
            executor: TestFixtures.makeExecutor(store: resolvedStore),
            undoService: undo,
            reportGenerator: ReportGenerator(store: resolvedStore),
            notifications: NotificationScheduler(),
            planner: PlannerAgent(),
            defaults: makeDefaultsSuite()
        )
        return Harness(model: model, store: resolvedStore, undo: undo)
    }

    /// Executes an approved tag action against a real fixture file so an undo
    /// record lands in the store.
    private func makeUndoRecord(store: SQLiteStore, in root: URL) async throws -> UndoRecord {
        let fileURL = root.appendingPathComponent("undo-me.txt")
        try Data("undoable".utf8).write(to: fileURL)
        let crawler = FileCrawler()
        let outcome = await crawler.crawl(rootURLs: [root], sessionID: "m2")
        let record = try XCTUnwrap(outcome.files.first { $0.url == fileURL.standardizedFileURL })
        let action = PlannedAction(
            id: "m2-action", planID: "m2-plan", actionType: .tag, targets: [record.id],
            destination: nil, status: .approved, risk: .low, confidence: 0.9, reason: "m2",
            userDecision: .approved, executedAt: nil, findingID: nil)
        let executor = TestFixtures.makeExecutor(store: store)
        let summary = await executor.execute(actions: [action], filesByID: [record.id: record])
        XCTAssertTrue(summary.failures.isEmpty, "fixture execution must succeed: \(summary.failures)")
        let undo = try XCTUnwrap(summary.undoRecords.first, "a tag execution must create an undo record")
        return undo
    }

    // MARK: - MB-10: menu-bar undo asks why, like in-app restore

    func testMenuBarUndoRoutesThroughRegretPromptInsteadOfRestoring() async throws {
        let harness = try makeModel()
        let model = harness.model
        let store = harness.store
        let undoService = harness.undo
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("M2-mb10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = try await makeUndoRecord(store: store, in: root)

        let delegate = AppDelegate()
        var openedWindow = false
        delegate.setModel(model, openMainWindow: { openedWindow = true })

        await delegate.undoLastAction()

        let request = try XCTUnwrap(
            model.pendingUndoRestore,
            "menu-bar undo must present the regret prompt (MB-10), not restore silently")
        guard case .systemRecord(let pending) = request else {
            return XCTFail("expected the system undo record, got \(request)")
        }
        XCTAssertEqual(pending.id, undo.id)
        XCTAssertTrue(openedWindow, "the prompt lives on the main window, which must be raised")
        // Nothing was restored yet: the record is still available in the store.
        let stillAvailable = try await store.loadUndoRecords().first { $0.id == undo.id }
        XCTAssertEqual(stillAvailable?.status, .available)
    }

    // MARK: - UN-09: restoring without a reason records no regret rule

    func testRestoreWithoutReasonRecordsNoRegretRule() async throws {
        let harness = try makeModel()
        let model = harness.model
        let store = harness.store
        let undoService = harness.undo
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("M2-un09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = try await makeUndoRecord(store: store, in: root)

        // The skip path: restore with a nil regret reason.
        let restored = try await undoService.restore(undo)
        XCTAssertEqual(restored.status, .restored)

        let rules = try await store.loadMemoryRules()
        XCTAssertTrue(
            rules.isEmpty,
            "a skip-reason restore must not teach the memory engine a regret rule; got \(rules)")
    }

    // MARK: - PR-18: review controls are no-ops while scanning

    func testApproveRejectAreNoOpsWhileScanning() throws {
        let model = try makeModel().model
        let action = PlannedAction(
            id: "p18", planID: "p18-plan", actionType: .moveToTrash, targets: ["t1"],
            destination: nil, status: .proposed, risk: .low, confidence: 0.9, reason: "p18",
            userDecision: .undecided, executedAt: nil, findingID: nil)
        model.plan = Plan(
            id: "p18-plan", scanSessionID: "s", createdAt: Date(), status: .proposed,
            summary: "p18", estimatedReclaimableBytes: 0, estimatedFilesAffected: 1,
            riskBreakdown: [.low: 1], actions: [action])
        model.isScanning = true

        model.approve(action)
        XCTAssertEqual(model.plan?.actions.first?.userDecision, .undecided, "approve is a no-op while scanning")
        model.reject(action)
        XCTAssertEqual(model.plan?.actions.first?.userDecision, .undecided, "reject is a no-op while scanning")
    }

    // MARK: - DP-04/05/06: the store-fallback ladder

    func testStoreSelectionUsesPrimaryWhenItWorks() async throws {
        let primary = try SQLiteStore.inMemory()
        let resolved = AppViewModel.resolveStore(primary: { primary })
        XCTAssertFalse(resolved.usedTempDatabase, "a healthy primary store must not set the temp flag")
        do { _ = try await resolved.store.loadUndoRecords() } catch { XCTFail("primary store must answer: \(error)") }
    }

    func testStoreSelectionFallsBackToTempWhenPrimaryFails() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("M2-temp-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let resolved = AppViewModel.resolveStore(primary: { throw PrimaryUnavailable() }, tempURL: tempURL)
        XCTAssertTrue(resolved.usedTempDatabase, "a failed primary must land on the temp tier (DP-04)")
        // The temp store is real: it opens and answers queries.
        do { _ = try await resolved.store.loadUndoRecords() } catch { XCTFail("temp store must answer: \(error)") }
    }

    func testStoreSelectionFallsBackToInMemoryWhenTempFails() async throws {
        // A temp URL whose parent directory does not exist cannot be opened.
        let impossibleTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("M2-missing-dir-\(UUID().uuidString)")
            .appendingPathComponent("nested.sqlite")
        let resolved = AppViewModel.resolveStore(
            primary: { throw PrimaryUnavailable() }, tempURL: impossibleTemp)
        XCTAssertTrue(resolved.usedTempDatabase, "every on-disk tier failed; the flag stays honest (DP-05)")
        // In-memory keeps the app running: queries work (DP-05).
        do { _ = try await resolved.store.loadUndoRecords() } catch { XCTFail("in-memory store must answer: \(error)") }
    }

    func testUnavailableStoreFailsClosedOnAccess() async {
        // DP-06: the last tier keeps the app alive but throws on every access.
        let store = SQLiteStore.unavailable
        do {
            _ = try await store.loadUndoRecords()
            XCTFail("the unavailable store must throw")
        } catch {
            guard case DatabaseError.databaseUnavailable = error else {
                return XCTFail("expected databaseUnavailable, got \(error)")
            }
        }
    }
}
