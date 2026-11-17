import Foundation
import MacOSCleanerCore
import SwiftUI

/// Grouping dimension shared by the Explore visualizations.
enum ExploreGrouping: String, CaseIterable, Identifiable, Sendable {
    case byFolder
    case byType
    case byAge

    var id: String { rawValue }

    var title: String {
        localizedTitle(language: nil)
    }

    func localizedTitle(language: AppLanguage?) -> String {
        switch self {
        case .byFolder:
            L10n.string("By Folder", language: language)
        case .byType:
            L10n.string("By Type", language: language)
        case .byAge:
            L10n.string("By Age", language: language)
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
        .blue, .teal, .green, .yellow, .orange, .coral, .pink, .purple
    ]

    static func palette(for index: Int) -> CategoricalPalette {
        ramp[safeIfValid: abs(index) % ramp.count] ?? .blue
    }

    /// Palette for a group: By-folder groups resolve through `FolderPastel`
    /// by folder name (stable across scans/views/launches); everything else
    /// cycles the generic categorical ramp by `paletteIndex`. A nil group
    /// (e.g. a connector with no matching branch) falls back to blue.
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
enum ExploreTreeBuilder {
    /// Files larger than this count as "big" for the Age Map spotlight.
    static let bigFileThresholdBytes: Int64 = 100_000_000
    /// Files untouched longer than this surface in the Age Map spotlight.
    static let untouchedThresholdDays = 180

    private static let noExtensionKey = "__none__"
    private static let summarizedFoldersKey = "__summarized__"

    static func filteredFiles(_ files: [FileRecord], nameFilter: String) -> [FileRecord] {
        let trimmed = nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return files
        }
        return files.filter { $0.fileName.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Finds the group matching `id` at any depth in `groups`.
    static func findGroup(id: String, in groups: [ExploreGroup]) -> ExploreGroup? {
        for group in groups {
            if group.id == id {
                return group
            }
            if let child = findGroup(id: id, in: group.children) {
                return child
            }
        }
        return nil
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

    /// All scanned records belonging to a group: folder groups match by normalized
    /// path prefix, type groups match by extension, age groups match by last-touched bucket.
    static func members(of group: ExploreGroup, in files: [FileRecord]) -> [FileRecord] {
        if group.id.hasPrefix("ext:") {
            let ext = String(group.id.dropFirst(4))
            if ext == noExtensionKey || ext == L10n.string("No Extension") {
                return files.filter { ($0.fileExtension ?? "").isEmpty && $0.rolledUpItemCount == nil }
            }
            if ext == summarizedFoldersKey || ext == L10n.string("Summarized Folders") {
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
        let normalizedID = ExploreSubtreeIndex.normalizedPath(group.id)
        let prefix = normalizedID == "/" ? "/" : normalizedID + "/"
        return files.filter { file in
            let standardized = file.url.standardizedFileURL.path
            return standardized == normalizedID || standardized.hasPrefix(prefix)
        }
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
        maxChildren: Int = 12,
        language: AppLanguage? = nil
    ) -> [ExploreGroup] {
        switch grouping {
        case .byFolder:
            buildFolderTree(
                files: files,
                maxDepth: max(1, maxDepth),
                maxChildren: maxChildren,
                language: language
            )
        case .byType:
            buildTypeGroups(files: files, maxChildren: maxChildren, language: language)
        case .byAge:
            buildAgeGroups(files: files, language: language)
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
                SectorAppendArgs(
                    group: group,
                    depth: 1,
                    start: cursor,
                    sweep: sweep,
                    maxDepth: max(1, maxDepth),
                    maxChildren: maxChildren
                ),
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

    private struct ExtensionBucketKey: Hashable {
        let key: String
        let title: String
    }

    private struct ExtensionBucketEntry {
        let key: ExtensionBucketKey
        let files: [FileRecord]
        let totalBytes: Int64
    }

    private static func buildTypeGroups(
        files: [FileRecord],
        maxChildren: Int,
        language: AppLanguage?
    ) -> [ExploreGroup] {
        let grouped = Dictionary(grouping: files) { file -> ExtensionBucketKey in
            if file.rolledUpItemCount != nil {
                return ExtensionBucketKey(
                    key: summarizedFoldersKey,
                    title: L10n.string("Summarized Folders", language: language)
                )
            }
            let ext = (file.fileExtension ?? "").lowercased()
            if ext.isEmpty {
                return ExtensionBucketKey(
                    key: noExtensionKey,
                    title: L10n.string("No Extension", language: language)
                )
            }
            return ExtensionBucketKey(key: ".\(ext)", title: ".\(ext)")
        }
        let sorted: [ExtensionBucketEntry] = grouped
            .map { bucket, bucketFiles in
                ExtensionBucketEntry(
                    key: bucket,
                    files: bucketFiles,
                    totalBytes: bucketFiles.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
                )
            }
            .sorted { $0.totalBytes > $1.totalBytes }
        let kept = Array(sorted.prefix(max(1, maxChildren)))
        var groups = kept.enumerated().map { index, entry in
            ExploreGroup(
                id: "ext:\(entry.key.key)",
                name: entry.key.title,
                bytes: entry.totalBytes,
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
                name: L10n.string("Other", language: language),
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

    private static func buildAgeGroups(files: [FileRecord], language: AppLanguage?) -> [ExploreGroup] {
        let buckets: [(id: String, title: String)] = [
            ("7d", L10n.string("Last 7 days", language: language)),
            ("30d", L10n.string("Last 30 days", language: language)),
            ("90d", L10n.string("Last 90 days", language: language)),
            ("1y", L10n.string("Last year", language: language)),
            ("older", L10n.string("Over a year ago", language: language)),
            ("unknown", L10n.string("Unknown date", language: language))
        ]
        let grouped = Dictionary(grouping: files) { ageBucketID(for: $0) }
        var groups: [ExploreGroup] = []
        for (index, bucket) in buckets.enumerated() {
            guard let bucketMembers = grouped[bucket.id], !bucketMembers.isEmpty else {
                continue
            }
            groups.append(ExploreGroup(
                id: "age:\(bucket.id)",
                name: bucket.title,
                bytes: bucketMembers.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) },
                fileCount: bucketMembers.reduce(0) { $0 + itemCount(of: $1) },
                detail: nil,
                paletteIndex: index,
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

    private struct SectorAppendArgs {
        let group: ExploreGroup
        let depth: Int
        let start: Double
        let sweep: Double
        let maxDepth: Int
        let maxChildren: Int
    }

    private static func appendSectors(_ args: SectorAppendArgs, into out: inout [SunburstSector]) {
        guard args.sweep > 0, args.depth <= args.maxDepth else {
            return
        }
        let group = args.group
        out.append(SunburstSector(
            id: "\(group.id)#\(args.depth)",
            name: group.name,
            bytes: group.bytes,
            fileCount: group.fileCount,
            depth: args.depth,
            startFraction: args.start,
            endFraction: args.start + args.sweep,
            paletteIndex: group.paletteIndex,
            usesFolderPastel: group.usesFolderPastel
        ))
        let kids = Array(group.children.prefix(max(1, args.maxChildren)))
        let kidsTotal = kids.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        guard !kids.isEmpty, kidsTotal > 0 else {
            return
        }
        var cursor = args.start
        for kid in kids {
            let kidSweep = args.sweep * Double(max(0, kid.bytes)) / Double(kidsTotal)
            appendSectors(
                SectorAppendArgs(
                    group: kid,
                    depth: args.depth + 1,
                    start: cursor,
                    sweep: kidSweep,
                    maxDepth: args.maxDepth,
                    maxChildren: args.maxChildren
                ),
                into: &out
            )
            cursor += kidSweep
        }
    }
}
