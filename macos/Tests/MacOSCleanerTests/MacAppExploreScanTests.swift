import AppKit
import Foundation
import SwiftUI
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

    // MARK: - Round 3: on-screen render and accessibility of the Explore views

    private func renderModel() throws -> AppViewModel {
        let store = try SQLiteStore.inMemory()
        let memory = MemoryEngine(store: store)
        return AppViewModel(
            store: store, keychain: KeychainStore(inMemory: true), memory: memory,
            orchestrator: ScanOrchestrator(store: store, memory: memory),
            executor: TestFixtures.makeExecutor(store: store),
            undoService: UndoManagerService(store: store, memory: memory),
            reportGenerator: ReportGenerator(store: store), notifications: NotificationScheduler(),
            planner: PlannerAgent(), defaults: makeIsolatedDefaults())
    }

    /// A small tree with one long path, so the inspector and the rows have real text to fit.
    private func fixtureFiles() -> [FileRecord] {
        let longPath = "/Fixture/Library/Application Support/ExampleVendorSuite/ProjectArchives/2024/"
            + "quarterly-review-final-v3-REALLY-FINAL/exported-assets/presentation-deck-with-a-long-name.key"
        let entries: [(String, Int64)] = [
            ("/Fixture/Projects/app/build/output.bin", 3_200_000_000),
            ("/Fixture/Projects/app/assets/hero.psd", 800_000_000),
            ("/Fixture/Projects/web/node_modules/pkg/index.js", 40_000_000),
            ("/Fixture/Downloads/installer-x.dmg", 1_400_000_000),
            ("/Fixture/Downloads/archive.zip", 220_000_000),
            ("/Fixture/Movies/clip.mov", 2_000_000_000),
            (longPath, 90_000_000),
            ("/Fixture/Library/Caches/Vendor/cache.db", 300_000_000),
            ("/Fixture/Library/Caches/Vendor/cache2.db", 120_000_000)
        ]
        return entries.enumerated().map { index, entry in
            var record = TestFixtures.makeFileRecord(id: "fx-\(index)", path: entry.0, sizeBytes: entry.1)
            record.modifiedAt = Calendar.current.date(byAdding: .day, value: -(index * 70), to: Date())
            return record
        }
    }

    /// Renders a view in an offscreen window, at a fixed size and colour scheme, and returns PNG data.
    @MainActor
    private func snapshot<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> (data: Data, window: NSWindow) {
        let root = view
            .padding(Spacing.cardPadding)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (try XCTUnwrap(rep.representation(using: .png, properties: [:])), window)
    }

    /// Share of sampled pixels that differ from the top-left background. A blank render is near 0.
    private func drawnFraction(_ png: Data) throws -> Double {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let background = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        var drawn = 0
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                total += 1
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.05 { drawn += 1 }
            }
        }
        return Double(drawn) / Double(max(total, 1))
    }

    /// Checks that each Explore view draws content, at both widths and both schemes.
    /// It does not check accessibility: SwiftUI exposes no accessibility tree to an in-process test.
    @MainActor
    func testExploreViewsRenderAtBothWidthsAndSchemes() throws {
        let model = try renderModel()
        let files = fixtureFiles()
        var outcome = ScanOutcome.standalone(session: ScanSession(
            scanType: .selectedFolders, rootURLs: [], permissionsSnapshot: "render", status: .completed))
        outcome.files = files
        model.outcome = outcome
        model.selectExploreRecord(id: files[6].id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-app-explore", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sizes: [(String, CGSize)] = [("900", CGSize(width: 900, height: 620)), ("1400", CGSize(width: 1400, height: 720))]
        for (width, size) in sizes {
            for dark in [false, true] {
                let scheme = dark ? "dark" : "light"
                let views: [(String, AnyView)] = [
                    ("topsizes", AnyView(ScrollView {
                        TopSizesView(model: model, files: files, grouping: .byFolder, maxDepth: 4, nameFilter: "")
                    })),
                    ("sunburst", AnyView(ScrollView {
                        SunburstView(model: model, files: files, grouping: .byFolder, maxDepth: 3, nameFilter: "")
                    })),
                    ("flame", AnyView(ScrollView {
                        FlameView(model: model, files: files, grouping: .byFolder, maxDepth: 4, nameFilter: "")
                    })),
                    ("agemap", AnyView(ScrollView { AgeMapView(model: model, files: files, nameFilter: "") })),
                    ("mindmap", AnyView(ScrollView {
                        MindMapView(model: model, files: files, grouping: .byFolder, maxDepth: 3, nameFilter: "")
                    })),
                    ("inspector", AnyView(SelectionInspectorView(model: model)))
                ]
                for (name, view) in views {
                    let shot = try snapshot(view, size: size, dark: dark)
                    let url = folder.appendingPathComponent("explore-\(name)-\(width)-\(scheme).png")
                    try shot.data.write(to: url)
                    let drawn = try drawnFraction(shot.data)
                    XCTAssertGreaterThan(drawn, 0.01, "\(name) at \(width) pt (\(scheme)) drew almost nothing")
                }
            }
        }
        print("EXP render PNGs written to \(folder.path)")
    }

    /// Root-level scans have "/" as the common path. Folder ids must not start with "//", and must resolve.
    func testRootLevelFolderIDsHaveNoDoubleSlashAndResolve() {
        let files = [
            TestFixtures.makeFileRecord(id: "a", path: "/Alpha/one.bin", sizeBytes: 100),
            TestFixtures.makeFileRecord(id: "b", path: "/Beta/two.bin", sizeBytes: 200)
        ]
        let groups = ExploreTreeBuilder.build(files: files, grouping: .byFolder, maxDepth: 3)
        XCTAssertFalse(groups.isEmpty)
        for group in groups {
            XCTAssertFalse(group.id.hasPrefix("//"), "Folder id \(group.id) has a double slash")
            XCTAssertFalse(ExploreTreeBuilder.members(of: group, in: files).isEmpty, "\(group.id) must resolve its members")
        }
    }

    /// A zero-byte file beside a subfolder still gets an "Other" row, because it counts as an item.
    func testZeroByteLooseFileBesideSubfolderGetsAnOtherRow() {
        let files = [
            TestFixtures.makeFileRecord(id: "a", path: "/fx/sub/a.bin", sizeBytes: 100),
            TestFixtures.makeFileRecord(id: "z", path: "/fx/zero.txt", sizeBytes: 0)
        ]
        let groups = ExploreTreeBuilder.build(files: files, grouping: .byFolder, maxDepth: 3)
        XCTAssertEqual(groups.first { $0.id == "__other__" }?.fileCount, 1)
    }
}
