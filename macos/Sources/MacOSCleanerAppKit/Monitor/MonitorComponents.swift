import Charts
import MacOSCleanerCore
import SwiftUI

/// Metric tile: label, big value, optional context line, sparkline.
struct MetricTileView: View {
    let title: String
    let icon: String
    let value: String
    let unit: String?
    let context: String?
    let tint: Color
    var points: [(Date, Double)] = []
    var scale: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if let unit {
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let context {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if points.count > 1 {
                SparklineView(points: points, tint: tint, scale: scale)
                    .frame(height: 28)
            }
        }
        .padding(Spacing.cardInternal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monitorCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [title, unit.map { "\(value) \($0)" } ?? value, context]
                .compactMap { $0 }.joined(separator: ", "))
    }
}

/// Tiny line chart for tiles and menu bar panels; no axes, just shape.
struct SparklineView: View {
    let points: [(Date, Double)]
    let tint: Color
    var scale: Double?

    var body: some View {
        let sampled = ChartDownsampler.downsampleTuples(points, targetCount: 60)
        let peakValue = sampled.map(\.1).max() ?? 1
        let upper = max(1, scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? peakValue)
        Chart {
            ForEach(Array(sampled.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value(Self.timeLabel, point.0),
                    y: .value(Self.valueLabel, point.1)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
            }
        }
        .chartYScale(domain: 0...upper)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    static let timeLabel = String(localized: "Time", comment: "Chart x-axis label")
    static let valueLabel = String(localized: "Value", comment: "Chart y-axis label")
}

/// The busiest list: app icon, name, bar, value.
struct BusiestListView: View {
    let title: String
    let groups: [AppProcessGroup]
    let metric: UsageMetric
    var maxValue: Double?
    var onSelect: ((AppProcessGroup) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if groups.isEmpty {
                Text(String(localized: "Nothing running.", comment: "Empty busiest list"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(groups.prefix(8)) { group in
                    row(group)
                }
            }
        }
        .padding(Spacing.cardInternal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorCard()
    }

    @ViewBuilder
    private func row(_ group: AppProcessGroup) -> some View {
        Button {
            onSelect?(group)
        } label: {
            HStack(spacing: Spacing.elementTight) {
                MonitorAppIconView(bundlePath: group.bundlePath)
                Text(group.name)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(minWidth: 90, maxWidth: 170, alignment: .leading)
                ProgressBarView(fraction: fraction(group), tint: MonitorTab.overview.tint)
                    .frame(maxWidth: .infinity)
                Text(MetricFormatting.value(group.value(for: metric), metric: metric))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fraction(_ group: AppProcessGroup) -> Double {
        let maximum = maxValue ?? max(1, groups.map { $0.value(for: metric) }.max() ?? 1)
        let raw = group.value(for: metric) / maximum
        return raw.isFinite ? min(1, max(0, raw)) : 0
    }
}

/// App icon by bundle path with a dashed fallback, wrapping the shared AppIconView.
struct MonitorAppIconView: View {
    let bundlePath: String?

    var body: some View {
        if let bundlePath {
            AppIconView(url: URL(fileURLWithPath: bundlePath), size: 18)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }
}

/// Horizontal usage bar used in busiest lists and table rows.
struct ProgressBarView: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * clamped))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Formatting for metric values, shared by tiles, lists, tables, and the menu bar.
enum MetricFormatting {
    enum ByteUnitsStyle: String {
        case automatic = "auto"
        case binary
        case decimal
    }

    static var byteUnitsStyle: ByteUnitsStyle {
        ByteUnitsStyle(rawValue: UserDefaults.standard.string(forKey: MonitoringKeys.byteUnits) ?? "") ?? .automatic
    }

    static func value(_ raw: Double, metric: UsageMetric) -> String {
        let safe = raw.isFinite ? max(0, raw) : 0
        switch metric {
        case .cpu: return String(format: "%.1f%%", safe)
        case .memory: return byteCount(bytes(safe))
        case .disk: return rate(safe)
        case .network: return rate(safe)
        case .energy: return energy(safe)
        }
    }

    static func byteCount(_ bytes: Int64) -> String {
        let safe = bytes > 0 ? bytes : 0
        switch byteUnitsStyle {
        case .automatic:
            return safe.formattedByteCount
        case .binary, .decimal:
            guard safe != 0 else {
                return String(localized: "0 bytes", comment: "Byte count for an empty file")
            }
            let formatter = ByteCountFormatter()
            formatter.countStyle = byteUnitsStyle == .binary ? .memory : .decimal
            return formatter.string(fromByteCount: safe)
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        byteCount(bytes(bytesPerSecond)) + "/s"
    }

    /// Clamps finite byte values within safe `Int64` range (avoids `Double(Int64.max)` rounding trap).
    static func bytes(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, 0), 9_000_000_000_000_000_000.0)
        return Int64(clamped)
    }

    static func whole(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -9.0e15), 9.0e15))
    }

    static func energy(_ index: Double) -> String {
        let safe = index.isFinite ? max(0, index) : 0
        return safe.formatted(.number.precision(.fractionLength(1)))
    }

    static func watts(_ value: Double) -> String {
        let safe = value.isFinite ? max(0, value) : 0
        return safe.formatted(.number.precision(.fractionLength(1))) + " W"
    }

    static func seconds(_ value: Double) -> String {
        let safe = value.isFinite ? max(0, value) : 0
        return safe.formatted(.number.precision(.fractionLength(1)))
    }

    static func percent(_ fraction: Double) -> String {
        let safe = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return String(format: "%.0f%%", safe * 100)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds.isFinite && seconds >= 0 && seconds < 1e12 ? seconds.formattedDuration : "-"
    }

    static func appCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 app", comment: "App count, singular")
            : String(localized: "\(count) apps", comment: "App count, plural")
    }

    static func processCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 process", comment: "Process count, singular")
            : String(localized: "\(count) processes", comment: "Process count, plural")
    }

    static func readingCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 reading", comment: "Chart reading count, singular")
            : String(localized: "\(count) readings", comment: "Chart reading count, plural")
    }
}

private struct MonitorCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(.separator.opacity(0.5)))
    }
}

extension View {
    func monitorCard() -> some View {
        modifier(MonitorCardChrome())
    }
}

// MARK: - LTTB Chart Downsampling & Charts

/// Largest-Triangle-Three-Buckets downsampling keeps dense 30-day/1-year charts
/// under 180 points per series while preserving visual peaks and valleys.
enum ChartDownsampler {
    static func downsample(
        _ points: [MetricsHistoryStore.SeriesPoint],
        targetCount: Int = 180
    ) -> [MetricsHistoryStore.SeriesPoint] {
        let clean = points.filter { $0.average.isFinite }
        guard clean.count > targetCount, targetCount >= 3 else { return clean }

        var sampled: [MetricsHistoryStore.SeriesPoint] = []
        sampled.reserveCapacity(targetCount)
        sampled.append(clean[0])

        let origin = clean[0].timestamp.timeIntervalSince1970
        let bucketSize = Double(clean.count - 2) / Double(targetCount - 2)
        var previousIndex = 0

        for bucket in 0..<(targetCount - 2) {
            let avgStart = Int((Double(bucket + 1) * bucketSize).rounded(.down)) + 1
            let avgEnd = min(Int((Double(bucket + 2) * bucketSize).rounded(.down)) + 1, clean.count)
            let (avgX, avgY) = bucketAverage(clean, start: avgStart, end: avgEnd, origin: origin)

            let rangeStart = Int((Double(bucket) * bucketSize).rounded(.down)) + 1
            let rangeEnd = min(Int((Double(bucket + 1) * bucketSize).rounded(.down)) + 1, clean.count - 1)
            let context = BucketContext(previous: previousIndex, avgX: avgX, avgY: avgY, origin: origin)
            let chosen = bestBucketPoint(clean, range: rangeStart..<rangeEnd, context: context)
            sampled.append(chosen.point)
            previousIndex = chosen.index
        }

        sampled.append(clean[clean.count - 1])
        return sampled
    }

    private struct BucketContext {
        let previous: Int
        let avgX: Double
        let avgY: Double
        let origin: TimeInterval
    }

    static func downsampleTuples(_ points: [(Date, Double)], targetCount: Int = 60) -> [(Date, Double)] {
        let clean = points.filter { $0.1.isFinite }
        guard clean.count > targetCount, targetCount >= 3 else { return clean }
        let wrapped = clean.map { MetricsHistoryStore.SeriesPoint(timestamp: $0.0, average: $0.1, peak: nil) }
        return downsample(wrapped, targetCount: targetCount).map { ($0.timestamp, $0.average) }
    }

    private static func bucketAverage(
        _ points: [MetricsHistoryStore.SeriesPoint], start: Int, end: Int, origin: TimeInterval
    ) -> (Double, Double) {
        guard start < end else {
            let fallback = points[min(start, points.count - 1)]
            return (fallback.timestamp.timeIntervalSince1970 - origin, fallback.average)
        }
        var sumX = 0.0
        var sumY = 0.0
        for index in start..<end {
            sumX += points[index].timestamp.timeIntervalSince1970 - origin
            sumY += points[index].average
        }
        let length = Double(end - start)
        return (sumX / length, sumY / length)
    }

    private static func bestBucketPoint(
        _ points: [MetricsHistoryStore.SeriesPoint],
        range: Range<Int>,
        context: BucketContext
    ) -> (index: Int, point: MetricsHistoryStore.SeriesPoint) {
        let prevX = points[context.previous].timestamp.timeIntervalSince1970 - context.origin
        let prevY = points[context.previous].average
        var bestArea = -1.0
        var bestIndex = min(range.lowerBound, points.count - 1)
        var maxPeak: Double?

        for index in range {
            let current = points[index]
            if let peak = current.peak, peak.isFinite {
                maxPeak = max(maxPeak ?? peak, peak)
            }
            let currX = current.timestamp.timeIntervalSince1970 - context.origin
            let area = abs(
                (prevX - context.avgX) * (current.average - prevY)
                    - (prevX - currX) * (context.avgY - prevY)) * 0.5
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        var chosen = points[bestIndex]
        if let maxPeak {
            chosen.peak = max(chosen.peak ?? maxPeak, maxPeak)
        }
        return (bestIndex, chosen)
    }
}

/// Full history chart with an average/peak area, used on CPU and Memory tabs.
struct HistoryChartView: View {
    static func summary(_ points: [MetricsHistoryStore.SeriesPoint], unit: UsageMetric) -> String {
        guard !points.isEmpty else {
            return String(localized: "No readings yet", comment: "Chart summary with no data")
        }
        let average = points.reduce(0.0) { $0 + ($1.average.isFinite ? $1.average : 0) } / Double(points.count)
        let peak = points.map { $0.peak ?? $0.average }.filter(\.isFinite).max() ?? average
        let avgText = MetricFormatting.value(average, metric: unit)
        let peakText = MetricFormatting.value(peak, metric: unit)
        let countText = MetricFormatting.readingCount(points.count)
        return String(localized: "Average \(avgText), peak \(peakText), \(countText)", comment: "History chart summary for VoiceOver")
    }

    let points: [MetricsHistoryStore.SeriesPoint]
    let tint: Color
    let unit: UsageMetric

    var body: some View {
        let sampled = ChartDownsampler.downsample(points, targetCount: 180)
        Chart {
            ForEach(sampled) { point in
                LineMark(
                    x: .value(SparklineView.timeLabel, point.timestamp),
                    y: .value(SparklineView.valueLabel, max(0, point.average))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
            }
            ForEach(sampled.filter { $0.peak != nil }) { point in
                AreaMark(
                    x: .value(SparklineView.timeLabel, point.timestamp),
                    yStart: .value(SparklineView.valueLabel, max(0, point.average)),
                    yEnd: .value(SparklineView.valueLabel, max(point.average, point.peak ?? point.average))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(tint.opacity(0.12))
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(unit == .cpu ? String(format: "%.0f%%", number) : MetricFormatting.value(number, metric: unit))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .frame(minHeight: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(unit.monitorTitle) history chart", comment: "History chart label"))
        .accessibilityValue(Self.summary(sampled, unit: unit))
    }
}

/// Dual-series chart for Disk (Read vs Write) and Network (Download vs Upload).
struct DualHistoryChartView: View {
    struct Entry: Identifiable {
        let id: String
        let series: String
        let timestamp: Date
        let value: Double
    }

    let primaryLabel: String
    let primaryColor: Color
    let primaryPoints: [MetricsHistoryStore.SeriesPoint]
    let secondaryLabel: String
    let secondaryColor: Color
    let secondaryPoints: [MetricsHistoryStore.SeriesPoint]
    let unit: UsageMetric

    var body: some View {
        let pDown = ChartDownsampler.downsample(primaryPoints, targetCount: 150)
        let sDown = ChartDownsampler.downsample(secondaryPoints, targetCount: 150)
        let entries = buildEntries(primary: pDown, secondary: sDown)
        Chart(entries) { entry in
            LineMark(
                x: .value(SparklineView.timeLabel, entry.timestamp),
                y: .value(SparklineView.valueLabel, max(0, entry.value))
            )
            .foregroundStyle(by: .value(Self.seriesLabel, entry.series))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([
            primaryLabel: primaryColor,
            secondaryLabel: secondaryColor
        ])
        .chartLegend(position: .top, alignment: .leading)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(MetricFormatting.value(number, metric: unit))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .frame(minHeight: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(unit.monitorTitle) history chart", comment: "History chart label"))
        .accessibilityValue(accessibilitySummary(primary: pDown, secondary: sDown))
    }

    private func buildEntries(
        primary: [MetricsHistoryStore.SeriesPoint],
        secondary: [MetricsHistoryStore.SeriesPoint]
    ) -> [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(primary.count + secondary.count)
        for point in primary {
            result.append(Entry(
                id: "p-\(point.timestamp.timeIntervalSince1970)",
                series: primaryLabel, timestamp: point.timestamp, value: point.average))
        }
        for point in secondary {
            result.append(Entry(
                id: "s-\(point.timestamp.timeIntervalSince1970)",
                series: secondaryLabel, timestamp: point.timestamp, value: point.average))
        }
        return result
    }

    private func accessibilitySummary(
        primary: [MetricsHistoryStore.SeriesPoint],
        secondary: [MetricsHistoryStore.SeriesPoint]
    ) -> String {
        let pText = HistoryChartView.summary(primary, unit: unit)
        let sText = HistoryChartView.summary(secondary, unit: unit)
        return "\(primaryLabel): \(pText). \(secondaryLabel): \(sText)"
    }

    private static let seriesLabel = String(localized: "Series", comment: "Dual chart legend label")
}
