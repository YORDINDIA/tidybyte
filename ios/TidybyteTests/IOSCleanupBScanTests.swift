import AVFoundation
import Photos
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

    // MARK: - Journal reconcile library gate

    func testReconcileReadsLibraryOnlyWithAccess() {
        XCTAssertTrue(CompressionJournal.canReadLibrary(.authorized))
        XCTAssertTrue(CompressionJournal.canReadLibrary(.limited))
        XCTAssertFalse(CompressionJournal.canReadLibrary(.denied))
        XCTAssertFalse(CompressionJournal.canReadLibrary(.restricted))
        XCTAssertFalse(CompressionJournal.canReadLibrary(.notDetermined))
    }
}
