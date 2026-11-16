import XCTest
import SwiftData
@testable import Tidybyte

/// Regression tests for the ios-core scan. Each test pins one fix.
@MainActor
final class IOSCoreScanTests: XCTestCase {

    // Held for the lifetime of the test so the in-memory store stays valid.
    private var container: ModelContainer!

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    private func makeSession(pending: [String]) throws -> SwipeSessionViewModel {
        let schema = Schema([SwipeRecord.self, CompressionRecord.self, StorageSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = SwipeSessionViewModel(
            filter: .allMedia,
            photoService: PhotoLibraryService(),
            modelContext: container.mainContext
        )
        viewModel.assets = pending.map { makeAsset(id: $0) }
        viewModel.loadDetails = { _ in [:] }
        viewModel.pendingDeletionIds = pending
        return viewModel
    }

    private func makeAsset(id: String) -> AssetSummary {
        AssetSummary(
            id: id,
            mediaType: .photo,
            creationDate: .now,
            modificationDate: .now,
            pixelWidth: 4032,
            pixelHeight: 3024,
            duration: 0,
            fileSize: 8_000_000,
            filename: "\(id).jpg",
            isFavorite: false,
            isBurst: false,
            burstIdentifier: nil,
            isLivePhoto: false,
            isScreenshot: false,
            isLocallyAvailable: true
        )
    }

    // MARK: - CORE-01: a launch that needs a review switches to the hosting tab

    /// A session started on the Cleanup tab holds pending deletions. A Storage
    /// launch must bring the user to Cleanup, where the review is shown.
    func testSwipeLaunchWithPendingReviewSwitchesToTheHostingTab() throws {
        let navigation = AppNavigation()
        navigation.selectedTab = .cleanup
        let session = try makeSession(pending: ["asset-0"])
        navigation.setActiveSwipeSession(session)
        navigation.selectedTab = .storage

        navigation.showSwipeSession(filter: .allMedia)

        XCTAssertEqual(navigation.selectedTab, .cleanup)
        XCTAssertTrue(session.deletionReviewRequested)
        XCTAssertNotNil(navigation.consumePendingSwipeFilter(), "the launch stays queued behind the review")
    }

    // MARK: - CORE-02: opening Activity must not dismiss or review a session

    func testShowActivityDoesNotRequestSwipeDismissal() {
        let navigation = AppNavigation()
        let before = navigation.swipeDismissRequestID

        navigation.showActivity()

        XCTAssertEqual(navigation.selectedTab, .storage)
        XCTAssertEqual(navigation.storagePath, [.activity])
        XCTAssertEqual(navigation.swipeDismissRequestID, before)
    }

    // MARK: - CORE-05: a resize never restarts a load that is in flight

    func testShouldReloadIsFalseWhileAnImageIsLoading() {
        let shown = CGSize(width: 800, height: 1000)
        let resized = CGSize(width: 1200, height: 1500)

        XCTAssertTrue(CardImageRequest.shouldReload(
            currentTarget: resized, lastRequestedTarget: shown, hasImage: true
        ))
        XCTAssertFalse(CardImageRequest.shouldReload(
            currentTarget: resized, lastRequestedTarget: shown, hasImage: true, isLoading: true
        ))
    }
}
