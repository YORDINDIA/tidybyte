import XCTest
@testable import Tidybyte

/// Saved scans and checked items: they round-trip, a scan made with other
/// settings or an older file format does not load, limited access saves and
/// restores no picks, and Clear removes all.
@MainActor
final class SavedScanStoreTests: XCTestCase {
    private var originalDirectory: URL!
    private var originalEnabled = false
    private var originalTrust: (() -> Bool)!

    override func setUp() async throws {
        try await super.setUp()
        originalDirectory = SavedScanStore.directory
        originalEnabled = SavedScanStore.isEnabled
        originalTrust = SavedScanStore.canTrustLibrary
        SavedScanStore.directory = URL.temporaryDirectory.appending(path: "SavedScansTests-\(UUID().uuidString)")
        SavedScanStore.isEnabled = true
        SavedScanStore.canTrustLibrary = { true }
    }

    override func tearDown() async throws {
        SavedScanStore.removeAll()
        SavedScanStore.directory = originalDirectory
        SavedScanStore.isEnabled = originalEnabled
        SavedScanStore.canTrustLibrary = originalTrust
        try await super.tearDown()
    }

    private struct Payload: Codable, Equatable, Sendable {
        let ids: [String]
    }

    func testRoundTrip() async {
        SavedScanStore.save(Payload(ids: ["a", "b"]), name: "tool", stamp: "medium")
        let loaded = await SavedScanStore.load(Payload.self, name: "tool", stamp: "medium")
        XCTAssertEqual(loaded?.payload, Payload(ids: ["a", "b"]))
    }

    /// Results made with another sensitivity must not show as current.
    func testAnotherStampDoesNotLoad() async {
        SavedScanStore.save(Payload(ids: ["a"]), name: "tool", stamp: "medium")
        let loaded = await SavedScanStore.load(Payload.self, name: "tool", stamp: "high")
        XCTAssertNil(loaded)
    }

    func testAFileOfAnotherShapeDoesNotLoad() async {
        SavedScanStore.save(["not", "a", "payload"], name: "tool")
        let loaded = await SavedScanStore.load(Payload.self, name: "tool")
        XCTAssertNil(loaded)
    }

    /// A file from an older format version does not load, even when its payload
    /// would still decode.
    func testAnOlderFormatVersionDoesNotLoad() async throws {
        let old = #"{"version":0,"savedAt":0,"stamp":"","payload":{"ids":["a"]}}"#
        try FileManager.default.createDirectory(at: SavedScanStore.directory, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: SavedScanStore.directory.appending(path: "tool.json"))
        let loaded = await SavedScanStore.load(Payload.self, name: "tool")
        XCTAssertNil(loaded)
    }

    func testSelectionRoundTripAndClear() async {
        SavedScanStore.saveSelection(["b", "a"], name: "tool")
        let saved = await SavedScanStore.selection(name: "tool")
        XCTAssertEqual(saved, ["a", "b"])
        SavedScanStore.removeAll()
        let cleared = await SavedScanStore.selection(name: "tool")
        XCTAssertEqual(cleared, [])
    }

    /// With limited access the visible picks must not replace the saved set,
    /// and nothing is restored.
    func testLimitedAccessNeitherSavesNorRestoresPicks() async {
        SavedScanStore.saveSelection(["a", "b"], name: "tool")
        SavedScanStore.canTrustLibrary = { false }
        SavedScanStore.saveSelection(["a"], name: "tool")
        let whileLimited = await SavedScanStore.selection(name: "tool")
        XCTAssertEqual(whileLimited, [])
        SavedScanStore.canTrustLibrary = { true }
        let afterwards = await SavedScanStore.selection(name: "tool")
        XCTAssertEqual(afterwards, ["a", "b"])
    }

    /// Unit tests run inside the app; with the store off nothing is written.
    func testOffWritesAndReadsNothing() async {
        SavedScanStore.isEnabled = false
        SavedScanStore.save(Payload(ids: ["a"]), name: "tool")
        SavedScanStore.isEnabled = true
        let loaded = await SavedScanStore.load(Payload.self, name: "tool")
        XCTAssertNil(loaded)
    }

    /// The tools' payloads encode and decode as saved, including the enum sets.
    func testToolPayloadsRoundTrip() async throws {
        let blurry = BlurryPhotosViewModel.SavedScan(
            scannedAt: Date(timeIntervalSince1970: 1_000),
            photos: [.init(id: "a", blurScore: 0.8, luminance: 0.4, categories: [.blurry, .tooDark],
                           smudgeConfidence: nil, modified: Date(timeIntervalSince1970: 500))],
            supportsLensSmudge: true,
            skippedScreenshotCount: 2,
            skippedAnalysisCount: 1,
            skippedSmudgeCount: 3
        )
        SavedScanStore.save(blurry, name: "blurry", stamp: "medium")
        let loadedBlurry = await SavedScanStore.load(BlurryPhotosViewModel.SavedScan.self, name: "blurry", stamp: "medium")
        let restored = try XCTUnwrap(loadedBlurry?.payload)
        XCTAssertEqual(restored.photos.first?.categories, [.blurry, .tooDark])
        XCTAssertEqual(restored.photos.first?.modified, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(restored.skippedScreenshotCount, 2)
        XCTAssertEqual(restored.skippedAnalysisCount, 1)
        XCTAssertEqual(restored.skippedSmudgeCount, 3)

        let text = TextPhotosViewModel.SavedScan(scannedAt: .now, age: .threeMonths, photos: ["a": .init(characterCount: 120, modified: nil)])
        SavedScanStore.save(text, name: "text")
        let loadedText = await SavedScanStore.load(TextPhotosViewModel.SavedScan.self, name: "text")
        XCTAssertEqual(loadedText?.payload.age, .threeMonths)
    }
}
