import Foundation

enum MediaFilter: String, CaseIterable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"

    /// Literals let the localization extractor find the displayed names.
    var displayName: String {
        switch self {
        case .all: L10n.string("All")
        case .photos: L10n.string("Photos")
        case .videos: L10n.string("Videos")
        }
    }
}

enum MediaSortOrder: String, CaseIterable {
    case largest = "Largest"
    case newest = "Newest"
    case oldest = "Oldest"
    case filename = "Filename"

    var displayName: String {
        switch self {
        case .largest: L10n.string("Largest")
        case .newest: L10n.string("Newest")
        case .oldest: L10n.string("Oldest")
        case .filename: L10n.string("Filename")
        }
    }
}

enum MediaAssetFilter {
    static func apply(
        from assets: [AssetSummary],
        mediaFilter: MediaFilter,
        sortOrder: MediaSortOrder
    ) -> [AssetSummary] {
        var result = assets
        switch mediaFilter {
        case .all: break
        case .photos: result = result.filter { $0.mediaType == .photo }
        case .videos: result = result.filter { $0.mediaType == .video }
        }
        switch sortOrder {
        case .largest:
            return result.sorted { $0.fileSize > $1.fileSize }
        case .newest:
            return result.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest:
            return result.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .filename:
            return result.sorted {
                ($0.filename ?? "").localizedCaseInsensitiveCompare($1.filename ?? "") == .orderedAscending
            }
        }
    }
}
