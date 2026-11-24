import XCTest
import SwiftData
@testable import Tidybyte

/// Saved swipe decks: decisions survive a quit, a keep beats a delete mark in
/// another deck, and Reduce Swipe Motion only changes the drawing.
@MainActor
final class SavedSwipeSessionTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([SwipeRecord.self, SwipeDeckEntry.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    private var context: ModelContext { container.mainContext }

    private func decisions(_ deckKey: String) -> [String: SwipeDeckDecision] {
        SwipeDeckStore.decisions(deckKey: deckKey, context: context).reduce(into: [:]) {
            $0[$1.assetLocalIdentifier] = $1.deckDecision
        }
    }

    // MARK: - Store

    func testRecordReplacesTheEarlierDecisionInTheSameDeck() {
        SwipeDeckStore.record(.skip, assetId: "a", deckKey: "allMedia", context: context)
        SwipeDeckStore.record(.keep, assetId: "a", deckKey: "allMedia", context: context)
        XCTAssertEqual(decisions("allMedia"), ["a": .keep])
    }

    /// A photo kept anywhere must never be deleted from a deck left for later.
    func testAKeepClearsDeleteMarksInOtherDecks() {
        SwipeDeckStore.record(.marked, assetId: "a", deckKey: "blurry", context: context)
        SwipeDeckStore.record(.marked, assetId: "a", deckKey: "allMedia", context: context)
        XCTAssertEqual(SwipeDeckStore.markedCounts(context: context), ["blurry": 1, "allMedia": 1])

        SwipeDeckStore.record(.keep, assetId: "a", deckKey: "notSwipedYet", context: context)

        XCTAssertEqual(SwipeDeckStore.markedCounts(context: context), [:])
        XCTAssertEqual(decisions("notSwipedYet"), ["a": .keep])
    }

    func testAMarkLeavesOtherDecksAlone() {
        SwipeDeckStore.record(.keep, assetId: "a", deckKey: "allMedia", context: context)
        SwipeDeckStore.record(.marked, assetId: "a", deckKey: "blurry", context: context)
        XCTAssertEqual(decisions("allMedia"), ["a": .keep])
        XCTAssertEqual(decisions("blurry"), ["a": .marked])
    }

    func testRemoveByKindKeepsTheOtherKinds() {
        SwipeDeckStore.record(.keep, assetId: "a", deckKey: "d", context: context)
        SwipeDeckStore.record(.marked, assetId: "b", deckKey: "d", context: context)
        SwipeDeckStore.remove([.keep, .skip, .album], deckKey: "d", context: context)
        XCTAssertEqual(decisions("d"), ["b": .marked])
    }

    // MARK: - Deck keys

    func testDeckKeys() {
        XCTAssertEqual(SwipeFilter.allMedia.deckKey, "allMedia")
        XCTAssertEqual(SwipeFilter.specificAlbum(id: "x").deckKey, "album.x")
        XCTAssertNil(SwipeFilter.customAssetIds(["a"]).deckKey, "a tool or Storage row names its own deck")
        let morning = Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 5, hour: 8))!
        let evening = Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 5, hour: 21))!
        XCTAssertEqual(SwipeFilter.allMediaBefore(date: morning).deckKey, "allMediaBefore.2024-03-05")
        XCTAssertEqual(SwipeFilter.allMediaBefore(date: morning).deckKey, SwipeFilter.allMediaBefore(date: evening).deckKey)
        XCTAssertEqual(SwipeSessionRoute(filter: .customAssetIds(["a"]), deckKey: "blurry").deckKey, "blurry")
        XCTAssertEqual(SwipeSessionRoute(filter: .screenshots).deckKey, "screenshots")
    }

    // MARK: - Session

    private func makeSession(deckKey: String? = "allMedia", assetCount: Int = 3) -> SwipeSessionViewModel {
        let viewModel = SwipeSessionViewModel(
            filter: .allMedia,
            deckKey: deckKey,
            photoService: PhotoLibraryService(),
            modelContext: context
        )
        viewModel.assets = (0..<assetCount).map { makeAsset(id: "asset-\($0)") }
        viewModel.loadDetails = { _ in [:] }
        return viewModel
    }

    func testEveryDecisionIsSavedAndUndoRemovesIt() async {
        let session = makeSession()
        session.swipeLeft()
        session.swipeRight()
        session.skip()
        XCTAssertEqual(decisions("allMedia"), ["asset-0": .marked, "asset-1": .keep, "asset-2": .skip])

        await session.undo()
        XCTAssertEqual(decisions("allMedia"), ["asset-0": .marked, "asset-1": .keep])
    }

    func testKeepAllItemsUnmarksTheSavedMarks() {
        let session = makeSession()
        session.swipeLeft()
        session.discardPendingDeletions()
        XCTAssertEqual(decisions("allMedia"), [:])
    }

    func testAnUnsavedDeckWritesNothing() {
        let session = makeSession(deckKey: nil)
        session.swipeLeft()
        session.swipeRight()
        XCTAssertTrue(SwipeDeckStore.decisions(deckKey: "allMedia", context: context).isEmpty)
    }

    /// "Keep for Later" ends the need to decide, but only for a saved deck.
    func testKeepForLaterReleasesASavedDeckOnly() {
        let saved = makeSession()
        saved.swipeLeft()
        XCTAssertTrue(saved.needsDeletionDecision)
        saved.keepMarksForLater()
        XCTAssertFalse(saved.needsDeletionDecision)
        XCTAssertTrue(saved.hasPendingDeletions, "the marks stay")
        saved.swipeLeft()
        XCTAssertTrue(saved.needsDeletionDecision, "a new mark asks again")

        let unsaved = makeSession(deckKey: nil)
        unsaved.swipeLeft()
        unsaved.keepMarksForLater()
        XCTAssertTrue(unsaved.needsDeletionDecision, "an unsaved deck would lose its marks")
    }

    func testAFinishedSavedDeckCanStartOver() {
        let session = makeSession(assetCount: 1)
        XCTAssertFalse(session.canStartOver)
        session.swipeRight()
        XCTAssertTrue(session.canStartOver)
        XCTAssertFalse(makeSession(deckKey: nil, assetCount: 0).canStartOver)
    }

    func testUndecidedDeckDropsDecidedPhotos() {
        let deck = ["a", "b", "c"].map(makeAsset)
        XCTAssertEqual(SwipeSessionViewModel.undecidedDeck(deck, decided: ["b"]).map(\.id), ["a", "c"])
        XCTAssertEqual(SwipeSessionViewModel.undecidedDeck(deck, decided: []).map(\.id), ["a", "b", "c"])
    }

    // MARK: - Live Photo review

    func testLivePhotoReviewResumesAfterSavedDecisions() {
        let deck = LivePhotoReviewDeck(ids: ["a", "b", "c", "d"], startingAt: "c", saved: ["b": true, "gone": true])
        XCTAssertEqual(deck.ids, ["b", "c", "d", "a"], "decided photos first, then the tapped one")
        XCTAssertEqual(deck.current, "c")
        XCTAssertEqual(deck.markedIds, ["b"])
        XCTAssertEqual(deck.decisions, ["b": true], "a photo no longer listed is dropped")
        XCTAssertTrue(deck.canUndo, "a saved decision can be taken back")
    }

    func testLivePhotoReviewWithEverythingDecidedIsFinished() {
        let deck = LivePhotoReviewDeck(ids: ["a", "b"], saved: ["a": false, "b": true])
        XCTAssertTrue(deck.isFinished)
        XCTAssertEqual(deck.markedIds, ["b"])
    }

    // MARK: - Reduce Swipe Motion

    func testReducedMotionDrawsAQuarterOfTheDragWithNoTilt() {
        let drag = CGSize(width: 200, height: -40)
        let full = SwipeMotionStyle.drawn(drag, reduced: false)
        XCTAssertEqual(full.offset, drag)
        XCTAssertEqual(full.degrees, 10)
        let reduced = SwipeMotionStyle.drawn(drag, reduced: true)
        XCTAssertEqual(reduced.offset, CGSize(width: 50, height: -10))
        XCTAssertEqual(reduced.degrees, 0)
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
}
