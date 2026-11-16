import Foundation
import XCTest
@testable import MacOSCleanerCore

/// Regression tests for the macOS core audit. Every filesystem fixture lives
/// under a temporary directory; nothing here touches the user's real files or Trash.
final class MacCoreScanTests: XCTestCase {
    /// Temporary fixture folder. Nil until setUp creates it, so tearDown never removes anything else.
    private var fixtureFolder: URL?

    private var root: URL {
        get throws { try XCTUnwrap(fixtureFolder) }
    }

    override func setUp() async throws {
        try await super.setUp()
        fixtureFolder = try TestFixtures.makeTemporaryDirectory(named: "MacCoreScan-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let fixtureFolder {
            try? FileManager.default.removeItem(at: fixtureFolder)
        }
        try await super.tearDown()
    }

    /// Crawls `root` and returns the record for `url`, so identity fields match the scan.
    private func record(for url: URL) async throws -> FileRecord {
        let fixtureRoot = try root
        let outcome = await FileCrawler().crawl(rootURLs: [fixtureRoot], sessionID: "scan")
        return try XCTUnwrap(outcome.files.first { $0.url.standardizedFileURL == url.standardizedFileURL })
    }

    private func trashAction(for record: FileRecord, risk: RiskLevel = .low) -> PlannedAction {
        PlannedAction(
            id: "trash-\(record.id)", planID: "plan", actionType: .moveToTrash, targets: [record.id],
            destination: nil, status: .approved, risk: risk, confidence: 0.9, reason: "test",
            userDecision: .approved, executedAt: nil, findingID: nil
        )
    }

    // MARK: - Folder targets must not carry protected descendants

    func testAuditRejectsFolderContainingProtectedKeyFile() async throws {
        let folder = try root.appendingPathComponent("cache", isDirectory: true)
        let keys = folder.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try Data("PRIVATE".utf8).write(to: keys.appendingPathComponent("id_rsa"))
        let folderRecord = try await record(for: folder)
        XCTAssertEqual(folderRecord.kind, .directory)

        do {
            _ = try await SafetyAuditor().audit(
                action: trashAction(for: folderRecord), filesByID: [folderRecord.id: folderRecord]
            )
            XCTFail("A folder that holds a private key must not be trashed")
        } catch SafetyAuditError.unsafePath(let url, _) {
            XCTAssertEqual(url.lastPathComponent, "cache")
        }
    }

    func testAuditAllowsFolderWithOnlySourceAndManifestFiles() async throws {
        let project = try root.appendingPathComponent("build-output", isDirectory: true)
        let sources = project.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("print(1)".utf8).write(to: sources.appendingPathComponent("main.swift"))
        let folderRecord = try await record(for: project)

        let result = try await SafetyAuditor().audit(
            action: trashAction(for: folderRecord), filesByID: [folderRecord.id: folderRecord]
        )
        XCTAssertEqual(result.decision, .allowed)
    }

    // MARK: - Natural-language commands keep inspect-only findings inspect-only

    func testDeleteCommandKeepsInspectOnlyActionUnchanged() async throws {
        let inspect = TestFixtures.makeRecommendation(
            id: "inspect", targetID: "f-inspect", action: .inspectOnly, risk: .low, confidence: 0.86)
        let tag = TestFixtures.makeRecommendation(
            id: "tag", targetID: "f-tag", action: .tag, risk: .low, confidence: 0.86)
        let files = [
            "f-inspect": TestFixtures.makeFileRecord(id: "f-inspect", path: "/tmp/tidybyte-test/inspect.log", sizeBytes: 1),
            "f-tag": TestFixtures.makeFileRecord(id: "f-tag", path: "/tmp/tidybyte-test/tag.txt", sizeBytes: 1)
        ]
        let planner = PlannerAgent()
        let plan = await planner.makePlan(sessionID: "s", recommendations: [inspect, tag], filesByID: files)

        let updated = await planner.plan(for: PlanIntent(action: .delete), existingPlan: plan, filesByID: files)

        let typeByTarget = Dictionary(uniqueKeysWithValues: updated.actions.map { ($0.targets.first ?? "", $0.actionType) })
        XCTAssertEqual(typeByTarget["f-inspect"], .inspectOnly, "A delete command must not turn inspect-only findings into trash moves")
        XCTAssertEqual(typeByTarget["f-tag"], .moveToTrash)
    }

    func testOrganizeCommandDoesNotMoveInspectOnlyFindings() async throws {
        let inspect = TestFixtures.makeRecommendation(
            id: "inspect", targetID: "f-inspect", action: .inspectOnly, risk: .low, confidence: 0.86)
        let files = [
            "f-inspect": TestFixtures.makeFileRecord(id: "f-inspect", path: "/tmp/tidybyte-test/app-data/state.db", sizeBytes: 1)
        ]
        let planner = PlannerAgent()
        let plan = await planner.makePlan(sessionID: "s", recommendations: [inspect], filesByID: files)

        let updated = await planner.plan(for: PlanIntent(action: .organize), existingPlan: plan, filesByID: files)

        XCTAssertFalse(updated.actions.contains { $0.actionType == .move }, "An organize command must not move inspect-only data")
    }

    // MARK: - Database export never overwrites the live database

    func testExportRefusesToOverwriteLiveDatabase() async throws {
        let live = try root.appendingPathComponent("live.sqlite")
        let store = try SQLiteStore(databaseURL: live)
        do {
            try await store.exportCopy(to: live)
            XCTFail("Exporting over the live database must be refused")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "The live database must survive a refused export")
    }

    func testExportReplacesAnExistingCopy() async throws {
        let folder = try root
        let store = try SQLiteStore(databaseURL: folder.appendingPathComponent("live.sqlite"))
        let copy = folder.appendingPathComponent("export.sqlite")
        try Data("old".utf8).write(to: copy)

        try await store.exportCopy(to: copy)

        let size = try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 3, "The old export must be replaced by a database file")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".partial") }
        XCTAssertEqual(leftovers, [], "No staging file may remain after a successful export")
    }

    // MARK: - Child processes are bounded even when they ignore SIGTERM

    func testProcessRunnerKillsChildThatIgnoresTerminate() async {
        let started = Date()
        // "exec" keeps one process; the ignored TERM disposition survives exec.
        let result = await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec sleep 30"], timeout: 1
        )
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "The runner must return after the SIGKILL fallback")
    }

    // MARK: - Trash emptying removes nested items and leaves the Trash folder

    func testEmptyTrashRemovesNestedItemsAndKeepsFolder() throws {
        let trash = try root.appendingPathComponent(".Trash", isDirectory: true)
        let nested = trash.appendingPathComponent("folder/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: nested.appendingPathComponent("file.txt"))
        try Data("b".utf8).write(to: trash.appendingPathComponent("top.txt"))

        let removed = try TrashBin.empty(trashURL: trash)

        XCTAssertEqual(removed, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
    }
}
