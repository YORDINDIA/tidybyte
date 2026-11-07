import XCTest
@testable import Tidybyte

@MainActor
final class AlbumSheetStateTests: XCTestCase {
    func testOlderLoadCannotReplaceNewerAlbums() async {
        let state = AlbumSheetState()
        let started = expectation(description: "first load started")
        var resumeFirst: CheckedContinuation<(albums: [AlbumInfo], emptyReason: AlbumListEmptyReason?), Never>?
        let first = Task {
            await state.load {
                await withCheckedContinuation { continuation in
                    resumeFirst = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let album = AlbumInfo(id: "new", title: "New", count: 1, type: .userAlbum)
        await state.load { ([album], nil) }
        resumeFirst?.resume(returning: ([], .limitedNoSelection))
        await first.value
        XCTAssertEqual(state.albums, [album])
        XCTAssertNil(state.emptyReason)
        XCTAssertFalse(state.isLoading)
    }
}
