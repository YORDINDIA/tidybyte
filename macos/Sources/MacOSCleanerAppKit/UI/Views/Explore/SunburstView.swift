import MacOSCleanerCore
import SwiftUI

/// Concentric-ring sunburst with interactive zoom breadcrumbs, multi-depth
/// selection, Quick Look preview, and keyboard navigation.
struct SunburstView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var grouping: ExploreGrouping
    var maxDepth: Int
    var nameFilter: String

    @State private var zoomedGroupIDs: [String] = []
    @State private var selectedID: String?

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
        let sectors = model.exploreSectors(
            in: files,
            grouping: grouping,
            maxDepth: maxDepth,
            nameFilter: nameFilter,
            zoomedGroupID: zoomedGroupIDs.last
        )
        let zoomedChain = resolvedZoomChain(in: rootGroups)
        let activeGroups = displayedGroups(rootGroups: rootGroups, zoomedChain: zoomedChain)
        let selectedSector = sectors.first { $0.id == selectedID }
        let selectedGroup = resolvedGroup(for: selectedSector, in: rootGroups)

        return VStack(spacing: Spacing.elementNormal) {
            if !zoomedChain.isEmpty {
                zoomBreadcrumbBar(zoomedChain, filtered: filtered)
            }
            if sectors.isEmpty {
                ExploreEmptyState(language: override)
            } else {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, 280)
                    ZStack {
                        ForEach(sectors) { sector in
                            sectorSlice(
                                sector,
                                canvas: side,
                                rootGroups: rootGroups,
                                filtered: filtered
                            )
                        }
                        centerHub(
                            canvas: side,
                            zoomedChain: zoomedChain,
                            activeGroups: activeGroups,
                            filtered: filtered
                        )
                    }
                    .frame(width: proxy.size.width, height: 300, alignment: .center)
                }
                .frame(height: 300)
                legend(
                    activeGroups: activeGroups,
                    selectedSector: selectedSector,
                    selectedGroup: selectedGroup,
                    filtered: filtered
                )
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape, .space]) { press in
            handleKeyPress(press, sectors: sectors, rootGroups: rootGroups, filtered: filtered)
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            zoomedGroupIDs = []
            selectedID = nil
        }
        .onChange(of: grouping) { _, _ in
            zoomedGroupIDs = []
            selectedID = nil
        }
    }
}

extension SunburstView {
    private func centerHub(
        canvas: CGFloat,
        zoomedChain: [ExploreGroup],
        activeGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) -> some View {
        let totalBytes = (zoomedChain.last?.bytes)
            ?? activeGroups.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        let hubDiameter = canvas * 0.44
        return Button {
            guard !zoomedGroupIDs.isEmpty else { return }
            zoomOutOneLevel(in: zoomedChain, filtered: filtered)
        } label: {
            VStack(spacing: 2) {
                if let current = zoomedChain.last {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward")
                            .font(.caption2.weight(.semibold))
                        Text(current.name)
                            .appFont(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Color.secondary)
                }
                Text(totalBytes.formattedByteCount)
                    .appFont(.h4)
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if zoomedChain.isEmpty {
                    Text(L10n.format("%lld groups", language: override, activeGroups.count))
                        .appFont(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(width: hubDiameter, height: hubDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(zoomedChain.isEmpty)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format(
            "Total %@ in %lld groups",
            language: override,
            totalBytes.formattedByteCount,
            activeGroups.count
        ))
    }

    private func sectorSlice(
        _ sector: SunburstSector,
        canvas: CGFloat,
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) -> some View {
        let ringCount = CGFloat(max(1, maxDepth))
        let ringDepth = max(1, min(sector.depth, max(1, maxDepth)))
        let hubRadius = (canvas / 2) * 0.24
        let step = ((canvas / 2) - hubRadius) / ringCount
        let innerRadius = hubRadius + step * CGFloat(ringDepth - 1)
        let outerRadius = hubRadius + step * CGFloat(ringDepth)
        let startAngle = Angle.degrees(-90 + sector.startFraction * 360)
        let endAngle = Angle.degrees(-90 + sector.endFraction * 360)
        let palette = ExploreChartPalette.palette(for: sector)
        let isSelected = selectedID == sector.id
        let ring = RingSegment(
            innerRadius: innerRadius,
            outerRadius: max(innerRadius + 2, outerRadius - 1.5),
            startAngle: startAngle,
            endAngle: endAngle
        )
        return Button {
            handleSectorClick(sector, rootGroups: rootGroups, filtered: filtered)
        } label: {
            ring
                .fill(isSelected ? palette.mid : palette.mid.opacity(sector.depth == 1 ? 0.92 : 0.68))
                .overlay(
                    ring.stroke(
                        isSelected ? Color.primary : Color(nsColor: .windowBackgroundColor),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
                .contentShape(ring)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if let group = resolvedGroup(for: sector, in: rootGroups), !group.children.isEmpty {
                    zoomInto(group, filtered: filtered)
                }
            }
        )
        .zIndex(isSelected ? 100 : Double(sector.depth))
        .help(L10n.format("%@, %@", language: override, sector.name, sector.bytes.formattedByteCount))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format(
            "%@, %@, depth %lld",
            language: override,
            sector.name,
            sector.bytes.formattedByteCount,
            sector.depth
        )))
        .accessibilityHint(L10n.string("Selects this segment", language: override))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func zoomBreadcrumbBar(_ chain: [ExploreGroup], filtered: [FileRecord]) -> some View {
        HStack(spacing: 6) {
            Button(L10n.string("All", language: override)) {
                zoomedGroupIDs = []
                selectedID = nil
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
                    zoomedGroupIDs = Array(zoomedGroupIDs.prefix(index + 1))
                    selectedID = nil
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
                zoomOutOneLevel(in: chain, filtered: filtered)
            }
            .buttonStyle(.plain)
            .appFont(.caption)
            .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, Spacing.elementTight)
        .floatingGlassOverlay(in: Capsule())
    }

    private func legend(
        activeGroups: [ExploreGroup],
        selectedSector: SunburstSector?,
        selectedGroup: ExploreGroup?,
        filtered: [FileRecord]
    ) -> some View {
        VStack(spacing: Spacing.elementTight) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: Spacing.elementTight)],
                spacing: Spacing.elementTight
            ) {
                ForEach(Array(activeGroups.prefix(8))) { group in
                    legendButton(for: group, filtered: filtered)
                }
            }
            if let selectedSector {
                selectionFooter(
                    sector: selectedSector,
                    group: selectedGroup,
                    filtered: filtered
                )
            }
        }
    }

    private func legendButton(for group: ExploreGroup, filtered: [FileRecord]) -> some View {
        Button {
            let targetID = "\(group.id)#1"
            let next = selectedID == targetID ? nil : targetID
            selectedID = next
            syncSelection(group: next == nil ? nil : group, filtered: filtered)
        } label: {
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
        }
        .buttonStyle(.plain)
        .help(L10n.format("%@, %@", language: override, group.name, group.bytes.formattedByteCount))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format("%@, %@", language: override, group.name, group.bytes.formattedByteCount)))
    }

    private func selectionFooter(
        sector: SunburstSector,
        group: ExploreGroup?,
        filtered: [FileRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack(spacing: Spacing.elementTight) {
                Text(sector.name)
                    .appFont(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(sector.bytes.formattedByteCount)
                    .appFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                if let group, !group.children.isEmpty {
                    Button(L10n.string("Zoom In", language: override)) {
                        zoomInto(group, filtered: filtered)
                    }
                    .buttonStyle(.borderless)
                    .appFont(.caption)
                }
                Button(L10n.string("Clear", language: override)) {
                    selectedID = nil
                    model.selectExploreRecord(id: nil)
                }
                .buttonStyle(.plain)
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
            }
            if let group {
                ExploreGroupActionsView(model: model, group: group, files: filtered)
            }
        }
        .padding(Spacing.cardPadding)
        .softCardSurface(cornerRadius: Radius.cardCompact)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format(
            "Selected: %@, %@",
            language: override,
            sector.name,
            sector.bytes.formattedByteCount
        ))
    }

    private func handleSectorClick(
        _ sector: SunburstSector,
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) {
        let group = resolvedGroup(for: sector, in: rootGroups)
        if selectedID == sector.id {
            if let group, !group.children.isEmpty {
                zoomInto(group, filtered: filtered)
            } else {
                selectedID = nil
                model.selectExploreRecord(id: nil)
            }
            return
        }
        selectedID = sector.id
        syncSelection(group: group, filtered: filtered)
    }

    private func zoomInto(_ group: ExploreGroup, filtered: [FileRecord]) {
        guard !group.children.isEmpty else { return }
        if zoomedGroupIDs.last != group.id {
            zoomedGroupIDs.append(group.id)
        }
        selectedID = nil
        syncFocus(to: group, filtered: filtered)
    }

    private func zoomOutOneLevel(in chain: [ExploreGroup], filtered: [FileRecord]) {
        guard !zoomedGroupIDs.isEmpty else { return }
        zoomedGroupIDs.removeLast()
        selectedID = nil
        if zoomedGroupIDs.isEmpty {
            model.focusExploreRecord(id: nil)
            model.selectExploreRecord(id: nil)
        } else if chain.count >= 2 {
            syncFocus(to: chain[chain.count - 2], filtered: filtered)
        }
    }

    private func syncSelection(group: ExploreGroup?, filtered: [FileRecord]) {
        guard let group, let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) else {
            model.selectExploreRecord(id: nil)
            return
        }
        model.selectExploreRecord(id: record.id)
    }

    private func syncFocus(to group: ExploreGroup, filtered: [FileRecord]) {
        if let record = ExploreTreeBuilder.largestMember(of: group, in: filtered) {
            model.focusExploreRecord(id: record.id)
            model.selectExploreRecord(id: record.id)
        }
    }

    private func resolvedZoomChain(in rootGroups: [ExploreGroup]) -> [ExploreGroup] {
        var chain: [ExploreGroup] = []
        for id in zoomedGroupIDs {
            guard let found = ExploreTreeBuilder.findGroup(id: id, in: rootGroups) else { break }
            chain.append(found)
        }
        return chain
    }

    private func displayedGroups(rootGroups: [ExploreGroup], zoomedChain: [ExploreGroup]) -> [ExploreGroup] {
        guard let zoomed = zoomedChain.last else { return rootGroups }
        return zoomed.children.isEmpty ? [zoomed] : zoomed.children
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
        sectors: [SunburstSector],
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) -> KeyPress.Result {
        guard !sectors.isEmpty else { return .ignored }
        if press.key == .leftArrow || press.key == .upArrow {
            moveSectorSelection(by: -1, sectors: sectors, rootGroups: rootGroups, filtered: filtered)
            return .handled
        }
        if press.key == .rightArrow || press.key == .downArrow {
            moveSectorSelection(by: 1, sectors: sectors, rootGroups: rootGroups, filtered: filtered)
            return .handled
        }
        return handleActionKey(press.key, sectors: sectors, rootGroups: rootGroups, filtered: filtered)
    }

    private func handleActionKey(
        _ key: KeyEquivalent,
        sectors: [SunburstSector],
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) -> KeyPress.Result {
        switch key {
        case .return:
            guard let id = selectedID,
                  let sector = sectors.first(where: { $0.id == id }),
                  let group = resolvedGroup(for: sector, in: rootGroups),
                  !group.children.isEmpty else { return .ignored }
            zoomInto(group, filtered: filtered)
            return .handled
        case .escape:
            if selectedID != nil {
                selectedID = nil
                model.selectExploreRecord(id: nil)
                return .handled
            }
            if !zoomedGroupIDs.isEmpty {
                zoomedGroupIDs.removeLast()
                return .handled
            }
            return .ignored
        case .space:
            guard let id = selectedID,
                  let sector = sectors.first(where: { $0.id == id }),
                  let group = resolvedGroup(for: sector, in: rootGroups),
                  let url = ExploreTreeBuilder.largestMember(of: group, in: filtered)?.url else {
                return .ignored
            }
            QuickLookCoordinator.shared.togglePreview([url])
            return .handled
        default:
            return .ignored
        }
    }

    private func moveSectorSelection(
        by delta: Int,
        sectors: [SunburstSector],
        rootGroups: [ExploreGroup],
        filtered: [FileRecord]
    ) {
        let index = sectors.firstIndex(where: { $0.id == selectedID })
        let targetIndex = index.map { max(0, min(sectors.count - 1, $0 + delta)) }
            ?? (delta > 0 ? 0 : sectors.count - 1)
        let target = sectors[targetIndex]
        selectedID = target.id
        syncSelection(group: resolvedGroup(for: target, in: rootGroups), filtered: filtered)
    }
}

/// Annular segment used by the sunburst.
private struct RingSegment: Shape {
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var startAngle: Angle
    var endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let safeInner = max(0, innerRadius)
        let safeOuter = max(safeInner + 1, outerRadius)
        let sweep = endAngle.degrees - startAngle.degrees
        let effectiveEnd = sweep < 0.5 ? Angle.degrees(startAngle.degrees + 0.5) : endAngle
        path.addArc(center: center, radius: safeOuter, startAngle: startAngle, endAngle: effectiveEnd, clockwise: false)
        path.addArc(center: center, radius: safeInner, startAngle: effectiveEnd, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}
