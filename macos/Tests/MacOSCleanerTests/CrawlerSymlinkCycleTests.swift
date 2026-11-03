import Foundation
import XCTest
@testable import MacOSCleanerCore

/// SP-04: the crawler must survive circular symlinks. Directory symlinks are
/// never descended into (NSDirectoryEnumerator does not follow them, and the
/// crawler records symlink entries as `.symlink` leaves), so a cycle a → b → a
/// terminates after one visit. If this test ever hangs instead of failing, the
/// cycle guarantee has regressed.
final class CrawlerSymlinkCycleTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = try TestFixtures.makeTemporaryDirectory(named: "SymlinkCycle-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSymlink(_ name: String, pointingTo destination: URL) throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(name, isDirectory: false),
            withDestinationURL: destination)
    }

    func testCrawlTerminatesAndRecordsSymlinkCycle() async throws {
        // A real folder with one file, plus three loops: an ancestor loop
        // (root/loop → root), a sibling loop (root/a → root), and a self-loop
        // (root/self → root/self).
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("reachable content".utf8).write(to: inner.appendingPathComponent("real.txt", isDirectory: false))
        try makeSymlink("loop", pointingTo: root)
        try makeSymlink("a", pointingTo: root)
        try makeSymlink("self", pointingTo: root.appendingPathComponent("self", isDirectory: false))

        let crawler = FileCrawler()
        let (records, _) = await crawler.crawl(rootURLs: [root], sessionID: "cycle")

        let names = records.map(\.fileName)
        XCTAssertEqual(names.filter { $0 == "real.txt" }.count, 1,
                       "The reachable file must be recorded exactly once")
        for link in ["loop", "a", "self"] {
            let record = records.first { $0.fileName == link }
            XCTAssertEqual(record?.kind, .symlink, "\(link) must be recorded as a symlink leaf")
            XCTAssertNotNil(record?.symlinkTarget, "\(link) must carry its target")
        }
        XCTAssertLessThanOrEqual(records.count, 20,
                                 "A cycle must not multiply records (looping would grow this unboundedly)")
    }

    func testRootThatIsASymlinkIsRecordedNotFollowed() async throws {
        // Symlinks are never followed, roots included: crawling a symlink root
        // yields the symlink's own record, not the target's tree.
        let target = try TestFixtures.makeTemporaryDirectory(named: "SymlinkTarget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }
        try Data("target file".utf8).write(to: target.appendingPathComponent("inside.txt", isDirectory: false))
        let link = root.appendingPathComponent("root-link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let crawler = FileCrawler()
        let (records, _) = await crawler.crawl(rootURLs: [link], sessionID: "cycle-root")

        XCTAssertTrue(records.contains { $0.fileName == "root-link" && $0.kind == .symlink },
                      "The symlink root itself must be recorded")
        XCTAssertFalse(records.contains { $0.fileName == "inside.txt" },
                       "The symlink target's contents must not be crawled")
    }
}
