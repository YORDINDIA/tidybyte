import AppKit
import MacOSCleanerCore
import SwiftUI

/// 2D squarified treemap sized proportionally to byte usage, with drill-down
/// breadcrumbs, selection sync, Quick Look, and keyboard navigation.
struct TreemapView: View {
    var sections: [(FindingCategory, Int64)] = []
    var model: AppViewModel?
    var files: [FileRecord] = []
    var grouping: ExploreGrouping = .byFolder
    var maxDepth: Int = 7
    var nameFilter: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drillIDs: [String] = []
    @State private var selectedID: String?
    @State private var hoveredID: String?

    private var override: AppLanguage? {
        model?.languageStore.activeOverride
    }

    private var filtered: [FileRecord] {
        if let model {
            return model.exploreFilteredFiles(in: files, nameFilter: nameFilter)
        }
        return ExploreTreeBuilder.filteredFiles(files, nameFilter: nameFilter)
    }

    private var rootGroups: [ExploreGroup] {
        guard !files.isEmpty || model != nil else { return [] }
        if let model {
            return model.exploreGroups(
                in: files,
                grouping: grouping,
                maxDepth: maxDepth,
                nameFilter: nameFilter
            )
        }
        return ExploreTreeBuilder.build(files: filtered, grouping: grouping, maxDepth: maxDepth)
    }

    private var drillPath: [ExploreGroup] {
        var level = rootGroups
        var path: [ExploreGroup] = []
        for id in drillIDs {
            guard let match = level.first(where: { $0.id == id }) else { break }
            path.append(match)
            level = match.children
        }
        return path
    }

    private var activeGroups: [ExploreGroup] {
        if let current = drillPath.last {
            return current.children.isEmpty ? [current] : current.children
        }
        return rootGroups
    }

    private var items: [TreemapItem] {
        if !activeGroups.isEmpty {
            return activeGroups.compactMap { group in
                guard group.bytes > 0 else { return nil }
                return TreemapItem(
                    id: group.id,
                    title: group.name,
                    bytes: group.bytes,
                    fileCount: group.fileCount,
                    subtitle: group.detail,
                    palette: ExploreChartPalette.palette(for: group),
                    group: group
                )
            }
        }
        return sections.compactMap { section in
            guard section.1 > 0 else { return nil }
            return TreemapItem(
                id: "cat:\(section.0.rawValue)",
                title: section.0.displayName,
                bytes: section.1,
                fileCount: nil,
                subtitle: nil,
                palette: section.0.palette,
                group: nil
            )
        }
    }

    private var selectedItem: TreemapItem? {
        items.first { $0.id == selectedID }
    }

    var body: some View {
        let currentItems = items
        let path = drillPath
        return VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if !path.isEmpty {
                breadcrumbBar(path)
            }
            if currentItems.isEmpty {
                RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(minHeight: 240)
                    .overlay(ExploreEmptyState(language: override))
            } else {
                treemapCanvas(items: currentItems)
                if let selected = selectedItem {
                    selectionFooter(for: selected)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape, .space]) { press in
            handleKeyPress(press, in: currentItems)
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
            selectedID = nil
        }
        .onChange(of: sections.map(\.0)) { _, _ in
            if files.isEmpty {
                selectedID = nil
            }
        }
    }
}

extension TreemapView {
    private func treemapCanvas(items: [TreemapItem]) -> some View {
        GeometryReader { proxy in
            let placed = SquarifiedTreemapLayout.layout(
                items: items,
                in: CGRect(origin: .zero, size: proxy.size)
            )
            ZStack(alignment: .topLeading) {
                ForEach(placed) { tile in
                    treemapTileView(tile)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(minHeight: 260, maxHeight: 360)
        .clipped()
    }

    private func treemapTileView(_ tile: SquarifiedTreemapLayout.PlacedTile) -> some View {
        let item = tile.item
        let isSelected = selectedID == item.id
        let isHovered = hoveredID == item.id
        let frame = tile.rect
        let canDrill = !(item.group?.children.isEmpty ?? true)
        return Button {
            select(item)
        } label: {
            tileContent(item: item, size: frame.size, canDrill: canDrill, isHovered: isHovered, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                drillOrPreview(item)
            }
        )
        .onHover { inside in
            hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .position(x: frame.midX, y: frame.midY)
        .help(tooltipText(for: item))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format("%@, %@", language: override, item.title, item.bytes.formattedByteCount)))
        .accessibilityValue(isSelected
            ? L10n.string("Selected", language: override)
            : L10n.string("Not selected", language: override))
        .accessibilityHint(canDrill
            ? L10n.string("Selects group; double-click to drill in", language: override)
            : L10n.string("Shows size details", language: override))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tileContent(
        item: TreemapItem,
        size: CGSize,
        canDrill: Bool,
        isHovered: Bool,
        isSelected: Bool
    ) -> some View {
        let showsText = size.width >= 60 && size.height >= 36
        let showsSize = size.width >= 60 && size.height >= 54
        let shape = RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            if showsText {
                HStack(spacing: 4) {
                    Text(item.title)
                        .appFont(.labelMedium)
                        .foregroundStyle(item.palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if canDrill, size.width >= 96 {
                        Image(systemName: "chevron.forward")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.palette.ink.opacity(0.8))
                    }
                }
                Spacer(minLength: 2)
                if showsSize {
                    Text(item.bytes.formattedByteCount)
                        .appFont(.filePath)
                        .monospacedDigit()
                        .foregroundStyle(item.palette.ink.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(8)
        .frame(width: max(4, size.width), height: max(4, size.height), alignment: .topLeading)
        .background(item.palette.mid.opacity(isHovered ? 0.96 : 0.88), in: shape)
        .overlay {
            shape.strokeBorder(
                isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor).opacity(0.55),
                lineWidth: isSelected ? 2 : 1
            )
        }
    }

    private func breadcrumbBar(_ path: [ExploreGroup]) -> some View {
        HStack(spacing: 6) {
            Button(L10n.string("All", language: override)) {
                drillIDs = []
                selectedID = nil
                model?.selectExploreRecord(id: nil)
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
            Button(L10n.string("Back", language: override)) {
                if !drillIDs.isEmpty {
                    drillIDs.removeLast()
                }
                selectedID = nil
            }
            .buttonStyle(.plain)
            .appFont(.caption)
            .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, Spacing.elementTight)
        .floatingGlassOverlay(in: Capsule())
    }

    private func selectionFooter(for item: TreemapItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack(spacing: Spacing.elementTight) {
                Circle()
                    .fill(item.palette.mid)
                    .frame(width: 10, height: 10)
                Text(item.title)
                    .appFont(.labelMedium)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.bytes.formattedByteCount)
                    .appFont(.filePath)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                if let group = item.group, !group.children.isEmpty {
                    Button(L10n.string("Drill In", language: override)) {
                        drillInto(group)
                    }
                    .buttonStyle(.borderless)
                    .appFont(.caption)
                }
                Button(L10n.string("Clear", language: override)) {
                    selectedID = nil
                    model?.selectExploreRecord(id: nil)
                }
                .buttonStyle(.plain)
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
            }
            if let model, let group = item.group {
                ExploreGroupActionsView(model: model, group: group, files: filtered)
            }
        }
        .padding(Spacing.cardPadding)
        .softCardSurface(cornerRadius: Radius.cardCompact)
        .animation(reduceMotion ? nil : .appSelection, value: selectedID)
    }

    private func select(_ item: TreemapItem) {
        let next = selectedID == item.id ? nil : item.id
        selectedID = next
        syncExploreSelection(for: next == nil ? nil : item)
    }

    private func drillOrPreview(_ item: TreemapItem) {
        if let group = item.group, !group.children.isEmpty {
            drillInto(group)
        } else if let url = quickLookURL(for: item) {
            QuickLookCoordinator.shared.preview(url)
        }
    }

    private func drillInto(_ group: ExploreGroup) {
        guard !group.children.isEmpty else { return }
        drillIDs.append(group.id)
        selectedID = nil
        if let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) {
            model?.focusExploreRecord(id: record.id)
            model?.selectExploreRecord(id: record.id)
        }
    }

    private func syncExploreSelection(for item: TreemapItem?) {
        guard let model else { return }
        guard let group = item?.group,
              let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) else {
            model.selectExploreRecord(id: nil)
            return
        }
        model.selectExploreRecord(id: record.id)
    }

    private func quickLookURL(for item: TreemapItem) -> URL? {
        guard let group = item.group else { return nil }
        return ExploreTreeBuilder.largestMember(of: group, in: filtered)?.url
    }

    private func tooltipText(for item: TreemapItem) -> String {
        var parts = [item.title, item.bytes.formattedByteCount]
        if let count = item.fileCount {
            parts.append(ExploreCopy.fileCount(count, language: override))
        }
        if let subtitle = item.subtitle, subtitle != item.title {
            parts.append(subtitle)
        }
        return parts.joined(separator: " · ")
    }

    private func handleKeyPress(_ press: KeyPress, in currentItems: [TreemapItem]) -> KeyPress.Result {
        guard !currentItems.isEmpty else { return .ignored }
        if press.key == .leftArrow || press.key == .upArrow {
            moveSelection(by: -1, in: currentItems)
            return .handled
        }
        if press.key == .rightArrow || press.key == .downArrow {
            moveSelection(by: 1, in: currentItems)
            return .handled
        }
        return handleActionKey(press.key)
    }

    private func handleActionKey(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .return:
            guard let selected = selectedItem else { return .ignored }
            drillOrPreview(selected)
            return .handled
        case .escape:
            if selectedID != nil {
                selectedID = nil
                model?.selectExploreRecord(id: nil)
                return .handled
            }
            if !drillIDs.isEmpty {
                drillIDs.removeLast()
                return .handled
            }
            return .ignored
        case .space:
            guard let selected = selectedItem, let url = quickLookURL(for: selected) else { return .ignored }
            QuickLookCoordinator.shared.togglePreview([url])
            return .handled
        default:
            return .ignored
        }
    }

    private func moveSelection(by delta: Int, in currentItems: [TreemapItem]) {
        guard let currentIndex = currentItems.firstIndex(where: { $0.id == selectedID }) else {
            let first = delta > 0 ? currentItems.first : currentItems.last
            selectedID = first?.id
            syncExploreSelection(for: first)
            return
        }
        let nextIndex = max(0, min(currentItems.count - 1, currentIndex + delta))
        let next = currentItems[nextIndex]
        selectedID = next.id
        syncExploreSelection(for: next)
    }
}

private struct TreemapItem: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    let fileCount: Int?
    let subtitle: String?
    let palette: CategoricalPalette
    let group: ExploreGroup?
}

/// Bruls–Huizing–van Wijk squarified 2D treemap packing algorithm.
private enum SquarifiedTreemapLayout {
    struct PlacedTile: Identifiable {
        let id: String
        let rect: CGRect
        let item: TreemapItem
    }

    private struct ScaledItem {
        let item: TreemapItem
        let area: Double
    }

    static func layout(items: [TreemapItem], in bounds: CGRect) -> [PlacedTile] {
        let positive = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard !positive.isEmpty, bounds.width > 4, bounds.height > 4 else { return [] }
        let totalBytes = Double(positive.reduce(Int64(0)) { $0 + $1.bytes })
        let totalArea = Double(bounds.width * bounds.height)
        guard totalBytes > 0, totalArea > 0 else { return [] }

        let scaled = positive.map { item in
            ScaledItem(item: item, area: (Double(item.bytes) / totalBytes) * totalArea)
        }
        var remaining = bounds
        var currentRow: [ScaledItem] = []
        var placed: [PlacedTile] = []

        for next in scaled {
            let shortSide = Double(min(remaining.width, remaining.height))
            if currentRow.isEmpty ||
                worstAspectRatio(currentRow + [next], side: shortSide) <= worstAspectRatio(currentRow, side: shortSide) {
                currentRow.append(next)
            } else {
                placeRow(currentRow, in: &remaining, into: &placed)
                currentRow = [next]
            }
        }
        if !currentRow.isEmpty {
            placeRow(currentRow, in: &remaining, into: &placed)
        }
        return placed
    }

    private static func worstAspectRatio(_ row: [ScaledItem], side: Double) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let sum = row.reduce(0.0) { $0 + $1.area }
        guard sum > 0 else { return .infinity }
        let areas = row.map(\.area)
        let maxArea = areas.max() ?? 0
        let minArea = max(1e-6, areas.min() ?? 1e-6)
        let sideSquared = side * side
        return max((sideSquared * maxArea) / (sum * sum), (sum * sum) / (sideSquared * minArea))
    }

    private static func placeRow(_ row: [ScaledItem], in rect: inout CGRect, into placed: inout [PlacedTile]) {
        let sum = row.reduce(0.0) { $0 + $1.area }
        guard sum > 0, rect.width > 0, rect.height > 0 else { return }
        if rect.width >= rect.height {
            let stripWidth = min(rect.width, CGFloat(sum / Double(rect.height)))
            var yCursor = rect.minY
            for entry in row {
                let tileHeight = rect.height * CGFloat(entry.area / sum)
                let raw = CGRect(x: rect.minX, y: yCursor, width: stripWidth, height: tileHeight)
                placed.append(PlacedTile(id: entry.item.id, rect: insetTile(raw), item: entry.item))
                yCursor += tileHeight
            }
            rect = CGRect(
                x: rect.minX + stripWidth,
                y: rect.minY,
                width: max(0, rect.width - stripWidth),
                height: rect.height
            )
        } else {
            let stripHeight = min(rect.height, CGFloat(sum / Double(rect.width)))
            var xCursor = rect.minX
            for entry in row {
                let tileWidth = rect.width * CGFloat(entry.area / sum)
                let raw = CGRect(x: xCursor, y: rect.minY, width: tileWidth, height: stripHeight)
                placed.append(PlacedTile(id: entry.item.id, rect: insetTile(raw), item: entry.item))
                xCursor += tileWidth
            }
            rect = CGRect(
                x: rect.minX,
                y: rect.minY + stripHeight,
                width: rect.width,
                height: max(0, rect.height - stripHeight)
            )
        }
    }

    private static func insetTile(_ rect: CGRect) -> CGRect {
        let dx: CGFloat = rect.width > 8 ? 2 : 0
        let dy: CGFloat = rect.height > 8 ? 2 : 0
        return rect.insetBy(dx: dx, dy: dy)
    }
}
