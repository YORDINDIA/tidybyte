import MacOSCleanerCore
import SwiftUI

/// Grid of group cards (folders, extensions, or age buckets) with drill-down.
/// Renders entirely from already-scanned `FileRecord` values.
struct FoldersGridView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var grouping: ExploreGrouping
    var maxDepth: Int
    var nameFilter: String

    /// Ids of the drilled-into groups. Stored as ids so a changed filter or depth
    /// resolves against the current tree instead of showing a stale snapshot.
    @State private var memo = ExploreTreeMemo()
    @State private var drillIDs: [String] = []
    @State private var selectedID: String?

    private var filtered: [FileRecord] {
        ExploreTreeBuilder.filteredFiles(files, nameFilter: nameFilter)
    }

    private var roots: [ExploreGroup] {
        memo.groups(files: files, grouping: grouping, maxDepth: maxDepth, nameFilter: nameFilter)
    }

    /// The drill path resolved against the current tree. Stops at the first missing id.
    private func resolvedPath(in tree: [ExploreGroup]) -> [ExploreGroup] {
        var level = tree
        var path: [ExploreGroup] = []
        for id in drillIDs {
            guard let group = level.first(where: { $0.id == id }) else { break }
            path.append(group)
            level = group.children
        }
        return path
    }

    var body: some View {
        // Build the tree and the path once per render, then pass them down.
        let tree = roots
        let path = resolvedPath(in: tree)
        let visible = path.last?.children ?? tree
        let maxBytes = visible.map(\.bytes).max() ?? 1
        return VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if !path.isEmpty {
                breadcrumb(path)
            }
            if visible.isEmpty {
                ExploreEmptyState()
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: Spacing.elementNormal)],
                    spacing: Spacing.elementNormal
                ) {
                    ForEach(visible) { group in
                        groupCard(for: group, maxBytes: maxBytes)
                    }
                }
                if let selected = visible.first(where: { $0.id == selectedID }) {
                    selectedFooter(for: selected)
                }
            }
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            drillIDs = []
            selectedID = nil
        }
        .onChange(of: grouping) { _, _ in
            drillIDs = []
            selectedID = nil
        }
        // A filter or depth change can hide a drilled folder. Its id would then be unreachable.
        .onChange(of: nameFilter) { _, _ in
            drillIDs = []
        }
        .onChange(of: maxDepth) { _, _ in
            drillIDs = []
        }
    }

    private func breadcrumb(_ path: [ExploreGroup]) -> some View {
        HStack(spacing: 4) {
            Button(String(localized: "All", comment: "Explore breadcrumb root")) {
                drillIDs = []
                selectedID = nil
            }
            .buttonStyle(.plain)
            .appFont(.caption)
            .foregroundStyle(Color.secondary)
            ForEach(path) { crumb in
                Text("/")
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
                Text(crumb.name)
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if path.count > 1 {
                Button(String(localized: "Back", comment: "Explore drill back button")) {
                    drillIDs.removeLast()
                    selectedID = nil
                }
                .buttonStyle(.plain)
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Current folder: \(path.last?.name ?? "")"))
    }

    private func groupCard(for group: ExploreGroup, maxBytes: Int64) -> some View {
        let palette = ExploreChartPalette.palette(for: group)
        let fraction = maxBytes > 0 ? Double(max(0, group.bytes)) / Double(maxBytes) : 0
        return Button {
            if group.children.isEmpty {
                let next = selectedID == group.id ? nil : group.id
                selectedID = next
                if next != nil, let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) {
                    model.selectExploreRecord(id: record.id)
                } else if next == nil {
                    model.selectExploreRecord(id: nil)
                }
            } else {
                drillIDs.append(group.id)
                selectedID = nil
                if let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) {
                    model.focusExploreRecord(id: record.id)
                }
            }
        } label: {
            cardContent(group: group, palette: palette, fraction: fraction)
            .padding(Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                if selectedID == group.id {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.tint, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(groupTooltip(for: group))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(
            localized: "\(group.name), \(group.bytes.formattedByteCount), \(ExploreCopy.fileCount(group.fileCount))")))
        .accessibilityAddTraits(selectedID == group.id ? .isSelected : [])
        .accessibilityHint(group.children.isEmpty
            ? String(localized: "Shows group details")
            : String(localized: "Drills into this group"))
    }

    private func selectedFooter(for group: ExploreGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Text(group.name)
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(group.bytes.formattedByteCount)
                    .appFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                Button(String(localized: "Clear", comment: "Explore clear selection")) {
                    selectedID = nil
                    model.selectExploreRecord(id: nil)
                }
                .buttonStyle(.plain)
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
            }
            ExploreGroupActionsView(
                model: model,
                group: group,
                files: filtered,
                onFocus: { record in
                    if group.children.isEmpty {
                        model.selectExploreRecord(id: record.id)
                    } else {
                        drillIDs.append(group.id)
                        selectedID = nil
                        model.focusExploreRecord(id: record.id)
                    }
                }
            )
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, Spacing.elementTight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Selected: \(group.name), \(group.bytes.formattedByteCount)"))
    }

    private func groupTooltip(for group: ExploreGroup) -> String {
        var parts = ["\(group.name)", group.bytes.formattedByteCount]
        if let detail = group.detail, detail != group.name {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }

    private func cardContent(group: ExploreGroup, palette: CategoricalPalette, fraction: Double) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
            Circle()
                .fill(palette.mid)
                .frame(width: 8, height: 8)
            Text(group.name)
                .appFont(.labelMedium)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if !group.children.isEmpty {
                Image(systemName: "chevron.right")
                    .appFont(.labelMedium)
                    .foregroundStyle(Color.secondary)
            }
        }
        Text(group.bytes.formattedByteCount)
            .appFont(.h4)
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        Text(ExploreCopy.fileCount(group.fileCount))
            .appFont(.caption)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
        GeometryReader { proxy in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(palette.mid)
                        .frame(width: proxy.size.width * CGFloat(min(1, max(0, fraction))))
                }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
    }
}
