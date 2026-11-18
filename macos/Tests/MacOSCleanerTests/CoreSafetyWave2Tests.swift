import Foundation
@testable import MacOSCleanerCore
import SQLite3
import XCTest

private class Wave2MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class SQLiteStoreWave2Tests: XCTestCase {
    private func seedV6Database(at url: URL) throws {
        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, openFlags, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let session = ScanSession(
            id: "s1", startedAt: Date(), scanType: .selectedFolders,
            rootURLs: [], permissionsSnapshot: "test", status: .completed
        )
        let record = TestFixtures.makeFileRecord(id: "stable-1", path: "/Users/test/demo/a.txt", sizeBytes: 42)
        let fingerprint = FileFingerprint(
            fileID: "stable-1", sizeBytes: 42, quickHash: "qh", fullHash: "fh",
            imagePerceptualHash: nil, videoKeyframeHashes: [], hashStatus: .fullHashConfirmed
        )
        let sessionJSON = String(data: try encoder.encode(session), encoding: .utf8) ?? "{}"
        let fileJSON = String(data: try encoder.encode(record), encoding: .utf8) ?? "{}"
        let fpJSON = String(data: try encoder.encode(fingerprint), encoding: .utf8) ?? "{}"

        let tables = [
            "scan_sessions", "volumes", "fingerprints", "content_summaries", "projects",
            "relationship_edges", "findings", "recommendations", "plans", "planned_actions",
            "operation_logs", "memory_rules", "regret_events", "storage_snapshots",
            "file_hashes", "cleanup_state", "cleanup_activity", "cleanup_snapshots"
        ]
        for table in tables {
            let sql = """
            CREATE TABLE \(table) \
            (id TEXT PRIMARY KEY NOT NULL, scan_session_id TEXT, created_at REAL NOT NULL, json TEXT NOT NULL);
            """
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
        let extraSQL = """
        CREATE TABLE file_records \
        (id TEXT PRIMARY KEY NOT NULL, scan_session_id TEXT, created_at REAL NOT NULL, json TEXT NOT NULL, file_path TEXT);
        CREATE TABLE undo_records \
        (id TEXT PRIMARY KEY NOT NULL, scan_session_id TEXT, created_at REAL NOT NULL, json TEXT NOT NULL, \
        operation_log_id TEXT, status TEXT);
        INSERT INTO scan_sessions VALUES ('s1', 's1', 100, '\(sessionJSON)');
        INSERT INTO file_records VALUES ('stable-1', 's1', 100, '\(fileJSON)', 'file:///Users/test/demo/a.txt');
        INSERT INTO fingerprints VALUES ('stable-1', NULL, 100, '\(fpJSON)');
        PRAGMA user_version = 6;
        """
        XCTAssertEqual(sqlite3_exec(handle, extraSQL, nil, nil, nil), SQLITE_OK)
    }

    func testV7MigrationRepairsFileURLsAndScopesCompositeIDsAcrossSessions() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "SQLiteV7-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("legacy.sqlite")
        try seedV6Database(at: dbURL)

        let store = try SQLiteStore(databaseURL: dbURL)
        let repaired = try await store.loadFileRecords(matchingPrefix: "/Users/test/demo")
        XCTAssertEqual(repaired.map(\.id), ["stable-1"])
        let legacyFPs = try await store.loadFingerprints(forSession: "s1")
        XCTAssertEqual(legacyFPs.map(\.fileID), ["stable-1"])

        let s2 = ScanSession(
            id: "s2", startedAt: Date(), scanType: .selectedFolders,
            rootURLs: [], permissionsSnapshot: "test", status: .completed
        )
        try await store.saveScanSession(s2)
        var s2File = TestFixtures.makeFileRecord(id: "stable-1", path: "/Users/test/demo/a.txt", sizeBytes: 99)
        s2File.scanSessionID = "s2"
        try await store.saveFileRecords([s2File])
        let s2FP = FileFingerprint(
            fileID: "stable-1", sizeBytes: 99, quickHash: "q2", fullHash: "f2",
            imagePerceptualHash: nil, videoKeyframeHashes: [], hashStatus: .fullHashConfirmed
        )
        try await store.saveFingerprints([s2FP], scanSessionID: "s2")
        let s1Finding = Finding(
            id: "f1", scanSessionID: "s1", category: .cache, severity: .low, confidence: 0.9,
            bytesReclaimable: 42, summary: "s1", evidence: [:], targetFileIDs: ["stable-1"]
        )
        let s2Finding = Finding(
            id: "f1", scanSessionID: "s2", category: .duplicate, severity: .medium, confidence: 0.9,
            bytesReclaimable: 99, summary: "s2", evidence: [:], targetFileIDs: ["stable-1"]
        )
        try await store.saveFindings([s1Finding])
        try await store.saveFindings([s2Finding])

        let s1Files = try await store.loadFileRecords(for: "s1")
        let s2Files = try await store.loadFileRecords(for: "s2")
        let s1Fps = try await store.loadFingerprints(forSession: "s1")
        let s2Fps = try await store.loadFingerprints(forSession: "s2")
        let s1Findings = try await store.loadFindings(for: "s1")
        let s2Findings = try await store.loadFindings(for: "s2")
        XCTAssertEqual(s1Files.first?.sizeBytes, 42)
        XCTAssertEqual(s2Files.first?.sizeBytes, 99)
        XCTAssertEqual(s1Fps.first?.sizeBytes, 42)
        XCTAssertEqual(s2Fps.first?.sizeBytes, 99)
        XCTAssertEqual(s1Findings.first?.summary, "s1")
        XCTAssertEqual(s2Findings.first?.summary, "s2")
    }

    func testLatestRestorableScanSessionAndRecentExecutedActions() async throws {
        let store = try SQLiteStore.inMemory()
        let root = URL(fileURLWithPath: "/Users/me")

        var oldSession = ScanSession(
            id: "populated", startedAt: Date().addingTimeInterval(-120), scanType: .selectedFolders,
            rootURLs: [root], permissionsSnapshot: "test", status: .completed
        )
        oldSession.completedAt = Date().addingTimeInterval(-60)
        try await store.saveScanSession(oldSession)
        var oldFile = TestFixtures.makeFileRecord(id: "f-old", path: "/Users/me/f.bin", sizeBytes: 10)
        oldFile.scanSessionID = "populated"
        try await store.saveFileRecords([oldFile])

        var emptyNewer = ScanSession(
            id: "empty-newer", startedAt: Date(), scanType: .selectedFolders,
            rootURLs: [root], permissionsSnapshot: "test", status: .completed
        )
        emptyNewer.completedAt = Date()
        try await store.saveScanSession(emptyNewer)

        let latestFinished = try await store.latestFinishedScanSession()
        let latestRestorable = try await store.latestRestorableScanSession()
        XCTAssertEqual(latestFinished?.id, "empty-newer")
        XCTAssertEqual(latestRestorable?.id, "populated")

        let a1 = PlannedAction(
            id: "a1", planID: "p1", actionType: .tag, targets: ["t1"], status: .completed,
            risk: .low, confidence: 0.9, reason: "old", userDecision: .approved,
            executedAt: Date(timeIntervalSince1970: 100)
        )
        let a2 = PlannedAction(
            id: "a2", planID: "p1", actionType: .move, targets: ["t2"], status: .completed,
            risk: .low, confidence: 0.9, reason: "new", userDecision: .approved,
            executedAt: Date(timeIntervalSince1970: 200)
        )
        let a3 = PlannedAction(
            id: "a3", planID: "p1", actionType: .moveToTrash, targets: ["t3"], status: .proposed,
            risk: .low, confidence: 0.9, reason: "pending", userDecision: .undecided
        )
        var plan = Plan.empty(sessionID: "populated")
        plan.id = "p1"
        plan.originalActions = [a1, a2]
        plan.actions = [a2, a3]
        try await store.savePlan(plan)

        let recent1 = try await store.loadRecentExecutedActions(limit: 1).map(\.id)
        let recent10 = try await store.loadRecentExecutedActions(limit: 10).map(\.id)
        XCTAssertEqual(recent1, ["a2"])
        XCTAssertEqual(recent10, ["a2", "a1"])
    }

    func testAtomicExportCopyAndTransactionalPurgeOldData() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "SQLiteOps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("main.sqlite")
        let store = try SQLiteStore(databaseURL: dbURL)

        var session = ScanSession(
            id: "populated", startedAt: Date().addingTimeInterval(-120), scanType: .selectedFolders,
            rootURLs: [root], permissionsSnapshot: "test", status: .completed
        )
        session.completedAt = Date()
        try await store.saveScanSession(session)
        var oldFile = TestFixtures.makeFileRecord(id: "f-old", path: "/Users/me/f.bin", sizeBytes: 10)
        oldFile.scanSessionID = "populated"
        try await store.saveFileRecords([oldFile])

        let exportURL = root.appendingPathComponent("exports/backup.sqlite")
        try await store.exportCopy(to: exportURL)
        try await store.exportCopy(to: exportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path + "-wal"))
        let exported = try SQLiteStore(databaseURL: exportURL)
        let exportedSession = try await exported.latestRestorableScanSession()
        XCTAssertEqual(exportedSession?.id, "populated")

        do {
            try await store.exportCopy(to: dbURL)
            XCTFail("Exporting over live database must fail")
        } catch DatabaseError.exportFailed {}

        let expiredUndo = UndoRecord(
            id: "exp", operationLogID: "l-exp", inverseAction: .restore,
            restoreURL: nil, trashURL: nil, validUntil: nil, status: .expired
        )
        let keptLog = OperationLog(
            id: "l-keep", plannedActionID: "a2", operationType: .move,
            beforeState: [:], afterState: [:], executorVersion: "1",
            result: "ok", error: nil, timestamp: Date()
        )
        let keptUndo = UndoRecord(
            id: "keep", operationLogID: "l-keep", inverseAction: .move,
            restoreURL: nil, trashURL: nil,
            validUntil: Date().addingTimeInterval(3600), status: .available
        )
        try await store.saveUndoRecord(expiredUndo)
        try await store.saveOperationLog(keptLog)
        try await store.saveUndoRecord(keptUndo)
        try await store.purgeOldData(keepingDays: 0)
        let remainingFiles = try await store.loadFileRecords(for: "populated")
        let remainingUndo = try await store.loadUndoRecords().map(\.id)
        let keptLogReloaded = try await store.loadOperationLog(id: "l-keep")
        XCTAssertTrue(remainingFiles.isEmpty)
        XCTAssertEqual(remainingUndo, ["keep"])
        XCTAssertNotNil(keptLogReloaded)
    }
}

final class CoreSafetyWave2Tests: XCTestCase {
    private static func readBody(of request: URLRequest) -> String {
        if let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func makeMockGateway(home: String = "/Users/alice") -> (AIGateway, KeychainStore) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Wave2MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let keychain = KeychainStore(inMemory: true)
        let gateway = AIGateway(keychain: keychain, session: session, homeDirectoryOverride: URL(fileURLWithPath: home))
        return (gateway, keychain)
    }

    func testActionExecutorPackageAllowlistAndHighRiskConfirmation() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "ExecAllow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = TestFixtures.makeExecutor(store: try SQLiteStore.inMemory())

        let badShell = PackageCleanupCandidate(
            id: "sh", title: "sh", commandPath: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo hi"], dryRunOutput: "", risk: .low, category: .packageManagerCleanup
        )
        let badArgs = PackageCleanupCandidate(
            id: "brew-bad", title: "brew", commandPath: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["install", "foo"], dryRunOutput: "", risk: .low, category: .packageManagerCleanup
        )
        let badXcrun = PackageCleanupCandidate(
            id: "xcrun-bad", title: "xcrun", commandPath: root.appendingPathComponent("xcrun"),
            arguments: ["simctl", "delete", "unavailable"], dryRunOutput: "", risk: .low, category: .developerToolCache
        )
        let traversalURL = URL(string: "file:///opt/homebrew/bin/../bin/npm") ?? root
        let traversal = PackageCleanupCandidate(
            id: "trav", title: "npm", commandPath: traversalURL,
            arguments: ["cache", "ls"], dryRunOutput: "", risk: .low, category: .packageManagerCleanup
        )
        for bad in [badShell, badArgs, badXcrun, traversal] {
            XCTAssertFalse(ActionExecutor.isAllowedPackageCommand(bad), bad.id)
        }

        let allowedNpm = try TestFileFixtures.makeStub("npm", in: root, body: "exit 0")
        let highCand = PackageCleanupCandidate(
            id: "npm-hi", title: "npm", commandPath: allowedNpm,
            arguments: ["cache", "ls"], dryRunOutput: "", risk: .high, category: .packageManagerCleanup
        )
        let unconfirmed = PlannedAction(
            id: "hi-block", planID: "p", actionType: .runPackageManagerCleanup, targets: ["npm-hi"],
            status: .approved, risk: .high, confidence: 0.9, reason: "blocked", userDecision: .approved
        )
        let blockedSummary = await executor.execute(actions: [unconfirmed], filesByID: [:], packageCandidates: [highCand])
        XCTAssertTrue(blockedSummary.logs.isEmpty)
        XCTAssertTrue(blockedSummary.failedActionIDs.contains("hi-block"))
    }

    func testActionExecutorConcurrentExecutionLock() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "ExecLock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = TestFixtures.makeExecutor(store: try SQLiteStore.inMemory())

        let started = root.appendingPathComponent("started")
        let slowNpm = try TestFileFixtures.makeStub("npm", in: root, body: "touch '\(started.path)'\nsleep 0.4")
        let slowCand = PackageCleanupCandidate(
            id: "npm-slow", title: "npm", commandPath: slowNpm,
            arguments: ["cache", "ls"], dryRunOutput: "", risk: .high, category: .packageManagerCleanup
        )
        let firstAct = PlannedAction(
            id: "first", planID: "p", actionType: .runPackageManagerCleanup, targets: ["npm-slow"],
            status: .approved, risk: .high, confidence: 0.9, reason: "first",
            userDecision: .approved, requiresExplicitConfirmation: true
        )
        let secondAct = PlannedAction(
            id: "second", planID: "p", actionType: .runPackageManagerCleanup, targets: ["npm-slow"],
            status: .approved, risk: .high, confidence: 0.9, reason: "second",
            userDecision: .approved, requiresExplicitConfirmation: true
        )
        let firstTask = Task { await executor.execute(actions: [firstAct], filesByID: [:], packageCandidates: [slowCand]) }
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let lockSummary = await executor.execute(actions: [secondAct], filesByID: [:], packageCandidates: [slowCand])
        XCTAssertTrue(lockSummary.failedActionIDs.contains("second"))
        XCTAssertTrue(lockSummary.failures.first?.contains("already running") == true)
        _ = await firstTask.value
    }

    func testActionExecutorAndUndoPreserveFinderColorLabels() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "TagsWave2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore.inMemory()
        let executor = TestFixtures.makeExecutor(store: store)

        let taggedURL = root.appendingPathComponent("note.txt")
        try Data("tagged".utf8).write(to: taggedURL)
        try FinderTagHelper.write(["Urgent\n6", "Work\n2"], to: taggedURL)
        let crawled = await FileCrawler().crawl(rootURLs: [root], sessionID: "tag-test").files
        let record = try XCTUnwrap(crawled.first { $0.url == taggedURL.standardizedFileURL })
        let tagAction = PlannedAction(
            id: "tag-1", planID: "p", actionType: .tag, targets: [record.id],
            status: .approved, risk: .low, confidence: 0.9, reason: "tag", userDecision: .approved
        )
        let tagSummary = await executor.execute(actions: [tagAction], filesByID: [record.id: record])
        let afterTags = try FinderTagHelper.read(from: taggedURL)
        XCTAssertTrue(afterTags.contains("Urgent\n6"))
        XCTAssertTrue(afterTags.contains("Work\n2"))
        XCTAssertGreaterThan(afterTags.count, 2)

        let undoSvc = UndoManagerService(store: store, memory: MemoryEngine(store: store), trash: FixtureTrash())
        _ = try await undoSvc.restore(try XCTUnwrap(tagSummary.undoRecords.first))
        XCTAssertEqual(try FinderTagHelper.read(from: taggedURL), ["Urgent\n6", "Work\n2"])
    }

    func testUndoArchiveDeferralCollisionFreeMoveAndRegretRecording() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "UndoWave2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let dest = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let origURL = root.appendingPathComponent("report.txt")
        let moveDir = root.appendingPathComponent("v1.0.build", isDirectory: true)
        try Data("orig".utf8).write(to: origURL)
        try FileManager.default.createDirectory(at: moveDir, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: moveDir.appendingPathComponent("a.bin"))

        let crawled = await FileCrawler().crawl(rootURLs: [root], sessionID: "u").files
        let origRec = try XCTUnwrap(crawled.first { $0.url == origURL.standardizedFileURL })
        let dirRec = try XCTUnwrap(crawled.first { $0.url == moveDir.standardizedFileURL })
        let store = try SQLiteStore.inMemory()
        let executor = ActionExecutor(store: store, auditor: SafetyAuditor(), trash: FixtureTrash(folder: trash))
        let undoSvc = UndoManagerService(store: store, memory: MemoryEngine(store: store), trash: FixtureTrash(folder: trash))

        let archiveAct = PlannedAction(
            id: "arch", planID: "p", actionType: .archive, targets: [origRec.id], destination: dest,
            status: .approved, risk: .medium, confidence: 0.9, reason: "arch", userDecision: .approved
        )
        let archSummary = await executor.execute(actions: [archiveAct], filesByID: [origRec.id: origRec])
        let restoreOrig = try XCTUnwrap(archSummary.undoRecords.first { $0.inverseAction == .restore })
        let trashArch = try XCTUnwrap(archSummary.undoRecords.first { $0.inverseAction == .moveToTrash })
        // Put archive-trash first so batch deferral must reorder it after original restore.
        let batchResult = await undoSvc.restoreBatchDetailed([trashArch, restoreOrig], regretReason: "Needed later")
        XCTAssertEqual(batchResult.restored.count, 2)
        XCTAssertTrue(batchResult.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: origURL.path))
        let memoryRules = try await store.loadMemoryRules()
        XCTAssertFalse(memoryRules.isEmpty)

        let moveAct = PlannedAction(
            id: "mv", planID: "p", actionType: .move, targets: [dirRec.id], destination: dest,
            status: .approved, risk: .low, confidence: 0.9, reason: "mv", userDecision: .approved
        )
        let mvSummary = await executor.execute(actions: [moveAct], filesByID: [dirRec.id: dirRec])
        try FileManager.default.createDirectory(at: moveDir, withIntermediateDirectories: true)
        _ = try await undoSvc.restore(try XCTUnwrap(mvSummary.undoRecords.first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("v1.0.build-restored-1").path))
    }

    func testRuleEngineCacheDeductionDanglingSymlinkAndLocalAICaches() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "RuleWave2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeHome = root.appendingPathComponent("Home", isDirectory: true)
        let support = fakeHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        for name in ["com.apple.spotlight", "Dock", "Zombie Craft 2000"] {
            let dir = support.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try TestFileFixtures.makeSparseFile(at: dir.appendingPathComponent("blob.bin"), logicalSize: 55_000_000)
        }
        let proj = fakeHome.appendingPathComponent("Code/App", isDirectory: true)
        try FileManager.default.createDirectory(at: proj.appendingPathComponent("node_modules/.cache"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: proj.appendingPathComponent("package.json"))
        try TestFileFixtures.makeSparseFile(at: proj.appendingPathComponent("node_modules/.cache/c.bin"), logicalSize: 2_000_000)
        try TestFileFixtures.makeSparseFile(at: proj.appendingPathComponent("node_modules/pkg.bin"), logicalSize: 3_000_000)
        try FileManager.default.createSymbolicLink(
            at: fakeHome.appendingPathComponent("broken"),
            withDestinationURL: fakeHome.appendingPathComponent("missing.txt")
        )

        let devCachePaths = [
            ".cache/huggingface", ".ollama/models", ".cargo/registry/cache",
            ".cache/uv", ".bun/install/cache", "Library/Developer/Xcode/ModuleCache.noindex"
        ]
        for rel in devCachePaths {
            let dir = fakeHome.appendingPathComponent(rel, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try TestFileFixtures.makeSparseFile(at: dir.appendingPathComponent("data.bin"), logicalSize: 2_000_000)
        }

        let outcome = await FileCrawler().crawl(rootURLs: [fakeHome], sessionID: "rw2")
        let projects = try await ProjectDetector().detectProjects(in: outcome.files)
        let engine = CleanerRuleEngine(homeDirectoryOverride: fakeHome)
        let (findings, recs) = try await engine.analyze(files: outcome.files, projects: projects, sessionID: "rw2")
        XCTAssertEqual(findings.filter { $0.category == .appLeftover }.count, 1)
        let devNode = try XCTUnwrap(findings.first {
            $0.category == .developerArtifact && $0.evidence["folder_name"] == "node_modules"
        })
        XCTAssertEqual(devNode.bytesReclaimable, 3_000_000)
        XCTAssertTrue(recs.contains { $0.policyTraceID == "dangling_symlink_rule" && $0.actionType == .inspectOnly })
        XCTAssertEqual(recs.filter { $0.policyTraceID == "local_ai_dev_cache_rule" && $0.actionType == .inspectOnly }.count, 2)
        XCTAssertEqual(recs.filter { $0.policyTraceID == "dev_cache_rule" && $0.actionType == .moveToTrash }.count, 4)
    }

    func testAIGatewayLoopbackHTTPFenceStripAndRedaction() async throws {
        let (gateway, _) = makeMockGateway()
        var capturedBody = ""
        var capturedAuth: String?
        Wave2MockURLProtocol.requestCount = 0
        Wave2MockURLProtocol.handler = { req in
            capturedBody = Self.readBody(of: req)
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            let fenced = """
            ```json
            {"recommendations":[{"category":"cache","action":"moveToTrash","targetFileID":"f1",
            "confidence":0.9,"risk":"low","reason":"ok"}]}
            ```
            """
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": fenced]]]])
            let url = req.url ?? URL(fileURLWithPath: "/")
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse()
            return (data, resp)
        }

        let localURL = try XCTUnwrap(URL(string: "http://localhost:11434/v1"))
        let localSettings = ProviderSettings(providerName: "Ollama", apiBaseURL: localURL, textModel: "llama3", privacyMode: .snippetsAI)
        let file = TestFixtures.makeFileRecord(id: "f1", path: "/Users/alice/Caches/app.bin", sizeBytes: 100)
        let finding = Finding(
            id: "fn1", scanSessionID: "s", category: .cache, severity: .low, confidence: 0.9,
            bytesReclaimable: 100, summary: "Path /Users/bob/secret", evidence: [:], targetFileIDs: ["f1"]
        )
        let secretSummary = ContentSummary(
            fileID: "f1", textPreview: "SECRET_TOKEN_XYZ", ocrText: nil, language: "en",
            detectedTopics: ["possible_secret"], imageLabels: [], videoLabels: [], privacyLevel: .snippetsAI
        )

        let recs = try await gateway.classify(
            findings: [finding], filesByID: ["f1": file],
            settings: localSettings, contentSummaries: [secretSummary]
        )
        XCTAssertEqual(recs.count, 1)
        XCTAssertNil(capturedAuth)
        XCTAssertFalse(capturedBody.contains("alice"))
        XCTAssertFalse(capturedBody.contains("bob"))
        XCTAssertFalse(capturedBody.contains("SECRET_TOKEN_XYZ"))
    }

    func testAIGatewayRejectsInsecureRemoteAndRedactsErrorKey() async throws {
        let (gateway, keychain) = makeMockGateway()
        try await keychain.saveAPIKey("sk-secret-value", account: "Remote")
        let badURL = try XCTUnwrap(URL(string: "http://example.com/v1"))
        let insecure = ProviderSettings(providerName: "Remote", apiBaseURL: badURL, textModel: "m", privacyMode: .metadataOnlyAI)

        Wave2MockURLProtocol.requestCount = 0
        do {
            _ = try await gateway.classify(findings: [], filesByID: [:], settings: insecure)
            XCTFail("Remote http:// must be rejected")
        } catch AIGatewayError.insecureEndpoint {
            XCTAssertEqual(Wave2MockURLProtocol.requestCount, 0)
        }

        Wave2MockURLProtocol.handler = { req in
            let url = req.url ?? URL(fileURLWithPath: "/")
            let resp = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse()
            return (Data("bad key sk-secret-value".utf8), resp)
        }
        let tlsURL = try XCTUnwrap(URL(string: "https://api.example.com/v1"))
        let tlsSettings = ProviderSettings(providerName: "Remote", apiBaseURL: tlsURL, textModel: "m", privacyMode: .metadataOnlyAI)
        do {
            _ = try await gateway.classify(findings: [], filesByID: [:], settings: tlsSettings)
            XCTFail("Expected invalidResponse")
        } catch AIGatewayError.invalidResponse(_, let body) {
            XCTAssertFalse(body.contains("sk-secret-value"))
            XCTAssertTrue(body.contains("[redacted]"))
        }
    }
}
