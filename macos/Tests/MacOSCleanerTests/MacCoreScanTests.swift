import Foundation
import SQLite3
import XCTest
@testable import MacOSCleanerCore
@testable import MacOSCleanerMCPLibrary

// swiftlint:disable type_body_length file_length
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

    // MARK: - Descendant rule: build folders are removable, credentials are never taken along

    private func makeFolder(_ relative: String) throws -> URL {
        let folder = try root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func decision(for folder: URL) -> PolicyDecision {
        PathSafetyPolicy().decide(target: folder, isDirectory: true, descendants: true)
    }

    func testNestedGitAndConfigInsideNodeModulesDoNotBlockTrash() throws {
        let package = try makeFolder("node_modules/left-pad")
        try FileManager.default.createDirectory(at: package.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("settings.json"))
        try Data("x".utf8).write(to: package.appendingPathComponent("config.yaml"))
        XCTAssertEqual(decision(for: try root.appendingPathComponent("node_modules", isDirectory: true)), .allow)
    }

    func testSettingsInsideBuildAndDerivedDataDoNotBlockTrash() throws {
        let build = try makeFolder("App/build")
        try Data("{}".utf8).write(to: build.appendingPathComponent("settings.json"))
        XCTAssertEqual(decision(for: build), .allow)
    }

    func testCredentialMaterialBlocksFolderTrashEverywhere() throws {
        let derived = try makeFolder("DerivedData/Build")
        try FileManager.default.createDirectory(at: derived.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        XCTAssertNotEqual(decision(for: derived), .allow, "A .ssh folder inside a build folder must block")

        let packageDir = try makeFolder("node_modules/tool")
        try Data("SECRET=1".utf8).write(to: packageDir.appendingPathComponent(".env"))
        XCTAssertNotEqual(decision(for: try root.appendingPathComponent("node_modules", isDirectory: true)), .allow,
                          "A .env file inside node_modules must block")
    }

    func testPrivateKeyHeaderBlocksButPublicCertificateDoesNot() throws {
        let build = try makeFolder("proj/dist")
        try Data("-----BEGIN CERTIFICATE-----\nAAAA\n".utf8).write(to: build.appendingPathComponent("ca.pem"))
        XCTAssertEqual(decision(for: build), .allow, "A public certificate is not a secret")

        try Data("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n".utf8).write(to: build.appendingPathComponent("server.key"))
        XCTAssertNotEqual(decision(for: build), .allow, "A PEM private key must block")
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

    // MARK: - Round 2: plain defects

    func testUndoRemovesCreatedAliasThroughTrashNotDeletion() async throws {
        let store = try SQLiteStore.inMemory()
        let trash = FixtureTrash(folder: try root.appendingPathComponent("trash", isDirectory: true))
        try FileManager.default.createDirectory(at: trash.folder, withIntermediateDirectories: true)
        let alias = try root.appendingPathComponent("made.alias")
        try Data("alias".utf8).write(to: alias)
        let identity = try XCTUnwrap(FileArtifactIdentity.capture(at: alias))
        let log = OperationLog(
            id: "log-alias", plannedActionID: "a", operationType: .createAlias, beforeState: [:],
            afterState: ["artifact_identity": try XCTUnwrap(identity.encodedString)],
            executorVersion: "t", result: "alias_created", error: nil, timestamp: Date())
        try await store.saveOperationLog(log)
        let undo = UndoRecord(
            id: "undo-alias", operationLogID: "log-alias", inverseAction: .moveToTrash,
            restoreURL: alias, trashURL: nil, validUntil: nil, status: .available)
        try await store.saveUndoRecord(undo)
        let service = UndoManagerService(store: store, memory: MemoryEngine(store: store), trash: trash)

        _ = try await service.restore(undo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.folder.appendingPathComponent("made.alias").path),
                      "The created alias must be moved to the Trash, not deleted")
    }

    func testFinderTagWriteLandsOnFileAndNotThroughASymlink() throws {
        let target = try root.appendingPathComponent("tagged.txt")
        try Data("x".utf8).write(to: target)
        try FinderTagHelper.write(["Keep"], to: target)
        let tags = try URL(fileURLWithPath: target.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertTrue(tags.contains("Keep"))

        let real = try root.appendingPathComponent("real.txt")
        try Data("y".utf8).write(to: real)
        let link = try root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try? FinderTagHelper.write(["Swapped"], to: link)
        let realTags = try URL(fileURLWithPath: real.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertFalse(realTags.contains("Swapped"), "A tag write through a symlink must not reach its target")
    }

    func testCrawlCountsUnreadableSubfolderAsError() async throws {
        let locked = try root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("inside.txt"))
        let clean = try root.appendingPathComponent("open", isDirectory: true)
        try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let fixtureRoot = try root
        let outcome = await FileCrawler().crawl(rootURLs: [fixtureRoot], sessionID: "scan")

        XCTAssertGreaterThan(outcome.errors, 0, "An unreadable subfolder must count toward the scan errors")
    }

    func testRuleEngineDoesNotTreatUserLogsFolderAsLogFiles() async throws {
        let documents = try root.appendingPathComponent("Documents/Logs/report.pdf")
        let systemLog = try root.appendingPathComponent("Library/Logs/app.txt")
        let files = [
            TestFixtures.makeFileRecord(id: "doc", path: documents.path, sizeBytes: 2_000_000),
            TestFixtures.makeFileRecord(id: "sys", path: systemLog.path, sizeBytes: 2_000_000)
        ]
        let (findings, _) = try await CleanerRuleEngine().analyze(files: files, projects: [], sessionID: "s")

        let logged = findings.filter { $0.category == .log }.flatMap(\.targetFileIDs)
        XCTAssertFalse(logged.contains("doc"), "A Logs folder in Documents holds user files, not logs")
        XCTAssertTrue(logged.contains("sys"), "The macOS log folder must still be reported")
    }

    func testRuleEngineReportsCoverageFolderOnlyInsideAProject() async throws {
        let coverage = try root.appendingPathComponent("Taxes/coverage/report.bin")
        let files = [TestFixtures.makeFileRecord(id: "cov", path: coverage.path, sizeBytes: 2_000_000)]
        let (findings, _) = try await CleanerRuleEngine().analyze(files: files, projects: [], sessionID: "s")
        XCTAssertFalse(findings.flatMap(\.targetFileIDs).contains("cov"),
                       "coverage is project-bound, so a personal folder of that name is not a candidate")
    }

    func testExtractorNeverReadsCredentialNamedFiles() async throws {
        let secret = try root.appendingPathComponent("passwords.txt")
        try Data("hunter2-secret".utf8).write(to: secret)
        let record = TestFixtures.makeFileRecord(id: "pw", path: secret.path, sizeBytes: 14)

        let summaries = await ContentExtractor().summarize(files: [record], privacyMode: .snippetsAI)

        XCTAssertNil(summaries.first?.textPreview, "A credential-named file must not reach the AI payload")
    }

    func testExtractorRejectsBinaryTextAndKeepsPlainText() async throws {
        let binary = try root.appendingPathComponent("blob.txt")
        try Data("abc\u{0}def".utf8).write(to: binary)
        let plain = try root.appendingPathComponent("note.txt")
        try Data("hello world".utf8).write(to: plain)
        let files = [
            TestFixtures.makeFileRecord(id: "bin", path: binary.path, sizeBytes: 7),
            TestFixtures.makeFileRecord(id: "txt", path: plain.path, sizeBytes: 11)
        ]

        let summaries = await ContentExtractor().summarize(files: files, privacyMode: .snippetsAI)

        XCTAssertNil(summaries.first { $0.fileID == "bin" }?.textPreview, "NUL bytes must not become a text preview")
        XCTAssertEqual(summaries.first { $0.fileID == "txt" }?.textPreview, "hello world")
    }

    func testAIErrorBodyNeverEchoesTheAPIKey() async throws {
        let keychain = KeychainStore(inMemory: true)
        try await keychain.saveAPIKey("sk-round2-secret", account: "OpenAI-compatible")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let gateway = AIGateway(keychain: keychain, session: URLSession(configuration: config))
        MockURLProtocol.mockResponse = { _ in
            (Data("Invalid key sk-round2-secret".utf8),
             HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 401,
                             httpVersion: nil, headerFields: nil)!)
        }
        defer { MockURLProtocol.mockResponse = nil }

        do {
            _ = try await gateway.classify(findings: [], filesByID: [:], settings: ProviderSettings(privacyMode: .metadataOnlyAI))
            XCTFail("A 401 must fail")
        } catch AIGatewayError.invalidResponse(_, let body) {
            XCTAssertFalse(body.contains("sk-round2-secret"))
            XCTAssertTrue(body.contains("[redacted]"))
        }
        try? await keychain.deleteAPIKey(account: "OpenAI-compatible")
    }

    func testAIRetriesRequestTimeoutWithout408AsPermanent() async throws {
        let keychain = KeychainStore(inMemory: true)
        try await keychain.saveAPIKey("sk-round2-timeout", account: "OpenAI-compatible")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let gateway = AIGateway(keychain: keychain, session: URLSession(configuration: config))
        MockURLProtocol.requestCount = 0
        let envelope = Data(#"{"choices":[{"message":{"content":"{\"recommendations\":[]}"}}]}"#.utf8)
        MockURLProtocol.mockResponse = { _ in
            MockURLProtocol.requestCount += 1
            let status = MockURLProtocol.requestCount == 1 ? 408 : 200
            return (status == 200 ? envelope : Data("timeout".utf8),
                    HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!)
        }
        defer { MockURLProtocol.mockResponse = nil }

        let settings = ProviderSettings(privacyMode: .metadataOnlyAI)
        let recommendations = try await gateway.classify(findings: [], filesByID: [:], settings: settings)

        XCTAssertTrue(recommendations.isEmpty)
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "408 is a transient timeout and must be retried")
        try? await keychain.deleteAPIKey(account: "OpenAI-compatible")
    }

    func testMemoryNeverRuleStopsPackageCleanupAction() async throws {
        let store = try SQLiteStore.inMemory()
        let rule = MemoryRule(
            id: "never-packages", scopeType: "global", scopeValue: "", rule: "Never suggest package cleanup",
            source: "test", confidence: 0.9, createdAt: Date(), lastReinforcedAt: nil, ruleType: .never)
        try await store.saveMemoryRule(rule)
        let engine = MemoryEngine(store: store)
        let recommendation = TestFixtures.makeRecommendation(
            id: "pkg", targetID: "pkg-target", action: .runPackageManagerCleanup, risk: .low)

        let adjusted = try await engine.applyMemory(
            to: [recommendation],
            filesByID: ["pkg-target": TestFixtures.makeFileRecord(id: "pkg-target", path: "/tmp/tidybyte-test/x", sizeBytes: 1)])

        XCTAssertEqual(adjusted.first?.actionType, .inspectOnly)
    }

    func testReviewVerifyRefusesSecretsAndConfigButAllowsMedia() throws {
        let config = try root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: config)
        let movie = try root.appendingPathComponent("clip.mov")
        try Data("m".utf8).write(to: movie)
        func item(_ url: URL) throws -> ReviewItem {
            var item = ReviewItem(id: url.path, source: .file(url), name: url.lastPathComponent, kind: .video, bytes: 1)
            item.root = try root
            item.identity = try ReviewSafety.identity(at: url)
            return item
        }

        XCTAssertThrowsError(try ReviewSafety.verify(item(config)), "settings.json is protected config")
        XCTAssertNoThrow(try ReviewSafety.verify(item(movie)))
    }

    func testFullDiskAccessClosedContainerMatchesDescendants() {
        let closed: Set<String> = ["/Users/x/Library/Containers"]
        XCTAssertTrue(FullDiskAccess.isClosed("/Users/x/Library/Containers", in: closed))
        XCTAssertTrue(FullDiskAccess.isClosed("/Users/x/Library/Containers/com.docker.docker/Data", in: closed))
        XCTAssertFalse(FullDiskAccess.isClosed("/Users/x/Library/ContainersOld", in: closed))
    }

    func testReviewPhotoMoveDeletesNothingWhenExportIsIncomplete() async throws {
        let store = try SQLiteStore.inMemory()
        let photos = RecordingPhotoService()
        let folder = try root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = ReviewItem(id: "photo-1", source: .photos("photo-1"), name: "IMG_1", kind: .image, bytes: 10)
        let executor = ReviewExecutor(store: store, access: FolderAccess(store: store), photos: photos, trash: FixtureTrash())

        let event = await executor.apply(
            ReviewDecision(item: item, choice: .move, destination: folder), tool: .formatPairs, operationID: "photo-op")

        XCTAssertEqual(photos.exportCalls, 1)
        XCTAssertEqual(photos.deleteCalls, 0, "The Photos original must survive an incomplete export")
        XCTAssertNotEqual(event.state, .complete)
    }

    // MARK: - JSON payloads: missing values are null, integers keep their type

    func testJSONSanitizingMapsNilAndNonFiniteToNullAndKeepsIntegers() throws {
        let payload: [String: Any] = [
            "missing": Optional<Int>.none as Any,
            "nan": Float.nan,
            "inf": Double.infinity,
            "small": Int32(7),
            "count": UInt64(9),
            "ok": 1.5
        ]

        let sanitized = try XCTUnwrap(JSONSanitizing.sanitized(payload) as? [String: Any])

        XCTAssertTrue(sanitized["missing"] is NSNull)
        XCTAssertTrue(sanitized["nan"] is NSNull)
        XCTAssertTrue(sanitized["inf"] is NSNull)
        XCTAssertEqual(sanitized["small"] as? Int32, 7)
        XCTAssertEqual(sanitized["count"] as? UInt64, 9)
        XCTAssertEqual(sanitized["ok"] as? Double, 1.5)
        let data = try XCTUnwrap(JSONSanitizing.data(payload, options: [.sortedKeys]))
        XCTAssertTrue((String(bytes: data, encoding: .utf8) ?? "").contains("\"missing\":null"))
    }

    func testCalibrationPreferenceKeepsTheExplicitRuleType() async throws {
        let store = try SQLiteStore.inMemory()
        let memory = MemoryEngine(store: store)
        let text = "Prefer archiving files instead of moving to trash."

        try await memory.applyCalibrationPreference(text, ruleType: .preferArchive)

        let stored = try await store.loadMemoryRules().first { $0.rule == text }
        XCTAssertEqual(stored?.ruleType, .preferArchive, "The explicit type must be stored, not inferred from the text")
        XCTAssertEqual(stored?.scopeType, "global")
    }

    // MARK: - Round 2: store, scan sessions, formatting, paths, process output

    func testHashCacheMissesWhenInodeOrChangeTimeDiffers() async throws {
        let store = try SQLiteStore.inMemory()
        let changed = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.saveFileHashes([
            FileHashCacheEntry(path: "/tmp/tidybyte-test/a.bin", sizeBytes: 10, modifiedAt: changed,
                               fullHash: "abc", inode: 7, changedAt: changed)
        ])

        let hit = try await store.cachedFullHash(forPath: "/tmp/tidybyte-test/a.bin", sizeBytes: 10,
                                                 modifiedAt: changed, inode: 7, changedAt: changed)
        let replacedFile = try await store.cachedFullHash(forPath: "/tmp/tidybyte-test/a.bin", sizeBytes: 10,
                                                          modifiedAt: changed, inode: 8, changedAt: changed)
        let restoredMtime = try await store.cachedFullHash(forPath: "/tmp/tidybyte-test/a.bin", sizeBytes: 10,
                                                           modifiedAt: changed, inode: 7,
                                                           changedAt: changed.addingTimeInterval(60))

        XCTAssertEqual(hit, "abc")
        XCTAssertNil(replacedFile, "A different inode at the same path must not reuse the hash")
        XCTAssertNil(restoredMtime, "A status change with the mtime restored must not reuse the hash")
    }

    func testRunningSessionKeepsALiveOwnerAndRetiresADeadOne() async throws {
        let store = try SQLiteStore.inMemory()
        let old = Date(timeIntervalSinceNow: -3_600)
        var live = ScanSession(id: "live-owner", startedAt: old, scanType: .homeFolder, rootURLs: [],
                               permissionsSnapshot: "", status: .running)
        live.ownerProcessID = getpid()
        var dead = ScanSession(id: "dead-owner", startedAt: old, scanType: .homeFolder, rootURLs: [],
                               permissionsSnapshot: "", status: .running)
        dead.ownerProcessID = Int32.max
        try await store.saveScanSession(live)
        try await store.saveScanSession(dead)

        let retired = try await store.failStaleRunningSessions(olderThan: Date())

        XCTAssertEqual(retired, 1)
        // The live row is still running: the retirement must leave it alone. Its
        // status is read back by re-saving nothing and checking the count only.
        let liveAfter = try await store.failStaleRunningSessions(olderThan: Date())
        XCTAssertEqual(liveAfter, 0, "A second pass must not retire the live scan")
    }

    func testLatestFinishedSessionIgnoresCancelledRuns() async throws {
        let store = try SQLiteStore.inMemory()
        try await store.saveScanSession(ScanSession(id: "done", startedAt: Date(timeIntervalSinceNow: -600),
                                                    scanType: .homeFolder, rootURLs: [], permissionsSnapshot: "",
                                                    status: .completed))
        try await store.saveScanSession(ScanSession(id: "stopped", startedAt: Date(timeIntervalSinceNow: -60),
                                                    scanType: .homeFolder, rootURLs: [], permissionsSnapshot: "",
                                                    status: .cancelled))

        let latest = try await store.latestFinishedScanSession()

        XCTAssertEqual(latest?.id, "done", "A stopped scan with no saved rows must not hide the last completed scan")
    }

    func testStoreRefusesDatabaseFromNewerSchema() throws {
        let file = try root.appendingPathComponent("future.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version = 99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        XCTAssertThrowsError(try SQLiteStore(databaseURL: file))
    }

    func testProcessOutputWithInvalidUTF8KeepsReadableText() async {
        let result = await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'ok \\377 done'"], timeout: 5
        )
        XCTAssertTrue(result.stdout.contains("ok"))
        XCTAssertTrue(result.stdout.contains("done"), "Non-UTF-8 bytes must not blank the whole output")
    }

    func testSortedPathUpperBoundHandlesTheSurrogateGap() {
        let paths = ["\u{D7FF}x", "\u{E000}y"]
        XCTAssertEqual(SortedPathSearch.upperBound(paths, "\u{D7FF}"), 1)
    }

    func testFormattersNeverTrapOnNonFiniteValues() {
        XCTAssertEqual(Double.nan.formattedByteRate, "0 bytes/s")
        XCTAssertEqual(Double.infinity.formattedByteRate, "0 bytes/s")
        XCTAssertEqual((-5.0).formattedByteRate, "0 bytes/s")
        XCTAssertEqual(TimeInterval.nan.formattedDuration, "0h 0m")
        XCTAssertEqual(TimeInterval(90 * 60).formattedDuration, "1h 30m")
    }

    func testInboxRefusesToCreateInsideProtectedFolder() async throws {
        let protected = try root.appendingPathComponent(".ssh/Inbox", isDirectory: true)
        do {
            _ = try await InboxManager().ensureInboxExists(at: protected)
            XCTFail("The inbox must not be created inside ~/.ssh")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: protected.path))
    }

    // MARK: - Round 3: packages, cache sections, snapshots, faults

    func testPackageWithCredentialInsideIsNotDescendantSafe() throws {
        let package = try makeFolder("Notes.keynote")
        try FileManager.default.createDirectory(at: package.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        XCTAssertNotEqual(PathSafetyPolicy().decide(target: package, isDirectory: false, descendants: true), .allow)
    }

    func testAppBundleWithEmbeddedProvisioningProfileIsStillRemovable() throws {
        let app = try makeFolder("Shop.app/Contents")
        try Data("profile".utf8).write(to: app.appendingPathComponent("embedded.provisionprofile"))
        XCTAssertEqual(PathSafetyPolicy().decide(target: app.deletingLastPathComponent(), isDirectory: false, descendants: true), .allow,
                       "Every App Store app carries a provisioning profile; it must not block uninstall")
    }

    func testDockerVirtualMachineFolderIsReviewOnlyAndBunIsNotASweepTarget() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let docker = home.appendingPathComponent("Library/Containers/com.docker.docker").path
        XCTAssertTrue(MoCleanScanner.isReviewOnlyRoot(docker, home: home),
                      "The Docker VM disk holds every image and volume; it is never a trash candidate")
        let developer = MoCleanScanner.SystemCleanSection.developerTools.knownPaths(home: home).map(\.path)
        XCTAssertFalse(developer.contains { $0.hasSuffix("/.bundle") }, "~/.bundle holds Bundler credentials")
    }

    func testLargeFileSettingCannotTrapTheCandidateFilter() {
        var settings = CleanupSettings()
        settings.largeMegabytes = 1e300
        let item = ReviewItem(id: "big", source: .file(URL(fileURLWithPath: "/tmp/tidybyte-test/big.mov")),
                              name: "big.mov", kind: .video, bytes: 5_000_000_000)
        let result = AnalysisResult(generation: UUID(), scopeID: "scope", settings: settings,
                                    items: [item], groups: [])
        XCTAssertEqual(MediaAnalysisService.candidates(.large, in: result).count, 0)
    }

    func testSnapshotDiffFindsAnOlderSnapshotBeyondTheNewestRows() async throws {
        let store = try SQLiteStore.inMemory()
        let oldest = StorageSnapshot(id: "oldest", createdAt: Date(timeIntervalSinceNow: -100_000), totalBytes: 1,
                                     bytesByCategory: [:], bytesByRootPath: [:], bytesByProject: [:],
                                     removedBytesThroughApp: 0)
        try await store.saveStorageSnapshot(oldest)
        for index in 0..<205 {
            try await store.saveStorageSnapshot(StorageSnapshot(
                id: "s\(index)", createdAt: Date(), totalBytes: Int64(index), bytesByCategory: [:],
                bytesByRootPath: [:], bytesByProject: [:], removedBytesThroughApp: 0))
        }
        let diff = try await SnapshotService(store: store).diffSnapshot(olderID: "oldest", newerID: "s204")
        XCTAssertEqual(diff.older.id, "oldest")
    }

    func testKeychainReadFailureIsNotReportedAsNoKey() async throws {
        let keychain = KeychainStore(inMemory: true, injectedLoadError: .unexpectedStatus(-25300))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let gateway = AIGateway(keychain: keychain, session: URLSession(configuration: config))
        do {
            _ = try await gateway.classify(findings: [], filesByID: [:], settings: ProviderSettings(privacyMode: .metadataOnlyAI))
            XCTFail("A Keychain read failure must surface")
        } catch let error as KeychainError {
            guard case .unexpectedStatus(-25300) = error else { return XCTFail("Unexpected keychain error \(error)") }
        } catch {
            XCTFail("Expected the Keychain error, got \(error)")
        }
    }

    func testFinalStatusWriteFailureKeepsTheFinishedScan() async throws {
        let store = try SQLiteStore.inMemory()
        await store.setFailingSessionStatuses([.completed])
        let orchestrator = ScanOrchestrator(store: store, memory: MemoryEngine(store: store))
        let folder = try root.appendingPathComponent("small", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))

        let (outcome, _) = try await orchestrator.scan(
            mode: .selectedFolders, selectedFolders: [folder], providerSettings: ProviderSettings(), includeAI: false)

        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertTrue(outcome.notices.contains { $0.message.contains("status could not be saved") },
                      "The user must be told the status was not saved")
    }

    // MARK: - Round 4: review fixes

    func testAgentUndoGateAllowsOnlyTheReviewedKinds() {
        let allowed: Set<ActionType> = [.restore, .move, .rename, .tag, .unfoldClone]
        for kind in ActionType.allCases {
            XCTAssertEqual(MCPKit.agentMayUndo(kind), allowed.contains(kind), "\(kind.rawValue)")
        }
        XCTAssertFalse(MCPKit.agentMayUndo(.moveToTrash), "Trash-based removal of a created artifact stays in the app")
    }

    func testCheckReportStatesWhatWasCompared() {
        let hashed = MCPKit.checkReport(total: 2, verified: 2, hashed: 2, missing: [], changed: [])
        XCTAssertTrue(hashed.contains("byte-identical to the scan"))
        XCTAssertTrue(hashed.contains("The plan is still safe to execute."))

        let identityOnly = MCPKit.checkReport(total: 2, verified: 2, hashed: nil, missing: [], changed: [])
        XCTAssertTrue(identityOnly.contains("file bytes were not compared"))
        XCTAssertFalse(identityOnly.contains("byte-identical"))

        let drifted = MCPKit.checkReport(total: 3, verified: 1, hashed: nil, missing: ["/a"], changed: ["/b"])
        XCTAssertTrue(drifted.contains("Missing since the scan: /a"))
        XCTAssertTrue(drifted.contains("Changed since the scan"))
        XCTAssertTrue(drifted.contains("Re-scan before executing"))
        XCTAssertFalse(drifted.contains("still safe"))
    }

    func testTypedArgumentHelpersRejectWrongTypes() throws {
        XCTAssertNil(try MCPKit.stringArgument([:], "k"))
        XCTAssertEqual(try MCPKit.stringArgument(["k": "v"], "k"), "v")
        XCTAssertThrowsError(try MCPKit.stringArgument(["k": 5], "k"))

        XCTAssertNil(try MCPKit.intArgument([:], "k"))
        XCTAssertEqual(try MCPKit.intArgument(["k": 3], "k"), 3)
        XCTAssertThrowsError(try MCPKit.intArgument(["k": "3"], "k"))
        XCTAssertThrowsError(try MCPKit.intArgument(["k": true], "k"), "A JSON boolean is not an integer")

        XCTAssertNil(try MCPKit.stringArrayArgument([:], "k"))
        XCTAssertEqual(try MCPKit.stringArrayArgument(["k": ["a", "b"]], "k"), ["a", "b"])
        XCTAssertThrowsError(try MCPKit.stringArrayArgument(["k": "a"], "k"))
        XCTAssertThrowsError(try MCPKit.stringArrayArgument(["k": [1, 2]], "k"))

        XCTAssertNil(try MCPKit.boolArgument([:], "k"))
        XCTAssertEqual(try MCPKit.boolArgument(["k": true], "k"), true)
        XCTAssertThrowsError(try MCPKit.boolArgument(["k": 1], "k"))
        XCTAssertThrowsError(try MCPKit.boolArgument(["k": "true"], "k"))
    }

    func testIDPrefixGateRejectsEmptyAndShortValues() throws {
        XCTAssertThrowsError(try MCPKit.validatedIDPrefix(nil))
        XCTAssertThrowsError(try MCPKit.validatedIDPrefix("   "))
        XCTAssertThrowsError(try MCPKit.validatedIDPrefix("abc"))
        XCTAssertEqual(try MCPKit.validatedIDPrefix(" abcdefgh "), "abcdefgh")
        XCTAssertNil(try MCPKit.validatedIDPrefix(nil, allowNil: true))
        XCTAssertThrowsError(try MCPKit.validatedIDPrefix("", allowNil: true), "An empty filter would match everything")
    }

    func testShortUndoIDMatchingTwoOperationsRestoresNeither() async throws {
        let store = try SQLiteStore.inMemory()
        for suffix in ["one", "two"] {
            try await store.saveUndoRecord(UndoRecord(
                id: "undo-\(suffix)", operationLogID: "abcdefgh-\(suffix)", inverseAction: .move,
                restoreURL: URL(fileURLWithPath: "/tmp/tidybyte-test/\(suffix).txt"), trashURL: nil,
                validUntil: nil, status: .available))
        }
        let kit = MCPKit(store: store)
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": "u1", "method": "tools/call",
            "params": ["name": "undo", "arguments": ["operation_log_id": "abcdefgh", "confirm": true]]
        ]
        let reply = await kit.handle(request: request)
        let response = try XCTUnwrap(reply).payload
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("matches more than one recorded operation"), text)
    }

    func testAIKeychainFailureFallsBackToLocalRulesWithANotice() async throws {
        let store = try SQLiteStore.inMemory()
        let memory = MemoryEngine(store: store)
        let gateway = AIGateway(
            keychain: KeychainStore(inMemory: true, injectedLoadError: .unexpectedStatus(-25300)),
            session: URLSession(configuration: .ephemeral))
        let orchestrator = ScanOrchestrator(store: store, aiGateway: gateway, memory: memory)
        let folder = try root.appendingPathComponent("ai", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))

        let (outcome, _) = try await orchestrator.scan(
            mode: .selectedFolders, selectedFolders: [folder],
            providerSettings: ProviderSettings(privacyMode: .metadataOnlyAI), includeAI: true)

        XCTAssertFalse(outcome.wasCancelled, "An unreadable AI key must not fail the scan")
        XCTAssertTrue(outcome.notices.contains { $0.message.contains("AI classification was skipped") })
    }

    func testDescendantWalkDeniesFolderWithUnreadableChild() throws {
        let folder = try makeFolder("locked-tree")
        let hidden = folder.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: hidden.appendingPathComponent("inside.txt"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)

        XCTAssertNotEqual(decision(for: folder), .allow,
                          "A child that cannot be read may hold credentials, so the folder is blocked")
    }

    func testExecutionStopsBetweenActionsWhenTheCallerCancels() async throws {
        let store = try SQLiteStore.inMemory()
        let folder = try root.appendingPathComponent("cancel-run", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["first.txt", "second.txt"]
        for name in names { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let crawl = await FileCrawler().crawl(rootURLs: [folder], sessionID: "cancel")
        let records = crawl.files.filter { $0.kind == .regularFile }
        let filesByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let actions = records.sorted { $0.fileName < $1.fileName }.map { record in
            PlannedAction(id: "a-\(record.fileName)", planID: "p", actionType: .moveToTrash, targets: [record.id],
                          destination: nil, status: .approved, risk: .low, confidence: 0.9, reason: "test",
                          userDecision: .approved, executedAt: nil, findingID: nil)
        }
        let executor = TestFixtures.makeExecutor(store: store)

        let summary = await executor.execute(actions: actions, filesByID: filesByID, progress: { completed in
            // Cancel the caller's task after the first action finished.
            if completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        })

        XCTAssertEqual(summary.logs.count, 1, "The action in flight when cancellation arrived must finish")
        XCTAssertEqual(summary.undoRecords.count, 1, "Completed actions keep their undo records")
        XCTAssertTrue(summary.failures.contains { $0.contains("cancelled") })
        let remaining = records.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        XCTAssertEqual(remaining.count, 1, "The action after the cancellation must not run")
    }

    func testMigrationRefusesNewerDatabaseWithoutWritingToIt() throws {
        let file = try root.appendingPathComponent("newer-untouched.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE future_only (x INTEGER); PRAGMA user_version = 99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let before = try Data(contentsOf: file)

        XCTAssertThrowsError(try SQLiteStore(databaseURL: file))

        XCTAssertEqual(try Data(contentsOf: file), before, "A refused database must be left byte for byte unchanged")
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

/// Photos fake: records calls and exports nothing, so the export check is exercised.
private final class RecordingPhotoService: PhotoMutationService, @unchecked Sendable {
    var exportCalls = 0
    var deleteCalls = 0
    func previewURL(for item: ReviewItem) async throws -> URL { throw CleanupError.message("unused") }
    func localURLs(for item: ReviewItem) async throws -> [URL] { [] }
    func export(_ item: ReviewItem, to folder: URL) async throws -> [URL] {
        exportCalls += 1
        return []
    }
    func replace(_ item: ReviewItem, with url: URL, kind: MediaKind) async throws -> String { "" }
    func delete(_ item: ReviewItem) async throws { deleteCalls += 1 }
}
// swiftlint:enable type_body_length file_length
