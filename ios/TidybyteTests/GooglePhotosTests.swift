import XCTest
@testable import Tidybyte

final class GooglePhotosTests: XCTestCase {

    private func item(_ id: String = "x", kind: CloudMediaItem.Kind = .photo, name: String = "IMG_1.JPG",
                      mime: String = "image/jpeg", w: Int = 4032, h: Int = 3024, size: Int64? = nil) -> CloudMediaItem {
        CloudMediaItem(id: id, kind: kind, createTime: nil, filename: name, mimeType: mime,
                       width: w, height: h, baseUrl: "https://lh3.example/abc", fileSize: size)
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        // RFC 7636 Appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.makeVerifier().count, 43)
    }

    func testRedirectSchemeIsReversedClientID() {
        XCTAssertEqual(GoogleAuthService.redirectScheme(for: "123-abc.apps.googleusercontent.com"),
                       "com.googleusercontent.apps.123-abc")
    }

    func testMediaItemsPageDecodes() throws {
        let json = """
        {"mediaItems":[
          {"id":"a","createTime":"2024-05-01T10:00:00.123Z","type":"PHOTO",
           "mediaFile":{"baseUrl":"https://lh3/a","mimeType":"image/png","filename":"Screenshot 1.png",
                        "mediaFileMetadata":{"width":1179,"height":2556}}},
          {"id":"b","createTime":"2024-05-02T10:00:00Z","type":"VIDEO",
           "mediaFile":{"baseUrl":"https://lh3/b","mimeType":"video/mp4","filename":"v.mp4"}},
          {"id":"c"}
        ],"nextPageToken":"next"}
        """
        let page = try JSONDecoder().decode(MediaItemsPage.self, from: Data(json.utf8))
        let items = page.mediaItems?.compactMap(\.cloudItem) ?? []
        XCTAssertEqual(items.map(\.id), ["a", "b"], "an item with no media file is dropped")
        XCTAssertEqual(items[0].width, 1179)
        XCTAssertNotNil(items[0].createTime)
        XCTAssertEqual(items[1].kind, .video)
        XCTAssertEqual(page.nextPageToken, "next")
        XCTAssertEqual(items[1].originalURL?.absoluteString, "https://lh3/b=dv")
        XCTAssertEqual(items[0].thumbnailURL(size: 512)?.absoluteString, "https://lh3/a=w512-h512")
    }

    func testStorageQuotaMath() throws {
        let json = #"{"storageQuota":{"limit":"16106127360","usage":"9000","usageInDrive":"3000","usageInDriveTrash":"1000"}}"#
        let quota = try JSONDecoder().decode(About.self, from: Data(json.utf8)).storageQuota.quota
        XCTAssertEqual(quota.photosAndGmail, 5000)
        XCTAssertEqual(quota.limit, 16_106_127_360)
        let unlimited = try JSONDecoder().decode(About.self, from: Data(#"{"storageQuota":{"usage":"5"}}"#.utf8)).storageQuota.quota
        XCTAssertNil(unlimited.limit)
        XCTAssertEqual(unlimited.fractionUsed, 0)
    }

    func testPollingDurationParse() {
        XCTAssertEqual(GooglePhotosAPI.PickerSession.seconds("5s"), 5)
        XCTAssertEqual(GooglePhotosAPI.PickerSession.seconds("1.5s"), 1.5)
        XCTAssertNil(GooglePhotosAPI.PickerSession.seconds("5"))
    }

    func testScreenshotAndRecordingRules() {
        XCTAssertTrue(GooglePhotosScanner.isScreenshotOrRecording(item(name: "Screenshot_20240501.jpg")))
        XCTAssertTrue(GooglePhotosScanner.isScreenshotOrRecording(item(kind: .video, name: "RPReplay_Final1690000000.MP4")))
        XCTAssertTrue(GooglePhotosScanner.isScreenshotOrRecording(item(name: "a.png", mime: "image/png", w: 1179, h: 2556)))
        XCTAssertFalse(GooglePhotosScanner.isScreenshotOrRecording(item(name: "logo.png", mime: "image/png", w: 512, h: 512)))
        XCTAssertFalse(GooglePhotosScanner.isScreenshotOrRecording(item()))
    }

    func testLargeVideoNeedsAKnownSize() {
        XCTAssertTrue(GooglePhotosScanner.isLargeVideo(item(kind: .video, size: 50_000_000), threshold: 10_000_000))
        XCTAssertFalse(GooglePhotosScanner.isLargeVideo(item(kind: .video, size: nil), threshold: 10_000_000))
        XCTAssertFalse(GooglePhotosScanner.isLargeVideo(item(kind: .photo, size: 50_000_000), threshold: 10_000_000))
    }

    func testGroupingAndExactDuplicates() {
        let groups = GooglePhotosScanner.groups(from: [PairKey("a", "b"), PairKey("b", "c"), PairKey("x", "y")])
        XCTAssertEqual(groups, [["a", "b", "c"], ["x", "y"]])

        let items = ["a": item("a"), "b": item("b"), "c": item("c", w: 100, h: 100)]
        XCTAssertTrue(GooglePhotosScanner.isExactGroup(["a", "b"], items: items, distances: [PairKey("a", "b"): 0.01]))
        XCTAssertFalse(GooglePhotosScanner.isExactGroup(["a", "b"], items: items, distances: [PairKey("a", "b"): 0.3]))
        XCTAssertFalse(GooglePhotosScanner.isExactGroup(["a", "c"], items: items, distances: [PairKey("a", "c"): 0.01]),
                       "different dimensions are similar, not duplicates")
    }

    func testRecoverableKeepsFirstOfEachGroupAndCountsOnce() {
        var result = CloudScanResult()
        result.items = ["a": item("a", size: 10), "b": item("b", size: 20), "c": item("c", size: 40)]
        result.duplicateGroups = [.init(id: "g", itemIds: ["a", "b"], isExactDuplicate: true)]
        result.blurry = ["b", "c"]
        XCTAssertEqual(result.recoverableBytes, 60)
    }

    func testFormBodyEncodesReservedCharacters() {
        let body = String(data: GoogleAuthService.formBody(["b": "x y&z", "a": "1"]), encoding: .utf8)
        XCTAssertEqual(body, "a=1&b=x%20y%26z")
    }
}
