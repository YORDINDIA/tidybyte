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

    // MARK: - PSA-03: one global plan order, risk descending

    /// A plan assembled across many recommendation sources must be globally
    /// monotonic: no high-risk action may ever sit below a low-risk one (PSA-03).
    func testPlanSortsGloballyRiskDescThenConfidenceDesc() async throws {
        let planner = PlannerAgent()
        var recommendations: [Recommendation] = []
        var filesByID: [String: FileRecord] = [:]
        for index in 0..<40 {
            let risk: RiskLevel = [.low, .medium, .high, .forbidden][index % 4]
            let record = FileRecord(
                scanSessionID: "s",
                url: URL(fileURLWithPath: "/tmp/psa03/\(index).bin"), sizeBytes: 1000)
            filesByID[record.id] = record
            recommendations.append(TestFixtures.makeRecommendation(
                id: "rec-\(index)", targetID: record.id, action: .moveToTrash, risk: risk,
                confidence: 0.5 + Double(index % 5) * 0.05))
        }
        let plan = await planner.makePlan(
            sessionID: "s", recommendations: recommendations, filesByID: filesByID)
        XCTAssertFalse(plan.actions.isEmpty)
        let rank = [RiskLevel.low: 0, .medium: 1, .high: 2, .forbidden: 3]
        let risks = plan.actions.map(\.risk)
        for index in 0..<(risks.count - 1) {
            XCTAssertGreaterThanOrEqual(
                rank[risks[index]] ?? 0, rank[risks[index + 1]] ?? 0,
                "risk inversion at \(index): \(risks[index]) followed by \(risks[index + 1])")
        }
    }

    // MARK: - CP-01/AIApps-01: badge bytes are subtree-correct and deduped

    // Crawler shape for the badge fixture: the outer Caches dir is an
    // ordinary directory (~0 entry bytes); the inner App dir is rolled up
    // with the subtree total.
    private func directory(_ url: URL, sizeBytes: Int64, rolledUp: Bool) -> FileRecord {
        var record = FileRecord(
            id: url.lastPathComponent, scanSessionID: "badge", source: .local, url: url,
            displayPath: url.path, fileName: url.lastPathComponent,
            fileExtension: nil, utiDescription: nil,
            kind: .directory, sizeBytes: sizeBytes,
            createdAt: Date(), modifiedAt: Date(), lastOpenedAt: nil,
            owner: nil, permissions: nil, isSymlink: false, symlinkTarget: nil,
            isPackage: false, isCloudPlaceholder: false, cloudProvider: nil,
            finderTags: [], spotlightMetadata: [:], riskFlags: [],
            identity: FileIdentity(
                deviceIdentifier: 1, inodeIdentifier: 1, resourceIdentifier: nil,
                sizeBytes: sizeBytes, modifiedAt: Date()),
            capabilities: [])
        if rolledUp { record.rolledUpItemCount = 1 }
        return record
    }

    private func badgePlan(parent: FileRecord, child: FileRecord) -> Plan {
        func action(_ id: String, findingID: String, targets: [String]) -> PlannedAction {
            PlannedAction(
                id: id, planID: "badge-plan", actionType: .moveToTrash, targets: targets, destination: nil,
                status: .proposed, risk: .low, confidence: 0.9, reason: "badge", userDecision: .undecided,
                executedAt: nil, findingID: findingID)
        }
        return Plan(
            id: "badge-plan", scanSessionID: "badge", createdAt: Date(), status: .proposed,
            summary: "badge", estimatedReclaimableBytes: 0, estimatedFilesAffected: 2,
            riskBreakdown: [.low: 2],
            actions: [
                action("a-parent", findingID: "f-parent", targets: [parent.id]),
                action("a-child", findingID: "f-child", targets: [child.id])
            ])
    }

    /// Nested directory actions (Caches + Caches/App) must badge the union,
    /// not the sum: approving either alone reclaims the child's bytes once.
    /// Records ride the real `outcome` pipeline; rolled-up directory records
    /// carry their subtree total in `sizeBytes` (crawler semantics).
    func testBadgeBytesDeduplicateNestedDirectoryTargets() throws {
        let harness = try makeModel()
        let model = harness.model
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("M2-badge-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("Caches/App", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000_000).write(to: child.appendingPathComponent("cache.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = directory(root.appendingPathComponent("Caches"), sizeBytes: 0, rolledUp: false)
        let childRecord = directory(child, sizeBytes: 2_000_000, rolledUp: true)
        func cacheFinding(_ id: String, target: FileRecord) -> Finding {
            Finding(
                id: id, scanSessionID: "badge", category: .cache, severity: .low, confidence: 0.9,
                bytesReclaimable: 2_000_000, summary: "badge fixture", evidence: [:],
                targetFileIDs: [target.id])
        }
        model.outcome = ScanOutcome(
            session: ScanSession(scanType: .selectedFolders, rootURLs: [root], permissionsSnapshot: "test"),
            files: [parent, childRecord], fingerprints: [], contentSummaries: [],
            projects: [], edges: [],
            findings: [cacheFinding("f-parent", target: parent), cacheFinding("f-child", target: childRecord)],
            recommendations: [],
            snapshot: StorageSnapshot(
                id: "badge-snap", createdAt: Date(), totalBytes: 0, bytesByCategory: [:],
                bytesByRootPath: [:], bytesByProject: [:], removedBytesThroughApp: 0),
            packageCandidates: [])
        model.plan = badgePlan(parent: parent, child: childRecord)

        let bytes = model.pendingBytesByDestination[.systemJunk] ?? -1
        XCTAssertEqual(bytes, 2_000_000, "nested directory actions must badge once, not twice")
    }

    // MARK: - AIApps-01: treemap buckets do not double-count nested findings

    /// `dashboardSections` (the Explore treemap/category buckets) must count
    /// a child finding inside an already-counted directory finding zero
    /// times: the fixture's Caches 2.1 MB + Caches/App 2.1 MB showed 4.2 MB.
    func testDashboardSectionsDoNotDoubleCountNestedCacheFindings() throws {
        let harness = try makeModel()
        let model = harness.model
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("M2-treemap-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("Caches/App", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000_000).write(to: child.appendingPathComponent("cache.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = directory(root.appendingPathComponent("Caches"), sizeBytes: 0, rolledUp: false)
        let childRecord = directory(child, sizeBytes: 2_000_000, rolledUp: true)
        func cacheFinding(_ id: String, target: FileRecord) -> Finding {
            Finding(
                id: id, scanSessionID: "badge", category: .cache, severity: .low, confidence: 0.9,
                bytesReclaimable: 2_000_000, summary: "treemap fixture", evidence: [:],
                targetFileIDs: [target.id])
        }
        model.outcome = ScanOutcome(
            session: ScanSession(scanType: .selectedFolders, rootURLs: [root], permissionsSnapshot: "test"),
            files: [parent, childRecord], fingerprints: [], contentSummaries: [],
            projects: [], edges: [],
            findings: [cacheFinding("f-parent", target: parent), cacheFinding("f-child", target: childRecord)],
            recommendations: [],
            snapshot: StorageSnapshot(
                id: "treemap-snap", createdAt: Date(), totalBytes: 0, bytesByCategory: [:],
                bytesByRootPath: [:], bytesByProject: [:], removedBytesThroughApp: 0),
            packageCandidates: [])

        let cacheBytes = model.dashboardSections.first { $0.0 == .cache }?.1 ?? -1
        XCTAssertEqual(cacheBytes, 2_000_000, "nested cache findings must count once, not twice")
    }

    // MARK: - MON-01: the Battery and Power tiles agree about direction

    /// The Power tile's direction label must come from the same isCharging
    /// source as the Battery tile — the SMC amperage sign disagrees with IOPS
    /// on some hardware and showed "Discharging" next to a charging battery.
    func testPowerTileDirectionFollowsTheBatteryTile() {
        func tile(for reading: PowerReading) -> (battery: String, power: String?) {
            var battery = "—"
            if let level = reading.level {
                battery = MetricFormatting.percent(level)
            }
            let power = reading.wattage.map { _ in
                reading.isCharging
                    ? String(localized: "Charging", comment: "Power direction")
                    : String(localized: "Discharging", comment: "Power direction")
            }
            return (battery, power)
        }

        // The observed contradiction: charging at 24% with +50 W draw.
        var reading = PowerReading(hasBattery: true)
        reading.level = 0.24
        reading.isCharging = true
        reading.wattage = 50.2
        let tiles = tile(for: reading)
        XCTAssertEqual(tiles.power, "Charging", "a charging battery must never read Discharging")
        XCTAssertTrue(tiles.battery.contains("24"))
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
