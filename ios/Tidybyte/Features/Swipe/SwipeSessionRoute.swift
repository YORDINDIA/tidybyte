import Foundation
import SwiftData
import SwiftUI

struct SwipeSessionRoute: Identifiable, Hashable, Sendable {
    let id: UUID
    let filter: SwipeFilter
    /// Names the saved deck this session resumes. Nil keeps the session in
    /// memory only (an explicit id list with no owner).
    let deckKey: String?

    init(id: UUID = UUID(), filter: SwipeFilter, deckKey: String? = nil) {
        self.id = id
        self.filter = filter
        self.deckKey = deckKey ?? filter.deckKey
    }
}

extension SwipeFilter {
    /// The saved deck of a Swipe home filter. An explicit id list has none: the
    /// Cleanup tool or Storage row that builds it passes its own key.
    var deckKey: String? {
        switch self {
        case .allMedia: "allMedia"
        case .allMediaBefore(let date): "allMediaBefore.\(Self.dayKey(date))"
        case .notInAnyAlbum: "notInAnyAlbum"
        case .specificAlbum(let id): "album.\(id)"
        case .notSwipedYet: "notSwipedYet"
        case .screenshots: "screenshots"
        case .worstShots: "worstShots"
        case .largestFirst: "largestFirst"
        case .customAssetIds: nil
        }
    }

    /// The calendar day, so two picks of the same date resume the same deck.
    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct SwipeSessionHostView: View {
    @State private var viewModel: SwipeSessionViewModel

    init(route: SwipeSessionRoute, photoService: PhotoLibraryService, modelContext: ModelContext) {
        _viewModel = State(
            initialValue: SwipeSessionViewModel(
                filter: route.filter,
                deckKey: route.deckKey,
                photoService: photoService,
                modelContext: modelContext
            )
        )
    }

    var body: some View {
        SwipeSessionView(viewModel: viewModel)
            .recentlyDeletedNoticeInset()
    }
}
