import MacOSCleanerCore
import SwiftUI

/// Icicle / flame chart supporting selection at every depth, multi-level
/// breadcrumb zoom, Quick Look preview, and keyboard navigation.
struct FlameView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var grouping: ExploreGrouping
    var maxDepth: Int
    var nameFilter: String

    @State private var zoomedPath: [String] = []
    @State private var selectedSectorID: String?

    private var override: AppLanguage? {
        model.languageStore.activeOverride
    }

    var body: some View {
        let filtered = model.exploreFilteredFiles(in: files, nameFilter: nameFilter)
        let rootGroups = model.exploreGroups(
            in: files,
            grouping: grouping,
            maxDepth: maxDepth,
            nameFilter: nameFilter
        )
        let rows = model.exploreFlameRows(
            in: files,
            grouping: grouping,
            maxDepth: maxDepth,
            nameFilter: nameFilter,
            zoomedPath: zoomedPath
        )
        let zoomChain = resolvedZoomChain(in: rootGroups)
        let flatSectors = rows.flatMap { $0 }
        let selectedSector = flatSectors.first { $0.id == selectedSectorID }
        let selectedGroup = resolvedGroup(for: selectedSector, in: rootGroups) ?? zoomChain.last

        return VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if rootGroups.isEmpty {
                ExploreEmptyState(language: override)
            } else {
                if !zoomChain.isEmpty {
                    zoomBanner(chain: zoomChain, filtered: filtered)
                }
                GeometryReader { proxy in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            flameRow(
                                row,
                                width: proxy.size.width,
                                rootGroups: rootGroups,
                                filtered: filtered
                            )
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(minHeight: 220, maxHeight: 320)

                if let activeGroup = selectedGroup {
                    selectionFooter(
                        sector: selectedSector,
                        group: activeGroup,
                        filtered: filtered
                    )
                }
                legend(groups: zoomChain.last.map { $0.children.isEmpty ? [$0] : $0.children } ?? rootGroups)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape, .space]) { press in
            handleKeyPress(press, rows: rows, rootGroups: rootGroups, filtered: filtered)
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            zoomedPath = []
            selectedSectorID = nil
        }
        .onChange(of: grouping) { _, _ in
            zoomedPath = []
            selectedSectorID = nil
        }
    }
}

extension FlameView {
    private func zoomBanner(chain: [ExploreGroup], filtered: [FileRecord]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)
            Button(L10n.string("All", language: override)) {
                zoomedPath = []
                selectedSectorID = nil
                model.focusExploreRecord(id: nil)
                model.selectExploreRecord(id: nil)
            }
            .buttonStyle(.plain)
            .appFont(.caption)
            .foregroundStyle(Color.secondary)

            ForEach(Array(chain.enumerated()), id: \.element.id) { index, crumb in
                Image(systemName: "chevron.forward")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                Button(crumb.name) {
                    zoomedPath = Array(zoomedPath.prefix(index + 1))
                    selectedSectorID = nil
                    syncFocus(to: crumb, filtered: filtered)
                }
                .buttonStyle(.plain)
                .appFont(.caption)
                .foregroundStyle(index == chain.count - 1 ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(L10n.string("Zoom out", language: override)) {
                if !zoomedPath.isEmpty {
                    zoomedPath.removeLast()
                }
                selectedSectorID = nil
                if zoomedPath.isEmpty {
                    model.focusExploreRecord(id: nil)
                    model.selectExploreRecord(id: nil)
                }
            }
            .buttonStyle(.plain)
            .appFont(.caption)
            .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, Spacing.elementTight)
        .floatingGlassOverlay(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("Zoomed into %@", language: override, chain.last?.name ?? ""))
    }

    private func flameRow(
        _ row: [SunburstSector],
        width: CGFloat,
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) -> some View {
        ZStack(alignment: .leading) {
            ForEach(row) { sector in
                flameSegment(sector, rowWidth: max(0, width), rootGroups: rootGroups, filtered: filtered)
            }
        }
        .frame(width: max(0, width), height: 34, alignment: .leading)
    }

    private func flameSegment(
        _ sector: SunburstSector,
        rowWidth: CGFloat,
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) -> some View {
        let palette = ExploreChartPalette.palette(for: sector)
        let leading = max(0, rowWidth * CGFloat(sector.startFraction))
        let rawWidth = rowWidth * CGFloat(max(0, sector.sweepFraction))
        let segmentWidth = max(2, rawWidth - 1.5)
        let showsLabel = segmentWidth > 64
        let isSelected = selectedSectorID == sector.id
        return Button {
            handleSegmentClick(sector, rootGroups: rootGroups, filtered: filtered)
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(palette.mid.opacity(sector.depth == 1 ? 0.96 : 0.78))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.primary, lineWidth: 1.5)
                        }
                    }
                if showsLabel {
                    Text(sector.name)
                        .appFont(.caption)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                }
            }
            .frame(width: segmentWidth, height: 32)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if let group = resolvedGroup(for: sector, in: rootGroups), !group.children.isEmpty {
                    zoomInto(group, filtered: filtered)
                }
            }
        )
        .padding(.leading, leading)
        .help(L10n.format("%@, %@", language: override, sector.name, sector.bytes.formattedByteCount))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format(
            "%@, %@, depth %lld",
            language: override,
            sector.name,
            sector.bytes.formattedByteCount,
            sector.depth
        )))
        .accessibilityHint(L10n.string("Selects segment; double-click to zoom in", language: override))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectionFooter(
        sector: SunburstSector?,
        group: ExploreGroup,
        filtered: [FileRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack(spacing: Spacing.elementTight) {
                Text(sector?.name ?? group.name)
                    .appFont(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text((sector?.bytes ?? group.bytes).formattedByteCount)
                    .appFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                if !group.children.isEmpty, zoomedPath.last != group.id {
                    Button(L10n.string("Zoom In", language: override)) {
                        zoomInto(group, filtered: filtered)
                    }
                    .buttonStyle(.borderless)
                    .appFont(.caption)
                }
                if selectedSectorID != nil {
                    Button(L10n.string("Clear", language: override)) {
                        selectedSectorID = nil
                        model.selectExploreRecord(id: nil)
                    }
                    .buttonStyle(.plain)
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
                }
            }
            ExploreGroupActionsView(model: model, group: group, files: filtered)
        }
        .padding(Spacing.cardPadding)
        .softCardSurface(cornerRadius: Radius.cardCompact)
    }

    private func legend(groups: [ExploreGroup]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: Spacing.elementTight)],
            spacing: Spacing.elementTight
        ) {
            ForEach(Array(groups.prefix(8))) { group in
                HStack(spacing: 6) {
                    Circle()
                        .fill(ExploreChartPalette.palette(for: group).mid)
                        .frame(width: 8, height: 8)
                    Text(group.name)
                        .appFont(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(group.bytes.formattedByteCount)
                        .appFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                .help(L10n.format("%@, %@", language: override, group.name, group.bytes.formattedByteCount))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L10n.format("%@, %@", language: override, group.name, group.bytes.formattedByteCount)))
            }
        }
    }

    private func handleSegmentClick(
        _ sector: SunburstSector,
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) {
        let group = resolvedGroup(for: sector, in: rootGroups)
        if selectedSectorID == sector.id {
            if let group, !group.children.isEmpty, zoomedPath.last != group.id {
                zoomInto(group, filtered: filtered)
            } else {
                selectedSectorID = nil
                model.selectExploreRecord(id: nil)
            }
            return
        }
        selectedSectorID = sector.id
        if let group, let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) {
            model.selectExploreRecord(id: record.id)
        }
    }

    private func zoomInto(_ group: ExploreGroup, filtered: [FileRecord]) {
        guard !group.children.isEmpty else { return }
        if zoomedPath.last != group.id {
            zoomedPath.append(group.id)
        }
        selectedSectorID = nil
        syncFocus(to: group, filtered: filtered)
    }

    private func syncFocus(to group: ExploreGroup, filtered: [FileRecord]) {
        if let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) {
            model.focusExploreRecord(id: record.id)
            model.selectExploreRecord(id: record.id)
        }
    }

    private func resolvedZoomChain(in rootGroups: [ExploreGroup]) -> [ExploreGroup] {
        var chain: [ExploreGroup] = []
        for id in zoomedPath {
            guard let found = ExploreTreeBuilder.findGroup(id: id, in: rootGroups) else { break }
            chain.append(found)
        }
        return chain
    }

    private func baseGroupID(from sectorID: String) -> String {
        guard let hashIndex = sectorID.lastIndex(of: "#") else { return sectorID }
        return String(sectorID[..<hashIndex])
    }

    private func resolvedGroup(for sector: SunburstSector?, in rootGroups: [ExploreGroup]) -> ExploreGroup? {
        guard let sector else { return nil }
        return ExploreTreeBuilder.findGroup(id: baseGroupID(from: sector.id), in: rootGroups)
    }

    private func handleKeyPress(
        _ press: KeyPress,
        rows: [[SunburstSector]],
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) -> KeyPress.Result {
        let flat = rows.flatMap { $0 }
        guard !flat.isEmpty else { return .ignored }
        if press.key == .leftArrow || press.key == .upArrow {
            moveSelection(by: -1, flat: flat, rootGroups: rootGroups, filtered: filtered)
            return .handled
        }
        if press.key == .rightArrow || press.key == .downArrow {
            moveSelection(by: 1, flat: flat, rootGroups: rootGroups, filtered: filtered)
            return .handled
        }
        return handleActionKey(press.key, flat: flat, rootGroups: rootGroups, filtered: filtered)
    }

    private func handleActionKey(
        _ key: KeyEquivalent,
        flat: [SunburstSector],
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) -> KeyPress.Result {
        switch key {
        case .return:
            guard let id = selectedSectorID,
                  let sector = flat.first(where: { $0.id == id }),
                  let group = resolvedGroup(for: sector, in: rootGroups),
                  !group.children.isEmpty else { return .ignored }
            zoomInto(group, filtered: filtered)
            return .handled
        case .escape:
            if selectedSectorID != nil {
                selectedSectorID = nil
                model.selectExploreRecord(id: nil)
                return .handled
            }
            if !zoomedPath.isEmpty {
                zoomedPath.removeLast()
                return .handled
            }
            return .ignored
        case .space:
            let activeGroup = flat.first(where: { $0.id == selectedSectorID })
                .flatMap { resolvedGroup(for: $0, in: rootGroups) }
                ?? resolvedZoomChain(in: rootGroups).last
            guard let group = activeGroup,
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
        flat: [SunburstSector],
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) {
        let index = flat.firstIndex(where: { $0.id == selectedSectorID })
        let targetIndex = index.map { max(0, min(flat.count - 1, $0 + delta)) }
            ?? (delta > 0 ? 0 : flat.count - 1)
        let target = flat[targetIndex]
        selectedSectorID = target.id
        if let group = resolvedGroup(for: target, in: rootGroups),
           let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) {
            model.selectExploreRecord(id: record.id)
        }
    }
}
