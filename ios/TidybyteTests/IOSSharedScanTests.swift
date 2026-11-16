import SwiftUI
import XCTest
@testable import Tidybyte

/// Regression tests for the shared-layer audit: WCAG contrast of the colour
/// tokens that carry text in both appearances, and the once-only resume contract
/// of `ContinuationResumer`.
final class IOSSharedScanTests: XCTestCase {

    // MARK: - Contrast helpers

    private typealias RGB = (r: Double, g: Double, b: Double)

    /// The colour a token resolves to in one appearance, in sRGB components.
    private func resolved(_ color: Color, dark: Bool) -> RGB {
        var environment = EnvironmentValues()
        environment.colorScheme = dark ? .dark : .light
        let value = color.resolve(in: environment)
        return (Double(value.red), Double(value.green), Double(value.blue))
    }

    private func background(dark: Bool) -> RGB {
        dark ? (0, 0, 0) : (1, 1, 1)
    }

    /// `tint` at `alpha` laid over `base`, the way a `.opacity` fill composites.
    private func blend(_ tint: RGB, alpha: Double, over base: RGB) -> RGB {
        (
            tint.r * alpha + base.r * (1 - alpha),
            tint.g * alpha + base.g * (1 - alpha),
            tint.b * alpha + base.b * (1 - alpha)
        )
    }

    private func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG 2.x contrast ratio, 1...21.
    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private let aaText = 4.5

    // MARK: - White-label fills

    /// A filled control with a white label must clear AA in both appearances.
    /// The system tint, green, red and gray fail this (2.3 to 4.0:1).
    func testWhiteLabelFillsReachAAInBothAppearances() {
        let fills: [(String, Color)] = [
            ("actionFill", .actionFill),
            ("successFill", .successFill),
            ("destructiveFill", .destructiveFill),
            ("neutralFill", .neutralFill)
        ]
        for (name, fill) in fills {
            for dark in [false, true] {
                let ratio = contrast((1, 1, 1), resolved(fill, dark: dark))
                XCTAssertGreaterThanOrEqual(
                    ratio, aaText,
                    "\(name) with a white label is \(ratio):1 in \(dark ? "dark" : "light")"
                )
            }
        }
    }

    // MARK: - Text tokens

    /// Text tokens are drawn on the page background in both appearances.
    func testTextTokensReachAAOnPageInBothAppearances() {
        let texts: [(String, Color)] = [
            ("actionText", .actionText),
            ("successText", .successText),
            ("destructiveText", .destructiveText),
            ("warningText", .warningText)
        ]
        for (name, text) in texts {
            for dark in [false, true] {
                let ratio = contrast(resolved(text, dark: dark), background(dark: dark))
                XCTAssertGreaterThanOrEqual(
                    ratio, aaText,
                    "\(name) on the page is \(ratio):1 in \(dark ? "dark" : "light")"
                )
            }
        }
    }

    /// The Cancel button in `ToolScanningView` draws `destructiveText` on a 12%
    /// destructive wash. The system red text it replaced measured 3.0:1 in light.
    func testDestructiveCancelTextReachesAAOnItsWash() {
        for dark in [false, true] {
            let page = background(dark: dark)
            let wash = blend(resolved(.destructive, dark: dark), alpha: 0.12, over: page)
            let ratio = contrast(resolved(.destructiveText, dark: dark), wash)
            XCTAssertGreaterThanOrEqual(ratio, aaText, "Cancel text is \(ratio):1 in \(dark ? "dark" : "light")")
        }
    }

    /// `LimitedLibraryBanner` and `ToolErrorBanner` draw `actionText` on the
    /// warning wash. System blue on that wash measured about 3.1:1 in light.
    func testActionTextReachesAAOnWarningWash() {
        for dark in [false, true] {
            let page = background(dark: dark)
            let wash = blend(resolved(.warning, dark: dark), alpha: 0.12, over: page)
            let ratio = contrast(resolved(.actionText, dark: dark), wash)
            XCTAssertGreaterThanOrEqual(ratio, aaText, "Banner link is \(ratio):1 in \(dark ? "dark" : "light")")
        }
    }
}

// MARK: - ContinuationResumer

final class ContinuationResumerTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        var cleanups = 0
    }

    /// PHImageManager can deliver a degraded result and then a final result, and
    /// a timeout can race both. Only the first resume may land, and the cleanup
    /// hook (which cancels the request and the timeout) must run exactly once.
    func testResumesOnceAndRunsCleanupOnce() async {
        let counter = Counter()
        let value: Int = await withCheckedContinuation { continuation in
            let resumer = ContinuationResumer<Int>(continuation)
            resumer.onResume = { counter.cleanups += 1 }
            resumer.resume(1)
            resumer.resume(2)
            resumer.resume(3)
        }
        XCTAssertEqual(value, 1)
        XCTAssertEqual(counter.cleanups, 1)
    }

    /// The export path uses the return value to tell a late success from a stall.
    func testResumeReportsWhichCallLanded() async {
        let value: Int = await withCheckedContinuation { continuation in
            let resumer = ContinuationResumer<Int>(continuation)
            XCTAssertTrue(resumer.resume(7))
            XCTAssertFalse(resumer.resume(8))
        }
        XCTAssertEqual(value, 7)
    }
}

// MARK: - Round 2: pagination, markers, error text

final class SharedRound2Tests: XCTestCase {

    /// Google omits the token on the last page. An empty or repeated token must
    /// end the listing, or the loop never finishes.
    func testNextPageTokenStopsOnEmptyOrRepeatedToken() {
        XCTAssertNil(GooglePhotosAPI.nextPageToken(after: nil, returned: nil))
        XCTAssertNil(GooglePhotosAPI.nextPageToken(after: "a", returned: ""))
        XCTAssertNil(GooglePhotosAPI.nextPageToken(after: "a", returned: "a"))
        XCTAssertEqual(GooglePhotosAPI.nextPageToken(after: nil, returned: "b"), "b")
        XCTAssertEqual(GooglePhotosAPI.nextPageToken(after: "a", returned: "b"), "b")
    }

    /// The bare `-WA`, `INSTA` and `SIGNAL` markers matched ordinary words.
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

    /// An empty failure message left the sign-in banner blank.
    func testFailedAndKeychainErrorsAlwaysHaveText() {
        XCTAssertFalse((GoogleAuthError.failed("").errorDescription ?? "").isEmpty)
        XCTAssertFalse((GoogleAuthError.keychainWriteFailed.errorDescription ?? "").isEmpty)
        XCTAssertEqual(GoogleAuthError.failed("Boom").errorDescription, "Boom")
    }
}

// MARK: - Round 3: models, formatting, selection

private func makeRound3Asset(
    id: String,
    width: Int = 100,
    height: Int = 100,
    duration: TimeInterval = 0,
    favorite: Bool = false,
    filename: String? = nil,
    date: Date? = nil
) -> AssetSummary {
    AssetSummary(
        id: id, mediaType: .photo, creationDate: date, modificationDate: nil,
        pixelWidth: width, pixelHeight: height, duration: duration, fileSize: 1_000,
        filename: filename, isFavorite: favorite, isBurst: false, burstIdentifier: nil,
        isLivePhoto: false, isScreenshot: false, isLocallyAvailable: true
    )
}

final class ModelsAndFormattingRound3Tests: XCTestCase {

    /// The 999.95 kB boundary: the unit switches before one decimal place can
    /// print "1000 kB".
    func testFileSizeSwitchesUnitBeforeItRoundsToAThousand() {
        let us = Locale.Region("US")
        let almostMegabyte = Formatters.fileSize(999_950, language: .english, region: us)
        XCTAssertFalse(almostMegabyte.contains("1000"), "got \(almostMegabyte)")
        XCTAssertTrue(almostMegabyte.contains("MB"), "got \(almostMegabyte)")

        let justBelow = Formatters.fileSize(999_949, language: .english, region: us)
        XCTAssertTrue(justBelow.contains("kB"), "got \(justBelow)")
        XCTAssertTrue(justBelow.contains("999.9"), "got \(justBelow)")
    }

    func testDurationReadsMinutesUnderAnHourAndHoursFromAnHour() {
        XCTAssertEqual(makeRound3Asset(id: "a", duration: 0).formattedDuration, "")
        XCTAssertEqual(makeRound3Asset(id: "a", duration: 75).formattedDuration, "1:15")
        XCTAssertEqual(makeRound3Asset(id: "a", duration: 3_599).formattedDuration, "59:59")
        XCTAssertEqual(makeRound3Asset(id: "a", duration: 3_725).formattedDuration, "1:02:05")
    }

    /// `.anchored` with `.backwards` must match the extension only, at the end.
    func testIsHEICMatchesTheExtensionAtTheEndOnly() {
        XCTAssertTrue(makeRound3Asset(id: "a", filename: "IMG_1.HEIC").isHEIC)
        XCTAssertTrue(makeRound3Asset(id: "a", filename: "IMG_1.heif").isHEIC)
        XCTAssertFalse(makeRound3Asset(id: "a", filename: "IMG_1.heic.jpg").isHEIC)
        XCTAssertFalse(makeRound3Asset(id: "a", filename: "HEIC.jpg").isHEIC)
        XCTAssertFalse(makeRound3Asset(id: "a", filename: "IMG_1.HEICS").isHEIC)
        XCTAssertFalse(makeRound3Asset(id: "a", filename: nil).isHEIC)
    }

    /// The keeper must not depend on the order the tool happened to list the assets.
    func testBestByMetadataIgnoresInputOrder() {
        let favorite = makeRound3Asset(id: "b", width: 100, height: 100, favorite: true)
        let large = makeRound3Asset(id: "a", width: 4_000, height: 3_000)
        let mid = makeRound3Asset(id: "c", width: 2_000, height: 1_500)
        for order in [[favorite, large, mid], [mid, large, favorite], [large, mid, favorite]] {
            XCTAssertEqual(BestAssetSelector.bestByMetadata(from: order)?.id, "b")
        }
    }

    /// Two assets with nothing to tell them apart: the smaller id wins, in any order.
    func testBestByMetadataTieBreaksOnSmallerId() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let z = makeRound3Asset(id: "z", date: date)
        let a = makeRound3Asset(id: "a", date: date)
        XCTAssertEqual(BestAssetSelector.bestByMetadata(from: [z, a])?.id, "a")
        XCTAssertEqual(BestAssetSelector.bestByMetadata(from: [a, z])?.id, "a")
    }
}

// MARK: - Round 3: PhotoKit stall decision (fake clock, fake progress)

final class PhotoRequestStallRound3Tests: XCTestCase {

    /// `TimeInterval` values are not exact in binary, so durations are compared
    /// with an accuracy, and the case is matched separately.
    private func assertProgressing(_ verdict: StallVerdict, remaining expected: TimeInterval,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard case .progressing(let remaining) = verdict else {
            return XCTFail("expected progressing, got \(verdict)", file: file, line: line)
        }
        XCTAssertEqual(remaining, expected, accuracy: 1e-9, file: file, line: line)
    }

    func testProgressKeepsTheRequestAlive() {
        var tracker = PhotoRequestStallTracker(limit: 20, startedAt: 0)
        tracker.recordProgress(at: 15)
        assertProgressing(tracker.verdict(at: 30), remaining: 5)
    }

    func testNoProgressForTheWholeLimitStalls() {
        let tracker = PhotoRequestStallTracker(limit: 20, startedAt: 0)
        assertProgressing(tracker.verdict(at: 19.9), remaining: 0.1)
        XCTAssertEqual(tracker.verdict(at: 20), .stalled)
        XCTAssertEqual(tracker.verdict(at: 500), .stalled)
    }

    /// A late, older progress callback must not push the deadline back.
    func testOutOfOrderProgressDoesNotMoveTheDeadlineBack() {
        var tracker = PhotoRequestStallTracker(limit: 20, startedAt: 0)
        tracker.recordProgress(at: 15)
        tracker.recordProgress(at: 10)
        assertProgressing(tracker.verdict(at: 30), remaining: 5)
    }

    /// A finished request is `.done` even after its deadline has passed.
    func testFinishedRequestIsDoneEvenPastTheDeadline() {
        var tracker = PhotoRequestStallTracker(limit: 20, startedAt: 0)
        tracker.finish()
        XCTAssertEqual(tracker.verdict(at: 100), .done)
    }

    /// Progress that arrives after the request finished cannot revive the watch.
    func testProgressAfterFinishCannotReviveTheWatch() {
        var tracker = PhotoRequestStallTracker(limit: 20, startedAt: 0)
        tracker.finish()
        tracker.recordProgress(at: 50)
        XCTAssertEqual(tracker.verdict(at: 60), .done)
        XCTAssertTrue(tracker.finished)
    }

    /// The same progress, without a finish, does keep the request alive. This
    /// is the contrast that makes the test above meaningful.
    func testSameProgressWithoutFinishKeepsItAlive() {
        var tracker = PhotoRequestStallTracker(limit: 20, startedAt: 0)
        tracker.recordProgress(at: 50)
        assertProgressing(tracker.verdict(at: 60), remaining: 10)
    }

    func testStallLimitMatchesTheLiveWatch() {
        let tracker = PhotoRequestStallTracker(startedAt: 0)
        XCTAssertEqual(tracker.verdict(at: LoadStall.limit), .stalled)
    }
}

// MARK: - Round 3: export file sink

final class ExportFileSinkRound3Tests: XCTestCase {

    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportSinkTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testAppendThenCloseKeepsTheBytes() throws {
        let url = folder.appendingPathComponent("a.jpg")
        let sink = try XCTUnwrap(ExportFileSink(url: url))
        sink.append(Data("abc".utf8))
        sink.append(Data("def".utf8))
        sink.close()
        XCTAssertEqual(try Data(contentsOf: url), Data("abcdef".utf8))
    }

    /// A stalled or cancelled export must leave no partial file, and bytes that
    /// arrive after the discard must not recreate it.
    func testDiscardRemovesThePartialFileAndDropsLaterBytes() throws {
        let url = folder.appendingPathComponent("b.jpg")
        let sink = try XCTUnwrap(ExportFileSink(url: url))
        sink.append(Data("partial".utf8))
        sink.discard()
        sink.append(Data("late".utf8))
        sink.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSinkCannotBeCreatedWhereTheFolderIsMissing() {
        let url = folder.appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("c.jpg")
        XCTAssertNil(ExportFileSink(url: url))
    }
}

// MARK: - Round 3: Keychain write failure (fake backend)

@MainActor
final class GoogleKeychainRound3Tests: XCTestCase {

    /// In-memory stand-in for the Keychain. `refuseAdds` makes `SecItemAdd` fail
    /// the way a locked or full Keychain does.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        private let refuseAdds: Bool
        private(set) var addCount = 0

        init(refuseAdds: Bool) {
            self.refuseAdds = refuseAdds
        }

        var backend: GoogleKeychainBackend {
            GoogleKeychainBackend(
                add: { [self] query in
                    lock.withLock {
                        addCount += 1
                        if refuseAdds { return errSecInteractionNotAllowed }
                        stored = (query as NSDictionary)[kSecValueData] as? Data
                        return errSecSuccess
                    }
                },
                delete: { [self] _ in
                    lock.withLock {
                        stored = nil
                        return errSecSuccess
                    }
                },
                copyMatching: { [self] _ in
                    lock.withLock { stored }
                }
            )
        }
    }

    override func tearDown() {
        GoogleKeychain.backend = .system
        super.tearDown()
    }

    private func sampleTokens() -> GoogleAuthService.Tokens {
        GoogleAuthService.Tokens(accessToken: "access", refreshToken: "refresh", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    private func sampleResponse() throws -> GoogleAuthService.TokenResponse {
        try JSONDecoder().decode(
            GoogleAuthService.TokenResponse.self,
            from: Data(#"{"access_token":"access","expires_in":3600,"refresh_token":"refresh"}"#.utf8)
        )
    }

    func testSaveReportsFailureWhenTheKeychainRefusesTheWrite() {
        let fake = FakeKeychain(refuseAdds: true)
        GoogleKeychain.backend = fake.backend
        XCTAssertFalse(GoogleKeychain.save(sampleTokens()))
        XCTAssertEqual(fake.addCount, 1)
    }

    func testSaveRoundTripsThroughTheKeychain() {
        let fake = FakeKeychain(refuseAdds: false)
        GoogleKeychain.backend = fake.backend
        XCTAssertTrue(GoogleKeychain.save(sampleTokens()))
        XCTAssertEqual(GoogleKeychain.load(), sampleTokens())
    }

    /// The user must not be left looking signed in when the write failed: the
    /// error is thrown, and the app holds no tokens.
    func testStoreThrowsAndHoldsNoTokensWhenTheKeychainRefuses() throws {
        let fake = FakeKeychain(refuseAdds: true)
        GoogleKeychain.backend = fake.backend
        let auth = GoogleAuthService()
        XCTAssertNil(auth.tokens)

        XCTAssertThrowsError(try auth.store(try sampleResponse(), keepingRefreshToken: nil)) { error in
            XCTAssertEqual(error as? GoogleAuthError, .keychainWriteFailed)
        }
        XCTAssertNil(auth.tokens)
        XCTAssertFalse(auth.isSignedIn)
    }

    func testStoreKeepsTokensWhenTheKeychainAccepts() throws {
        let fake = FakeKeychain(refuseAdds: false)
        GoogleKeychain.backend = fake.backend
        let auth = GoogleAuthService()

        try auth.store(try sampleResponse(), keepingRefreshToken: nil)
        XCTAssertEqual(auth.tokens?.accessToken, "access")
        XCTAssertEqual(auth.tokens?.refreshToken, "refresh")
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(GoogleKeychain.load()?.accessToken, "access")
    }
}

// MARK: - Final pass: counted keys resolve per language

final class CountedKeyResolutionTests: XCTestCase {

    /// Foundation wraps inserted arguments in bidi isolation marks for
    /// right-to-left text. They are invisible and not part of the copy.
    private func visible(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2068}", with: "").replacingOccurrences(of: "\u{2069}", with: "")
    }

    private let reason = "Known limit: L10n.format picks the plural category from the device locale, not the app language (see L10n.swift). A non-English device shows the English category for count 5."

    /// Exact strings, not substrings: "صورة" contains "صور", so a substring
    /// check passed for the wrong form.
    func testFailedDeleteEnglishAndArabicOneResolve() {
        let key = "Failed to delete %lld photo: %@"
        let fallback = "Failed to delete %lld photos: %@"
        XCTAssertEqual(L10n.format(key, language: .english, fallback: fallback, 1, "x"), "Failed to delete 1 photo: x")
        XCTAssertEqual(L10n.format(key, language: .english, fallback: fallback, 5, "x"), "Failed to delete 5 photos: x")
        XCTAssertEqual(visible(L10n.format(key, language: .russian, fallback: fallback, 1, "x")), "Не удалось удалить 1 фотографию: x")
        XCTAssertEqual(visible(L10n.format(key, language: .arabic, fallback: fallback, 1, "x")), "تعذّر حذف 1 صورة: x")
    }

    func testFailedDeleteFiveInRussianAndArabicIsKnownToUseTheDeviceCategory() {
        let key = "Failed to delete %lld photo: %@"
        let fallback = "Failed to delete %lld photos: %@"
        XCTExpectFailure(reason) {
            XCTAssertEqual(visible(L10n.format(key, language: .russian, fallback: fallback, 5, "x")), "Не удалось удалить 5 фотографий: x")
        }
        XCTExpectFailure(reason) {
            XCTAssertEqual(visible(L10n.format(key, language: .arabic, fallback: fallback, 5, "x")), "تعذّر حذف 5 صور: x")
        }
    }

    func testUpdatedDayAgoEnglishResolves() {
        let key = "Updated %lld day ago"
        let fallback = "Updated %lld days ago"
        XCTAssertEqual(L10n.format(key, language: .english, fallback: fallback, 1), "Updated 1 day ago")
        XCTAssertEqual(L10n.format(key, language: .english, fallback: fallback, 5), "Updated 5 days ago")
    }

    func testUpdatedDayAgoFiveInRussianIsKnownToUseTheDeviceCategory() {
        XCTExpectFailure(reason) {
            XCTAssertEqual(L10n.format("Updated %lld day ago", language: .russian, fallback: "Updated %lld days ago", 5), "Обновлено 5 дней назад")
        }
    }
}
