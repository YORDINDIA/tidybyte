import MacOSCleanerCore
import SwiftUI

/// Non-destructive Photos album picker sheet for Swipe Review.
struct SwipeAlbumPickerSheet: View {
    let item: ReviewItem
    @Bindable var model: CleanupModel
    let onAdded: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var albums: [(id: String, title: String)] = []
    @State private var newTitle = ""
    @State private var isWorking = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            HStack(spacing: Spacing.elementNormal) {
                ReviewPreview(item: item, model: model, thumbnail: true)
                    .frame(width: 64, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.cardCompact))
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Add to Album")).font(.title3.weight(.semibold))
                    Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(SemanticScale.error)
            }

            HStack(spacing: Spacing.elementTight) {
                TextField(String(localized: "New album name"), text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                Button(String(localized: "Create & Add")) {
                    Task { await createAndAdd() }
                }
                .disabled(isWorking || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                if albums.isEmpty {
                    Text(String(localized: "No editable albums found. Create a new album above."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(albums, id: \.id) { album in
                        Button {
                            Task { await add(to: album.id, title: album.title) }
                        } label: {
                            Label(album.title, systemImage: "rectangle.stack")
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                    }
                }
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.cardPadding)
        .frame(minWidth: 420, minHeight: 380)
        .presentationSizing(.form)
        .task { await loadAlbums() }
    }

    private func loadAlbums() async {
        albums = await model.photos.fetchUserAlbums()
    }

    private func createAndAdd() async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let albumID = try await model.photos.createAlbum(title: trimmed)
            try await model.photos.addToAlbum(item: item, albumID: albumID)
            onAdded(trimmed)
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func add(to albumID: String, title: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.photos.addToAlbum(item: item, albumID: albumID)
            onAdded(title)
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }
}
