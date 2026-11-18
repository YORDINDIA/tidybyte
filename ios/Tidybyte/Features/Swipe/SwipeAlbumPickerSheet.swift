import SwiftUI
import UIKit

/// Album picker for the Swipe tab's "Specific Album" filter.
///
/// Loads its album list inside the sheet (`.task`) rather than relying on
/// parent state set just before presentation — a `.sheet(isPresented:)` content
/// closure isn't a dependency of the parent body, so pre-set parent state isn't
/// reliably reflected and the list rendered empty. Owning the data here (the
/// same pattern as `AlbumPickerSheet`) fixes that and lets us show explicit
/// loading and empty states.
struct SwipeAlbumPickerSheet: View {
    let photoService: PhotoLibraryService
    /// Called with the chosen album's local identifier. The sheet dismisses
    /// itself after; the caller starts the swipe session on dismissal so the
    /// navigation push isn't dropped by the simultaneous sheet dismissal.
    let onSelect: (String) -> Void

    @State private var albumState = AlbumSheetState()
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredAlbums: [AlbumInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return albumState.albums }
        return albumState.albums.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if albumState.isLoading {
                    ProgressView("Loading albums…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let reason = albumState.emptyReason {
                    ScrollView {
                        PhotoRecoveryCard(presentation: reason.recovery) { action in
                            switch action {
                            case .retry:
                                Task { await loadAlbums() }
                            case .addPhotos, .openSettings:
                                PhotoRecoveryPresentation.Action.perform(action)
                            }
                        }
                        .padding(.vertical, Spacing.xl)
                    }
                } else if filteredAlbums.isEmpty {
                    EmptyStateView(
                        icon: "rectangle.stack",
                        title: "No Albums",
                        message: albumState.albums.isEmpty
                            ? "No albums with photos were found."
                            : "Try a different search term.",
                        iconColor: .teal
                    )
                } else {
                    List(filteredAlbums) { album in
                        Button {
                            onSelect(album.id)
                            dismiss()
                        } label: {
                            HStack(spacing: Spacing.md) {
                                AsyncAlbumThumbnail(assetId: album.thumbnailAssetId, photoService: photoService)
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))

                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text(album.title)
                                        .font(.body)
                                    Text("\(album.count) items")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .localizedNavigationTitle("Select Album")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .modifier(AlbumSheetReload(emptyReason: albumState.emptyReason) { await loadAlbums() })
    }

    private func loadAlbums() async {
        await albumState.load { await AlbumSheetLoader.load(photoService: photoService, editableOnly: false) }
    }
}
