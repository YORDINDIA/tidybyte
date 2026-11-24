import AVFoundation
import Photos
import SwiftData
import XCTest
@testable import Tidybyte

/// Regression tests for the ios-cleanup-b scan (compression, Live Photos, journal).
final class IOSCleanupBScanTests: XCTestCase {

    // MARK: - Live Photo still resource

    func testStillPrefersEditedResource() {
        XCTAssertEqual(
            LivePhotosConverterViewModel.stillResourceType(available: [.photo, .fullSizePhoto, .pairedVideo]),
            .fullSizePhoto
        )
    }

    func testStillFallsBackToOriginalPhotoWhenNotEdited() {
        XCTAssertEqual(
            LivePhotosConverterViewModel.stillResourceType(available: [.photo, .pairedVideo]),
            .photo
        )
    }

    func testStillIsNilWithoutAnyStillResource() {
        XCTAssertNil(LivePhotosConverterViewModel.stillResourceType(available: [.pairedVideo]))
    }

    // MARK: - Video load failure mapping

    func testTimedOutLoadReportsTimeout() {
        guard case .videoLoadTimedOut? = VideoCompressionService.loadError(for: .timedOut) else {
            return XCTFail("A timeout must map to videoLoadTimedOut")
        }
    }

    func testFailedLoadKeepsPhotoKitDetail() {
        guard case .assetLoadFailed(let detail)? = VideoCompressionService.loadError(for: .failed("boom (PHPhotosErrorDomain 3164)")) else {
            return XCTFail("A PhotoKit error must not be folded into the timeout message")
        }
        XCTAssertEqual(detail, "boom (PHPhotosErrorDomain 3164)")
    }

    func testCancelledLoadMapsToCancelled() {
        guard case .cancelled? = VideoCompressionService.loadError(for: .cancelled) else {
            return XCTFail("A cancelled request must map to cancelled")
        }
    }

    func testLoadedAssetHasNoError() {
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        XCTAssertNil(VideoCompressionService.loadError(for: .loaded(UncheckedSendableBox(asset))))
    }

    // MARK: - Stall deadline (VID-03, round 2)

    func testStallDeadlineFailsOnlyAfterLimitWithoutProgress() {
        let deadline = StallDeadline(limit: 20, startedAt: 100)
        XCTAssertEqual(deadline.remaining(at: 100), 20)
        XCTAssertEqual(deadline.remaining(at: 115), 5)
        XCTAssertEqual(deadline.remaining(at: 120), 0)
    }

    func testProgressMovesStallDeadlineForward() {
        var deadline = StallDeadline(limit: 20, startedAt: 100)
        deadline.recordProgress(at: 115)
        XCTAssertEqual(deadline.remaining(at: 120), 15)
        XCTAssertEqual(deadline.remaining(at: 134), 1)
        XCTAssertEqual(deadline.remaining(at: 135), 0)
    }

    func testLateOlderProgressDoesNotMoveStallDeadlineBack() {
        var deadline = StallDeadline(limit: 20, startedAt: 100)
        deadline.recordProgress(at: 130)
        deadline.recordProgress(at: 110)
        XCTAssertEqual(deadline.lastProgress, 130)
    }

    func testSlowButSteadyDownloadNeverStalls() {
        var deadline = StallDeadline(limit: 20, startedAt: 0)
        var now = 0.0
        for _ in 0..<50 {
            now += 15
            deadline.recordProgress(at: now)
            XCTAssertGreaterThan(deadline.remaining(at: now), 0, "Progress every 15 s must keep a 20 s stall limit alive")
        }
    }

    /// The stall clock must never run backwards, or a deadline could move back.
    func testLoadStallClockNeverGoesBack() {
        var previous = LoadStall.now()
        for _ in 0..<1_000 {
            let current = LoadStall.now()
            XCTAssertGreaterThanOrEqual(current, previous)
            previous = current
        }
    }

    /// The lock serializes writes from concurrent queues, as the PhotoKit callbacks do.
    func testLockedValueSerializesConcurrentWrites() {
        let counter = LockedValue(0)
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            counter.withValue { $0 += 1 }
        }
        XCTAssertEqual(counter.withValue { $0 }, 1_000)
    }

    /// With no progress, the watch fires once its limit passes.
    func testWatchForStallFiresWhenNoProgressArrives() async {
        let fired = LockedValue(false)
        let watch = StallWatch(limit: 0.05)
        let task = watchForStall(watch) { fired.withValue { $0 = true } }
        await task.value
        XCTAssertTrue(fired.withValue { $0 })
    }

    // MARK: - Export failure mapping (round 2 item 3c)

    func testInterruptedExportMapsToForegroundMessage() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.operationInterrupted.rawValue)
        guard case .exportInterrupted = VideoCompressionService.exportFailure(for: error) else {
            return XCTFail("-11847 must map to exportInterrupted")
        }
    }

    func testOtherExportFailureKeepsDomainAndCode() {
        let error = NSError(domain: AVFoundationErrorDomain, code: -11800)
        guard case .exportFailed(let detail) = VideoCompressionService.exportFailure(for: error) else {
            return XCTFail("Other AVFoundation errors keep the detailed export failure")
        }
        XCTAssertTrue(detail.contains("AVFoundationErrorDomain -11800"), detail)
    }

    // MARK: - Check Sizes failure mapping (PH-02, round 2 item 1)

    func testMeasureCancellationIsSilent() {
        XCTAssertEqual(PhotoCompressionViewModel.measureFailure(for: CancellationError()), .cancelled)
        XCTAssertEqual(PhotoCompressionViewModel.measureFailure(for: PhotoCompressionError.cancelled), .cancelled)
    }

    func testMeasureCannotReachTargetMeansCannotFit() {
        XCTAssertEqual(PhotoCompressionViewModel.measureFailure(for: PhotoCompressionError.cannotReachTarget), .cannotFit)
    }

    func testMeasureLoadFailureIsReportedNotCannotFit() {
        let failure = PhotoCompressionViewModel.measureFailure(for: PhotoCompressionError.imageDataLoadFailed)
        guard case .message(let text) = failure else {
            return XCTFail("A load failure must not be reported as Can't fit")
        }
        XCTAssertEqual(text, PhotoCompressionError.imageDataLoadFailed.localizedDescription)
    }

    // MARK: - Batch summary and background pause

    func testFailureSummaryOnlyWhenSomethingFailed() {
        XCTAssertNotNil(CompressionBatchRunner.failureSummary(completed: 2, failed: 1))
        XCTAssertNil(CompressionBatchRunner.failureSummary(completed: 2, failed: 0))
    }

    /// The tester's bug: after Stop the batch task is cancelled, and
    /// `deleteAssets` refused to start in it, so no original was ever deleted.
    /// The commit's delete runs through this shield.
    func testIgnoringCancellationRunsInsideACancelledTask() async throws {
        let task = Task { () -> (outer: Bool, inner: Bool) in
            withUnsafeCurrentTask { $0?.cancel() }
            let inner = try await ignoringCancellation { () -> Bool in
                try Task.checkCancellation()
                return Task.isCancelled
            }
            return (Task.isCancelled, inner)
        }
        let result = try await task.value
        XCTAssertTrue(result.outer, "the caller is cancelled")
        XCTAssertFalse(result.inner, "the shielded step is not")
    }

    @MainActor
    func testNoBatchIsPausedAtRest() {
        XCTAssertFalse(CompressionSession.isPaused)
    }

    /// A copy the user later deleted frees its original for a new run; a live
    /// copy blocks a second compression or Live Photo conversion.
    func testIdsWithLiveCopy() {
        let settled = ["a": "copyA", "b": "copyB", "c": "copyC"]
        XCTAssertEqual(
            CompressionJournal.idsWithLiveCopy(settled: settled, liveCopies: ["copyA", "copyC", "other"]),
            ["a", "c"]
        )
        XCTAssertEqual(CompressionJournal.idsWithLiveCopy(settled: settled, liveCopies: []), [])
    }

    // MARK: - Journal reconcile library gate

    /// Without Photos access the rows must stay pending. This test never reaches
    /// PhotoKit: the gate returns before any library lookup. The settle path with
    /// access is covered by MediaLibraryStatsTests, which passes `.authorized`.
    @MainActor
    func testReconcileLeavesRowsPendingWithoutLibraryAccess() async throws {
        let schema = Schema([CompressionRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // Keep the container alive for the whole test: a temporary container
        // can be released under its main context.
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let record = try CompressionJournal.beginPending(
            modelContext: context,
            mediaType: .video,
            assetId: "no-access-asset",
            originalSize: 1_000,
            compressedSize: 0,
            exportPreset: "720p"
        )
        for status in [PHAuthorizationStatus.denied, .notDetermined, .restricted] {
            await CompressionJournal.reconcile(modelContext: context, authorization: status)
            XCTAssertEqual(record.outcome, "pending", "\(status) must not settle rows")
        }
        withExtendedLifetime(container) {}
    }

    func testReconcileReadsLibraryOnlyWithAccess() {
        XCTAssertTrue(CompressionJournal.canReadLibrary(.authorized))
        // Limited access hides unselected originals, so it must not settle rows.
        XCTAssertFalse(CompressionJournal.canReadLibrary(.limited))
        XCTAssertFalse(CompressionJournal.canReadLibrary(.denied))
        XCTAssertFalse(CompressionJournal.canReadLibrary(.restricted))
        XCTAssertFalse(CompressionJournal.canReadLibrary(.notDetermined))
    }
}
