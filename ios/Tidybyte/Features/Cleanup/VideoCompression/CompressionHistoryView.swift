import SwiftUI
import SwiftData

struct CompressionHistoryView: View {
    @Query(sort: \CompressionRecord.compressedAt, order: .reverse) private var records: [CompressionRecord]

    /// COMP-01: failed records carry `compressedSizeBytes == 0`; summing them
    /// would inflate the total with fake savings. Only completed rows count.
    var totalSaved: Int64 {
        records.reduce(0) { $0 + $1.savedBytes }
    }

    /// D15: "N compressions" means completed swaps — skipped (no savings) and
    /// failed attempts are not compressions.
    var completedCount: Int {
        records.filter(\.succeeded).count
    }

    static func icon(for mediaType: String) -> String {
        switch mediaType {
        case "photo": "photo"
        case "livePhoto": "livephoto"
        default: "video"
        }
    }

    /// Readable preset names instead of raw ids ("balanced", "still").
    ///
    /// The video and photo labels come from `CompressionPreset` / 
    /// `PhotoCompressionPreset`, which already resolve through `L10n`. The
    /// "still" id has no preset of its own — it is written by the Live Photos
    /// converter (`LivePhotosConverterViewModel`) — so its label is resolved
    /// here. That one literal was previously returned raw and reached the UI
    /// through `Text(presetLabel(...))`, which renders a `String` verbatim: the
    /// row read "Still image" in every language.
    static func presetLabel(_ id: String) -> String {
        if id == "still" { return L10n.string("Still image") }
        if let video = CompressionPreset.presets.first(where: { $0.id == id }) { return video.label }
        if let photo = PhotoCompressionPreset.presets.first(where: { $0.id == id }) { return photo.label }
        return id
    }

    /// Read here and passed to the date format below. The body re-runs on a
    /// language switch, and the `String` values in each row (such as
    /// `presetLabel`) only update that way.
    @Environment(\.locale) private var locale
    @State private var mediaFilter: HistoryFilter = .all
    /// Newest first is the query order, so it is the default.
    @State private var sortOrder: MediaSortOrder = .newest

    private enum HistoryFilter: String, CaseIterable {
        case all
        case photo
        case video
        case livePhoto

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .photo: "Photos"
            case .video: "Videos"
            case .livePhoto: "Live Photos"
            }
        }
    }

    private var availableFilters: [HistoryFilter] {
        var filters: [HistoryFilter] = [.all]
        let types = Set(records.map(\.mediaType))
        if types.contains("photo") { filters.append(.photo) }
        if types.contains(where: { $0 != "photo" && $0 != "livePhoto" }) { filters.append(.video) }
        if types.contains("livePhoto") { filters.append(.livePhoto) }
        return filters
    }

    private var filteredRecords: [CompressionRecord] {
        let filtered = switch mediaFilter {
        case .all: records
        case .photo: records.filter { $0.mediaType == "photo" }
        case .video: records.filter { $0.mediaType != "photo" && $0.mediaType != "livePhoto" }
        case .livePhoto: records.filter { $0.mediaType == "livePhoto" }
        }
        return switch sortOrder {
        case .oldest: filtered.reversed()
        case .largest: filtered.sorted { $0.originalSizeBytes > $1.originalSizeBytes }
        default: filtered
        }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No History",
                    message: "Compressed photos and videos will appear here.",
                    iconColor: .indigo
                )
            } else {
                List {
                    // Summary
                    Section {
                        CleanupSummaryCard(
                            icon: "arrow.down.circle.fill",
                            tint: Color.successText,
                            headline: Text("\(completedCount) compressions"),
                            subtitle: Text("Total saved: \(totalSaved.formattedFileSize)")
                        )
                        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    if availableFilters.count > 2 {
                        Section {
                            Picker("Filter", selection: $mediaFilter) {
                                ForEach(availableFilters, id: \.self) { filter in
                                    Text(filter.title).tag(filter)
                                }
                            }
                            .pickerStyle(.segmented)
                            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }

                    // Records
                    ForEach(filteredRecords) { record in
                        HStack(spacing: Spacing.md) {
                            if let replacementId = record.replacementAssetLocalIdentifier {
                                AsyncThumbnailView(
                                    assetId: replacementId,
                                    photoService: .shared,
                                    targetSize: CGSize(width: 96, height: 96)
                                )
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                            } else {
                                Image(systemName: Self.icon(for: record.mediaType))
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                                    .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small))
                            }

                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(record.compressedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
                                    .font(.subheadline)

                                Text(Self.presetLabel(record.exportPreset))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if record.replacementAssetLocalIdentifier != nil {
                                    Text("Replacement saved to library")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: Spacing.xs) {
                                // The arrow only when a copy exists: a failed or
                                // skipped row showing "12 MB → Zero KB" read as
                                // a 100% saving.
                                if record.succeeded || record.replacementAssetLocalIdentifier != nil {
                                    HStack(spacing: Spacing.xs) {
                                        Text(record.originalSizeBytes.formattedFileSize)
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel(L10n.string("to"))
                                        Text(record.compressedSizeBytes.formattedFileSize)
                                            .foregroundStyle(.primary)
                                    }
                                    .font(.caption.monospacedDigit())
                                } else {
                                    Text(record.originalSizeBytes.formattedFileSize)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                // COMP-01: failed rows show a "Failed" badge with
                                // zero savings instead of a misleading green
                                // "-X" (compressedSizeBytes == 0 would compute
                                // savings equal to the whole original). Skipped
                                // records (no savings / kept original) are NOT
                                // failures — they render the neutral "No
                                // savings" label instead of a red badge.
                                if record.isFailed {
                                    Text("Failed")
                                        .font(.caption.bold())
                                        .foregroundStyle(.red)
                                } else if record.savedBytes > 0 {
                                    Text("-\(record.savedBytes.formattedFileSize)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.green)
                                } else {
                                    Text("No savings")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                // No pull-to-refresh: `@Query` is live and auto-updates from
                // SwiftData, so a manual refresh gesture could only fake work.
            }
        }
        .localizedNavigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if records.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    SortMenu(selection: $sortOrder, options: [.newest, .oldest, .largest], title: \.displayName)
                }
            }
        }
    }
}
