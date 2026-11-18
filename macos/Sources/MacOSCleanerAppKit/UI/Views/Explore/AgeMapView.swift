import MacOSCleanerCore
import SwiftUI

/// Timeline of when files were last touched: per-month heat grid, drilled-in
/// month file list, and spotlight list of large untouched files.
struct AgeMapView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var nameFilter: String

    @State private var selectedMonthKey: String?
    private let drilledDisplayLimit = 25

    private var override: AppLanguage? {
        model.languageStore.activeOverride
    }

    var body: some View {
        let filtered = model.exploreFilteredFiles(in: files, nameFilter: nameFilter)
        let snapshot = model.exploreAgeSnapshot(in: files, nameFilter: nameFilter)
        let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if filtered.isEmpty {
                ExploreEmptyState(language: override)
            } else {
                heatGrid(buckets: snapshot.buckets, undated: snapshot.undatedCount)
                if let selected = snapshot.buckets.first(where: { $0.id == selectedMonthKey }) {
                    monthDetailSection(for: selected, byID: byID)
                }
                spotlightSection(snapshot.spotlight)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let url = model.selectedExploreRecord?.url ?? selectedFallbackURL(in: filtered) else {
                return .ignored
            }
            QuickLookCoordinator.shared.togglePreview([url])
            return .handled
        }
        .onKeyPress(.escape) {
            if selectedMonthKey != nil {
                selectedMonthKey = nil
                return .handled
            }
            return .ignored
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            selectedMonthKey = nil
        }
    }

    private func selectedFallbackURL(in filtered: [FileRecord]) -> URL? {
        guard let selectedID = model.selectedExploreRecordID else { return nil }
        return filtered.first(where: { $0.id == selectedID })?.url
    }

    private func heatGrid(buckets: [ExploreSnapshotCache.AgeMonthBucket], undated: Int) -> some View {
        let maxBucketBytes = buckets.map(\.bytes).max() ?? 1
        return VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(L10n.string("Touched per month", language: override))
                .appFont(.labelMedium)
                .foregroundStyle(Color.secondary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6),
                spacing: 6
            ) {
                ForEach(buckets) { bucket in
                    monthCell(for: bucket, maxBucketBytes: maxBucketBytes)
                }
            }
            if undated > 0 {
                Text(L10n.format("%@ have no known date", language: override, ExploreCopy.fileCount(undated, language: override)))
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func monthCell(for bucket: ExploreSnapshotCache.AgeMonthBucket, maxBucketBytes: Int64) -> some View {
        let intensity = maxBucketBytes > 0 ? Double(max(0, bucket.bytes)) / Double(maxBucketBytes) : 0
        let isSelected = selectedMonthKey == bucket.id
        return Button {
            selectedMonthKey = isSelected ? nil : bucket.id
        } label: {
            monthCellLabel(for: bucket, intensity: intensity, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help(L10n.format(
            "%@, %@, %@",
            language: override,
            bucket.label,
            bucket.bytes.formattedByteCount,
            ExploreCopy.fileCount(bucket.fileCount, language: override)
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format(
            "%@: %@, %@",
            language: override,
            bucket.label,
            bucket.bytes.formattedByteCount,
            ExploreCopy.fileCount(bucket.fileCount, language: override)
        )))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(L10n.string("Shows month files", language: override))
    }

    private func monthCellLabel(
        for bucket: ExploreSnapshotCache.AgeMonthBucket,
        intensity: Double,
        isSelected: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
        return VStack(spacing: 2) {
            Text(bucket.label)
                .appFont(.caption)
                .foregroundStyle(bucket.bytes > 0 ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(bucket.bytes.formattedByteCount)
                .appFont(.caption)
                .monospacedDigit()
                .foregroundStyle(bucket.bytes > 0 ? Color.primary.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .padding(6)
        .background(
            bucket.bytes > 0
                ? AnyShapeStyle(SemanticScale.warning.opacity(0.18 + 0.54 * intensity))
                : AnyShapeStyle(.quaternary),
            in: shape
        )
        .overlay {
            shape.strokeBorder(
                isSelected ? Color.accentColor : SemanticScale.subtleBorder,
                lineWidth: isSelected ? 2 : 1
            )
        }
    }

    private func monthDetailSection(
        for bucket: ExploreSnapshotCache.AgeMonthBucket,
        byID: [String: FileRecord]
    ) -> some View {
        let members = bucket.memberIDs.compactMap { byID[$0] }
        let displayed = Array(members.prefix(drilledDisplayLimit))
        return VStack(alignment: .leading, spacing: Spacing.elementTight) {
            monthDetailHeader(for: bucket)
            if displayed.isEmpty {
                Text(L10n.string("No files touched during this month.", language: override))
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(displayed) { file in
                    fileRow(file)
                }
                if members.count > displayed.count {
                    Text(L10n.format(
                        "Showing largest %lld of %lld files in this month.",
                        language: override,
                        displayed.count,
                        members.count
                    ))
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(Spacing.cardPadding)
        .softCardSurface(cornerRadius: Radius.cardCompact)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format(
            "Selected month: %@, %@",
            language: override,
            bucket.label,
            bucket.bytes.formattedByteCount
        ))
    }

    private func monthDetailHeader(for bucket: ExploreSnapshotCache.AgeMonthBucket) -> some View {
        HStack {
            Text(bucket.label)
                .appFont(.labelMedium)
                .foregroundStyle(Color.primary)
            Spacer()
            Text(L10n.format(
                "%@ · %@",
                language: override,
                bucket.bytes.formattedByteCount,
                ExploreCopy.fileCount(bucket.fileCount, language: override)
            ))
            .appFont(.caption)
            .monospacedDigit()
            .foregroundStyle(Color.secondary)
            Button(L10n.string("Clear", language: override)) {
                selectedMonthKey = nil
            }
            .buttonStyle(.plain)
            .appFont(.caption)
            .foregroundStyle(Color.secondary)
        }
    }

    private func spotlightSection(_ spotlight: [FileRecord]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(SemanticScale.warning)
                Text(L10n.string("Big and untouched (180+ days)", language: override))
                    .appFont(.labelMedium)
                    .foregroundStyle(Color.secondary)
                Spacer()
            }
            if spotlight.isEmpty {
                Text(L10n.string("No large untouched files found. Everything big was opened recently.", language: override))
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(spotlight) { file in
                    fileRow(file)
                }
            }
        }
    }

    private func fileRow(_ file: FileRecord) -> some View {
        let isSelected = model.selectedExploreRecordID == file.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.selectExploreRecord(id: isSelected ? nil : file.id)
            } label: {
                HStack(spacing: 8) {
                    Text(file.fileName)
                        .appFont(.bodyMedium)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let touched = ExploreTreeBuilder.lastTouchedDate(for: file) {
                        Text(touched.formatted(date: .abbreviated, time: .omitted))
                            .appFont(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Text(file.sizeBytes.formattedByteCount)
                        .appFont(.labelMedium)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            fileRowActions(file)
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, 8)
        .softCardSurface(cornerRadius: Radius.cardCompact, isSelected: isSelected)
        .help(L10n.format("%@, %@", language: override, file.fileName, file.sizeBytes.formattedByteCount))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.format("%@, %@", language: override, file.fileName, file.sizeBytes.formattedByteCount)))
    }

    private func fileRowActions(_ file: FileRecord) -> some View {
        HStack(spacing: Spacing.elementTight) {
            SecondaryButton(
                title: L10n.string("Focus", language: override),
                icon: "scope",
                action: {
                    model.focusExploreRecord(id: file.id)
                    model.selectExploreRecord(id: file.id)
                }
            )
            SecondaryButton(
                title: L10n.string("Quick Look", language: override),
                icon: "eye",
                action: { QuickLookCoordinator.shared.preview(file.url) }
            )
            if let staged = model.stagedExploreAction(matching: file) {
                SecondaryButton(
                    title: L10n.string("Approve", language: override),
                    icon: "checkmark",
                    action: { model.approve(staged) }
                )
            } else {
                SecondaryButton(
                    title: L10n.string("Stage", language: override),
                    icon: "plus.circle",
                    action: {
                        if model.stageExploreRecordForCleanup(file) != nil {
                            model.setStatusMessage(
                                L10n.string("Added to the cleanup plan. Review it in Proposed Actions.", language: override)
                            )
                        } else {
                            model.setStatusMessage(
                                L10n.string("Could not stage. A scan, execution, or plan change is in flight.", language: override)
                            )
                        }
                    }
                )
            }
        }
    }
}
