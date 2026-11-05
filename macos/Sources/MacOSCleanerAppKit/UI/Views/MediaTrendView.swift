import Charts
import MacOSCleanerCore
import SwiftUI

/// Daily size snapshots for the cleanup scope. Renders once two snapshots
/// exist, with an honest span label ("Shrank by 2.1 GB in 6 days").
/// Lives on Insights › Changes and on the Overview dashboard.
struct MediaTrendView: View {
    @Bindable var model: CleanupModel

    var body: some View {
        if !model.hasLoaded {
            // Stored snapshots are still being read (Phase 3): skeleton chart
            // frame instead of a false "No trend yet".
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                SkeletonBlock(height: 180)
                SkeletonBlock(height: 14, width: 220)
            }
            .accessibilityLabel(Text(String(localized: "Loading snapshots…", comment: "Trend loading")))
        } else if model.snapshots.count >= 2, let first = model.snapshots.first, let last = model.snapshots.last {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                Chart(model.snapshots) {
                    LineMark(
                        x: .value(String(localized: "Date"), $0.date),
                        y: .value(String(localized: "Size"), $0.bytes))
                    .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { Text(Int64(value.as(Double.self) ?? 0).formattedByteCount) }
                    }
                }
                .frame(minHeight: 180)
                .accessibilityLabel(trendLabel(first, last))
                Text(trendLabel(first, last))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(
                String(localized: "No trend yet"), systemImage: "chart.line.uptrend.xyaxis",
                description: Text(String(localized: "Scan on two different days to see how this scope changes.")))
        }
    }

    private func trendLabel(_ first: CleanupSnapshot, _ last: CleanupSnapshot) -> String {
        let days = Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0
        let delta = last.bytes - first.bytes
        return delta < 0
            ? String(localized: "Shrank by \((-delta).formattedByteCount) in \(days) days")
            : String(localized: "Grew by \(delta.formattedByteCount) in \(days) days")
    }
}
