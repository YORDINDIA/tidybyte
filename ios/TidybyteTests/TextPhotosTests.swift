import XCTest
@testable import Tidybyte

/// Text Photos: what counts as "a lot of text", which photos are scanned, and
/// how the age choice narrows the results.
@MainActor
final class TextPhotosTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func asset(_ id: String, daysOld: Double?, size: Int64 = 1, screenshot: Bool = false, favorite: Bool = false) -> AssetSummary {
        AssetSummary(
            id: id, mediaType: .photo, creationDate: daysOld.map { now.addingTimeInterval(-$0 * day) },
            modificationDate: nil, pixelWidth: 100, pixelHeight: 100, duration: 0, fileSize: size,
            filename: "\(id).JPG", isFavorite: favorite, isBurst: false, burstIdentifier: nil,
            isLivePhoto: false, isScreenshot: screenshot, isLocallyAvailable: true
        )
    }

    func testTextHeavyNeedsALotOfText() {
        XCTAssertFalse(TextPhotoPolicy.isTextHeavy(TextAmount(characterCount: 11, lineCount: 1)), "A street sign")
        XCTAssertFalse(TextPhotoPolicy.isTextHeavy(TextAmount(characterCount: 39, lineCount: 6)), "A few labels")
        XCTAssertTrue(TextPhotoPolicy.isTextHeavy(TextAmount(characterCount: 40, lineCount: 4)), "A short ticket")
        XCTAssertTrue(TextPhotoPolicy.isTextHeavy(TextAmount(characterCount: 80, lineCount: 1)), "A dense line block")
        XCTAssertFalse(TextPhotoPolicy.isTextHeavy(TextAmount(characterCount: 500, lineCount: 20, succeeded: false)))
    }

    func testOnlyOldNonScreenshotNonFavoritePhotosAreScanned() {
        let cutoff = TextPhotoPolicy.scanAge.cutoff(from: now)
        XCTAssertTrue(TextPhotoPolicy.isCandidate(asset("old", daysOld: 15), cutoff: cutoff))
        XCTAssertTrue(TextPhotoPolicy.isCandidate(asset("edge", daysOld: 14), cutoff: cutoff))
        XCTAssertFalse(TextPhotoPolicy.isCandidate(asset("new", daysOld: 13), cutoff: cutoff))
        XCTAssertFalse(TextPhotoPolicy.isCandidate(asset("shot", daysOld: 90, screenshot: true), cutoff: cutoff))
        XCTAssertFalse(TextPhotoPolicy.isCandidate(asset("fav", daysOld: 90, favorite: true), cutoff: cutoff))
        XCTAssertFalse(TextPhotoPolicy.isCandidate(asset("undated", daysOld: nil), cutoff: cutoff))
    }

    func testAgeCutoffsGetOlder() {
        let cutoffs = TextPhotoAge.allCases.map { $0.cutoff(from: now) }
        XCTAssertEqual(cutoffs, cutoffs.sorted(by: >), "Each age choice reaches further back")
        XCTAssertEqual(TextPhotoAge.twoWeeks.cutoff(from: now).timeIntervalSince(now), -14 * day, accuracy: 3_600)
    }

    func testVisibleFiltersByAgeAndSortsOldestFirst() {
        let photos = [
            TextPhoto(id: "20d", asset: asset("20d", daysOld: 20, size: 5), characterCount: 100),
            TextPhoto(id: "400d", asset: asset("400d", daysOld: 400, size: 1), characterCount: 100),
            TextPhoto(id: "45d", asset: asset("45d", daysOld: 45, size: 9), characterCount: 100),
        ]
        func ids(_ age: TextPhotoAge, _ order: MediaSortOrder = .oldest) -> [String] {
            TextPhotosViewModel.visible(photos, age: age, now: now, order: order).map(\.id)
        }
        XCTAssertEqual(ids(.twoWeeks), ["400d", "45d", "20d"])
        XCTAssertEqual(ids(.oneMonth), ["400d", "45d"])
        XCTAssertEqual(ids(.threeMonths), ["400d"])
        XCTAssertEqual(ids(.oneYear), ["400d"])
        XCTAssertEqual(ids(.twoWeeks, .largest), ["45d", "20d", "400d"])
    }

    func testANarrowerAgeDropsHiddenPicks() {
        let viewModel = TextPhotosViewModel()
        viewModel.age = .twoWeeks
        // Real dates, because the view model filters against the time it was made.
        viewModel.photos = [
            TextPhoto(id: "recent", asset: AssetSummary(
                id: "recent", mediaType: .photo, creationDate: Date().addingTimeInterval(-20 * day),
                modificationDate: nil, pixelWidth: 1, pixelHeight: 1, duration: 0, fileSize: 1, filename: nil,
                isFavorite: false, isBurst: false, burstIdentifier: nil, isLivePhoto: false, isScreenshot: false,
                isLocallyAvailable: true), characterCount: 90),
            TextPhoto(id: "old", asset: AssetSummary(
                id: "old", mediaType: .photo, creationDate: Date().addingTimeInterval(-200 * day),
                modificationDate: nil, pixelWidth: 1, pixelHeight: 1, duration: 0, fileSize: 1, filename: nil,
                isFavorite: false, isBurst: false, burstIdentifier: nil, isLivePhoto: false, isScreenshot: false,
                isLocallyAvailable: true), characterCount: 90),
        ]
        viewModel.selectAll()
        XCTAssertEqual(viewModel.selectedIds, ["recent", "old"])

        viewModel.age = .threeMonths
        XCTAssertEqual(viewModel.visiblePhotos.map(\.id), ["old"])
        XCTAssertEqual(viewModel.selectedIds, ["old"], "A photo the filter hides must not stay selected for delete")
    }

    func testTextPhotosIsAReviewToolWithALedgerKind() {
        XCTAssertEqual(CleanupTool.textPhotos.category, .organize)
        XCTAssertEqual(CleanupActivityKind.textPhotos.tool, .textPhotos)
    }
}
