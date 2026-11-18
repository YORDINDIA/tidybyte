import MacOSCleanerCore
import SwiftUI

/// Grid of group cards (folders, extensions, or age buckets) with drill-down,
/// keyboard navigation, and Quick Look support.
struct FoldersGridView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var grouping: ExploreGrouping
    var maxDepth: Int
    var nameFilter: String

    @State private var drillIDs: [String] = []
    @State private var selectedID: String?

    private var override: AppLanguage? {
        model.languageStore.activeOverride
    }

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
        let filtered = model.exploreFilteredFiles(in: files, nameFilter: nameFilter)
        let tree = model.exploreGroups(
            in: files,
            grouping: grouping,
            maxDepth: maxDepth,
            nameFilter: nameFilter
        )
        let path = resolvedPath(in: tree)
        let visible = path.last?.children ?? tree
        let maxBytes = visible.map(\.bytes).max() ?? 1

        return VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if !path.isEmpty {
                breadcrumb(path)
            }
            if visible.isEmpty {
                ExploreEmptyState(language: override)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: Spacing.elementNormal)],
                    spacing: Spacing.elementNormal
                ) {
                    ForEach(visible) { group in
                        groupCard(for: group, maxBytes: maxBytes, filtered: filtered)
                    }
                }
                if let selected = visible.first(where: { $0.id == selectedID }) {
                    selectedFooter(for: selected, filtered: filtered)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape, .space]) { press in
            handleKeyPress(press, visible: visible, filtered: filtered)
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            drillIDs = []
            selectedID = nil
        }
        .onChange(of: grouping) { _, _ in
            drillIDs = []
            selectedID = nil
        }
        .onChange(of: nameFilter) { _, _ in
            drillIDs = []
        }
        .onChange(of: maxDepth) { _, _ in
            drillIDs = []
        }
    }
}

extension FoldersGridView {
    private func breadcrumb(_ path: [ExploreGroup]) -> some View {
        HStack(spacing: 6) {
            Button(L10n.string("All", language: override)) {
                drillIDs = []
                selectedID = nil
                model.selectExploreRecord(id: nil)
            }
            .buttonStyle(.plain)
            .appFont(.caption)
            .foregroundStyle(Color.secondary)

            ForEach(Array(path.enumerated()), id: \.element.id) { index, crumb in
                Image(systemName: "chevron.forward")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                Button(crumb.name) {
                    drillIDs = Array(drillIDs.prefix(index + 1))
                    selectedID = nil
                }
                .buttonStyle(.plain)
                .appFont(.caption)
                .foregroundStyle(index == path.count - 1 ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if path.count > 1 {
                Button(L10n.string("Back", language: override)) {
                    drillIDs.removeLast()
                    selectedID = nil
                }
                .buttonStyle(.plain)
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, Spacing.elementTight)
        .floatingGlassOverlay(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("Current folder: %@", language: override, path.last?.name ?? ""))
    }

    private func groupCard(for group: ExploreGroup, maxBytes: Int64, filtered: [FileRecord]) -> some View {
        let palette = ExploreChartPalette.palette(for: group)
        let fraction = maxBytes > 0 ? Double(max(0, group.bytes)) / Double(maxBytes) : 0
        let isSelected = selectedID == group.id
        return Button {
            if group.children.isEmpty {
                let next = isSelected ? nil : group.id
                selectedID = next
                syncSelection(group: next == nil ? nil : group, filtered: filtered)
            } else {
                drillInto(group, filtered: filtered)
            }
        } label: {
            cardContent(group: group, palette: palette, fraction: fraction)
                .padding(Spacing.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .softCardSurface(cornerRadius: Radius.card, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help(groupTooltip(for: group))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format(
            "%@, %@, %@",
            language: override,
            group.name,
            group.bytes.formattedByteCount,
            ExploreCopy.fileCount(group.fileCount, language: override)
        )))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(group.children.isEmpty
            ? L10n.string("Shows group details", language: override)
            : L10n.string("Drills into this group", language: override))
    }

    private func selectedFooter(for group: ExploreGroup, filtered: [FileRecord]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Text(group.name)
                    .appFont(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(group.bytes.formattedByteCount)
                    .appFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                Button(L10n.string("Clear", language: override)) {
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
        .padding(Spacing.cardPadding)
        .softCardSurface(cornerRadius: Radius.cardCompact)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("Selected: %@, %@", language: override, group.name, group.bytes.formattedByteCount))
    }

    private func groupTooltip(for group: ExploreGroup) -> String {
        var parts = [group.name, group.bytes.formattedByteCount]
        if let detail = group.detail, detail != group.name {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }

    private func cardContent(group: ExploreGroup, palette: CategoricalPalette, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    Image(systemName: "chevron.forward")
                        .appFont(.labelMedium)
                        .foregroundStyle(Color.secondary)
                }
            }
            Text(group.bytes.formattedByteCount)
                .appFont(.h4)
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(ExploreCopy.fileCount(group.fileCount, language: override))
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

    private func drillInto(_ group: ExploreGroup, filtered: [FileRecord]) {
        drillIDs.append(group.id)
        selectedID = nil
        if let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) {
            model.focusExploreRecord(id: record.id)
            model.selectExploreRecord(id: record.id)
        }
    }

    private func syncSelection(group: ExploreGroup?, filtered: [FileRecord]) {
        guard let group, let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) else {
            model.selectExploreRecord(id: nil)
            return
        }
        model.selectExploreRecord(id: record.id)
    }

    private func handleKeyPress(
        _ press: KeyPress,
        visible: [ExploreGroup],
        filtered: [FileRecord]
    ) -> KeyPress.Result {
        guard !visible.isEmpty else { return .ignored }
        if press.key == .leftArrow || press.key == .upArrow {
            moveSelection(by: -1, visible: visible, filtered: filtered)
            return .handled
        }
        if press.key == .rightArrow || press.key == .downArrow {
            moveSelection(by: 1, visible: visible, filtered: filtered)
            return .handled
        }
        return handleActionKey(press.key, visible: visible, filtered: filtered)
    }

    private func handleActionKey(
        _ key: KeyEquivalent,
        visible: [ExploreGroup],
        filtered: [FileRecord]
    ) -> KeyPress.Result {
        switch key {
        case .return:
            guard let group = visible.first(where: { $0.id == selectedID }), !group.children.isEmpty else {
                return .ignored
            }
            drillInto(group, filtered: filtered)
            return .handled
        case .escape:
            if selectedID != nil {
                selectedID = nil
                model.selectExploreRecord(id: nil)
                return .handled
            }
            if !drillIDs.isEmpty {
                drillIDs.removeLast()
                return .handled
            }
            return .ignored
        case .space:
            guard let group = visible.first(where: { $0.id == selectedID }),
                  let url = ExploreTreeBuilder.largestMember(of: group, in: filtered)?.url else {
                return .ignored
            }
            QuickLookCoordinator.shared.togglePreview([url])
            return .handled
        default:
            return .ignored
        }
    }

    private func moveSelection(by delta: Int, visible: [ExploreGroup], filtered: [FileRecord]) {
        let index = visible.firstIndex(where: { $0.id == selectedID })
        let targetIndex = index.map { max(0, min(visible.count - 1, $0 + delta)) }
            ?? (delta > 0 ? 0 : visible.count - 1)
        let target = visible[targetIndex]
        selectedID = target.id
        syncSelection(group: target, filtered: filtered)
    }
}
