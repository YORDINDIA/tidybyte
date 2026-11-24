import XCTest
@testable import Tidybyte

/// Saved scans and checked items: they round-trip, a scan made with other
/// settings or an older file format does not load, and Clear removes all.
@MainActor
final class SavedScanStoreTests: XCTestCase {
    private var originalDirectory: URL!
    private var originalEnabled = false

    override func setUp() async throws {
        try await super.setUp()
        originalDirectory = SavedScanStore.directory
        originalEnabled = SavedScanStore.isEnabled
        SavedScanStore.directory = URL.temporaryDirectory.appending(path: "SavedScansTests-\(UUID().uuidString)")
        SavedScanStore.isEnabled = true
    }

    override func tearDown() async throws {
        SavedScanStore.removeAll()
        SavedScanStore.directory = originalDirectory
        SavedScanStore.isEnabled = originalEnabled
        try await super.tearDown()
    }

    private struct Payload: Codable, Equatable {
        let ids: [String]
    }

    func testRoundTrip() {
        SavedScanStore.save(Payload(ids: ["a", "b"]), name: "tool", stamp: "medium")
        XCTAssertEqual(SavedScanStore.load(Payload.self, name: "tool", stamp: "medium")?.payload, Payload(ids: ["a", "b"]))
    }

    /// Results made with another sensitivity must not show as current.
    func testAnotherStampDoesNotLoad() {
        SavedScanStore.save(Payload(ids: ["a"]), name: "tool", stamp: "medium")
        XCTAssertNil(SavedScanStore.load(Payload.self, name: "tool", stamp: "high"))
    }

    func testAFileOfAnotherShapeDoesNotLoad() {
        SavedScanStore.save(["not", "a", "payload"], name: "tool")
        XCTAssertNil(SavedScanStore.load(Payload.self, name: "tool"))
    }

    func testSelectionRoundTripAndClear() {
        SavedScanStore.saveSelection(["b", "a"], name: "tool")
        XCTAssertEqual(SavedScanStore.selection(name: "tool"), ["a", "b"])
        SavedScanStore.removeAll()
        XCTAssertEqual(SavedScanStore.selection(name: "tool"), [])
        XCTAssertNil(SavedScanStore.load(Payload.self, name: "tool"))
    }

    /// Unit tests run inside the app; with the store off nothing is written.
    func testOffWritesAndReadsNothing() {
        SavedScanStore.isEnabled = false
        SavedScanStore.save(Payload(ids: ["a"]), name: "tool")
        SavedScanStore.isEnabled = true
        XCTAssertNil(SavedScanStore.load(Payload.self, name: "tool"))
    }

    /// The tools' payloads encode and decode as saved, including the enum sets.
    func testToolPayloadsRoundTrip() throws {
        let blurry = BlurryPhotosViewModel.SavedScan(
            scannedAt: Date(timeIntervalSince1970: 1_000),
            photos: [.init(id: "a", blurScore: 0.8, luminance: 0.4, categories: [.blurry, .tooDark], smudgeConfidence: nil)],
            supportsLensSmudge: true,
            skippedScreenshotCount: 2
        )
        SavedScanStore.save(blurry, name: "blurry", stamp: "medium")
        let loaded = try XCTUnwrap(SavedScanStore.load(BlurryPhotosViewModel.SavedScan.self, name: "blurry", stamp: "medium")?.payload)
        XCTAssertEqual(loaded.photos.first?.categories, [.blurry, .tooDark])
        XCTAssertEqual(loaded.scannedAt, Date(timeIntervalSince1970: 1_000))

        let text = TextPhotosViewModel.SavedScan(scannedAt: .now, age: .threeMonths, characterCounts: ["a": 120])
        SavedScanStore.save(text, name: "text")
        XCTAssertEqual(SavedScanStore.load(TextPhotosViewModel.SavedScan.self, name: "text")?.payload.age, .threeMonths)
    }
}
