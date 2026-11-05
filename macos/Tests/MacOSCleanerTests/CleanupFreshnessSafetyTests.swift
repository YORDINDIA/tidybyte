import Foundation
import XCTest

@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore

/// PSA-01 + S-04 regression coverage: the freshness monitor's FSEventStream
/// must never be built on the main thread, and file-change bursts must
/// coalesce into one auto-rescan.
@MainActor
final class CleanupFreshnessSafetyTests: XCTestCase {
    /// PSA-01: scan() creates the monitor in a detached task, so the stream
    /// creation never runs on the main actor. Runs a real scan over a small
    /// fixture root and asserts the probe never saw a main-thread creation.
    func testScanDoesNotCreateFSEventStreamOnMainThread() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidybyte-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fresh".utf8).write(to: root.appendingPathComponent("a.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let model = CleanupModel(store: try SQLiteStore.inMemory())
        model.scope = ReviewScope()
        model.scope.mode = .folder
        model.scope.roots = [root]

        let before = CleanupFreshnessMonitor.creationProbe.mainThreadCreations
        model.scan()
        // The monitor build is a detached task; give it time to land.
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(50))
            if model.hasFreshnessMonitor { break }
        }
        let probe = CleanupFreshnessMonitor.creationProbe
        XCTAssertGreaterThan(probe.totalCreations, before, "scan must create a freshness monitor")
        XCTAssertEqual(
            probe.mainThreadCreations, before,
            "FSEventStreamCreate must never run on the main thread (PSA-01)")
        model.cancel()
    }

    /// S-04: a burst of freshness changes coalesces into one debounced
    /// auto-rescan instead of one scan per change.
    func testFreshnessBurstsCoalesceIntoOneDebouncedRescan() async throws {
        let model = CleanupModel(store: try SQLiteStore.inMemory())
        model.scope = ReviewScope()
        model.scope.mode = .folder
        let root = URL(fileURLWithPath: "/tmp/tidybyte-freshness-debounce")
        model.scope.roots = [root]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scansBefore = model.scanRequestCount
        for _ in 0..<5 { model.freshnessDidChange() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.scanRequestCount - scansBefore, 0, "no rescan inside the debounce window")
        try await Task.sleep(for: .seconds(2.2))
        XCTAssertEqual(
            model.scanRequestCount - scansBefore, 1,
            "a burst of changes must coalesce into exactly one auto-rescan")
        model.cancel()
    }

    /// O-03: a second scan request while a scan is already running must not
    /// pop the scope sheet mid-flow — it coalesces with a notice.
    func testScanWhileBusyShowsNoticeInsteadOfScopeSheet() throws {
        let model = CleanupModel(store: try SQLiteStore.inMemory())
        model.scope.mode = .folder
        model.scope.roots = [FileManager.default.temporaryDirectory]
        model.isBusy = true
        model.scan()
        XCTAssertFalse(model.showsScope, "busy scan must not open the scope sheet")
        XCTAssertEqual(model.notice, "A media scan is already running.")
    }

    /// The scope sheet still opens for the legitimate no-roots case.
    func testScanWithoutRootsStillOpensScopeSheet() throws {
        let model = CleanupModel(store: try SQLiteStore.inMemory())
        model.scope = ReviewScope()
        model.scan()
        XCTAssertTrue(model.showsScope, "no roots and no Photos must open the scope sheet")
        XCTAssertNil(model.notice)
    }
}
