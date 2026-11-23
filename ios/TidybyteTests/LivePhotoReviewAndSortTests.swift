import XCTest
@testable import Tidybyte

/// Live Photo swipe review (one batch, one iOS prompt) and the sort orders
/// shared by the Cleanup tools and the Swipe tab's Largest First deck.
@MainActor
final class LivePhotoReviewAndSortTests: XCTestCase {

    private func asset(
        _ id: String,
        size: Int64 = 0,
        taken: TimeInterval? = nil,
        duration: TimeInterval = 0,
        burst: String? = nil
    ) -> AssetSummary {
        AssetSummary(
            id: id, mediaType: duration > 0 ? .video : .photo,
            creationDate: taken.map { Date(timeIntervalSince1970: $0) },
            modificationDate: nil, pixelWidth: 100, pixelHeight: 100, duration: duration, fileSize: size,
            filename: "\(id).HEIC", isFavorite: false, isBurst: burst != nil, burstIdentifier: burst,
            isLivePhoto: true, isScreenshot: false, isLocallyAvailable: true
        )
    }

    // MARK: - Review deck

    func testDeckStartsAtTheTappedPhotoAndWrapsAround() {
        let deck = LivePhotoReviewDeck(ids: ["a", "b", "c", "d"], startingAt: "c")
        XCTAssertEqual(deck.ids, ["c", "d", "a", "b"])
        XCTAssertEqual(deck.current, "c")
        XCTAssertEqual(LivePhotoReviewDeck(ids: ["a", "b"], startingAt: "gone").ids, ["a", "b"])
    }

    func testDecisionsUndoAndToggle() {
        var deck = LivePhotoReviewDeck(ids: ["a", "b", "c"])
        deck.decide(convert: true)
        deck.decide(convert: false)
        XCTAssertEqual(deck.markedIds, ["a"])
        XCTAssertEqual(deck.current, "c")

        deck.undo()
        XCTAssertEqual(deck.current, "b")
        XCTAssertNil(deck.decisions["b"], "Undo forgets the decision it takes back")

        deck.decide(convert: true)
        deck.decide(convert: true)
        XCTAssertTrue(deck.isFinished)
        XCTAssertNil(deck.current)
        XCTAssertEqual(deck.markedIds, ["a", "b", "c"])

        deck.decide(convert: false) // finished: no-op
        XCTAssertEqual(deck.markedIds, ["a", "b", "c"])

        deck.toggle("b")
        XCTAssertEqual(deck.markedIds, ["a", "c"], "Unchecking in the review leaves the photo a Live Photo")
        deck.toggle("b")
        XCTAssertEqual(deck.markedIds, ["a", "b", "c"])
        deck.toggle("never-decided")
        XCTAssertNil(deck.decisions["never-decided"])
    }

    func testUndoAtTheStartDoesNothing() {
        var deck = LivePhotoReviewDeck(ids: ["a"])
        deck.undo()
        XCTAssertEqual(deck.current, "a")
        XCTAssertFalse(deck.canUndo)
    }

    // MARK: - Batch scope

    func testEligibleIdsAreConvertibleRowsInListOrderNarrowedToTheReview() {
        var items = ["a", "b", "c", "d"].map { LivePhotoItem(id: $0, asset: asset($0)) }
        items[1].conversionState = .completed
        items[3].conversionState = .failed("x")

        XCTAssertEqual(LivePhotosConverterViewModel.eligibleIds(items: items, accepted: nil), ["a", "c", "d"],
                       "A failed row is retried: its Live Photo was never deleted")
        XCTAssertEqual(LivePhotosConverterViewModel.eligibleIds(items: items, accepted: ["c", "b", "zz"]), ["c"])
        XCTAssertEqual(LivePhotosConverterViewModel.eligibleIds(items: items, accepted: []), [])
    }

    // MARK: - Media sort

    func testMediaSortOrders() {
        let items = [
            asset("a", size: 5, taken: 200, duration: 3),
            asset("b", size: 0, taken: nil, duration: 0),
            asset("c", size: 9, taken: 100, duration: 30),
            asset("d", size: 5, taken: 300, duration: 0),
        ]
        func ids(_ order: MediaSortOrder) -> [String] { order.sorted(items) { $0 }.map(\.id) }

        XCTAssertEqual(ids(.largest), ["c", "a", "d", "b"], "Unknown size last; equal sizes keep their order")
        XCTAssertEqual(ids(.newest), ["d", "a", "c", "b"])
        XCTAssertEqual(ids(.oldest), ["b", "c", "a", "d"])
        XCTAssertEqual(ids(.longest), ["c", "a", "d", "b"], "Equal lengths (photos) fall back to size")
        XCTAssertEqual(MediaAssetFilter.apply(from: items, mediaFilter: .videos, sortOrder: .largest).map(\.id), ["c", "a"])
    }

    // MARK: - Group sort

    func testGroupSortOrders() {
        let groups: [[AssetSummary]] = [
            [asset("g1a", size: 1, taken: 100), asset("g1b", size: 1, taken: 500)],
            [asset("g2a", size: 50, taken: 300), asset("g2b", size: 50, taken: 50), asset("g2c", size: 0, taken: 200)],
            [asset("g3a", size: 70, taken: 400)],
        ]
        func firstIds(_ order: GroupSortOrder) -> [String] {
            order.sorted(groups) { $0 }.map { $0[0].id }
        }
        XCTAssertEqual(firstIds(.mostItems), ["g2a", "g1a", "g3a"])
        XCTAssertEqual(firstIds(.largest), ["g2a", "g3a", "g1a"])
        XCTAssertEqual(firstIds(.newest), ["g1a", "g3a", "g2a"])
        XCTAssertEqual(firstIds(.oldest), ["g2a", "g1a", "g3a"])
    }

    func testUndatedGroupsSortAsOldest() {
        let groups: [[AssetSummary]] = [
            [asset("dated", taken: 100)],
            [asset("undated", taken: nil)],
        ]
        func firstIds(_ order: GroupSortOrder) -> [String] { order.sorted(groups) { $0 }.map { $0[0].id } }
        XCTAssertEqual(firstIds(.oldest), ["undated", "dated"], "No date counts as the distant past, as in MediaSortOrder")
        XCTAssertEqual(firstIds(.newest), ["dated", "undated"])
    }

    func testLongestIsOfferedOnlyWhenVideosCanBeListed() {
        XCTAssertTrue(MediaSortOrder.options(includingVideos: true).contains(.longest))
        XCTAssertFalse(MediaSortOrder.options(includingVideos: false).contains(.longest))
    }

    func testDuplicateSortKeepsExactGroupsFirst() {
        let viewModel = DuplicateFinderViewModel()
        viewModel.scanType = .all
        viewModel.exactGroups = [DuplicateGroup(id: "e2", assets: [asset("a"), asset("b")], bestAssetId: "a", type: .exact)]
        viewModel.visualGroups = [
            DuplicateGroup(id: "v3", assets: [asset("c"), asset("d"), asset("e")], bestAssetId: "c", type: .visual),
            DuplicateGroup(id: "v4", assets: [asset("f"), asset("g"), asset("h"), asset("i")], bestAssetId: "f", type: .visual),
        ]
        XCTAssertEqual(viewModel.sortedGroups.map(\.id), ["e2", "v4", "v3"], "Sorted inside each type, exact first")
    }

    // MARK: - Swipe tab: Largest First

    func testLargestFirstDeckDropsSwipedItemsAndCollapsesBursts() {
        let all = [
            asset("small", size: 10),
            asset("swiped", size: 999),
            asset("big", size: 500),
            asset("burst1", size: 300, burst: "B"),
            asset("burst2", size: 200, burst: "B"),
            asset("unknown", size: 0),
        ]
        let deck = SwipeSessionViewModel.largestFirstDeck(all, swipedIds: ["swiped"])
        XCTAssertEqual(deck.map(\.id), ["big", "burst1", "small", "unknown"])
    }
}
