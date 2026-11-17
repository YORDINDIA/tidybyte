import MacOSCleanerCore
import SwiftUI

/// Radial mind map: scan root sits at the center and top-level groups
/// fan out as branches with size labels and connector lines.
struct MindMapView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var grouping: ExploreGrouping
    var maxDepth: Int
    var nameFilter: String

    @State private var selectedID: String?
    private let branchLimit = 10

    private var override: AppLanguage? {
        model.languageStore.activeOverride
    }

    private func nodePositions(count: Int) -> [CGPoint] {
        guard count > 0 else {
            return []
        }
        if count == 1 {
            return [CGPoint(x: 0.5, y: 0.28)]
        }
        return (0..<count).map { index in
            let angle = (Double(index) / Double(count)) * 2 * Double.pi - Double.pi / 2
            return CGPoint(
                x: 0.5 + 0.34 * CGFloat(cos(angle)),
                y: 0.5 + 0.34 * CGFloat(sin(angle))
            )
        }
    }

    var body: some View {
        let filtered = model.exploreFilteredFiles(in: files, nameFilter: nameFilter)
        let roots = model.exploreGroups(
            in: files,
            grouping: grouping,
            maxDepth: maxDepth,
            nameFilter: nameFilter
        )
        let groups = Array(roots.sorted { $0.bytes > $1.bytes }.prefix(branchLimit))
        let totalBytes = groups.reduce(Int64(0)) { $0 + max(0, $1.bytes) }

        return VStack(spacing: Spacing.elementNormal) {
            if groups.isEmpty {
                ExploreEmptyState(language: override)
            } else {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height: CGFloat = 300
                    let positions = nodePositions(count: groups.count)
                    let center = CGPoint(x: width / 2, y: height / 2)
                    ZStack {
                        ConnectorLinesView(
                            center: center,
                            targets: groups.indices.map { index in
                                CGPoint(x: positions[index].x * width, y: positions[index].y * height)
                            },
                            groups: groups
                        )
                        .frame(width: width, height: height)
                        rootNode(totalBytes: totalBytes, at: center)
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            if index < positions.count {
                                branchNode(
                                    group,
                                    at: CGPoint(x: positions[index].x * width, y: positions[index].y * height),
                                    filtered: filtered
                                )
                            }
                        }
                    }
                    .frame(width: width, height: height)
                }
                .frame(height: 300)
                if let selected = groups.first(where: { $0.id == selectedID }) {
                    selectedFooter(for: selected, filtered: filtered)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .escape, .space]) { press in
            handleKeyPress(press, groups: groups, filtered: filtered)
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            selectedID = nil
        }
        .onChange(of: grouping) { _, _ in
            selectedID = nil
        }
    }

    private func rootNode(totalBytes: Int64, at center: CGPoint) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "internaldrive")
                .foregroundStyle(Primary.primary)
            Text(totalBytes.formattedByteCount)
                .appFont(.labelMedium)
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: Circle())
        .overlay(Circle().strokeBorder(SemanticScale.subtleBorder, lineWidth: 1))
        .position(center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("Scan total: %@", language: override, totalBytes.formattedByteCount))
    }

    private func branchNode(_ group: ExploreGroup, at point: CGPoint, filtered: [FileRecord]) -> some View {
        let palette = ExploreChartPalette.palette(for: group)
        let isSelected = selectedID == group.id
        return Button {
            let next = isSelected ? nil : group.id
            selectedID = next
            syncSelection(group: next == nil ? nil : group, filtered: filtered)
        } label: {
            branchNodeLabel(group, palette: palette, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .position(point)
        .help(L10n.format("%@, %@", language: override, group.name, group.bytes.formattedByteCount))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format(
            "%@, %@, %@",
            language: override,
            group.name,
            group.bytes.formattedByteCount,
            ExploreCopy.fileCount(group.fileCount, language: override)
        )))
        .accessibilityHint(L10n.string("Shows group details", language: override))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func branchNodeLabel(_ group: ExploreGroup, palette: CategoricalPalette, isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
        return VStack(spacing: 2) {
            Text(group.name)
                .appFont(.labelMedium)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(group.bytes.formattedByteCount)
                .appFont(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if group.fileCount > 0 {
                Text(ExploreCopy.fileCount(group.fileCount, language: override))
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 150)
        .background(palette.soft, in: shape)
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .overlay {
            shape.strokeBorder(
                isSelected ? Color.accentColor : palette.border,
                lineWidth: isSelected ? 2 : 1
            )
        }
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
        case .leftArrow, .upArrow:
            moveSelection(by: -1, groups: groups, filtered: filtered)
            return .handled
        case .rightArrow, .downArrow:
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

private struct ConnectorLinesView: View {
    var center: CGPoint
    var targets: [CGPoint]
    var groups: [ExploreGroup]

    var body: some View {
        ZStack {
            ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                let group = index < groups.count ? groups[index] : nil
                ConnectorLineShape(center: center, target: target)
                    .stroke(
                        ExploreChartPalette.palette(for: group).mid.opacity(0.65),
                        lineWidth: 1.5
                    )
            }
        }
    }
}

private struct ConnectorLineShape: Shape {
    var center: CGPoint
    var target: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x - rect.origin.x, y: center.y - rect.origin.y))
        path.addLine(to: CGPoint(x: target.x - rect.origin.x, y: target.y - rect.origin.y))
        return path
    }
}
