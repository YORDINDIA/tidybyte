import SwiftUI
import UIKit

@Observable
@MainActor
final class AlbumSheetState {
    private(set) var albums: [AlbumInfo] = []
    private(set) var emptyReason: AlbumListEmptyReason?
    private(set) var isLoading = true
    private var loadToken = 0

    func load(_ fetch: () async -> (albums: [AlbumInfo], emptyReason: AlbumListEmptyReason?)) async {
        loadToken += 1
        let token = loadToken
        let result = await fetch()
        // An older fetch can finish after a permission change.
        guard token == loadToken else { return }
        albums = result.albums
        emptyReason = result.emptyReason
        isLoading = false
    }
}

struct AlbumSheetReload: ViewModifier {
    @Environment(LibraryChangeMonitor.self) private var libraryMonitor
    let emptyReason: AlbumListEmptyReason?
    let reload: () async -> Void

    func body(content: Content) -> some View {
        // Sheets can miss scene-phase changes, so retry on UIKit activation.
        content
            .task(id: libraryMonitor.generation) { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                guard emptyReason != nil else { return }
                Task { await reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .photoLibrarySelectionDidChange)) { _ in
                guard emptyReason != nil else { return }
                Task { await reload() }
            }
    }
}
