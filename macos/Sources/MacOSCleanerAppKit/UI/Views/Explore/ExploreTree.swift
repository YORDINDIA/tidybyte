import Foundation
import SwiftUI
import MacOSCleanerCore

/// Grouping dimension shared by the Explore visualizations.
enum ExploreGrouping: String, CaseIterable, Identifiable, Sendable {
    case byFolder
    case byType
    case byAge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .byFolder:
            String(localized: "By Folder", comment: "Explore grouping option")
        case .byType:
            String(localized: "By Type", comment: "Explore grouping option")
        case .byAge:
            String(localized: "By Age", comment: "Explore grouping option")
        }
    }
}

/// One aggregated node rendered by the Explore visualizations.
/// Built from already-scanned `FileRecord` values; no new scanning logic.
struct ExploreGroup: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var bytes: Int64
    var fileCount: Int
    /// Tooltip subtitle, e.g. the full folder path.
    var detail: String?
    /// Stable color assignment: siblings cycle the chart palette,
    /// descendants inherit their top-level ancestor's index.
    var paletteIndex: Int
    /// True for By-folder groups: views resolve the color from
    /// `FolderPastel` by folder name instead of `paletteIndex`, so the same
    /// folder keeps its pastel across scans, views, and launches.
    var usesFolderPastel: Bool = false
    var children: [ExploreGroup]
}

/// A flattened slice of the folder tree for radial / icicle layouts.
/// Fractions are relative to the grand total (0..<1).
struct SunburstSector: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var bytes: Int64
    var fileCount: Int
    var depth: Int
    var startFraction: Double
    var endFraction: Double
    var paletteIndex: Int
    /// Mirrors `ExploreGroup.usesFolderPastel` so radial/icicle views keep
    /// folder pastels without re-deriving the grouping.
    var usesFolderPastel: Bool = false

    var sweepFraction: Double { max(0, endFraction - startFraction) }
}

/// Categorical chart palette cycled by `paletteIndex`. System colors adapt
/// to light, dark, and Increase Contrast on their own.
enum ExploreChartPalette {
    // CategoricalPalette wraps SwiftUI Color (non-Sendable); the ramp is
    // immutable after initialization, so unchecked shared access is safe.
    nonisolated(unsafe) private static let ramp: [CategoricalPalette] = [
        .blue, .teal, .green, .yellow, .orange, .coral, .pink, .purple,
    ]

    static func palette(for index: Int) -> CategoricalPalette {
        ramp[safeIfValid: abs(index) % ramp.count] ?? .blue
    }

    /// Palette for a group: By-folder groups resolve through `FolderPastel`
    /// by folder name (stable across scans/views/launches); everything else
    /// cycles the generic categorical ramp by `paletteIndex`. A nil group
    /// (e.g. a connector with no matching branch) falls back to sky.
    static func palette(for group: ExploreGroup?) -> CategoricalPalette {
        guard let group else {
            return .blue
        }
        guard group.usesFolderPastel else {
            return palette(for: group.paletteIndex)
        }
        return FolderPastel.palette(forFolderName: group.name)
    }

    /// Non-optional convenience over the optional overload.
    static func palette(for group: ExploreGroup) -> CategoricalPalette {
        palette(for: Optional(group))
    }

    /// Palette for a radial/flame sector: folder sectors resolve through
    /// `FolderPastel` by name; others cycle the generic ramp by index.
    static func palette(for sector: SunburstSector) -> CategoricalPalette {
        guard sector.usesFolderPastel else {
            return palette(for: sector.paletteIndex)
        }
        return FolderPastel.palette(forFolderName: sector.name)
    }
}

extension Array {
    subscript(safeIfValid index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Stateless builder turning scanned files into visualization-ready groups.
/// Stateless `enum` namespace per the codebase's service conventions.
enum ExploreTreeBuilder {
    /// Files larger than this count as "big" for the Age Map spotlight.
    static let bigFileThresholdBytes: Int64 = 100_000_000
    /// Files untouched longer than this surface in the Age Map spotlight.
    static let untouchedThresholdDays = 180

    static func filteredFiles(_ files: [FileRecord], nameFilter: String) -> [FileRecord] {
        let trimmed = nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return files
        }
        return files.filter { $0.fileName.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Largest member of a group by scanned size. Used to Focus/Stage a
    /// concrete FileRecord from an aggregated group selection.
    static func largestMember(of group: ExploreGroup, in files: [FileRecord]) -> FileRecord? {
        members(of: group, in: files).max { $0.sizeBytes < $1.sizeBytes }
    }

    /// Items one record stands for in a file count. A summarized folder stands
    /// for its items; a plain folder or package stands for none.
    static func itemCount(of file: FileRecord) -> Int {
        file.rolledUpItemCount ?? (file.kind == .directory || file.kind == .package ? 0 : 1)
    }

    /// All scanned records belonging to a group: folder groups match by path
    /// prefix (their `id` is the folder path), type groups match by extension,
    /// age groups match by last-touched bucket.
    static func members(of group: ExploreGroup, in files: [FileRecord]) -> [FileRecord] {
        if group.id.hasPrefix("ext:") {
            let ext = String(group.id.dropFirst(4))
            if ext == String(localized: "No Extension", comment: "Explore extension key for files without one") {
                return files.filter { ($0.fileExtension ?? "").isEmpty }
            }
            if ext == summarizedFoldersTitle {
                return files.filter { $0.rolledUpItemCount != nil }
            }
            let wanted = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
            return files.filter { ($0.fileExtension ?? "").lowercased() == wanted.lowercased() }
        }
        if group.id.hasPrefix("age:") {
            let bucket = String(group.id.dropFirst(4))
            return files.filter { ageBucketID(for: $0) == bucket }
        }
        if group.id == "__other__" {
            return []
        }
        let prefix = group.id.hasSuffix("/") ? group.id : group.id + "/"
        return files.filter { $0.url.path == group.id || $0.url.path.hasPrefix(prefix) }
    }

    /// Age-bucket id matching `buildAgeGroups` ("7d" | "30d" | "90d" | "1y" | "older" | "unknown").
    static func ageBucketID(for file: FileRecord) -> String {
        guard let touched = lastTouchedDate(for: file) else {
            return "unknown"
        }
        let days = Date().timeIntervalSince(touched) / 86_400
        if days <= 7 {
            return "7d"
        }
        if days <= 30 {
            return "30d"
        }
        if days <= 90 {
            return "90d"
        }
        if days <= 365 {
            return "1y"
        }
        return "older"
    }

    /// Top-level groups for the requested dimension.
    static func build(
        files: [FileRecord],
        grouping: ExploreGrouping,
        maxDepth: Int,
        maxChildren: Int = 12
    ) -> [ExploreGroup] {
        switch grouping {
        case .byFolder:
            buildFolderTree(files: files, maxDepth: max(1, maxDepth), maxChildren: maxChildren)
        case .byType:
            buildTypeGroups(files: files, maxChildren: maxChildren)
        case .byAge:
            buildAgeGroups(files: files)
        }
    }

    /// Flattened radial sectors (depth 1 = first ring) for sunburst / flame.
    static func sectors(
        groups: [ExploreGroup],
        maxDepth: Int,
        maxChildren: Int = 10
    ) -> [SunburstSector] {
        let total = groups.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        guard total > 0 else {
            return []
        }
        var out: [SunburstSector] = []
        var cursor = 0.0
        for group in groups {
            let sweep = Double(max(0, group.bytes)) / Double(total)
            appendSectors(
                group: group,
                depth: 1,
                start: cursor,
                sweep: sweep,
                maxDepth: max(1, maxDepth),
                maxChildren: maxChildren,
                into: &out
            )
            cursor += sweep
        }
        return out
    }

    /// Sectors regrouped into one row per depth level, ordered left to right.
    static func flameRows(
        groups: [ExploreGroup],
        maxDepth: Int,
        maxChildren: Int = 10
    ) -> [[SunburstSector]] {
        let flat = sectors(groups: groups, maxDepth: maxDepth, maxChildren: maxChildren)
        let byDepth = Dictionary(grouping: flat, by: \.depth)
        return byDepth.keys.sorted().compactMap { depth in
            byDepth[depth]?.sorted { $0.startFraction < $1.startFraction }
        }
    }

    // MARK: - By Type

    /// Group title for summarized folders in By Type. Shared with `members(of:)`.
    private static var summarizedFoldersTitle: String {
        String(localized: "Summarized Folders", comment: "Explore group for folders shown as one total")
    }

    private static func buildTypeGroups(files: [FileRecord], maxChildren: Int) -> [ExploreGroup] {
        let grouped = Dictionary(grouping: files) { file -> String in
            // A folder name is not a file type: summarized folders get one group.
            if file.rolledUpItemCount != nil {
                return summarizedFoldersTitle
            }
            let ext = (file.fileExtension ?? "").lowercased()
            return ext.isEmpty
                ? String(localized: "No Extension", comment: "Explore group for files without an extension")
                : ".\(ext)"
        }
        let sorted = grouped.map { (key: $0.key, files: $0.value) }.sorted {
            $0.files.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
                > $1.files.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
        }
        let kept = Array(sorted.prefix(max(1, maxChildren)))
        var groups = kept.enumerated().map { index, entry in
            ExploreGroup(
                id: "ext:\(entry.key)",
                name: entry.key,
                bytes: entry.files.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) },
                fileCount: entry.files.reduce(0) { $0 + itemCount(of: $1) },
                detail: nil,
                paletteIndex: index,
                children: []
            )
        }
        let remainder = sorted.dropFirst(kept.count)
        if !remainder.isEmpty {
            let rest = remainder.flatMap(\.files)
            groups.append(ExploreGroup(
                id: "__other__",
                name: String(localized: "Other", comment: "Explore rollup group for small entries"),
                bytes: rest.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) },
                fileCount: rest.reduce(0) { $0 + itemCount(of: $1) },
                detail: nil,
                paletteIndex: kept.count,
                children: []
            ))
        }
        return groups
    }

    // MARK: - By Age

    private static func buildAgeGroups(files: [FileRecord]) -> [ExploreGroup] {
        let now = Date()
        let buckets: [(id: String, title: String)] = [
            ("7d", String(localized: "Last 7 days", comment: "Explore age bucket")),
            ("30d", String(localized: "Last 30 days", comment: "Explore age bucket")),
            ("90d", String(localized: "Last 90 days", comment: "Explore age bucket")),
            ("1y", String(localized: "Last year", comment: "Explore age bucket")),
            ("older", String(localized: "Over a year ago", comment: "Explore age bucket"))
        ]
        var bucketed: [String: [FileRecord]] = [:]
        var unknown: [FileRecord] = []
        for file in files {
            guard let touched = lastTouchedDate(for: file) else {
                unknown.append(file)
                continue
            }
            let days = now.timeIntervalSince(touched) / 86_400
            if days < 0 {
                bucketed["7d", default: []].append(file)
            } else if days <= 7 {
                bucketed["7d", default: []].append(file)
            } else if days <= 30 {
                bucketed["30d", default: []].append(file)
            } else if days <= 90 {
                bucketed["90d", default: []].append(file)
            } else if days <= 365 {
                bucketed["1y", default: []].append(file)
            } else {
                bucketed["older", default: []].append(file)
            }
        }
        var groups: [ExploreGroup] = []
        for (index, bucket) in buckets.enumerated() {
            guard let members = bucketed[bucket.id], !members.isEmpty else {
                continue
            }
            groups.append(ExploreGroup(
                id: "age:\(bucket.id)",
                name: bucket.title,
                bytes: members.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) },
                fileCount: members.reduce(0) { $0 + itemCount(of: $1) },
                detail: nil,
                paletteIndex: index,
                children: []
            ))
        }
        if !unknown.isEmpty {
            groups.append(ExploreGroup(
                id: "age:unknown",
                name: String(localized: "Unknown date", comment: "Explore age bucket for files without dates"),
                bytes: unknown.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) },
                fileCount: unknown.reduce(0) { $0 + itemCount(of: $1) },
                detail: nil,
                paletteIndex: buckets.count,
                children: []
            ))
        }
        return groups
    }

    /// Most recent evidence the file was touched; nil when no date is known.
    static func lastTouchedDate(for file: FileRecord) -> Date? {
        [file.lastOpenedAt, file.modifiedAt, file.createdAt].compactMap { $0 }.max()
    }

    /// Large files quiet for a long time — the Age Map spotlight list.
    static func bigUntouchedFiles(in files: [FileRecord], limit: Int = 10) -> [FileRecord] {
        let cutoff = Date().addingTimeInterval(-Double(untouchedThresholdDays) * 86_400)
        return files
            .filter { $0.sizeBytes >= bigFileThresholdBytes }
            .filter { file in
                guard let touched = lastTouchedDate(for: file) else {
                    return true
                }
                return touched < cutoff
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(max(1, limit))
            .map { $0 }
    }

    // MARK: - Sectors

    private static func appendSectors(
        group: ExploreGroup,
        depth: Int,
        start: Double,
        sweep: Double,
        maxDepth: Int,
        maxChildren: Int,
        into out: inout [SunburstSector]
    ) {
        guard sweep > 0, depth <= maxDepth else {
            return
        }
        out.append(SunburstSector(
            id: "\(group.id)#\(depth)",
            name: group.name,
            bytes: group.bytes,
            fileCount: group.fileCount,
            depth: depth,
            startFraction: start,
            endFraction: start + sweep,
            paletteIndex: group.paletteIndex,
            usesFolderPastel: group.usesFolderPastel
        ))
        let kids = Array(group.children.prefix(max(1, maxChildren)))
        guard !kids.isEmpty else {
            return
        }
        let kidsTotal = kids.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        guard kidsTotal > 0 else {
            return
        }
        var cursor = start
        for kid in kids {
            let kidSweep = sweep * Double(max(0, kid.bytes)) / Double(kidsTotal)
            appendSectors(
                group: kid,
                depth: depth + 1,
                start: cursor,
                sweep: kidSweep,
                maxDepth: maxDepth,
                maxChildren: maxChildren,
                into: &out
            )
            cursor += kidSweep
        }
    }
}
