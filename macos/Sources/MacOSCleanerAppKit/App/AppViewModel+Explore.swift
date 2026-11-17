import Foundation
import MacOSCleanerCore

// MARK: - Explore selection + staging + memoized layout cache

/// Cached Explore computation so 50k-node trees, spiral layouts, and age
/// buckets are built once per scan/filter change instead of inside SwiftUI `body`.
@MainActor
final class ExploreSnapshotCache {
    struct PlacedBubble: Identifiable, Sendable {
        var id: String
        var group: ExploreGroup
        var center: CGPoint
        var radius: CGFloat
    }

    struct AgeMonthBucket: Identifiable, Sendable {
        var id: String
        var label: String
        var bytes: Int64
        var fileCount: Int
        var memberIDs: [String]
    }

    private struct MonthRange {
        let key: String
        let label: String
        let start: Date
        let end: Date
    }

    struct AgeSnapshot: Sendable {
        var buckets: [AgeMonthBucket]
        var undatedCount: Int
        var spotlight: [FileRecord]
    }

    private struct FilterKey: Equatable {
        let token: ExploreFilesToken
        let nameFilter: String
    }

    private struct GroupKey: Equatable {
        let token: ExploreFilesToken
        let grouping: ExploreGrouping
        let maxDepth: Int
        let nameFilter: String
        let language: AppLanguage?
    }

    private struct FlameKey: Equatable {
        let groupKey: GroupKey
        let zoomedIDs: [String]
    }

    private struct AgeKey: Equatable {
        let token: ExploreFilesToken
        let nameFilter: String
        let dayOrdinal: Int
        let language: AppLanguage?
    }

    private static func monthFormatter(for language: AppLanguage?) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.formattingLocale(for: language)
        formatter.setLocalizedDateFormatFromTemplate("MMM yy")
        return formatter
    }

    private var filterKey: FilterKey?
    private var cachedFiltered: [FileRecord] = []

    private var groupKey: GroupKey?
    private var cachedGroups: [ExploreGroup] = []

    private var sectorKey: FlameKey?
    private var cachedSectors: [SunburstSector] = []

    private var flameKey: FlameKey?
    private var cachedFlameRows: [[SunburstSector]] = []

    private var bubbleKey: GroupKey?
    private var cachedBubbles: [PlacedBubble] = []

    private var ageKey: AgeKey?
    private var cachedAgeSnapshot: AgeSnapshot?

    func invalidate() {
        filterKey = nil
        cachedFiltered = []
        groupKey = nil
        cachedGroups = []
        sectorKey = nil
        cachedSectors = []
        flameKey = nil
        cachedFlameRows = []
        bubbleKey = nil
        cachedBubbles = []
        ageKey = nil
        cachedAgeSnapshot = nil
    }

    func filteredFiles(_ files: [FileRecord], nameFilter: String) -> [FileRecord] {
        let next = FilterKey(token: ExploreFilesToken(files), nameFilter: nameFilter)
        if next == filterKey { return cachedFiltered }
        filterKey = next
        cachedFiltered = ExploreTreeBuilder.filteredFiles(files, nameFilter: nameFilter)
        return cachedFiltered
    }

    func groups(
        files: [FileRecord],
        grouping: ExploreGrouping,
        maxDepth: Int,
        nameFilter: String,
        language: AppLanguage? = nil
    ) -> [ExploreGroup] {
        let filtered = filteredFiles(files, nameFilter: nameFilter)
        if grouping == .byAge {
            return ExploreTreeBuilder.build(files: filtered, grouping: grouping, maxDepth: maxDepth, language: language)
        }
        let next = GroupKey(
            token: ExploreFilesToken(files), grouping: grouping, maxDepth: maxDepth,
            nameFilter: nameFilter, language: language
        )
        if next == groupKey { return cachedGroups }
        groupKey = next
        cachedGroups = ExploreTreeBuilder.build(files: filtered, grouping: grouping, maxDepth: maxDepth, language: language)
        return cachedGroups
    }

    func sectors(
        files: [FileRecord],
        grouping: ExploreGrouping,
        maxDepth: Int,
        nameFilter: String,
        zoomedGroupID: String? = nil,
        language: AppLanguage? = nil
    ) -> [SunburstSector] {
        let currentGroups = groups(
            files: files, grouping: grouping, maxDepth: maxDepth, nameFilter: nameFilter, language: language
        )
        let gKey = GroupKey(
            token: ExploreFilesToken(files), grouping: grouping, maxDepth: maxDepth,
            nameFilter: nameFilter, language: language
        )
        let next = FlameKey(groupKey: gKey, zoomedIDs: zoomedGroupID.map { [$0] } ?? [])
        if grouping != .byAge, next == sectorKey { return cachedSectors }
        sectorKey = next
        let chartGroups: [ExploreGroup]
        if let zoomedGroupID,
           let target = ExploreTreeBuilder.findGroup(id: zoomedGroupID, in: currentGroups) {
            chartGroups = target.children.isEmpty ? [target] : target.children
        } else {
            chartGroups = currentGroups
        }
        cachedSectors = ExploreTreeBuilder.sectors(groups: chartGroups, maxDepth: maxDepth)
        return cachedSectors
    }

    func flameRows(
        files: [FileRecord],
        grouping: ExploreGrouping,
        maxDepth: Int,
        nameFilter: String,
        zoomedPath: [String],
        language: AppLanguage? = nil
    ) -> [[SunburstSector]] {
        let currentGroups = groups(
            files: files, grouping: grouping, maxDepth: maxDepth, nameFilter: nameFilter, language: language
        )
        let gKey = GroupKey(
            token: ExploreFilesToken(files), grouping: grouping, maxDepth: maxDepth,
            nameFilter: nameFilter, language: language
        )
        let next = FlameKey(groupKey: gKey, zoomedIDs: zoomedPath)
        if grouping != .byAge, next == flameKey { return cachedFlameRows }
        flameKey = next
        let chartGroups: [ExploreGroup]
        if let zoomedID = zoomedPath.last,
           let target = ExploreTreeBuilder.findGroup(id: zoomedID, in: currentGroups) {
            chartGroups = [target]
        } else {
            chartGroups = currentGroups
        }
        cachedFlameRows = ExploreTreeBuilder.flameRows(groups: chartGroups, maxDepth: maxDepth)
        return cachedFlameRows
    }

    func placedBubbles(
        files: [FileRecord],
        grouping: ExploreGrouping,
        maxDepth: Int,
        nameFilter: String,
        limit: Int = 24,
        language: AppLanguage? = nil
    ) -> [PlacedBubble] {
        let next = GroupKey(
            token: ExploreFilesToken(files), grouping: grouping, maxDepth: maxDepth,
            nameFilter: nameFilter, language: language
        )
        if grouping != .byAge, next == bubbleKey { return cachedBubbles }
        bubbleKey = next
        let roots = groups(
            files: files, grouping: grouping, maxDepth: maxDepth, nameFilter: nameFilter, language: language
        )
        let topGroups = Array(roots.sorted { $0.bytes > $1.bytes }.prefix(limit))
        let computed = Self.packSpiralBubbles(groups: topGroups)
        cachedBubbles = computed
        return computed
    }

    func ageSnapshot(
        files: [FileRecord],
        nameFilter: String,
        monthCount: Int = 12,
        language: AppLanguage? = nil
    ) -> AgeSnapshot {
        let calendar = Calendar.current
        let now = Date()
        let dayOrdinal = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        let next = AgeKey(
            token: ExploreFilesToken(files), nameFilter: nameFilter, dayOrdinal: dayOrdinal, language: language
        )
        if next == ageKey, let cachedAgeSnapshot { return cachedAgeSnapshot }
        ageKey = next
        let filtered = filteredFiles(files, nameFilter: nameFilter)
        let built = Self.buildAgeSnapshot(
            filtered: filtered, calendar: calendar, now: now, monthCount: monthCount, language: language
        )
        cachedAgeSnapshot = built
        return built
    }
}

extension ExploreSnapshotCache {
    private static func buildAgeSnapshot(
        filtered: [FileRecord],
        calendar: Calendar,
        now: Date,
        monthCount: Int,
        language: AppLanguage?
    ) -> AgeSnapshot {
        let formatter = monthFormatter(for: language)
        let currentMonthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? now
        var monthStarts: [MonthRange] = []
        for offset in stride(from: monthCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart) else { continue }
            let rangeStart = calendar.startOfDay(for: start)
            guard let rangeEnd = calendar.date(byAdding: .month, value: 1, to: rangeStart) else { continue }
            let year = calendar.component(.year, from: rangeStart)
            let month = calendar.component(.month, from: rangeStart)
            monthStarts.append(MonthRange(
                key: "\(year)-\(month)",
                label: formatter.string(from: rangeStart),
                start: rangeStart,
                end: rangeEnd
            ))
        }

        var membersByMonth: [String: [FileRecord]] = [:]
        var undated = 0
        let earliestStart = monthStarts.first?.start ?? .distantFuture
        let latestEnd = monthStarts.last?.end ?? .distantPast
        for file in filtered {
            guard let touched = ExploreTreeBuilder.lastTouchedDate(for: file) else {
                undated += 1
                continue
            }
            guard touched >= earliestStart, touched < latestEnd else { continue }
            let year = calendar.component(.year, from: touched)
            let month = calendar.component(.month, from: touched)
            membersByMonth["\(year)-\(month)", default: []].append(file)
        }

        let buckets = monthStarts.map { entry in
            let members = (membersByMonth[entry.key] ?? []).sorted { $0.sizeBytes > $1.sizeBytes }
            return AgeMonthBucket(
                id: entry.key,
                label: entry.label,
                bytes: members.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) },
                fileCount: members.count,
                memberIDs: members.map(\.id)
            )
        }
        let spotlight = ExploreTreeBuilder.bigUntouchedFiles(in: filtered, limit: 10)
        return AgeSnapshot(buckets: buckets, undatedCount: undated, spotlight: spotlight)
    }

    private static func packSpiralBubbles(groups: [ExploreGroup]) -> [PlacedBubble] {
        let total = Double(max(1, groups.reduce(Int64(0)) { $0 + max(0, $1.bytes) }))
        let radii = groups.map { group -> CGFloat in
            let fraction = Double(max(0, group.bytes)) / total
            return CGFloat(0.24 * sqrt(max(0.0004, fraction)))
        }
        var placed: [PlacedBubble] = []
        for (index, group) in groups.enumerated() {
            let radius = radii[index]
            let center: CGPoint
            if index == 0 {
                center = CGPoint(x: 0.5, y: 0.5)
            } else if let spot = spiralSpot(for: radius, avoiding: placed) {
                center = spot
            } else {
                continue
            }
            placed.append(PlacedBubble(id: group.id, group: group, center: center, radius: radius))
        }
        return placed
    }

    private static func spiralSpot(for radius: CGFloat, avoiding placed: [PlacedBubble]) -> CGPoint? {
        let goldenAngle = Double.pi * (3 - sqrt(5))
        var distance = 0.02
        var angle = 0.0
        for _ in 0..<900 {
            let candidate = CGPoint(
                x: 0.5 + CGFloat(cos(angle) * distance),
                y: 0.5 + CGFloat(sin(angle) * distance)
            )
            let inside = candidate.x - radius >= -0.01
                && candidate.x + radius <= 1.01
                && candidate.y - radius >= -0.01
                && candidate.y + radius <= 1.01
            let overlaps = placed.contains { other in
                hypot(candidate.x - other.center.x, candidate.y - other.center.y)
                    < radius + other.radius + 0.008
            }
            if inside, !overlaps {
                return candidate
            }
            angle += goldenAngle
            distance += 0.0016
            if distance > 0.75 {
                return nil
            }
        }
        return nil
    }
}

@MainActor
extension AppViewModel {

    /// The currently selected Explore record, resolved against the scan cache.
    var selectedExploreRecord: FileRecord? {
        guard let id = selectedExploreRecordID else {
            return nil
        }
        return filesByID[id]
    }

    /// The currently focused (drilled-into) Explore record.
    var focusedExploreRecord: FileRecord? {
        guard let id = focusedExploreRecordID else {
            return nil
        }
        return filesByID[id]
    }

    /// Select an Explore group member by record id. Nil clears the selection.
    func selectExploreRecord(id: String?) {
        selectedExploreRecordID = id
        if let id, let url = filesByID[id]?.url {
            QuickLookCoordinator.shared.updateSelectionIfVisible([url])
        }
    }

    /// Drill the Explore list into the given record. Nil zooms back out.
    func focusExploreRecord(id: String?) {
        focusedExploreRecordID = id
    }

    func exploreFilteredFiles(in sourceFiles: [FileRecord]? = nil, nameFilter: String) -> [FileRecord] {
        exploreCache.filteredFiles(sourceFiles ?? outcome?.files ?? [], nameFilter: nameFilter)
    }

    func exploreGroups(
        in sourceFiles: [FileRecord]? = nil,
        grouping: ExploreGrouping,
        maxDepth: Int,
        nameFilter: String
    ) -> [ExploreGroup] {
        exploreCache.groups(
            files: sourceFiles ?? outcome?.files ?? [], grouping: grouping,
            maxDepth: maxDepth, nameFilter: nameFilter, language: languageStore.activeOverride
        )
    }

    func exploreSectors(
        in sourceFiles: [FileRecord]? = nil,
        grouping: ExploreGrouping,
        maxDepth: Int,
        nameFilter: String,
        zoomedGroupID: String? = nil
    ) -> [SunburstSector] {
        exploreCache.sectors(
            files: sourceFiles ?? outcome?.files ?? [], grouping: grouping, maxDepth: maxDepth,
            nameFilter: nameFilter, zoomedGroupID: zoomedGroupID, language: languageStore.activeOverride
        )
    }

    func exploreFlameRows(
        in sourceFiles: [FileRecord]? = nil,
        grouping: ExploreGrouping,
        maxDepth: Int,
        nameFilter: String,
        zoomedPath: [String]
    ) -> [[SunburstSector]] {
        exploreCache.flameRows(
            files: sourceFiles ?? outcome?.files ?? [], grouping: grouping, maxDepth: maxDepth,
            nameFilter: nameFilter, zoomedPath: zoomedPath, language: languageStore.activeOverride
        )
    }

    func explorePlacedBubbles(
        in sourceFiles: [FileRecord]? = nil,
        grouping: ExploreGrouping,
        maxDepth: Int,
        nameFilter: String
    ) -> [ExploreSnapshotCache.PlacedBubble] {
        exploreCache.placedBubbles(
            files: sourceFiles ?? outcome?.files ?? [], grouping: grouping,
            maxDepth: maxDepth, nameFilter: nameFilter, language: languageStore.activeOverride
        )
    }

    func exploreAgeSnapshot(in sourceFiles: [FileRecord]? = nil, nameFilter: String) -> ExploreSnapshotCache.AgeSnapshot {
        exploreCache.ageSnapshot(
            files: sourceFiles ?? outcome?.files ?? [], nameFilter: nameFilter, language: languageStore.activeOverride
        )
    }

    func stagedExploreAction(matching record: FileRecord) -> PlannedAction? {
        plan?.actions.first {
            $0.targets == [record.id] && $0.actionType == .moveToTrash
                && $0.status == .proposed && $0.executedAt == nil
        }
    }

    @discardableResult
    func stageExploreRecordForCleanup(_ record: FileRecord) -> PlannedAction? {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting, !isPlanning else { return nil }
        if let existing = stagedExploreAction(matching: record) {
            return existing
        }
        guard var currentPlan = plan, filesByID[record.id] != nil else {
            return nil
        }
        guard !record.riskFlags.contains(.reviewOnly) else {
            statusMessage = L10n.format(
                "%@ is review-only and cannot be staged for cleanup.",
                language: override,
                record.fileName
            )
            return nil
        }
        let action = PlannedAction(
            id: UUID().uuidString,
            planID: currentPlan.id,
            actionType: .moveToTrash,
            targets: [record.id],
            destination: nil,
            status: .proposed,
            risk: max(.low, PlannerAgent.riskFloor(for: record.riskFlags)),
            confidence: 0.7,
            reason: L10n.format(
                "Staged from Explore: %@ (%@).",
                language: override,
                record.fileName,
                record.sizeBytes.formattedByteCount
            ),
            userDecision: .undecided,
            executedAt: nil,
            findingID: nil
        )
        currentPlan.actions.append(action)
        currentPlan.originalActions?.append(action)
        refreshPlanEstimates(plan: &currentPlan)
        plan = currentPlan
        schedulePlanPersistence()
        selectedActionID = action.id
        selectedActionIDs = [action.id]
        statusMessage = L10n.format(
            "Staged %@ for review in Proposed Actions.",
            language: override,
            record.fileName
        )
        return action
    }

    func unstageExploreAction(matching record: FileRecord) {
        guard !isScanning, !isExecuting, !isPlanning else { return }
        guard var currentPlan = plan else {
            return
        }
        let before = currentPlan.actions.count
        currentPlan.actions.removeAll { $0.targets == [record.id] && $0.status == .proposed }
        currentPlan.originalActions?.removeAll { $0.targets == [record.id] && $0.status == .proposed }
        guard currentPlan.actions.count != before else {
            return
        }
        refreshPlanEstimates(plan: &currentPlan)
        plan = currentPlan
        schedulePlanPersistence()
        if selectedActionID.map({ id in !currentPlan.actions.contains(where: { $0.id == id }) }) ?? false {
            selectedActionID = currentPlan.actions.first?.id
        }
        statusMessage = L10n.format(
            "Removed %@ from the cleanup plan.",
            language: languageStore.activeOverride,
            record.fileName
        )
    }
}
