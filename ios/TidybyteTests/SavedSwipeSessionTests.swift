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
        XCTAssertEqual(SwipeDeckStore.markedByDeck(context: context), ["blurry": ["a"], "allMedia": ["a"]])

        SwipeDeckStore.record(.keep, assetId: "a", deckKey: "notSwipedYet", context: context)

        XCTAssertEqual(SwipeDeckStore.markedByDeck(context: context), [:])
        XCTAssertEqual(decisions("notSwipedYet"), ["a": .keep])
    }

    func testAMarkLeavesOtherDecksAlone() {
        SwipeDeckStore.record(.keep, assetId: "a", deckKey: "allMedia", context: context)
        SwipeDeckStore.record(.marked, assetId: "a", deckKey: "blurry", context: context)
        XCTAssertEqual(decisions("allMedia"), ["a": .keep])
        XCTAssertEqual(decisions("blurry"), ["a": .marked])
    }

    /// A photo that left the library leaves every deck.
    func testRemoveEverywhere() {
        SwipeDeckStore.record(.marked, assetId: "a", deckKey: "d1", context: context)
        SwipeDeckStore.record(.keep, assetId: "a", deckKey: "d2", context: context)
        SwipeDeckStore.record(.keep, assetId: "b", deckKey: "d2", context: context)
        SwipeDeckStore.removeEverywhere(assetIds: ["a"], context: context)
        XCTAssertEqual(decisions("d1"), [:])
        XCTAssertEqual(decisions("d2"), ["b": .keep])
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

    /// Reopening a saved deck brings its delete marks back as pending, with
    /// the tally rebuilt from the saved decisions.
    func testReopeningASavedDeckRestoresItsMarks() async {
        SwipeDeckStore.record(.marked, assetId: "asset-0", deckKey: "allMedia", context: context)
        SwipeDeckStore.record(.keep, assetId: "asset-1", deckKey: "allMedia", context: context)
        let reopened = SwipeSessionViewModel(filter: .allMedia, deckKey: "allMedia", photoService: PhotoLibraryService(), modelContext: context)
        let marked = makeAsset(id: "asset-0")
        reopened.loadDetails = { ids in ids.contains("asset-0") ? ["asset-0": marked] : [:] }

        await reopened.loadAssetsIfNeeded()

        XCTAssertEqual(reopened.pendingDeletionIds, ["asset-0"])
        XCTAssertEqual(reopened.pendingDeletionBytes, 8_000_000)
        XCTAssertEqual(reopened.sessionStats.keptCount, 1)
        XCTAssertTrue(reopened.needsDeletionDecision)
    }

    /// A keep in another deck clears the mark in the store; the deck that still
    /// holds it in memory must not delete it.
    func testCommitSkipsAPhotoKeptInAnotherDeck() async {
        let session = makeSession()
        session.swipeLeft()
        SwipeDeckStore.record(.keep, assetId: "asset-0", deckKey: "blurry", context: context)

        await session.commitDeletions()

        XCTAssertTrue(session.pendingDeletionIds.isEmpty)
        XCTAssertFalse(session.deletionCommitted, "nothing was sent to Photos")
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
        XCTAssertFalse(deck.canUndo, "undo does not reach past a quit")
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
