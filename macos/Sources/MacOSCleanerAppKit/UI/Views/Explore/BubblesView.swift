import MacOSCleanerCore
import SwiftUI

/// Packed circles: each group is a circle sized proportionally by bytes,
/// laid out deterministically via the shared Explore spiral layout cache.
struct BubblesView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var grouping: ExploreGrouping
    var maxDepth: Int
    var nameFilter: String

    @State private var selectedID: String?
    @State private var hoveredID: String?

    private var override: AppLanguage? {
        model.languageStore.activeOverride
    }

    var body: some View {
        let filtered = model.exploreFilteredFiles(in: files, nameFilter: nameFilter)
        let bubbles = model.explorePlacedBubbles(
            in: files,
            grouping: grouping,
            maxDepth: maxDepth,
            nameFilter: nameFilter
        )
        return VStack(spacing: Spacing.elementNormal) {
            if bubbles.isEmpty {
                ExploreEmptyState(language: override)
            } else {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height, 340)
                    let xOffset = (proxy.size.width - side) / 2
                    ZStack {
                        ForEach(bubbles) { bubble in
                            bubbleView(bubble, canvas: side, xOffset: xOffset, filtered: filtered)
                        }
                    }
                    .frame(width: proxy.size.width, height: max(side, 200))
                }
                .frame(minHeight: 220, maxHeight: 360)
                if let selected = bubbles.first(where: { $0.id == selectedID })?.group {
                    selectedFooter(for: selected, filtered: filtered)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .escape, .space]) { press in
            handleKeyPress(press, bubbles: bubbles, filtered: filtered)
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            selectedID = nil
        }
        .onChange(of: grouping) { _, _ in
            selectedID = nil
        }
    }

    private func bubbleView(
        _ bubble: ExploreSnapshotCache.PlacedBubble,
        canvas: CGFloat,
        xOffset: CGFloat,
        filtered: [FileRecord]
    ) -> some View {
        let palette = ExploreChartPalette.palette(for: bubble.group)
        let diameter = max(14, bubble.radius * 2 * canvas)
        let isSelected = selectedID == bubble.id
        let isHovered = hoveredID == bubble.id
        let showsLabel = diameter > 56
        return Button {
            select(bubble.group, filtered: filtered)
        } label: {
            ZStack {
                Circle()
                    .fill(palette.mid.opacity(isHovered || isSelected ? 0.94 : 0.82))
                if showsLabel {
                    VStack(spacing: 1) {
                        Text(bubble.group.name)
                            .appFont(.caption)
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                        Text(bubble.group.bytes.formattedByteCount)
                            .appFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(palette.ink.opacity(0.88))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(0.28),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            .shadow(color: Color.black.opacity(isSelected ? 0.18 : 0.06), radius: isSelected ? 6 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredID = inside ? bubble.id : (hoveredID == bubble.id ? nil : hoveredID)
        }
        .position(x: xOffset + bubble.center.x * canvas, y: bubble.center.y * canvas)
        .help(tooltip(for: bubble.group))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format("%@, %@", language: override, bubble.group.name, bubble.group.bytes.formattedByteCount)))
        .accessibilityHint(L10n.string("Shows group details", language: override))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectedFooter(for group: ExploreGroup, filtered: [FileRecord]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack(spacing: Spacing.elementTight) {
                Text(group.name)
                    .appFont(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(L10n.format(
                    "%@ · %@",
                    language: override,
                    group.bytes.formattedByteCount,
                    ExploreCopy.fileCount(group.fileCount, language: override)
                ))
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
            ExploreGroupActionsView(model: model, group: group, files: filtered)
        }
        .padding(Spacing.cardPadding)
        .softCardSurface(cornerRadius: Radius.cardCompact)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("Selected: %@, %@", language: override, group.name, group.bytes.formattedByteCount))
    }

    private func select(_ group: ExploreGroup, filtered: [FileRecord]) {
        let next = selectedID == group.id ? nil : group.id
        selectedID = next
        syncExploreSelection(group: next == nil ? nil : group, filtered: filtered)
    }

    private func syncExploreSelection(group: ExploreGroup?, filtered: [FileRecord]) {
        guard let group, let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) else {
            model.selectExploreRecord(id: nil)
            return
        }
        model.selectExploreRecord(id: record.id)
    }

    private func tooltip(for group: ExploreGroup) -> String {
        let summary = L10n.format(
            "%@ · %@",
            language: override,
            group.bytes.formattedByteCount,
            ExploreCopy.fileCount(group.fileCount, language: override)
        )
        if let detail = group.detail, detail != group.name {
            return "\(group.name) — \(summary)\n\(detail)"
        }
        return "\(group.name) — \(summary)"
    }

    private func handleKeyPress(
        _ press: KeyPress,
        bubbles: [ExploreSnapshotCache.PlacedBubble],
        filtered: [FileRecord]
    ) -> KeyPress.Result {
        guard !bubbles.isEmpty else { return .ignored }
        switch press.key {
        case .leftArrow, .upArrow:
            moveSelection(by: -1, bubbles: bubbles, filtered: filtered)
            return .handled
        case .rightArrow, .downArrow:
            moveSelection(by: 1, bubbles: bubbles, filtered: filtered)
            return .handled
        case .escape:
            guard selectedID != nil else { return .ignored }
            selectedID = nil
            model.selectExploreRecord(id: nil)
            return .handled
        case .space:
            guard let id = selectedID,
                  let group = bubbles.first(where: { $0.id == id })?.group,
                  let url = ExploreTreeBuilder.largestMember(of: group, in: filtered)?.url else {
                return .ignored
            }
            QuickLookCoordinator.shared.togglePreview([url])
            return .handled
        default:
            return .ignored
        }
    }

    private func moveSelection(
        by delta: Int,
        bubbles: [ExploreSnapshotCache.PlacedBubble],
        filtered: [FileRecord]
    ) {
        let index = bubbles.firstIndex(where: { $0.id == selectedID })
        let targetIndex: Int = if let index {
            max(0, min(bubbles.count - 1, index + delta))
        } else {
            delta > 0 ? 0 : bubbles.count - 1
        }
        let target = bubbles[targetIndex]
        selectedID = target.id
        syncExploreSelection(group: target.group, filtered: filtered)
    }
}
