import Charts
import MacOSCleanerCore
import SwiftUI

struct MediaKindBreakdown: View {
    let items: [ReviewItem]
    var override: AppLanguage?
    let onPick: (AppDestination) -> Void

    private struct Entry: Identifiable {
        let kind: MediaKind
        let count: Int
        let bytes: Int64
        var id: MediaKind { kind }
    }

    private var entries: [Entry] {
        MediaKind.allCases.compactMap { kind in
            let matching = items.filter { $0.kind == kind }
            guard !matching.isEmpty else { return nil }
            return Entry(kind: kind, count: matching.count, bytes: matching.reduce(0) { $0 + $1.bytes })
        }
        .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        if entries.isEmpty {
            Text(L10n.string("No files in this scope yet.", language: override)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                Chart(entries) { entry in
                    SectorMark(
                        angle: .value(L10n.string("Size", language: override), entry.bytes),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(entry.kind.palette.mid)
                    .cornerRadius(3)
                }
                .frame(height: 160)
                .accessibilityLabel(
                    entries.first.map { entry in
                        L10n.format(
                            "Storage by kind; largest is %@ at %@",
                            language: override,
                            entry.kind.title,
                            entry.bytes.formattedByteCount
                        )
                    } ?? L10n.string("Storage by kind", language: override)
                )
                ForEach(entries) { entry in legendRow(entry) }
            }
        }
    }

    private func legendRow(_ entry: Entry) -> some View {
        Button { onPick(destination(for: entry.kind)) } label: {
            LabeledContent {
                Text(L10n.format("%lld · %@", language: override, entry.count, entry.bytes.formattedByteCount))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(entry.kind.title)
                } icon: {
                    Circle().fill(entry.kind.palette.mid).frame(width: 9, height: 9)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func destination(for kind: MediaKind) -> AppDestination {
        kind == .image || kind == .video ? .media : .largeFiles
    }
}

struct ReclaimHero: View {
    let rows: [(row: AppDestination, bytes: Int64)]
    var override: AppLanguage?
    let onPick: (AppDestination) -> Void

    private var total: Int64 { rows.reduce(0) { $0 + $1.bytes } }
    private var biggest: AppDestination { rows.first?.row ?? .media }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            LabeledContent {
                Text(total.formattedByteCount)
                    .font(.title3.bold())
                    .monospacedDigit()
            } label: {
                Label(L10n.string("You Could Free", language: override), systemImage: "sparkles")
            }
            if rows.count > 1 { segments }
            HStack(alignment: .center) {
                Text(L10n.format("Biggest win: %@", language: override, biggest.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("Review now", language: override)) { onPick(biggest) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var segments: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let widths = Self.segmentWidths(
                for: rows.map(\.bytes),
                availableWidth: proxy.size.width,
                spacing: spacing
            )
            HStack(spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.element.row) { index, item in
                    Button { onPick(item.row) } label: {
                        Capsule()
                            .fill(item.row.palette.mid)
                            .frame(width: widths[index], height: 14)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.format("%@ · %@", language: override, item.row.title, item.bytes.formattedByteCount))
                    .accessibilityLabel(L10n.format(
                        "%@, %@",
                        language: override,
                        item.row.title,
                        item.bytes.formattedByteCount
                    ))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
        }
        .frame(height: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Reclaimable space by area", language: override))
    }

    private static func segmentWidths(for values: [Int64], availableWidth: CGFloat, spacing: CGFloat) -> [CGFloat] {
        guard !values.isEmpty else { return [] }
        let totalSpacing = spacing * CGFloat(max(0, values.count - 1))
        let usable = max(0, availableWidth - totalSpacing)
        guard usable > 0 else { return Array(repeating: 0, count: values.count) }
        let minWidth = min(CGFloat(12), usable / CGFloat(values.count))
        let totalBytes = max(1, values.reduce(Int64(0)) { $0 + max(0, $1) })
        var widths = values.map { bytes -> CGFloat in
            max(minWidth, usable * CGFloat(max(0, bytes)) / CGFloat(totalBytes))
        }
        let overflow = widths.reduce(0, +) - usable
        guard overflow > 0 else { return widths }
        let flexible = widths.reduce(CGFloat(0)) { $0 + max(0, $1 - minWidth) }
        guard flexible > 0 else { return Array(repeating: usable / CGFloat(values.count), count: values.count) }
        widths = widths.map { width in
            let share = max(0, width - minWidth) / flexible
            return max(minWidth, width - overflow * share)
        }
        return widths
    }
}

extension CleanupModel {
    /// Bytes the Photos & Media tools could reclaim, counting each item once
    /// and never selecting the best copy of a group.
    var reclaimableBytes: Int64 {
        guard result?.isFresh == true else { return 0 }
        let fullAssetTools: [CleanupTool] = [
            .duplicates, .similar, .bursts, .blurry, .screenshots, .screenRecordings, .large
        ]
        let keepers = Set(result?.groups.map(\.bestID) ?? [])
        var bytesByID: [String: Int64] = [:]
        for tool in fullAssetTools {
            for item in items(for: tool) where item.canChange && !keepers.contains(item.id) {
                bytesByID[item.id] = item.bytes
            }
        }
        for item in items(for: .livePhotos) where item.canChange && !keepers.contains(item.id) {
            if bytesByID[item.id] == nil {
                let videoBytes = item.resources
                    .filter { $0.type == 9 || $0.type == 10 }
                    .reduce(Int64(0)) { $0 + max(0, $1.bytes) }
                bytesByID[item.id] = videoBytes > 0 ? videoBytes : item.bytes
            }
        }
        let allowed = MediaAnalysisService.safeSelection(Set(bytesByID.keys), groups: result?.groups ?? [])
        return bytesByID.filter { allowed.contains($0.key) }.values.reduce(0, +)
    }
}

/// Size of ~/.Trash. Reading it needs Full Disk Access; nil means unknown.
enum TrashMeasure {
    static func userTrashBytes() async -> Int64? {
        await Task.detached(priority: .utility) {
            let trash = ReviewSafety.userHome.appendingPathComponent(".Trash")
            guard (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil,
                  let files = FileManager.default.enumerator(
                      at: trash,
                      includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
                  )
            else { return nil }
            var total: Int64 = 0
            while let file = files.nextObject() as? URL {
                if Task.isCancelled { return nil }
                guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                else { return nil }
                if values.isRegularFile == true { total += Int64(values.totalFileAllocatedSize ?? 0) }
            }
            return total
        }.value
    }
}
