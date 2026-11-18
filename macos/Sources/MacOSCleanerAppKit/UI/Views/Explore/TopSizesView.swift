import MacOSCleanerCore
import SwiftUI

/// Horizontal ranked bars of the largest groups, biggest first.
struct TopSizesView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var grouping: ExploreGrouping
    var maxDepth: Int
    var nameFilter: String

    @State private var selectedID: String?
    private let rowLimit = 20

    private var override: AppLanguage? {
        model.languageStore.activeOverride
    }

    var body: some View {
        let filtered = model.exploreFilteredFiles(in: files, nameFilter: nameFilter)
        let roots = model.exploreGroups(
            in: files,
            grouping: grouping,
            maxDepth: maxDepth,
            nameFilter: nameFilter
        )
        let groups = Array(roots.sorted { $0.bytes > $1.bytes }.prefix(rowLimit))
        let maxBytes = groups.first?.bytes ?? 1

        return VStack(alignment: .leading, spacing: Spacing.elementTight) {
            if groups.isEmpty {
                ExploreEmptyState(language: override)
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    row(rank: index + 1, group: group, maxBytes: maxBytes, filtered: filtered)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .escape, .space]) { press in
            handleKeyPress(press, groups: groups, filtered: filtered)
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            selectedID = nil
        }
        .onChange(of: grouping) { _, _ in
            selectedID = nil
        }
    }

    private func row(rank: Int, group: ExploreGroup, maxBytes: Int64, filtered: [FileRecord]) -> some View {
        let palette = ExploreChartPalette.palette(for: group)
        let fraction = maxBytes > 0 ? Double(max(0, group.bytes)) / Double(maxBytes) : 0
        let isSelected = selectedID == group.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                let next = isSelected ? nil : group.id
                selectedID = next
                syncSelection(group: next == nil ? nil : group, filtered: filtered)
            } label: {
                summary(rank: rank, group: group, palette: palette, fraction: fraction)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L10n.format(
                "Rank %lld: %@, %@",
                language: override,
                rank,
                group.name,
                group.bytes.formattedByteCount
            )))
            .accessibilityHint(L10n.string("Shows group details", language: override))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                HStack {
                    Spacer()
                    Button(L10n.string("Clear", language: override)) {
                        selectedID = nil
                        model.selectExploreRecord(id: nil)
                    }
                    .buttonStyle(.plain)
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
                }
                ExploreGroupActionsView(model: model, group: group, files: filtered)
            }
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, Spacing.elementTight)
        .softCardSurface(cornerRadius: Radius.cardCompact, isSelected: isSelected)
        .help(L10n.format("%@, %@", language: override, group.name, group.bytes.formattedByteCount))
    }

    private func summary(rank: Int, group: ExploreGroup, palette: CategoricalPalette, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .appFont(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
                .frame(width: 24, alignment: .trailing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.name)
                        .appFont(.bodyMedium)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(group.bytes.formattedByteCount)
                        .appFont(.labelMedium)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(palette.mid)
                                .frame(width: proxy.size.width * CGFloat(min(1, max(0, fraction))))
                        }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                HStack {
                    Text(ExploreCopy.fileCount(group.fileCount, language: override))
                        .appFont(.caption)
                        .foregroundStyle(Color.secondary)
                    if let detail = group.detail, detail != group.name {
                        Text(detail)
                            .appFont(.filePath)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func syncSelection(group: ExploreGroup?, filtered: [FileRecord]) {
        guard let group, let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) else {
            model.selectExploreRecord(id: nil)
            return
        }
        model.selectExploreRecord(id: record.id)
    }

    private func handleKeyPress(_ press: KeyPress, groups: [ExploreGroup], filtered: [FileRecord]) -> KeyPress.Result {
        guard !groups.isEmpty else { return .ignored }
        switch press.key {
        case .upArrow:
            moveSelection(by: -1, groups: groups, filtered: filtered)
            return .handled
        case .downArrow:
            moveSelection(by: 1, groups: groups, filtered: filtered)
            return .handled
        case .escape:
            guard selectedID != nil else { return .ignored }
            selectedID = nil
            model.selectExploreRecord(id: nil)
            return .handled
        case .space:
            guard let group = groups.first(where: { $0.id == selectedID }),
                  let url = ExploreTreeBuilder.largestMember(of: group, in: filtered)?.url else {
                return .ignored
            }
            QuickLookCoordinator.shared.togglePreview([url])
            return .handled
        default:
            return .ignored
        }
    }

    private func moveSelection(by delta: Int, groups: [ExploreGroup], filtered: [FileRecord]) {
        let index = groups.firstIndex(where: { $0.id == selectedID })
        let targetIndex = index.map { max(0, min(groups.count - 1, $0 + delta)) }
            ?? (delta > 0 ? 0 : groups.count - 1)
        let target = groups[targetIndex]
        selectedID = target.id
        syncSelection(group: target, filtered: filtered)
    }
}
