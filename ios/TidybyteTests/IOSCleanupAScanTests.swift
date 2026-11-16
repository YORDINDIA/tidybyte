import XCTest
@testable import Tidybyte

/// Regression tests for the cleanup audit (ios-cleanup-a): Bursts selection
/// invariants, the shared scan runner, and the shared delete pipeline.
/// Call counter for the fetch stub. An actor, because the stub runs off the
/// main actor (the view model's fetch task is nonisolated).
actor FetchCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
final class IOSCleanupAScanTests: XCTestCase {

    private func makeAsset(
        id: String,
        fileSize: Int64 = 8_000_000,
        isFavorite: Bool = false,
        creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AssetSummary {
        AssetSummary(
            id: id,
            mediaType: .photo,
            creationDate: creationDate,
            modificationDate: creationDate,
            pixelWidth: 4032,
            pixelHeight: 3024,
            duration: 0,
            fileSize: fileSize,
            filename: "\(id).jpg",
            isFavorite: isFavorite,
            isBurst: true,
            burstIdentifier: "burst",
            isLivePhoto: false,
            isScreenshot: false,
            isLocallyAvailable: true
        )
    }

    // MARK: - Bursts: keeper is never marked (BURST-01)

    /// A refresh can move a group's keeper onto a frame the user had already
    /// marked (for example, after a favorite in Photos). The new keeper must
    /// not stay in the deletion set.
    func testMergedSelectionDropsKeeperThatRefreshPromoted() {
        let group = BurstGroup(
            id: "g",
            assets: [makeAsset(id: "A"), makeAsset(id: "B"), makeAsset(id: "C")],
            bestAssetId: "C"
        )
        let merged = BurstCleanerViewModel.mergedSelection(
            oldSelection: ["B", "C"],
            survivingIds: ["A", "B", "C"],
            touchedGroups: ["g"],
            groups: [group]
        )
        XCTAssertEqual(merged, ["B"])
    }

    func testMergedSelectionNeverIncludesKeeperForUntouchedGroup() {
        let group = BurstGroup(
            id: "g",
            assets: [makeAsset(id: "A"), makeAsset(id: "B"), makeAsset(id: "C")],
            bestAssetId: "C"
        )
        let merged = BurstCleanerViewModel.mergedSelection(
            oldSelection: ["C"],
            survivingIds: ["A", "B", "C"],
            touchedGroups: [],
            groups: [group]
        )
        XCTAssertFalse(merged.contains("C"))
        XCTAssertEqual(merged, ["A", "B"])
    }

    func testAutoCleanArmedIdsSkipsKeeperInTouchedGroup() {
        let group = BurstGroup(
            id: "g",
            assets: [makeAsset(id: "A"), makeAsset(id: "B")],
            bestAssetId: "B"
        )
        let armed = BurstCleanerViewModel.autoCleanArmedIds(
            groups: [group],
            touchedGroups: ["g"],
            selection: ["A", "B"]
        )
        XCTAssertEqual(armed, ["A"])
    }

    // MARK: - Bursts: deterministic group order

    func testRebuildGroupsOrdersEqualSizeBurstsByIdentifier() {
        let groups = BurstSelectionPolicy.rebuildGroups(from: [
            "zeta": [makeAsset(id: "z1"), makeAsset(id: "z2")],
            "alpha": [makeAsset(id: "a1"), makeAsset(id: "a2")],
            "big": [makeAsset(id: "b1"), makeAsset(id: "b2"), makeAsset(id: "b3")]
        ])
        XCTAssertEqual(groups.map(\.id), ["big", "alpha", "zeta"])
    }

    // MARK: - Bursts: one fetch at a time

    func testOverlappingLoadAndRefreshRunOneFetch() async {
        let counter = FetchCounter()
        let assets = [makeAsset(id: "a"), makeAsset(id: "b")]
        let viewModel = BurstCleanerViewModel(fetchBursts: {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return ["burst": assets]
        })
        async let load: Void = viewModel.load()
        async let refresh: Void = viewModel.refresh()
        _ = await (load, refresh)
        let fetches = await counter.count
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(viewModel.groups.map(\.id), ["burst"])
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Duplicates and Similar: items vanish during review

    func testDuplicatePruneRemovesGoneItemsAndDropsSmallGroups() {
        let viewModel = DuplicateFinderViewModel()
        viewModel.scanState = .completed
        viewModel.exactGroups = [
            DuplicateGroup(id: "g", assets: [makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")],
                           bestAssetId: "a", type: .exact)
        ]
        viewModel.selectedForDeletion = ["b", "c"]

        viewModel.pruneGone(["c"])
        XCTAssertEqual(viewModel.exactGroups.map { $0.assets.map(\.id) }, [["a", "b"]])
        XCTAssertEqual(viewModel.selectedForDeletion, ["b"])

        viewModel.pruneGone(["b"])
        XCTAssertTrue(viewModel.exactGroups.isEmpty, "a group with one item left is dropped")
        XCTAssertTrue(viewModel.selectedForDeletion.isEmpty)
    }

    func testDuplicatePruneReElectsKeeperWhenKeeperVanishes() {
        let viewModel = DuplicateFinderViewModel()
        viewModel.scanState = .completed
        viewModel.exactGroups = [
            DuplicateGroup(id: "g", assets: [makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")],
                           bestAssetId: "a", type: .exact)
        ]
        viewModel.selectedForDeletion = ["b", "c"]
        viewModel.pruneGone(["a"])
        XCTAssertEqual(viewModel.exactGroups.count, 1)
        XCTAssertEqual(Set(viewModel.exactGroups[0].assets.map(\.id)), ["b", "c"])
        let keeper = viewModel.exactGroups[0].bestAssetId
        XCTAssertTrue(["b", "c"].contains(keeper))
        // The re-picked keeper has no delete toggle, so it must not stay selected:
        // confirming Delete would otherwise remove every copy.
        XCTAssertFalse(viewModel.selectedForDeletion.contains(keeper))
        XCTAssertEqual(viewModel.selectedForDeletion, Set(["b", "c"]).subtracting([keeper]))
    }

    func testSimilarPruneRemovesGoneItemsAndDropsSmallGroups() {
        let viewModel = SimilarPhotosViewModel()
        viewModel.scanState = .completed
        viewModel.groups = [
            SimilarGroup(id: "g", assets: [makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")],
                         bestAssetId: "a", qualityScores: [:], bestReason: .bestOverall)
        ]
        viewModel.selectedForDeletion = ["b", "c"]

        viewModel.pruneGone(["a"])
        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(Set(viewModel.groups[0].assets.map(\.id)), ["b", "c"])
        XCTAssertNotEqual(viewModel.groups[0].bestAssetId, "a")
        // The re-picked keeper must not stay selected, as in the Duplicates test.
        let keeper = viewModel.groups[0].bestAssetId
        XCTAssertFalse(viewModel.selectedForDeletion.contains(keeper))
        XCTAssertEqual(viewModel.selectedForDeletion, Set(["b", "c"]).subtracting([keeper]))

        viewModel.pruneGone(["c"])
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertTrue(viewModel.selectedForDeletion.isEmpty)
    }

    // MARK: - Large Files: a complete share clears the earlier shortfall

    func testCompleteShareClearsEarlierShortfallWarning() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(PhotoLibraryService.shareExportFolderPrefix)ios-cleanup-a-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [folder.appendingPathComponent("a.jpg"), folder.appendingPathComponent("b.jpg")]
        var returned = [urls[0]]
        let viewModel = LargeFilesViewModel(shareExporter: { _, _ in (folder, returned) })
        viewModel.assets = [makeAsset(id: "a", fileSize: 1_000_000_000), makeAsset(id: "b", fileSize: 1_000_000_000)]
        viewModel.selectedIds = ["a", "b"]

        viewModel.startShare()
        while viewModel.isPreparingShare { await Task.yield() }
        XCTAssertNotNil(viewModel.errorMessage, "one of two items came back, so the shortfall is reported")
        viewModel.cleanupShareExport()

        returned = urls
        viewModel.startShare()
        while viewModel.isPreparingShare { await Task.yield() }
        XCTAssertNil(viewModel.errorMessage, "a complete export clears the earlier shortfall")
        viewModel.cleanupShareExport()
    }

    // MARK: - Delete confirmations share one title pattern

    func testConfirmTitleUsesSingularForOneItem() {
        XCTAssertEqual(CleanupDeletion.confirmTitle(count: 1), "Delete 1 Item")
        XCTAssertEqual(CleanupDeletion.confirmTitle(count: 3), "Delete 3 Items")
    }

    // MARK: - Shared scan runner (C1/C2)

    func testScanRunnerCancelInvalidatesOldToken() async {
        let runner = ScanRunner()
        var firstToken: Int?
        runner.start { token in
            firstToken = token
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        await Task.yield()
        guard let firstToken else { return XCTFail("scan did not start") }
        XCTAssertTrue(runner.isCurrent(firstToken))

        runner.cancel()
        XCTAssertFalse(runner.isRunning)
        XCTAssertFalse(runner.isCurrent(firstToken))

        var applied = false
        runner.update(firstToken) { applied = true }
        XCTAssertFalse(applied, "progress from a cancelled run must be dropped")
    }

    func testScanRunnerRejectsSecondStartWhileRunning() async {
        let runner = ScanRunner()
        var starts = 0
        runner.start { _ in
            starts += 1
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        runner.start { _ in starts += 1 }
        await Task.yield()
        XCTAssertEqual(starts, 1)
        runner.cancel()
    }

    // MARK: - Shared delete pipeline (partial failure)

    func testDeletePartialFailureReportsOnlyRealDeletions() async {
        let outcome = await CleanupDeletion.delete(
            requestedIds: ["a", "b"],
            kind: .bursts,
            sizeById: ["a": 1, "b": 1],
            performDelete: { _ in
                throw PhotoServiceError.partialDeletion(succeededIds: ["a"], failedCount: 1)
            },
            apply: { _ in }
        )
        XCTAssertEqual(outcome.deleted, ["a"])
        XCTAssertEqual(outcome.removed, ["a"])
        XCTAssertNotNil(outcome.errorMessage)
    }

    func testDeleteCancellationIsSilent() async {
        let outcome = await CleanupDeletion.delete(
            requestedIds: ["a"],
            kind: .largeFiles,
            sizeById: ["a": 1],
            performDelete: { _ in throw CancellationError() },
            apply: { _ in XCTFail("apply must not run on cancel") }
        )
        XCTAssertTrue(outcome.deleted.isEmpty)
        XCTAssertNil(outcome.errorMessage)
    }
}
