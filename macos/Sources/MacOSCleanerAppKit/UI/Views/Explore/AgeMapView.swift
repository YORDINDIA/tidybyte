import MacOSCleanerCore
import SwiftUI

/// Timeline of when files were last touched: per-month heat grid plus a
/// spotlight list of big files untouched for a long time.
/// Renders entirely from already-scanned `FileRecord` values.
struct AgeMapView: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var nameFilter: String

    @State private var selectedMonthKey: String?
    private let monthCount = 12
    private let untouchedLimit = 10

    private struct MonthBucket: Identifiable, Sendable {
        var id: String
        var label: String
        var bytes: Int64
        var fileCount: Int
    }

    private var filtered: [FileRecord] {
        ExploreTreeBuilder.filteredFiles(files, nameFilter: nameFilter)
    }

    /// One formatter for every render: creating a DateFormatter per call was costly.
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yy")
        return formatter
    }()

    /// Built once per render from the body, then passed down to the views that need it.
    private var monthBuckets: [MonthBucket] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [MonthBucket] = []
        for offset in stride(from: monthCount - 1, through: 0, by: -1) {
            guard let monthStart = calendar.date(
                byAdding: .month,
                value: -offset,
                to: calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            ) else {
                continue
            }
            let rangeStart = calendar.startOfDay(for: monthStart)
            guard let rangeEnd = calendar.date(byAdding: .month, value: 1, to: rangeStart) else {
                continue
            }
            let members = filtered.filter { file in
                guard let touched = ExploreTreeBuilder.lastTouchedDate(for: file) else {
                    return false
                }
                return touched >= rangeStart && touched < rangeEnd
            }
            let key = "\(calendar.component(.year, from: rangeStart))-\(calendar.component(.month, from: rangeStart))"
            buckets.append(MonthBucket(
                id: key,
                label: Self.monthFormatter.string(from: rangeStart),
                bytes: members.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) },
                fileCount: members.count
            ))
        }
        return buckets
    }

    private var undatedCount: Int {
        filtered.filter { ExploreTreeBuilder.lastTouchedDate(for: $0) == nil }.count
    }

    var body: some View {
        // Each derived value is computed once per render.
        let buckets = monthBuckets
        let undated = undatedCount
        let spotlight = ExploreTreeBuilder.bigUntouchedFiles(in: filtered, limit: untouchedLimit)
        return VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if filtered.isEmpty {
                ExploreEmptyState()
            } else {
                heatGrid(buckets: buckets, undated: undated)
                if let selected = buckets.first(where: { $0.id == selectedMonthKey }) {
                    selectedFooter(for: selected)
                }
                spotlightSection(spotlight)
            }
        }
        .onChange(of: ExploreFilesToken(files)) { _, _ in
            selectedMonthKey = nil
        }
    }

    private func heatGrid(buckets: [MonthBucket], undated: Int) -> some View {
        let maxBucketBytes = buckets.map(\.bytes).max() ?? 1
        return VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(String(localized: "Touched per month", comment: "Age Map heat grid title"))
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
                Text(String(localized: "\(undated) files have no known date", comment: "Age Map undated files note"))
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func monthCell(for bucket: MonthBucket, maxBucketBytes: Int64) -> some View {
        let intensity = maxBucketBytes > 0
            ? Double(max(0, bucket.bytes)) / Double(maxBucketBytes)
            : 0
        let isSelected = selectedMonthKey == bucket.id
        return Button {
            selectedMonthKey = isSelected ? nil : bucket.id
        } label: {
            VStack(spacing: 2) {
                Text(bucket.label)
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(bucket.bytes.formattedByteCount)
                    .appFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(4)
            .background(
                bucket.bytes > 0
                    ? AnyShapeStyle(SemanticScale.warningSoft.opacity(0.25 + 0.75 * intensity))
                    : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous).strokeBorder(.tint, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(String(localized: "\(bucket.label), \(bucket.bytes.formattedByteCount), \(bucket.fileCount) files"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "\(bucket.label): \(bucket.bytes.formattedByteCount), \(bucket.fileCount) files")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(String(localized: "Shows month details"))
    }

    private func selectedFooter(for bucket: MonthBucket) -> some View {
        HStack {
            Text(bucket.label)
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
            Spacer()
            Text(String(localized: "\(bucket.bytes.formattedByteCount) · \(bucket.fileCount) files"))
                .appFont(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
            Button(String(localized: "Clear", comment: "Explore clear selection")) {
                selectedMonthKey = nil
            }
            .buttonStyle(.plain)
            .appFont(.caption)
            .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, Spacing.elementTight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Selected month: \(bucket.label), \(bucket.bytes.formattedByteCount)"))
    }

    private func spotlightSection(_ spotlight: [FileRecord]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(SemanticScale.warning)
                Text(String(localized: "Big and untouched (180+ days)", comment: "Age Map spotlight title"))
                    .appFont(.labelMedium)
                    .foregroundStyle(Color.secondary)
                Spacer()
            }
            if spotlight.isEmpty {
                Text(String(localized: "No large untouched files found. Everything big was opened recently.", comment: "Age Map spotlight empty"))
                    .appFont(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(spotlight) { file in
                    spotlightRow(file)
                }
            }
        }
    }

    private func spotlightRow(_ file: FileRecord) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
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
            spotlightActions(file)
        }
        .padding(.horizontal, Spacing.cardPadding)
        .padding(.vertical, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous))
        .overlay {
            if model.selectedExploreRecordID == file.id {
                RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .help(String(localized: "\(file.fileName), \(file.sizeBytes.formattedByteCount)"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "\(file.fileName), \(file.sizeBytes.formattedByteCount)")))
    }

    private func spotlightActions(_ file: FileRecord) -> some View {
        return HStack(spacing: Spacing.elementTight) {
    SecondaryButton(
        title: String(localized: "Focus"),
        icon: "scope",
        action: {
            model.focusExploreRecord(id: file.id)
            model.selectExploreRecord(id: file.id)
        }
    )
    if model.stagedExploreAction(matching: file) != nil {
        SecondaryButton(
            title: String(localized: "Approve"),
            icon: "checkmark",
            action: {
                guard let staged = model.stagedExploreAction(matching: file) else {
                    return
                }
                model.approve(staged)
            }
        )
    } else {
        SecondaryButton(
            title: String(localized: "Stage"),
            icon: "plus.circle",
            action: {
                if model.stageExploreRecordForCleanup(file) != nil {
                    model.setStatusMessage(String(
                        localized: "Added to the cleanup plan. Review it in Proposed Actions.",
                        comment: "Explore staging accepted"))
                } else {
                    model.setStatusMessage(String(
                        localized: "Could not stage. A scan, execution, or plan change is in flight.",
                        comment: "Explore staging refused"))
                }
            }
        )
    }
}
    }
}
