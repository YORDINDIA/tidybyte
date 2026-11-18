import MacOSCleanerCore
import SwiftUI

/// Displays project relationships as a simple graph visualization.
struct RelationshipGraphView: View {
    @Bindable var model: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let edges: [RelationshipEdge]
    let filesByID: [String: FileRecord]

    @State private var hoveredNode: String?

    var body: some View {
        let override = model.languageStore.activeOverride
        VStack(alignment: .leading, spacing: 12) {
            header(override: override)
            if edges.isEmpty {
                emptyState(override: override)
            } else {
                graphContent(override: override)
            }
        }
        .padding(Spacing.cardPadding)
    }

    private func header(override: AppLanguage?) -> some View {
        HStack(spacing: Spacing.elementTight) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(Primary.primary)
                .accessibilityHidden(true)
            Text(L10n.string("Project Relationships", language: override))
                .font(.app(.h3))
                .foregroundStyle(Color.primary)
            Spacer()
            Text(
                edges.count == 1
                    ? L10n.string("1 connection", language: override)
                    : L10n.format("%lld connections", language: override, edges.count)
            )
            .appFont(.labelMedium)
            .foregroundStyle(Color.secondary)
        }
    }

    private func emptyState(override: AppLanguage?) -> some View {
        ContentUnavailableView {
            Label(
                L10n.string("No relationships detected yet.", language: override),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        } description: {
            Text(L10n.string("Run a scan to discover file connections.", language: override))
        } actions: {
            EmptyStateActionsView(model: model)
        }
    }

    private func graphContent(override: AppLanguage?) -> some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                canvas
                    .frame(minWidth: 400, minHeight: 240)
            }
            edgeLegend(override: override)
        }
    }

    private func edgeLegend(override: AppLanguage?) -> some View {
        let presentTypes = Array(Set(edges.map(\.edgeType))).sorted { $0.rawValue < $1.rawValue }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.elementNormal) {
                ForEach(presentTypes, id: \.self) { type in
                    HStack(spacing: 4) {
                        edgeSwatch(for: type)
                        Text(edgeDisplayName(for: type, override: override))
                            .appFont(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    private func edgeSwatch(for type: RelationshipEdgeType) -> some View {
        let dash = edgeDash(for: type)
        return Path { path in
            path.move(to: CGPoint(x: 0, y: 4))
            path.addLine(to: CGPoint(x: 18, y: 4))
        }
        .stroke(
            edgeColor(for: type),
            style: StrokeStyle(lineWidth: 1.5, dash: dash)
        )
        .frame(width: 18, height: 8)
        .accessibilityHidden(true)
    }

    private func edgeDisplayName(for type: RelationshipEdgeType, override: AppLanguage?) -> String {
        switch type {
        case .duplicate: L10n.string("Duplicate", language: override)
        case .generatedFrom: L10n.string("Generated From", language: override)
        case .sameProject: L10n.string("Same Project", language: override)
        case .exportOf: L10n.string("Export Of", language: override)
        case .backupOf: L10n.string("Backup Of", language: override)
        case .versionOf: L10n.string("Version Of", language: override)
        case .manifestOf: L10n.string("Manifest Of", language: override)
        case .temporaryArtifactOf: L10n.string("Temporary Artifact", language: override)
        case .nearDuplicateOf: L10n.string("Near Duplicate", language: override)
        case .cloudCopyOf: L10n.string("Cloud Copy", language: override)
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let nodes = calculateNodePositions(in: geometry.size)
            ZStack {
                ForEach(edges) { edge in
                    if let fromNode = nodes[edge.fromFileID],
                       let toNode = nodes[edge.toFileID] {
                        edgePath(
                            from: fromNode,
                            to: toNode,
                            type: edge.edgeType,
                            isHighlighted: hoveredNode == edge.fromFileID || hoveredNode == edge.toFileID
                        )
                    }
                }

                ForEach(nodes.keys.sorted(), id: \.self) { fileID in
                    if let position = nodes[fileID],
                       let record = filesByID[fileID] {
                        nodeView(for: record, at: position)
                    }
                }
            }
        }
    }

    private func calculateNodePositions(in size: CGSize) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        let uniqueFiles = Set(edges.flatMap { [$0.fromFileID, $0.toFileID] })
        let fileList = Array(uniqueFiles).sorted()
        guard !fileList.isEmpty else { return positions }

        let safeWidth = max(CGFloat(1), size.width)
        let safeHeight = max(CGFloat(1), size.height)
        let cols = Int(ceil(sqrt(Double(fileList.count))))
        let spacingX = safeWidth / CGFloat(cols + 1)
        let rows = Int(ceil(Double(fileList.count) / Double(cols)))
        let spacingY = safeHeight / CGFloat(rows + 1)

        for (index, fileID) in fileList.enumerated() {
            let col = index % cols
            let row = index / cols
            let x = spacingX * CGFloat(col + 1)
            let y = spacingY * CGFloat(row + 1)
            positions[fileID] = CGPoint(x: x, y: y)
        }
        return positions
    }

    private func edgePath(from: CGPoint, to: CGPoint, type: RelationshipEdgeType, isHighlighted: Bool) -> some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            edgeColor(for: type),
            style: StrokeStyle(
                lineWidth: isHighlighted ? 2 : 1,
                dash: edgeDash(for: type)
            )
        )
        .opacity(isHighlighted ? 1.0 : 0.6)
        .animation(reduceMotion ? nil : .appSelection, value: isHighlighted)
    }

    private func edgeColor(for type: RelationshipEdgeType) -> Color {
        switch type {
        case .duplicate, .nearDuplicateOf: SemanticScale.error
        case .generatedFrom: Primary.primary
        case .sameProject: SemanticScale.success
        case .exportOf: SemanticScale.warning
        case .backupOf: CategoricalPalette.pink.mid
        case .versionOf: CategoricalPalette.purple.mid
        case .manifestOf: CategoricalPalette.orange.mid
        case .temporaryArtifactOf: CategoricalPalette.yellow.mid
        case .cloudCopyOf: CategoricalPalette.teal.mid
        }
    }

    private func edgeDash(for type: RelationshipEdgeType) -> [CGFloat] {
        switch type {
        case .duplicate, .nearDuplicateOf: []
        case .generatedFrom, .temporaryArtifactOf: [5, 3]
        default: [8, 4]
        }
    }

    private func nodeView(for record: FileRecord, at position: CGPoint) -> some View {
        let isHovered = hoveredNode == record.id
        return VStack(spacing: 2) {
            Image(systemName: nodeIcon(for: record))
                .font(.caption)
                .foregroundStyle(nodeColor(for: record))
            Text(record.fileName)
                .appFont(.labelMedium)
                .lineLimit(1)
                .foregroundStyle(Color.primary)
                .frame(width: 80)
        }
        .padding(4)
        .background(
            isHovered ? AnyShapeStyle(Primary.selection) : AnyShapeStyle(.background.secondary),
            in: RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
        )
        .position(position)
        .onHover { hovered in
            withAnimation(reduceMotion ? nil : .appSelection) {
                hoveredNode = hovered ? record.id : nil
            }
        }
        .help(record.fileName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(record.fileName))
        .accessibilityHint(L10n.string("File relationship node", language: model.languageStore.activeOverride))
    }

    private func nodeIcon(for record: FileRecord) -> String {
        switch record.kind {
        case .directory: "folder.fill"
        case .package: "folder.badge.gearshape"
        case .symlink: "arrow.triangle.turn.up.right.diamond"
        default: "doc.fill"
        }
    }

    private func nodeColor(for record: FileRecord) -> Color {
        if record.riskFlags.contains(.protectedFile) || record.riskFlags.contains(.protectedDirectory) {
            return SemanticScale.error
        }
        if record.cloudProvider != nil {
            return CategoricalPalette.teal.mid
        }
        return Primary.primary
    }
}
