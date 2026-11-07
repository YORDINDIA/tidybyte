import XCTest
@testable import Tidybyte

@MainActor
final class LargeFilesViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppPreferences.saveLargeFileThresholdMB(10)
    }

    func testFilterChangeKeepsHiddenSelection() {
        let viewModel = LargeFilesViewModel()
        viewModel.assets = [
            makeAsset(id: "video-large", mediaType: .video, fileSize: 150_000_000, filename: "video-large.mov"),
            makeAsset(id: "photo-large", mediaType: .photo, fileSize: 120_000_000, filename: "photo-large.jpg"),
            makeAsset(id: "photo-small", mediaType: .photo, fileSize: 4_000_000, filename: "photo-small.jpg")
        ]
        viewModel.selectedIds = ["video-large", "photo-large"]
        viewModel.mediaFilter = .photos

        // The video pick survives; only the visible pick counts for delete.
        XCTAssertEqual(viewModel.selectedIds, ["video-large", "photo-large"])
        XCTAssertEqual(viewModel.selectedVisibleCount, 1)
    }

    func testSelectAllUsesOnlyCurrentlyVisibleAssets() {
        let viewModel = LargeFilesViewModel()
        viewModel.assets = [
            makeAsset(id: "b", mediaType: .photo, fileSize: 25_000_000, filename: "b.jpg"),
            makeAsset(id: "a", mediaType: .photo, fileSize: 25_000_000, filename: "a.jpg"),
            makeAsset(id: "video", mediaType: .video, fileSize: 25_000_000, filename: "video.mov")
        ]
        viewModel.mediaFilter = .photos
        viewModel.sortOrder = .filename

        viewModel.selectAll()

        XCTAssertEqual(viewModel.selectedIds, ["a", "b"])
        XCTAssertEqual(viewModel.selectedVisibleCount, 2)
    }

    func testThresholdMBSetPersistsToDefaults() {
        let viewModel = LargeFilesViewModel()

        viewModel.thresholdMB = 123

        XCTAssertEqual(AppPreferences.largeFileThresholdMB(), 123)
    }

    func testCancelledExportCannotReplaceNewExportState() async throws {
        let started = expectation(description: "both exports started")
        started.expectedFulfillmentCount = 2
        var continuations: [CheckedContinuation<(folder: URL, urls: [URL]), Never>] = []
        var progress: [@MainActor @Sendable (Int, Int) -> Void] = []
        let viewModel = LargeFilesViewModel { _, callback in
            progress.append(callback)
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
                started.fulfill()
            }
        }
        viewModel.assets = [makeAsset(id: "item", mediaType: .photo, fileSize: 25_000_000, filename: "item.jpg")]
        viewModel.selectedIds = ["item"]
        viewModel.startShare()
        await Task.yield()
        viewModel.cancelShare()
        viewModel.startShare()
        await fulfillment(of: [started], timeout: 5)
        let oldFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let newFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: oldFolder); try? FileManager.default.removeItem(at: newFolder) }
        progress[0](1, 1)
        XCTAssertEqual(viewModel.shareProgress.completed, 0)
        continuations[0].resume(returning: (oldFolder, []))
        for _ in 0..<100 where FileManager.default.fileExists(atPath: oldFolder.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewModel.isPreparingShare)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path))
        let file = newFolder.appendingPathComponent("item.jpg")
        continuations[1].resume(returning: (newFolder, [file]))
        for _ in 0..<100 where viewModel.isPreparingShare {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(viewModel.isPreparingShare)
        XCTAssertEqual(viewModel.shareExportFolder, newFolder)
        XCTAssertEqual(viewModel.sharePayload?.urls, [file])
        viewModel.cleanupShareExport()
    }

    private func makeAsset(id: String, mediaType: MediaType, fileSize: Int64, filename: String) -> AssetSummary {
        AssetSummary(
            id: id,
            mediaType: mediaType,
            creationDate: .now,
            modificationDate: .now,
            pixelWidth: 4000,
            pixelHeight: 3000,
            duration: mediaType == .video ? 60 : 0,
            fileSize: fileSize,
            filename: filename,
            isFavorite: false,
            isBurst: false,
            burstIdentifier: nil,
            isLivePhoto: false,
            isScreenshot: false,
            isLocallyAvailable: true
        )
    }
}
