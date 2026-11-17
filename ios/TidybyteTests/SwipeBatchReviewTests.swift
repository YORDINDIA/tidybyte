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
}

