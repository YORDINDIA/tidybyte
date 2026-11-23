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
    case longest = "Longest"

    var displayName: String {
        switch self {
        case .largest: L10n.string("Largest")
        case .newest: L10n.string("Newest")
        case .oldest: L10n.string("Oldest")
        case .filename: L10n.string("Filename")
        case .longest: L10n.string("Longest")
        }
    }

    /// `items` in this order. Swift's sort is stable, so ties keep their
    /// incoming order. An unknown size is 0, so Largest puts it last.
    func sorted<T>(_ items: [T], asset: (T) -> AssetSummary) -> [T] {
        switch self {
        case .largest:
            items.sorted { asset($0).fileSize > asset($1).fileSize }
        case .newest:
            items.sorted { (asset($0).creationDate ?? .distantPast) > (asset($1).creationDate ?? .distantPast) }
        case .oldest:
            items.sorted { (asset($0).creationDate ?? .distantPast) < (asset($1).creationDate ?? .distantPast) }
        case .filename:
            items.sorted {
                (asset($0).filename ?? "").localizedCaseInsensitiveCompare(asset($1).filename ?? "") == .orderedAscending
            }
        case .longest:
            // Photos have no duration: among them, and among equal lengths,
            // the larger file comes first.
            items.sorted {
                let (a, b) = (asset($0), asset($1))
                return a.duration != b.duration ? a.duration > b.duration : a.fileSize > b.fileSize
            }
        }
    }
}

/// Order of a tool's result groups (bursts, duplicates, similar photos).
enum GroupSortOrder: String, CaseIterable {
    case mostItems, largest, newest, oldest

    var displayName: String {
        switch self {
        case .mostItems: L10n.string("Most Items")
        case .largest: L10n.string("Largest")
        case .newest: L10n.string("Newest")
        case .oldest: L10n.string("Oldest")
        }
    }

    /// `groups` in this order. Largest is the group's total size, Newest its
    /// latest photo, Oldest its earliest. Keys are read once per group, and
    /// the sort is stable.
    func sorted<G>(_ groups: [G], assets: (G) -> [AssetSummary]) -> [G] {
        let keyed: [(group: G, key: Double)] = groups.map { group in
            let members = assets(group)
            let key: Double = switch self {
            case .mostItems: Double(members.count)
            case .largest: Double(members.reduce(Int64(0)) { $0 + $1.fileSize })
            case .newest: members.compactMap(\.creationDate).max()?.timeIntervalSinceReferenceDate ?? -.infinity
            case .oldest: -(members.compactMap(\.creationDate).min()?.timeIntervalSinceReferenceDate ?? .infinity)
            }
            return (group, key)
        }
        return keyed.sorted { $0.key > $1.key }.map(\.group)
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
        return sortOrder.sorted(result) { $0 }
    }
}
