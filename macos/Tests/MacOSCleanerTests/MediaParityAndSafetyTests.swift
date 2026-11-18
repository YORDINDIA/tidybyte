import CoreGraphics
import Foundation
import ImageIO
@testable import MacOSCleanerAppKit
@testable import MacOSCleanerCore
import UniformTypeIdentifiers
import XCTest

private actor MockLivePhotosService: PhotoMutationService {
    let previewDirectory: URL
    var failBatchDelete = false
    private(set) var replaceCalls = 0
    private(set) var singleDeleteCalls = 0
    private(set) var batchDeleteCounts: [Int] = []

    init(previewDirectory: URL, failBatchDelete: Bool = false) {
        self.previewDirectory = previewDirectory
        self.failBatchDelete = failBatchDelete
    }

    func previewURL(for item: ReviewItem) async throws -> URL {
        previewDirectory.appendingPathComponent(item.name)
    }

    func localURLs(for item: ReviewItem) async throws -> [URL] {
        item.resources.map { previewDirectory.appendingPathComponent($0.name) }
    }

    func export(_ item: ReviewItem, to folder: URL) async throws -> [URL] {
        []
    }

    func replace(_ item: ReviewItem, with url: URL, kind: MediaKind) async throws -> String {
        replaceCalls += 1
        return "replacement-\(item.id)"
    }

    func delete(_ item: ReviewItem) async throws {
        singleDeleteCalls += 1
    }

    func delete(_ items: [ReviewItem]) async throws {
        batchDeleteCounts.append(items.count)
        if failBatchDelete {
            throw CleanupError.message("Batch delete refused")
        }
    }
}

final class MediaParityAndSafetyTests: XCTestCase {
    private func makeNoisyJPEG(at url: URL, width: Int = 640, height: Int = 480) throws {
        var state: UInt64 = 17
        let pixels: [UInt8] = (0..<(width * height * 4)).map { index in
            if index % 4 == 3 { return 255 }
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        }
        try writeImage(pixels: pixels, width: width, height: height, url: url, uti: UTType.jpeg.identifier as CFString)
    }

    private func makePatternPNG(at url: URL, sharp: Bool) throws {
        let side = 512
        var pixels = [UInt8](repeating: 128, count: side * side * 4)
        for row in 0..<side {
            for col in 0..<side {
                let offset = (row * side + col) * 4
                let value: UInt8 = sharp ? (((row + col).isMultiple(of: 2)) ? 245 : 10) : 128
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        try writeImage(pixels: pixels, width: side, height: side, url: url, uti: UTType.png.identifier as CFString)
    }

    private func writeImage(pixels: [UInt8], width: Int, height: Int, url: URL, uti: CFString) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        )
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
    }

    private func makePhotoItem(id: String, bytes: Int64, resources: [PhotoResource] = []) -> ReviewItem {
        var item = ReviewItem(id: id, source: .photos(id), name: "\(id).jpg", kind: .image, bytes: bytes)
        item.resources = resources
        return item
    }

    // MARK: - IC-01..IC-04: Sort, Keep Both vs Replace & Trash, Max Size, Measure

    func testPhotoCompressionSortOrderCoversAllOrders() {
        var oldest = ReviewItem(id: "a", source: .photos("a"), name: "a.jpg", kind: .image, bytes: 5_000_000)
        oldest.createdAt = Date(timeIntervalSince1970: 1_000)
        var middle = ReviewItem(id: "b", source: .photos("b"), name: "b.jpg", kind: .image, bytes: 1_000_000)
        middle.facts.capturedAt = Date(timeIntervalSince1970: 3_000)
        middle.createdAt = Date(timeIntervalSince1970: 1_500)
        var newest = ReviewItem(id: "c", source: .photos("c"), name: "c.jpg", kind: .image, bytes: 3_000_000)
        newest.modifiedAt = Date(timeIntervalSince1970: 2_000)

        let input = [oldest, middle, newest]
        XCTAssertEqual(PhotoCompressionSortOrder.ordered(input, by: .recentlyAdded).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(PhotoCompressionSortOrder.ordered(input, by: .dateTaken).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(PhotoCompressionSortOrder.ordered(input, by: .largestFirst).map(\.id), ["a", "c", "b"])
        XCTAssertTrue(PhotoCompressionSortOrder.allCases.allSatisfy { !$0.title.isEmpty })
    }

    func testCleanupSettingsMaxSizeAndAlreadyUnderTarget() throws {
        XCTAssertEqual(CleanupSettings.photoMaxSizeChoicesMB, [1, 2, 3, 4.5, 5, 10])

        var settings = CleanupSettings()
        XCTAssertFalse(settings.deleteOriginalsAfterCompression)
        settings.deleteOriginalsAfterCompression = true
        settings.photoCompressionSortOrder = .largestFirst
        settings.photoMaxSizeMB = 2.0
        settings.photoMaxDimension = 2048

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CleanupSettings.self, from: encoded)
        XCTAssertEqual(decoded, settings)

        let smallImage = ReviewItem(id: "small", source: .photos("s"), name: "small.jpg", kind: .image, bytes: 1_500_000)
        let largeImage = ReviewItem(id: "large", source: .photos("l"), name: "large.jpg", kind: .image, bytes: 4_000_000)
        let video = ReviewItem(id: "vid", source: .photos("v"), name: "clip.mov", kind: .video, bytes: 500_000)

        XCTAssertTrue(MediaCompressionService.isAlreadyUnderTarget(smallImage, settings: settings))
        XCTAssertFalse(MediaCompressionService.isAlreadyUnderTarget(largeImage, settings: settings))
        XCTAssertFalse(MediaCompressionService.isAlreadyUnderTarget(video, settings: settings))
        XCTAssertEqual(MediaCompressionService.estimate(largeImage, settings: settings), 2_000_000)
    }

    func testCompressionKeepBothVsReplaceAndTrashOriginals() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "ICKeepBoth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let trashDir = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let keepSource = root.appendingPathComponent("keep.jpg")
        let replaceSource = root.appendingPathComponent("replace.jpg")
        try makeNoisyJPEG(at: keepSource)
        try makeNoisyJPEG(at: replaceSource)

        let keepItem = try XCTUnwrap(ReviewInventory.record(keepSource, root: root))
        let replaceItem = try XCTUnwrap(ReviewInventory.record(replaceSource, root: root))
        let store = try SQLiteStore.inMemory()
        let executor = ReviewExecutor(
            store: store, access: FolderAccess(store: store), photos: PhotoLibraryService(),
            trash: FixtureTrash(folder: trashDir)
        )

        var keepSettings = CleanupSettings()
        keepSettings.deleteOriginalsAfterCompression = false
        let keepEvent = await executor.compress(keepItem, settings: keepSettings) { _ in }
        XCTAssertEqual(keepEvent.state, .complete)
        XCTAssertEqual(keepEvent.action, "keepBoth")
        XCTAssertEqual(keepEvent.savings, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(keepEvent.replacementURL).path))

        var replaceSettings = CleanupSettings()
        replaceSettings.deleteOriginalsAfterCompression = true
        let replaceEvent = await executor.compress(replaceItem, settings: replaceSettings) { _ in }
        XCTAssertEqual(replaceEvent.state, .complete)
        XCTAssertEqual(replaceEvent.action, "compress")
        XCTAssertGreaterThan(replaceEvent.savings, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaceSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(replaceEvent.replacementURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(replaceEvent.outputURL).path))
    }

    @MainActor
    func testMeasureCompressedSizeAndCleanupModelCache() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "ICMeasure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.jpg")
        try makeNoisyJPEG(at: source)
        let item = try XCTUnwrap(ReviewInventory.record(source, root: root))

        let measured = try await MediaCompressionService().measureCompressedSize(
            item, source: source, settings: CleanupSettings()
        )
        XCTAssertGreaterThan(measured, 0)
        XCTAssertLessThan(measured, item.bytes)

        let videoItem = ReviewItem(id: "vid", source: .photos("v"), name: "v.mov", kind: .video, bytes: 100)
        do {
            _ = try await MediaCompressionService().measureCompressedSize(videoItem, settings: CleanupSettings())
            XCTFail("Expected non-image error")
        } catch {}

        let model = CleanupModel(store: try SQLiteStore.inMemory())
        await model.measureCompressionSizes(for: [item])
        XCTAssertEqual(model.measuredBytes(for: item), measured)
        XCTAssertFalse(model.isMeasuringSizes)
        model.settings.imageQuality = .small
        XCTAssertNil(model.measuredBytes(for: item), "Signature change must invalidate cached measurement")
    }

    // MARK: - Safe Selection & Live Photos

    func testSafeSelectionProtectsFavoritesAndBurstPicksUnlessExplicitlyChosen() {
        var favorite = makePhotoItem(id: "fav", bytes: 100)
        favorite.isFavorite = true
        var burstPick = makePhotoItem(id: "burst", bytes: 100)
        burstPick.isBurstPick = true
        let plain = makePhotoItem(id: "plain", bytes: 100)
        let extra = makePhotoItem(id: "extra", bytes: 100)

        let group = AnalysisGroup(
            tool: .duplicates, memberIDs: ["fav", "burst", "plain", "extra"],
            bestID: "plain", explanation: "Exact content match", protectedIDs: ["fav", "burst"]
        )
        let allItems = [favorite, burstPick, plain, extra]

        let defaultSafe = MediaAnalysisService.safeSelection(
            ["fav", "burst", "plain", "extra"], groups: [group], items: allItems
        )
        XCTAssertEqual(defaultSafe, ["extra"])

        let explicitBurst = MediaAnalysisService.safeSelection(
            ["fav", "burst", "extra"], groups: [group], items: allItems, explicitlyChosen: ["burst"]
        )
        XCTAssertEqual(explicitBurst, ["burst", "extra"], "Explicitly chosen burst pick is allowed while favorite stays protected")

        let autoSelected = MediaAnalysisService.autoCleanSelection(for: [group], items: allItems)
        XCTAssertEqual(autoSelected, ["extra"])
    }

    @MainActor
    func testLivePhotosFilteringAndRecoverableBytes() throws {
        let liveOne = makePhotoItem(id: "lp-1", bytes: 5_000_000, resources: [
            PhotoResource(name: "still.heic", type: 1, uniformType: "public.heic", bytes: 1_500_000),
            PhotoResource(name: "motion.mov", type: 9, uniformType: "com.apple.quicktime-movie", bytes: 3_500_000)
        ])
        let liveTwo = makePhotoItem(id: "lp-2", bytes: 4_000_000, resources: [
            PhotoResource(name: "still.heic", type: 5, uniformType: "public.heic", bytes: 1_200_000),
            PhotoResource(name: "motion.mov", type: 10, uniformType: "com.apple.quicktime-movie", bytes: 2_800_000)
        ])
        let ordinaryPhoto = makePhotoItem(id: "plain", bytes: 2_000_000, resources: [
            PhotoResource(name: "still.heic", type: 1, uniformType: "public.heic", bytes: 2_000_000)
        ])

        XCTAssertTrue(MediaAnalysisService.isLivePhoto(liveOne))
        XCTAssertFalse(MediaAnalysisService.isLivePhoto(ordinaryPhoto))

        let analysis = AnalysisResult(
            generation: UUID(), scopeID: "scope", settings: CleanupSettings(),
            items: [liveOne, liveTwo, ordinaryPhoto], groups: []
        )
        let candidates = MediaAnalysisService.candidates(.livePhotos, in: analysis)
        XCTAssertEqual(candidates.map(\.id), ["lp-1", "lp-2"])
        XCTAssertFalse(MediaAnalysisService.candidates(.imageCompression, in: analysis).contains { $0.id == "lp-1" })

        let model = CleanupModel(store: try SQLiteStore.inMemory())
        XCTAssertEqual(model.livePhotoRecoverableBytes(for: liveOne), 3_500_000)
        XCTAssertEqual(model.livePhotoRecoverableBytes(for: liveTwo), 2_800_000)
    }

    func testLivePhotosBatchConversionAndFailureHandling() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "LivePhotos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("still".utf8).write(to: root.appendingPathComponent("still.heic"))

        let liveOne = makePhotoItem(id: "lp-1", bytes: 5_000_000, resources: [
            PhotoResource(name: "still.heic", type: 1, uniformType: "public.heic", bytes: 1_500_000),
            PhotoResource(name: "motion.mov", type: 9, uniformType: "com.apple.quicktime-movie", bytes: 3_500_000)
        ])
        let liveTwo = makePhotoItem(id: "lp-2", bytes: 4_000_000, resources: [
            PhotoResource(name: "still.heic", type: 5, uniformType: "public.heic", bytes: 1_200_000),
            PhotoResource(name: "motion.mov", type: 10, uniformType: "com.apple.quicktime-movie", bytes: 2_800_000)
        ])

        let photos = MockLivePhotosService(previewDirectory: root)
        let store = try SQLiteStore.inMemory()
        let executor = ReviewExecutor(store: store, access: FolderAccess(store: store), photos: photos)
        let events = await executor.convertLivePhotosToStills([liveOne, liveTwo], deleteOriginals: true)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.state == .complete && $0.action == "keepComponent" })
        let replaceCalls = await photos.replaceCalls
        let batchDeleteCounts = await photos.batchDeleteCounts
        let singleDeleteCalls = await photos.singleDeleteCalls
        XCTAssertEqual(replaceCalls, 2)
        XCTAssertEqual(batchDeleteCounts, [2])
        XCTAssertEqual(singleDeleteCalls, 0)

        let keepEvents = await executor.convertLivePhotosToStills([liveOne], deleteOriginals: false)
        XCTAssertEqual(keepEvents.first?.action, "keepBoth")
        XCTAssertEqual(keepEvents.first?.savings, 0)

        let failingPhotos = MockLivePhotosService(previewDirectory: root, failBatchDelete: true)
        let failStore = try SQLiteStore.inMemory()
        let failExecutor = ReviewExecutor(store: failStore, access: FolderAccess(store: failStore), photos: failingPhotos)
        let interrupted = await failExecutor.convertLivePhotosToStills([liveOne], deleteOriginals: true)
        XCTAssertEqual(interrupted.first?.state, .interrupted)
        XCTAssertNotNil(interrupted.first?.replacementPhotoID)
    }

    // MARK: - Interrupted Operations Dismissal & Quality Thresholds

    @MainActor
    func testDismissInterruptedOperationsClearsStuckStates() async throws {
        let store = try SQLiteStore.inMemory()
        let item = makePhotoItem(id: "op-item", bytes: 1_000)

        var prepared = ActivityEvent(id: "ev-prep", tool: .swipe, item: item, action: "trash")
        prepared.state = .prepared
        var outputReady = ActivityEvent(id: "ev-ready", tool: .imageCompression, item: item, action: "compress")
        outputReady.state = .outputReady
        var interrupted = ActivityEvent(id: "ev-int", tool: .livePhotos, item: item, action: "keepComponent")
        interrupted.state = .interrupted
        var stuckRestore = ActivityEvent(id: "ev-restore", tool: .swipe, item: item, action: "trash")
        stuckRestore.state = .complete
        stuckRestore.restoreStartedAt = Date()
        var cleanComplete = ActivityEvent(id: "ev-clean", tool: .swipe, item: item, action: "trash")
        cleanComplete.state = .complete

        for event in [prepared, outputReady, interrupted, stuckRestore, cleanComplete] {
            try await store.saveActivity(event)
        }

        let model = CleanupModel(store: store)
        try await model.reloadHistory()
        XCTAssertTrue(model.hasInterruptedOperations)

        await model.dismissInterruptedOperations()
        XCTAssertFalse(model.hasInterruptedOperations)
        XCTAssertNotNil(model.notice)

        let reloaded = Dictionary(uniqueKeysWithValues: (try await store.cleanupActivity()).map { ($0.id, $0) })
        XCTAssertEqual(reloaded["ev-prep"]?.state, .failed)
        XCTAssertEqual(reloaded["ev-ready"]?.state, .failed)
        XCTAssertEqual(reloaded["ev-int"]?.state, .failed)
        XCTAssertEqual(reloaded["ev-restore"]?.state, .complete)
        XCTAssertNil(reloaded["ev-restore"]?.restoreStartedAt)
        XCTAssertEqual(reloaded["ev-clean"]?.state, .complete)
    }

    func testImageQualityThresholdsAnd512pxSharpnessAnalysis() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "ImageQuality512-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharpURL = root.appendingPathComponent("sharp-checker.png")
        let flatURL = root.appendingPathComponent("flat-blur.png")
        try makePatternPNG(at: sharpURL, sharp: true)
        try makePatternPNG(at: flatURL, sharp: false)

        let sharpMeasure = try ImageQualityAnalysis.measureImage(sharpURL, original: MediaFacts(), sensitivity: 1)
        let flatMeasure = try ImageQualityAnalysis.measureImage(flatURL, original: MediaFacts(), sensitivity: 1)
        XCTAssertGreaterThan(sharpMeasure.facts.sharpness ?? 0, 120)
        XCTAssertLessThan(flatMeasure.facts.sharpness ?? 999, 40)

        let asyncMeasure = try await ImageQualityAnalysis.measureImageAsync(sharpURL, original: MediaFacts(), sensitivity: 1)
        XCTAssertGreaterThan(asyncMeasure.facts.sharpness ?? 0, 120)

        var midSharp = makePhotoItem(id: "mid", bytes: 100)
        midSharp.facts.sharpness = 55
        XCTAssertTrue(MediaAnalysisService.qualityIssues(midSharp, sensitivity: 0).isEmpty)
        XCTAssertEqual(MediaAnalysisService.qualityIssues(midSharp, sensitivity: 1), ["Out of focus"])

        var borderline = makePhotoItem(id: "border", bytes: 100)
        borderline.facts.sharpness = 95
        XCTAssertTrue(MediaAnalysisService.qualityIssues(borderline, sensitivity: 1).isEmpty)
        XCTAssertEqual(MediaAnalysisService.qualityIssues(borderline, sensitivity: 2), ["Out of focus"])

        borderline.facts.hasLensSmudge = true
        borderline.facts.aestheticsScore = -0.5
        XCTAssertTrue(MediaAnalysisService.qualityIssues(borderline, sensitivity: 1).contains("Lens smudge"))
        XCTAssertEqual(
            ImageQualityAnalysis.reviewReason(for: borderline, isUtility: false, largeMegabytes: 10),
            "A lens smudge may have reduced image clarity."
        )

        var lowAesthetic = makePhotoItem(id: "low-ae", bytes: 100)
        lowAesthetic.facts.aestheticsScore = -0.5
        XCTAssertEqual(
            ImageQualityAnalysis.reviewReason(for: lowAesthetic, isUtility: false, largeMegabytes: 10),
            "This photo received a low visual-quality score."
        )
        XCTAssertNil(ImageQualityAnalysis.reviewReason(for: lowAesthetic, isUtility: true, largeMegabytes: 10))
        lowAesthetic.facts.category = .documents
        XCTAssertNil(ImageQualityAnalysis.reviewReason(for: lowAesthetic, isUtility: false, largeMegabytes: 10))
    }
}
