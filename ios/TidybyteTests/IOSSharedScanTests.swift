import SwiftUI
import XCTest
@testable import Tidybyte

/// Regression tests for the shared-layer audit: WCAG contrast of the colour
/// tokens that carry text in both appearances, and the once-only resume contract
/// of `ContinuationResumer`.
final class ColorContrastTests: XCTestCase {

    // MARK: - Contrast helpers

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The colour a token resolves to in one appearance, in sRGB components.
    private func resolved(_ color: Color, dark: Bool) -> RGB {
        var environment = EnvironmentValues()
        environment.colorScheme = dark ? .dark : .light
        let value = color.resolve(in: environment)
        return RGB(Double(value.red), Double(value.green), Double(value.blue))
    }

    private func background(dark: Bool) -> RGB {
        dark ? RGB(0, 0, 0) : RGB(1, 1, 1)
    }

    /// `tint` at `alpha` laid over `base`, the way a `.opacity` fill composites.
    private func blend(_ tint: RGB, alpha: Double, over base: RGB) -> RGB {
        RGB(
            tint.red * alpha + base.red * (1 - alpha),
            tint.green * alpha + base.green * (1 - alpha),
            tint.blue * alpha + base.blue * (1 - alpha)
        )
    }

    private func luminance(_ rgb: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// WCAG 2.x contrast ratio, 1...21.
    private func contrast(_ first: RGB, _ second: RGB) -> Double {
        let lumFirst = luminance(first)
        let lumSecond = luminance(second)
        return (max(lumFirst, lumSecond) + 0.05) / (min(lumFirst, lumSecond) + 0.05)
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
                let ratio = contrast(RGB(1, 1, 1), resolved(fill, dark: dark))
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
            ("warningText", .warningText),
            ("footnoteText", .footnoteText)
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

    // MARK: Cancellation reaches the PhotoKit request

    /// A card swiped away cancels its task. The waiting caller must get the
    /// fallback at once, and the request (an iCloud download) must be cancelled.
    func testTaskCancelResumesWithFallbackAndCancelsRequest() async {
        let cancelledIds = LockedValue<[Int32]>([])
        let task = Task { () -> Int in
            await withCancellableContinuation { continuation, relay in
                let resumer = ContinuationResumer<Int>(continuation)
                let request = PendingRequest { id in cancelledIds.withValue { $0.append(id) } }
                resumer.onResume = { request.cancel() }
                relay.install { resumer.resume(-1) }
                // A request that never answers, like a stalled download.
                request.started(42)
            }
        }
        task.cancel()
        let value = await task.value
        XCTAssertEqual(value, -1)
        XCTAssertEqual(cancelledIds.withValue { $0 }, [42])
    }

    /// The cancel can land before the resumer exists (the task was cancelled
    /// while it waited for the actor). Installing the action then runs it.
    func testRelayRunsActionInstalledAfterCancel() {
        let relay = CancelRelay()
        let runs = LockedValue(0)
        relay.cancel()
        XCTAssertTrue(relay.isCancelled)
        relay.install { runs.withValue { $0 += 1 } }
        XCTAssertEqual(runs.withValue { $0 }, 1)
    }

    func testRelayRunsInstalledActionOnce() {
        let relay = CancelRelay()
        let runs = LockedValue(0)
        relay.install { runs.withValue { $0 += 1 } }
        XCTAssertEqual(runs.withValue { $0 }, 0)
        relay.cancel()
        relay.cancel()
        XCTAssertEqual(runs.withValue { $0 }, 1)
    }

    /// PhotoKit returns the request id only after the call that starts the
    /// request. A cancel that comes before it must still cancel that id.
    func testPendingRequestCancelBeforeStartCancelsOnStart() {
        let cancelledIds = LockedValue<[Int32]>([])
        let request = PendingRequest { id in cancelledIds.withValue { $0.append(id) } }
        request.cancel()
        XCTAssertEqual(cancelledIds.withValue { $0 }, [])
        request.started(7)
        XCTAssertEqual(cancelledIds.withValue { $0 }, [7])
    }

    func testPendingRequestCancelAfterStart() {
        let cancelledIds = LockedValue<[Int32]>([])
        let request = PendingRequest { id in cancelledIds.withValue { $0.append(id) } }
        request.started(9)
        XCTAssertEqual(cancelledIds.withValue { $0 }, [])
        request.cancel()
        XCTAssertEqual(cancelledIds.withValue { $0 }, [9])
    }
}

// MARK: - models, formatting, selection

func makeTestAsset(
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

final class FormattingAndModelTests: XCTestCase {

    /// The 999.95 kB boundary: the unit switches before one decimal place can
    /// print "1000 kB".
    func testFileSizeSwitchesUnitBeforeItRoundsToAThousand() {
        let unitedStates = Locale.Region("US")
        let almostMegabyte = Formatters.fileSize(999_950, language: .english, region: unitedStates)
        XCTAssertFalse(almostMegabyte.contains("1000"), "got \(almostMegabyte)")
        XCTAssertTrue(almostMegabyte.contains("MB"), "got \(almostMegabyte)")

        let justBelow = Formatters.fileSize(999_949, language: .english, region: unitedStates)
        XCTAssertTrue(justBelow.contains("kB"), "got \(justBelow)")
        XCTAssertTrue(justBelow.contains("999.9"), "got \(justBelow)")
    }

    func testDurationReadsMinutesUnderAnHourAndHoursFromAnHour() {
        XCTAssertEqual(makeTestAsset(id: "a", duration: 0).formattedDuration, "")
        XCTAssertEqual(makeTestAsset(id: "a", duration: 75).formattedDuration, "1:15")
        XCTAssertEqual(makeTestAsset(id: "a", duration: 3_599).formattedDuration, "59:59")
        XCTAssertEqual(makeTestAsset(id: "a", duration: 3_725).formattedDuration, "1:02:05")
    }

    /// `.anchored` with `.backwards` must match the extension only, at the end.
    func testIsHEICMatchesTheExtensionAtTheEndOnly() {
        XCTAssertTrue(makeTestAsset(id: "a", filename: "IMG_1.HEIC").isHEIC)
        XCTAssertTrue(makeTestAsset(id: "a", filename: "IMG_1.heif").isHEIC)
        XCTAssertFalse(makeTestAsset(id: "a", filename: "IMG_1.heic.jpg").isHEIC)
        XCTAssertFalse(makeTestAsset(id: "a", filename: "HEIC.jpg").isHEIC)
        XCTAssertFalse(makeTestAsset(id: "a", filename: "IMG_1.HEICS").isHEIC)
        XCTAssertFalse(makeTestAsset(id: "a", filename: nil).isHEIC)
    }

    /// The keeper must not depend on the order the tool happened to list the assets.
    func testBestByMetadataIgnoresInputOrder() {
        let favorite = makeTestAsset(id: "b", width: 100, height: 100, favorite: true)
        let large = makeTestAsset(id: "a", width: 4_000, height: 3_000)
        let mid = makeTestAsset(id: "c", width: 2_000, height: 1_500)
        for order in [[favorite, large, mid], [mid, large, favorite], [large, mid, favorite]] {
            XCTAssertEqual(BestAssetSelector.bestByMetadata(from: order)?.id, "b")
        }
    }

    /// Two assets with nothing to tell them apart: the smaller id wins, in any order.
    func testBestByMetadataTieBreaksOnSmallerId() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let zebra = makeTestAsset(id: "zebra", date: date)
        let alpha = makeTestAsset(id: "alpha", date: date)
        XCTAssertEqual(BestAssetSelector.bestByMetadata(from: [zebra, alpha])?.id, "alpha")
        XCTAssertEqual(BestAssetSelector.bestByMetadata(from: [alpha, zebra])?.id, "alpha")
    }
}

// MARK: - export file sink

final class ExportFileSinkTests: XCTestCase {

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
        XCTAssertTrue(sink.finish())
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
        XCTAssertFalse(sink.finish(), "a discarded sink never reports a complete file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A disk-full write must not come back as a complete copy. `finish` reports
    /// the failure, and the bytes after the first failure are not written.
    func testFailedWriteIsReportedByFinishAndLaterBytesAreSkipped() throws {
        struct DiskFull: Error {}
        final class Attempts: @unchecked Sendable { var count = 0 }
        let attempts = Attempts()
        let url = folder.appendingPathComponent("disk-full.jpg")
        let sink = try XCTUnwrap(ExportFileSink(url: url, writeChunk: { _, _ in
            attempts.count += 1
            throw DiskFull()
        }))
        sink.append(Data("abc".utf8))
        sink.append(Data("def".utf8))
        XCTAssertFalse(sink.finish())
        XCTAssertEqual(attempts.count, 1, "no write is attempted after the first failure")
        sink.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSinkCannotBeCreatedWhereTheFolderIsMissing() {
        let url = folder.appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("c.jpg")
        XCTAssertNil(ExportFileSink(url: url))
    }
}
