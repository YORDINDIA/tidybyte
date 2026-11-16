import Darwin
import Foundation
import XCTest
@testable import MacOSCleanerCore

/// Regression tests for the PR #26 Core review comments.
final class MacCoreReviewFixTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tidybyte-pr26-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFolder(_ relative: String) throws -> URL {
        let folder = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func setPermissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func fileRecord(id: String, path: String, linkCount: Int) -> FileRecord {
        var record = TestFixtures.makeFileRecord(id: id, path: path, sizeBytes: 10)
        record.linkCount = linkCount
        return record
    }

    // MARK: - Credential walk: unreadable and oversized key files fail closed

    func testUnreadableKeyFileBlocksFolderTrash() throws {
        let folder = try makeFolder("bundle")
        let key = folder.appendingPathComponent("id.pem")
        try Data("-----BEGIN CERTIFICATE-----".utf8).write(to: key)
        try setPermissions(0o000, at: key)
        defer { try? setPermissions(0o644, at: key) }

        XCTAssertEqual(PathSafetyPolicy().firstProtectedDescendant(of: folder)?.lastPathComponent, "id.pem")
    }

    func testUnreadableChildFolderBlocksFolderTrash() throws {
        let folder = try makeFolder("locked")
        let inner = folder.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try setPermissions(0o000, at: inner)
        defer { try? setPermissions(0o755, at: inner) }

        XCTAssertEqual(PathSafetyPolicy().firstProtectedDescendant(of: folder), folder,
                       "A folder that cannot be fully read must block the trash")
    }

    func testReadableCertificateWithoutPrivateKeyDoesNotBlock() throws {
        let folder = try makeFolder("certs")
        try Data("-----BEGIN CERTIFICATE-----\nMIIB\n".utf8).write(to: folder.appendingPathComponent("ca.pem"))
        XCTAssertNil(PathSafetyPolicy().firstProtectedDescendant(of: folder))
    }

    func testPrivateKeyMarkerAfterLongPreambleStillBlocks() throws {
        let folder = try makeFolder("deep")
        let key = folder.appendingPathComponent("server.pem")
        let preamble = Data(repeating: UInt8(ascii: "a"), count: 100_000)
        try (preamble + Data("-----BEGIN PRIVATE KEY-----".utf8)).write(to: key)
        XCTAssertEqual(PathSafetyPolicy().firstProtectedDescendant(of: folder)?.lastPathComponent, "server.pem")
    }

    func testKeyFileOverInspectionLimitBlocks() throws {
        let folder = try makeFolder("big")
        let key = folder.appendingPathComponent("blob.key")
        try Data(repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024 + 1).write(to: key)
        XCTAssertEqual(PathSafetyPolicy().firstProtectedDescendant(of: folder)?.lastPathComponent, "blob.key")
    }

    // MARK: - Duplicate detection: hard links and change stamps

    func testHardLinkedMembersLeaveNoTrashTarget() {
        let first = fileRecord(id: "a", path: "/tmp/tidybyte-test/a.txt", linkCount: 2)
        let second = fileRecord(id: "b", path: "/tmp/tidybyte-test/b.txt", linkCount: 2)
        XCTAssertNil(DuplicateDetector.selectKeeper(sortedNewestFirst: [first, second]))
    }

    func testHardLinkedKeeperIsKeptAndSeparateCopyIsTheTarget() throws {
        let linked = fileRecord(id: "linked", path: "/tmp/tidybyte-test/linked.txt", linkCount: 2)
        let copy = fileRecord(id: "copy", path: "/tmp/tidybyte-test/copy.txt", linkCount: 1)
        let result = try XCTUnwrap(DuplicateDetector.selectKeeper(sortedNewestFirst: [copy, linked]))
        XCTAssertEqual(result.keeper.id, "linked")
        XCTAssertEqual(result.duplicates.map(\.id), ["copy"])
    }

    func testChangeStampReportsInodeAndNanosecondChangeTime() throws {
        let file = root.appendingPathComponent("stamp.txt")
        try Data("x".utf8).write(to: file)
        let stamp = try XCTUnwrap(DuplicateDetector.changeStamp(of: file))
        XCTAssertGreaterThan(stamp.inode, 0)
        // Nanoseconds since 2020-01-01: a seconds-only value would be far smaller.
        XCTAssertGreaterThan(stamp.changedAtNanoseconds, 1_577_836_800_000_000_000)
        XCTAssertEqual(DuplicateDetector.changeStamp(of: file)?.changedAtNanoseconds, stamp.changedAtNanoseconds)
    }

    // MARK: - Log roots match the folder exactly

    func testLogRootMatchesOnlyTheLogFolderItself() {
        let home = "/Users/tester"
        XCTAssertTrue(CleanerRuleEngine.isMacOSLogPath("/Library/Logs", home: home))
        XCTAssertTrue(CleanerRuleEngine.isMacOSLogPath("/Users/tester/Library/Logs", home: home))
        XCTAssertTrue(CleanerRuleEngine.isMacOSLogPath("/Users/tester/Library/Logs/app/run.txt", home: home))
        XCTAssertFalse(CleanerRuleEngine.isMacOSLogPath("/Users/tester/Library/Logs-backup/run.txt", home: home))
        XCTAssertFalse(CleanerRuleEngine.isMacOSLogPath("/Users/tester/Library/Logsx", home: home))
        XCTAssertFalse(CleanerRuleEngine.isMacOSLogPath("/Users/other/Library/Logs/run.txt", home: home))
    }

    // MARK: - Docker, credential names and permission paths

    func testDockerReasonMatchesOnlyTheContainerRoot() {
        XCTAssertTrue(MoCleanScanner.isDockerContainerRoot(
            "/Users/tester/Library/Containers/com.docker.docker"))
        XCTAssertFalse(MoCleanScanner.isDockerContainerRoot(
            "/Users/tester/Library/Containers/com.docker.docker.helper"))
    }

    func testCredentialNamesAndFoldersAreRecognised() {
        XCTAssertTrue(ContentExtractor.isCredentialLike(URL(fileURLWithPath: "/x/my-api-key.txt")))
        XCTAssertTrue(ContentExtractor.isCredentialLike(URL(fileURLWithPath: "/x/private_key.txt")))
        XCTAssertTrue(ContentExtractor.isCredentialLike(URL(fileURLWithPath: "/x/secrets/notes.txt")))
        XCTAssertFalse(ContentExtractor.isCredentialLike(URL(fileURLWithPath: "/x/notes.txt")))
    }

    func testClosedFolderMatchIgnoresCase() {
        let closed: Set<String> = ["/Users/tester/Library/Containers"]
        XCTAssertTrue(FullDiskAccess.isClosed("/Users/tester/library/containers/app", in: closed))
        XCTAssertFalse(FullDiskAccess.isClosed("/Users/tester/Library/ContainersX", in: closed))
    }

    // MARK: - Process output and descendants

    func testUndecodableProcessOutputKeepsTheValidBytes() {
        XCTAssertEqual(ProcessRunner.readableText(Data([0x41, 0xFF, 0x42])), "A\u{FFFD}B")
    }

    func testDescendantPIDsFindChildProcesses() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30 & sleep 30 & wait"]
        try shell.run()
        defer {
            for pid in ProcessRunner.descendantPIDs(of: shell.processIdentifier) { kill(pid, SIGKILL) }
            kill(shell.processIdentifier, SIGKILL)
        }

        var children: [pid_t] = []
        for _ in 0..<100 where children.count < 2 {
            Thread.sleep(forTimeInterval: 0.05)
            children = ProcessRunner.descendantPIDs(of: shell.processIdentifier)
        }
        XCTAssertGreaterThanOrEqual(children.count, 2, "Both sleep children must be found")
        XCTAssertFalse(children.contains(shell.processIdentifier))
    }

    // MARK: - Finder tags and owner identity

    func testFinderTagWriteRefusesSymlinkedAncestor() throws {
        let real = try makeFolder("real")
        let file = real.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try FinderTagHelper.write(["Red"], to: link.appendingPathComponent("a.txt")))
        XCTAssertNoThrow(try FinderTagHelper.write(["Red"], to: file))
    }

    func testOwnerWithChangedStartTimeCountsAsExited() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { kill(child.processIdentifier, SIGKILL) }

        let pid = child.processIdentifier
        let start = try XCTUnwrap(SQLiteStore.processStartTime(of: pid))
        var session = ScanSession(id: "owner-check", startedAt: Date(), scanType: .homeFolder, rootURLs: [],
                                  permissionsSnapshot: "", status: .running)
        session.ownerProcessID = pid
        session.ownerProcessStart = start
        XCTAssertFalse(SQLiteStore.ownerHasExited(session), "A live owner with the same start time is alive")

        session.ownerProcessStart = start + 1
        XCTAssertTrue(SQLiteStore.ownerHasExited(session), "A reused PID with another start time has exited")
    }

    // MARK: - JSON integer widths

    func testSanitizerKeepsEveryIntegerWidth() throws {
        let value: [String: Any] = ["i8": Int8(-5), "u16": UInt16(7), "u64": UInt64.max, "i64": Int64.min]
        let text = try XCTUnwrap(String(data: XCTUnwrap(JSONSanitizing.data(value)), encoding: .utf8))
        XCTAssertTrue(text.contains("\"i8\":-5"))
        XCTAssertTrue(text.contains("\"u16\":7"))
        XCTAssertTrue(text.contains("\"u64\":18446744073709551615"))
        XCTAssertTrue(text.contains("\"i64\":-9223372036854775808"))
    }
}
