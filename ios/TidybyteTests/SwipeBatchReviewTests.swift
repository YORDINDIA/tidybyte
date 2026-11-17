import XCTest
import SwiftData
@testable import Tidybyte

@MainActor
final class SwipeBatchReviewTests: XCTestCase {
    private var container: ModelContainer!

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    private func makeViewModel(assetCount: Int = 4) throws -> SwipeSessionViewModel {
        let schema = Schema([SwipeRecord.self, CompressionRecord.self, StorageSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        let vm = SwipeSessionViewModel(
            filter: .allMedia,
            photoService: PhotoLibraryService(),
            modelContext: container.mainContext
        )
        vm.assets = (0..<assetCount).map { idx in
            makeAsset(id: "asset-\(idx)", fileSize: Int64(idx + 1) * 1_000_000)
        }
        vm.loadDetails = { _ in [:] }
        return vm
    }

    private func makeAsset(id: String, fileSize: Int64) -> AssetSummary {
        AssetSummary(
            id: id,
            mediaType: .photo,
            creationDate: .now,
            modificationDate: .now,
            pixelWidth: 4032,
            pixelHeight: 3024,
            duration: 0,
            fileSize: fileSize,
            filename: "\(id).jpg",
            isFavorite: false,
            isBurst: false,
            burstIdentifier: nil,
            isLivePhoto: false,
            isScreenshot: false,
            isLocallyAvailable: true
        )
    }

    func testPendingDeletionAssetsResolveFromMarkedSwipes() throws {
        let vm = try makeViewModel()
        vm.swipeLeft() // 1 MB
        vm.swipeRight()
        vm.swipeLeft() // 3 MB

        XCTAssertEqual(vm.pendingDeletionAssets.map(\.id), ["asset-0", "asset-2"])
        XCTAssertEqual(vm.pendingDeletionBytes, 4_000_000)
    }

    func testApplyDeletionReviewKeepsSelectedAndRemovesUncheckedFromUndo() throws {
        let vm = try makeViewModel()
        vm.swipeLeft() // asset-0: 1 MB
        vm.swipeLeft() // asset-1: 2 MB
        vm.swipeLeft() // asset-2: 3 MB

        vm.applyDeletionReview(keeping: ["asset-1"])

        XCTAssertEqual(vm.pendingDeletionIds, ["asset-0", "asset-2"])
        XCTAssertEqual(vm.pendingDeletionBytes, 4_000_000)
        XCTAssertEqual(vm.sessionStats.deletedCount, 2)
        XCTAssertEqual(vm.sessionStats.deletedBytes, 4_000_000)
        XCTAssertEqual(vm.undoStack.map(\.asset.id), ["asset-0", "asset-2"])
    }

    func testApplyDeletionReviewCanClearEntirePendingBatch() throws {
        let vm = try makeViewModel()
        vm.swipeLeft()
        vm.swipeLeft()

        vm.unmarkPendingDeletion(id: "asset-0")
        vm.unmarkPendingDeletion(id: "asset-1")

        XCTAssertFalse(vm.hasPendingDeletions)
        XCTAssertEqual(vm.pendingDeletionBytes, 0)
        XCTAssertEqual(vm.sessionStats.deletedCount, 0)
    }

    func testAppNavigationTracksActiveSwipeSession() throws {
        let vm = try makeViewModel()
        let nav = AppNavigation()
        XCTAssertFalse(nav.isInSwipeSession)

        nav.setActiveSwipeSession(vm)
        XCTAssertTrue(nav.isInSwipeSession)

        nav.selectTabManually(.cleanup)
        XCTAssertFalse(nav.isInSwipeSession)
    }

    func testSimilarCheckedIdsExcludesKeeper() {
        let a = makeAsset(id: "a", fileSize: 1_000)
        let b = makeAsset(id: "b", fileSize: 2_000)
        let c = makeAsset(id: "c", fileSize: 3_000)
        let group = SimilarGroup(id: "g", assets: [a, b, c], bestAssetId: "a")
        let vm = SimilarPhotosViewModel()
        vm.groups = [group]
        vm.selectedForDeletion = ["a", "b"]

        XCTAssertEqual(vm.checkedIds(in: group), ["b"])
    }

    func testApplyDeletionReviewEmptyAndUnknownAreNoOps() throws {
        let vm = try makeViewModel()
        vm.swipeLeft() // asset-0: 1 MB
        vm.swipeLeft() // asset-1: 2 MB

        vm.applyDeletionReview(keeping: [])
        XCTAssertEqual(vm.pendingDeletionIds, ["asset-0", "asset-1"])
        XCTAssertEqual(vm.pendingDeletionBytes, 3_000_000)
        XCTAssertEqual(vm.sessionStats.deletedCount, 2)
        XCTAssertEqual(vm.sessionStats.deletedBytes, 3_000_000)

        vm.applyDeletionReview(keeping: ["unknown-id"])
        XCTAssertEqual(vm.pendingDeletionIds, ["asset-0", "asset-1"])
        XCTAssertEqual(vm.sessionStats.deletedCount, 2)
        XCTAssertGreaterThanOrEqual(vm.sessionStats.deletedBytes, 0)
    }

    func testFetchPendingDeletionAssetsFallsBackToFetchDetails() async throws {
        let vm = try makeViewModel(assetCount: 2)
        let fetchedRequests = LockedValue<[[String]]>([])
        let fallbackAsset = makeAsset(id: "evicted-1", fileSize: 5_000_000)
        vm.loadDetails = { ids in
            fetchedRequests.withValue { $0.append(ids) }
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, fallbackAsset) })
        }
        vm.pendingDeletionIds = ["evicted-1"]

        let resolved = await vm.fetchPendingDeletionAssets()
        XCTAssertEqual(resolved.map(\.id), ["evicted-1"])
        XCTAssertEqual(resolved.first?.fileSize, 5_000_000)
        XCTAssertEqual(fetchedRequests.withValue { $0 }, [["evicted-1"]])

        // Second call uses the populated cache without re-fetching.
        _ = await vm.fetchPendingDeletionAssets()
        XCTAssertEqual(fetchedRequests.withValue { $0.count }, 1)
    }

    func testSimilarDeleteGroupDeletesOnlyTargetAndPreservesOtherGroups() async {
        CleanupLedger.shared.detach()
        defer { CleanupLedger.shared.detach() }

        let g1 = SimilarGroup(
            id: "g1",
            assets: [makeAsset(id: "a", fileSize: 1_000), makeAsset(id: "b", fileSize: 2_000)],
            bestAssetId: "a"
        )
        let g2 = SimilarGroup(
            id: "g2",
            assets: [makeAsset(id: "c", fileSize: 3_000), makeAsset(id: "d", fileSize: 4_000)],
            bestAssetId: "c"
        )
        let vm = SimilarPhotosViewModel()
        vm.groups = [g1, g2]
        vm.selectedForDeletion = ["b", "d"]
        vm.performDelete = { ids in
            PhotoDeletionOutcome(deletedIds: Set(ids), alreadyAbsentIds: [])
        }

        await vm.delete(group: g1)

        XCTAssertEqual(vm.deletedCount, 1)
        XCTAssertEqual(vm.groups.map(\.id), ["g2"])
        XCTAssertEqual(vm.selectedForDeletion, ["d"])
        XCTAssertNil(vm.errorMessage)
    }

    func testSimilarDeleteGroupPreservesSelectionOnDeclineAndPartialDelete() async {
        CleanupLedger.shared.detach()
        defer { CleanupLedger.shared.detach() }

        let g1 = SimilarGroup(
            id: "g1",
            assets: [
                makeAsset(id: "a", fileSize: 1_000),
                makeAsset(id: "b", fileSize: 2_000),
                makeAsset(id: "e", fileSize: 2_500)
            ],
            bestAssetId: "a"
        )
        let g2 = SimilarGroup(
            id: "g2",
            assets: [makeAsset(id: "c", fileSize: 3_000), makeAsset(id: "d", fileSize: 4_000)],
            bestAssetId: "c"
        )
        let vm = SimilarPhotosViewModel()
        vm.groups = [g1, g2]
        vm.selectedForDeletion = ["b", "e", "d"]
        vm.performDelete = { _ in
            throw PhotoServiceError.userDeclined(alreadyAbsentIds: [])
        }

        await vm.delete(group: g1)
        XCTAssertEqual(vm.deletedCount, 0)
        XCTAssertEqual(vm.groups.count, 2)
        XCTAssertEqual(vm.selectedForDeletion, ["b", "e", "d"])

        vm.performDelete = { _ in
            throw PhotoServiceError.partialDeletion(succeededIds: ["b"], failedCount: 1)
        }
        await vm.delete(group: g1)
        XCTAssertEqual(vm.deletedCount, 1)
        XCTAssertEqual(vm.groups.first?.assets.map(\.id), ["a", "e"])
        XCTAssertEqual(vm.selectedForDeletion, ["e", "d"])
    }
}

