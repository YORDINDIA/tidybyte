import XCTest
@testable import Tidybyte

// MARK: - counted keys resolve per language

final class CountedKeyResolutionTests: XCTestCase {

    /// Foundation wraps inserted arguments in bidi isolation marks for
    /// right-to-left text. They are invisible and not part of the copy.
    private func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2068}", with: "").replacingOccurrences(of: "\u{2069}", with: "")
    }

    /// Each counted form must follow the app language's plural rules, not the
    /// device locale (the simulator is en_US).
    func testFailedDeleteResolvesPerAppLanguage() {
        let key = "Failed to delete %lld photo: %@"
        let fallback = "Failed to delete %lld photos: %@"
        XCTAssertEqual(
            visible(L10n.format(key, language: .english, fallback: fallback, 1, "x")),
            "Failed to delete 1 photo: x"
        )
        XCTAssertEqual(
            visible(L10n.format(key, language: .english, fallback: fallback, 5, "x")),
            "Failed to delete 5 photos: x"
        )
        XCTAssertEqual(
            visible(L10n.format(key, language: .russian, fallback: fallback, 1, "x")),
            "Не удалось удалить 1 фотографию: x"
        )
        XCTAssertEqual(
            visible(L10n.format(key, language: .russian, fallback: fallback, 5, "x")),
            "Не удалось удалить 5 фотографий: x"
        )
        XCTAssertEqual(visible(L10n.format(key, language: .arabic, fallback: fallback, 1, "x")), "تعذّر حذف 1 صورة: x")
        XCTAssertEqual(visible(L10n.format(key, language: .arabic, fallback: fallback, 5, "x")), "تعذّر حذف 5 صور: x")
    }

    func testUpdatedDayAgoResolvesPerAppLanguage() {
        let key = "Updated %lld day ago"
        let fallback = "Updated %lld days ago"
        XCTAssertEqual(L10n.format(key, language: .english, fallback: fallback, 1), "Updated 1 day ago")
        XCTAssertEqual(L10n.format(key, language: .english, fallback: fallback, 5), "Updated 5 days ago")
        XCTAssertEqual(L10n.format(key, language: .russian, fallback: fallback, 5), "Обновлено 5 дней назад")
    }

    /// Digits in `%lld` stay ASCII in every language, as before this change.
    func testCountDigitsStayASCIIInArabic() {
        let text = visible(L10n.format("Failed to delete %lld photo: %@", language: .arabic, fallback: "x", 5, "x"))
        XCTAssertTrue(text.contains("5"))
        XCTAssertFalse(text.contains("٥"))
    }
}

/// Pruning treats an empty `existingIds` as "every asset deleted". Without library
/// access that answer is not real, so the groups must stay.
@MainActor
final class PruneNeedsLibraryAccessTests: XCTestCase {

    func testDuplicatesKeepGroupsWithoutLibraryAccess() async {
        let viewModel = DuplicateFinderViewModel()
        viewModel.exactGroups = [DuplicateGroup(
            id: "g1",
            assets: [makeTestAsset(id: "dup-a"), makeTestAsset(id: "dup-b")],
            bestAssetId: "dup-a",
            type: .exact
        )]
        viewModel.scanState = .completed
        await viewModel.pruneDeleted(authorization: .denied)
        XCTAssertEqual(viewModel.exactGroups.count, 1)
        await viewModel.pruneDeleted(authorization: .notDetermined)
        XCTAssertEqual(viewModel.exactGroups.count, 1)
    }

    func testSimilarKeepsGroupsWithoutLibraryAccess() async {
        let viewModel = SimilarPhotosViewModel()
        viewModel.groups = [SimilarGroup(
            id: "s1",
            assets: [makeTestAsset(id: "sim-a"), makeTestAsset(id: "sim-b")],
            bestAssetId: "sim-a"
        )]
        viewModel.scanState = .completed
        await viewModel.pruneDeleted(authorization: .restricted)
        XCTAssertEqual(viewModel.groups.count, 1)
    }
}

// MARK: - Share shortfall (LargeFiles)

@MainActor
final class ShareShortfallTests: XCTestCase {

    func testNoShortfallWhenEveryItemCameBack() {
        XCTAssertNil(LargeFilesViewModel.shareShortfallMessage(requested: 5, returned: 5))
    }

    func testShortfallNamesHowManyFailed() {
        XCTAssertEqual(
            LargeFilesViewModel.shareShortfallMessage(requested: 5, returned: 3),
            "2 of 5 items couldn't be prepared to share."
        )
    }

    func testOneItemFailingIsNamedAsOne() {
        XCTAssertEqual(
            LargeFilesViewModel.shareShortfallMessage(requested: 3, returned: 2),
            "1 of 3 items couldn't be prepared to share."
        )
    }
}

// MARK: - Saved-from-app markers

final class SavedFromAppMarkerTests: XCTestCase {

    /// `INSTA_` keeps INSTANT and INSTALL out. `INSTAGRAM` must still match its own name.
    func testInstagramBothPrefixesMatch() {
        XCTAssertTrue(SavedFromAppMarkers.matches(filename: "INSTAGRAM_20240101.JPG"))
        XCTAssertTrue(SavedFromAppMarkers.matches(filename: "INSTA_1704067200000.JPG"))
        XCTAssertTrue(SavedFromAppMarkers.matches(filename: "instagram-export-1.jpg"))
        XCTAssertFalse(SavedFromAppMarkers.matches(filename: "INSTANT_1.JPG"))
        XCTAssertFalse(SavedFromAppMarkers.matches(filename: "INSTALL_1.JPG"))
    }

    /// The WhatsApp rule is not in `all`, so the list hygiene tests never see it.
    /// These direct checks cover it.
    func testWhatsAppRuleIsCheckedDirectly() {
        XCTAssertTrue(SavedFromAppMarkers.hasWhatsAppMarker("IMG-20240101-WA0001.JPG"))
        XCTAssertTrue(SavedFromAppMarkers.hasWhatsAppMarker("VID-20240101-WA0002.MP4"))
        XCTAssertFalse(SavedFromAppMarkers.hasWhatsAppMarker("PHOTO-WALL.JPG"))
        XCTAssertFalse(SavedFromAppMarkers.hasWhatsAppMarker("PHOTO-WA.JPG"))
        XCTAssertFalse(SavedFromAppMarkers.all.contains { $0.contains("-WA") })
    }

    func testMarkersDoNotMatchInsideOrdinaryWords() {
        for name in ["INSTANT_1.JPG", "INSTALL.JPG", "SIGNALS_1.JPG", "PHOTO-WALL.JPG", "PHOTO-WA.JPG"] {
            XCTAssertFalse(SavedFromAppMarkers.matches(filename: name), name)
        }
    }

    func testMarkersStillMatchRealExportNames() {
        for name in ["IMG-20240101-WA0001.JPG", "VID-20240101-WA0002.MP4", "INSTA_1704067200000.JPG",
                     "signal-2024-01-01-120000.jpg", "LINE_ALBUM_1.JPG"] {
            XCTAssertTrue(SavedFromAppMarkers.matches(filename: name), name)
        }
    }
}
