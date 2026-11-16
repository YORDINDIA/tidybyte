import AppKit
import Foundation
import SwiftUI
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore
import XCTest

/// Regression tests for the mac-app audit fixes (confirmation split, regret
/// titles). These never execute an action: they test the pure selection helper.
@MainActor
final class MacAppScanTests: XCTestCase {
    private func action(id: String, type: ActionType) -> PlannedAction {
        PlannedAction(
            id: id, planID: "plan", actionType: type, targets: type == .runPackageManagerCleanup ? [] : ["file-\(id)"],
            destination: nil, status: .approved, risk: .low, confidence: 0.9,
            reason: "fixture", userDecision: .approved, executedAt: nil, findingID: nil
        )
    }

    func testFileStepExcludesPackageCommands() {
        let actions = [
            action(id: "trash-1", type: .moveToTrash),
            action(id: "pkg-1", type: .runPackageManagerCleanup),
            action(id: "move-1", type: .move)
        ]
        let ids = AppViewModel.confirmedActionIDs(in: actions, packageCommandsOnly: false)
        XCTAssertEqual(ids, ["trash-1", "move-1"],
                       "The main confirm button must never run package-manager commands")
    }

    func testPackageStepRunsOnlyPackageCommands() {
        let actions = [
            action(id: "trash-1", type: .moveToTrash),
            action(id: "pkg-1", type: .runPackageManagerCleanup)
        ]
        let ids = AppViewModel.confirmedActionIDs(in: actions, packageCommandsOnly: true)
        XCTAssertEqual(ids, ["pkg-1"])
    }

    func testPackageStepIsEmptyWithoutPackageCommands() {
        let actions = [action(id: "trash-1", type: .moveToTrash)]
        XCTAssertTrue(AppViewModel.confirmedActionIDs(in: actions, packageCommandsOnly: true).isEmpty)
    }

    func testRegretReasonRawValuesStayEnglishAndEveryReasonHasATitle() {
        // The raw value is stored with the regret event, so it must not change.
        XCTAssertEqual(
            AppViewModel.RegretReason.allCases.map(\.rawValue),
            ["Needed later", "Misclassified", "Should have archived, not deleted", "Wrong project", "Too aggressive"])
        for reason in AppViewModel.RegretReason.allCases {
            XCTAssertFalse(reason.title.isEmpty)
        }
    }

    // MARK: - Round 2: persistence (MAC-02 to MAC-04), NL refusal, loading flag, row render (MAC-19)

    private struct Timeout: Error {}

    private func makeModel() throws -> (model: AppViewModel, store: SQLiteStore) {
        let store = try SQLiteStore.inMemory()
        let memory = MemoryEngine(store: store)
        let model = AppViewModel(
            store: store, keychain: KeychainStore(inMemory: true), memory: memory,
            orchestrator: ScanOrchestrator(store: store, memory: memory),
            executor: TestFixtures.makeExecutor(store: store),
            undoService: UndoManagerService(store: store, memory: memory),
            reportGenerator: ReportGenerator(store: store), notifications: NotificationScheduler(),
            planner: PlannerAgent(), defaults: makeIsolatedDefaults())
        return (model, store)
    }

    /// Scans a two-file folder for real, so the model has a plan and file records.
    private func scanFixture(_ model: AppViewModel) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAppScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture-one".utf8).write(to: root.appendingPathComponent("one.txt"))
        try Data("fixture-two".utf8).write(to: root.appendingPathComponent("two.txt"))
        model.selectedMode = .selectedFolders
        model.selectedFolders = [root]
        model.runScan()
        try await waitUntil { model.plan != nil && !model.isScanning }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The plan as the store holds it after the 500 ms debounced save.
    private func persistedPlan(_ store: SQLiteStore, _ model: AppViewModel) async throws -> Plan? {
        try await Task.sleep(nanoseconds: 900_000_000)
        return try await store.latestPlan(for: try XCTUnwrap(model.plan).scanSessionID)
    }

    func testStagingFromExploreIsPersisted() async throws {
        let (model, store) = try makeModel()
        try await scanFixture(model)
        let record = try XCTUnwrap(model.outcome?.files.first { $0.kind == .regularFile })
        let staged = try XCTUnwrap(model.stageExploreRecordForCleanup(record))
        let saved = try await persistedPlan(store, model)
        XCTAssertTrue(saved?.actions.contains { $0.id == staged.id } == true,
                      "A staged action must reach the store, not only memory")
    }

    func testUnstagingFromExploreIsPersisted() async throws {
        let (model, store) = try makeModel()
        try await scanFixture(model)
        let record = try XCTUnwrap(model.outcome?.files.first { $0.kind == .regularFile })
        let staged = try XCTUnwrap(model.stageExploreRecordForCleanup(record))
        _ = try await persistedPlan(store, model)
        model.unstageExploreAction(matching: record)
        let saved = try await persistedPlan(store, model)
        XCTAssertFalse(saved?.actions.contains { $0.id == staged.id } == true,
                       "A removed staged action must not come back after relaunch")
    }

    func testNaturalLanguageRefusalSurfacesAnErrorInTheSheet() async throws {
        let (model, _) = try makeModel()
        try await scanFixture(model)
        model.isScanning = true
        defer { model.isScanning = false }
        model.naturalLanguageCommand = "duplicate files"
        let applied = await model.applyNaturalLanguageCommand()
        XCTAssertFalse(applied)
        XCTAssertNotNil(model.errorMessage, "The Ask Tidybyte sheet shows errorMessage, so a refusal must set it")
    }

    func testNaturalLanguagePlanIsPersisted() async throws {
        let (model, store) = try makeModel()
        try await scanFixture(model)
        model.naturalLanguageCommand = "safe caches"
        let applied = await model.applyNaturalLanguageCommand()
        XCTAssertTrue(applied)
        let saved = try await persistedPlan(store, model)
        XCTAssertEqual(saved?.actions.map(\.id), model.plan?.actions.map(\.id))
    }

    func testStorageTimelineClearsItsLoadingFlag() async throws {
        let (model, _) = try makeModel()
        await model.loadStorageTimeline()
        XCTAssertFalse(model.isLoadingTimeline, "The Changes tab must not stay in its loading state")
    }

    /// Renders one action row in an offscreen window. Only the decision differs
    /// between the two rows, so any pixel difference comes from the decision state.
    @MainActor
    private func renderRow(decision: UserDecision) throws -> Data {
        let (model, _) = try makeModel()
        let action = PlannedAction(
            id: "row-\(decision.rawValue)", planID: "render", actionType: .moveToTrash, targets: [],
            destination: nil, status: .proposed, risk: .low, confidence: 0.9,
            reason: "Remove old build cache", userDecision: decision, executedAt: nil, findingID: nil)
        let size = CGSize(width: 520, height: 110)
        let host = NSHostingView(rootView: ActionRow(model: model, action: action)
            .padding(12)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    @MainActor
    func testActiveDecisionChangesTheRowAppearance() throws {
        let approved = try renderRow(decision: .approved)
        let undecided = try renderRow(decision: .undecided)
        let folder = FileManager.default.temporaryDirectory
        try approved.write(to: folder.appendingPathComponent("mac-app-row-approved.png"))
        try undecided.write(to: folder.appendingPathComponent("mac-app-row-undecided.png"))
        print("MAC-19 row renders written to \(folder.path)")
        XCTAssertNotEqual(approved, undecided, "The approved row must look different from an undecided row")
    }

    /// MAC-29: a Photos & Media setting persists when changed through the model.
    /// No view is involved, so the save cannot depend on a view staying on screen.
    func testPhotosSettingChangePersistsFromTheModel() async throws {
        let (model, store) = try makeModel()
        model.cleanup.settings.blurSensitivity = 2
        try await Task.sleep(nanoseconds: 300_000_000)
        let stored = try await store.loadCleanupState(CleanupSettings.self, key: "settings")
        XCTAssertEqual(stored?.blurSensitivity, 2)
    }

    /// Loading stored settings must not write them back: the store is the source, not a copy to save.
    func testLoadingStoredSettingsDoesNotRewriteThem() async throws {
        let (model, store) = try makeModel()
        var stored = CleanupSettings()
        stored.blurSensitivity = 1
        try await store.saveCleanupState(stored, key: "settings")
        await model.cleanup.load()
        XCTAssertEqual(model.cleanup.settings.blurSensitivity, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        let reread = try await store.loadCleanupState(CleanupSettings.self, key: "settings")
        XCTAssertEqual(reread?.blurSensitivity, 1)
    }
}
