import Foundation
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore
import XCTest

/// Regression tests for the Explore tree builder and token fixes. These use
/// path strings only. No fixture path exists on disk, and nothing is read.
@MainActor
final class MacAppExploreScanTests: XCTestCase {
    private let root = "/Users/explore-fixture"

    private func file(_ relative: String, bytes: Int64) -> FileRecord {
        TestFixtures.makeFileRecord(id: "file-\(relative)", path: "\(root)/\(relative)", sizeBytes: bytes)
    }

    private func folder(_ relative: String, items: Int? = nil, bytes: Int64 = 0) -> FileRecord {
        var record = TestFixtures.makeFileRecord(id: "dir-\(relative)", path: "\(root)/\(relative)", sizeBytes: bytes)
        record.kind = .directory
        record.rolledUpItemCount = items
        return record
    }

    func testByFolderIDsUseStandardPathsAndMembersResolve() throws {
        let files = [
            file("Projects/app/a.bin", bytes: 100),
            file("Projects/app/b.bin", bytes: 200),
            file("Downloads/c.zip", bytes: 50)
        ]
        let groups = ExploreTreeBuilder.build(files: files, grouping: .byFolder, maxDepth: 3)
        XCTAssertEqual(groups.map(\.bytes), [300, 50])
        XCTAssertTrue(groups.allSatisfy { !$0.id.hasPrefix("//") }, "Folder group ids must equal URL paths")
        let projects = try XCTUnwrap(groups.first)
        XCTAssertEqual(projects.id, "\(root)/Projects")
        XCTAssertEqual(ExploreTreeBuilder.members(of: projects, in: files).count, 2)
        XCTAssertEqual(ExploreTreeBuilder.largestMember(of: projects, in: files)?.id, "file-Projects/app/b.bin")
    }

    func testSingleFolderScanStillProducesAGroup() throws {
        let files = [file("Only/a.bin", bytes: 100), file("Only/b.bin", bytes: 50)]
        let groups = ExploreTreeBuilder.build(files: files, grouping: .byFolder, maxDepth: 2)
        XCTAssertEqual(groups.count, 1, "Files that share one folder must not produce an empty view")
        let only = try XCTUnwrap(groups.first)
        XCTAssertEqual(only.bytes, 150)
        XCTAssertEqual(ExploreTreeBuilder.members(of: only, in: files).count, 2)
    }

    func testLooseFilesBesideSubfoldersAreNotDropped() {
        let files = [file("Projects/a.bin", bytes: 100), file("Projects/sub/b.bin", bytes: 200)]
        let groups = ExploreTreeBuilder.build(files: files, grouping: .byFolder, maxDepth: 2)
        XCTAssertEqual(groups.reduce(Int64(0)) { $0 + $1.bytes }, 300)
    }

    func testSummarizedFolderTypeGroupResolvesItsRecord() throws {
        let summarized = folder("Library/Caches/App", items: 40, bytes: 5_000)
        let files = [summarized, file("Notes/readme.txt", bytes: 10)]
        let groups = ExploreTreeBuilder.build(files: files, grouping: .byType, maxDepth: 2)
        let group = try XCTUnwrap(groups.first { $0.bytes == 5_000 })
        XCTAssertEqual(ExploreTreeBuilder.largestMember(of: group, in: files)?.id, summarized.id)
    }

    func testFileCountsDoNotCountPlainFolders() {
        let files = [
            folder("Projects/sub"),
            file("Projects/sub/b.bin", bytes: 100),
            file("Projects/other.bin", bytes: 50)
        ]
        let groups = ExploreTreeBuilder.build(files: files, grouping: .byFolder, maxDepth: 2)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.fileCount }, 2)
    }

    func testDescendantsOfFilesystemRootAreFound() {
        let record = file("Projects/a.bin", bytes: 1)
        XCTAssertEqual(ExploreSubtreeIndex.descendants(ofParentPath: "/", in: [record]).count, 1)
    }

    func testFilesTokenChangesWhenScanSessionChanges() {
        let first = [file("a.bin", bytes: 1)]
        var second = first
        second[0].scanSessionID = "other-scan"
        XCTAssertNotEqual(ExploreFilesToken(first), ExploreFilesToken(second))
    }
}
