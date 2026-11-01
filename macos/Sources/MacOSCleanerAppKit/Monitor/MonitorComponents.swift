import MacOSCleanerCore
import SwiftUI
import Charts

/// Metric tile: label, big value, optional context line, sparkline. The
/// compact density shrinks paddings rather than dropping data.
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorCard()
        // One tile reads as one VoiceOver result: title, value, context.
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
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value(Self.timeLabel, point.0),
                    y: .value(Self.valueLabel, point.1)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
            }
            AreaMark(
                x: .value(Self.timeLabel, points.first?.0 ?? .now),
                y: .value(Self.valueLabel, points.first?.1 ?? 0)
            )
            .foregroundStyle(.clear)
        }
        .chartYScale(domain: 0...(scale ?? max(1, points.map(\.1).max() ?? 1)))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    static let timeLabel = String(localized: "Time", comment: "Chart x-axis label")
    static let valueLabel = String(localized: "Value", comment: "Chart y-axis label")
}

/// The "busiest right now" list: app icon, name, bar, value.
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
                MonitorAppIconView(bundlePath: group.bundlePath, name: group.name)
                Text(group.name)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(minWidth: 90, maxWidth: 170, alignment: .leading)
                ProgressBarView(fraction: fraction(group), tint: barTint)
                    .frame(maxWidth: .infinity)
                Text(formatted(group))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
    }

    private var barTint: Color {
        MonitorTab.overview.tint
    }

    private func fraction(_ group: AppProcessGroup) -> Double {
        let maximum = maxValue ?? max(1, groups.map { $0.value(for: metric) }.max() ?? 1)
        return min(1, group.value(for: metric) / maximum)
    }

    private func formatted(_ group: AppProcessGroup) -> String {
        MetricFormatting.value(group.value(for: metric), metric: metric)
    }
}

/// App icon by bundle path with a dashed fallback, wrapping the shared
/// AppIconView used across the app.
struct MonitorAppIconView: View {
    let bundlePath: String?
    let name: String

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

/// The horizontal usage bar used in busiest lists and table rows.
struct ProgressBarView: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Formatting for metric values, shared by tiles, lists, tables, and the
/// menu bar. Byte-based metrics switch units automatically, or follow the
/// Settings › Monitoring byte-units style.
enum MetricFormatting {
    /// Byte display style, persisted as "monitor.byteUnits"
    /// ("auto" | "binary" | "decimal").
    enum ByteUnitsStyle: String {
        case automatic = "auto"
        case binary
        case decimal
    }

    static var byteUnitsStyle: ByteUnitsStyle {
        ByteUnitsStyle(rawValue: UserDefaults.standard.string(forKey: MonitoringKeys.byteUnits) ?? "") ?? .automatic
    }

    static func value(_ raw: Double, metric: UsageMetric) -> String {
        switch metric {
        case .cpu: String(format: "%.1f%%", raw)
        case .memory: byteCount(Int64(raw))
        case .disk: rate(raw)
        case .network: rate(raw)
        case .energy: energy(raw)
        }
    }

    /// Byte counts honoring the units setting. "Automatic" keeps the Core
    /// formatter's shared style; binary and decimal override the count style.
    static func byteCount(_ bytes: Int64) -> String {
        switch byteUnitsStyle {
        case .automatic:
            return bytes.formattedByteCount
        case .binary, .decimal:
            guard bytes != 0 else {
                return String(localized: "0 bytes", comment: "Byte count for an empty file")
            }
            // A fresh formatter per call: ByteCountFormatter is not documented
            // thread-safe, and these render on the main actor anyway.
            let formatter = ByteCountFormatter()
            formatter.countStyle = byteUnitsStyle == .binary ? .memory : .decimal
            return formatter.string(fromByteCount: bytes)
        }
    }

    /// Byte rates honor the same units setting; the no-op localization wrapper
    /// is gone (it made the localized key a placeholder).
    static func rate(_ bytesPerSecond: Double) -> String {
        byteCount(Int64(bytesPerSecond)) + "/s"
    }

    /// Energy index in vendor units, one decimal.
    static func energy(_ index: Double) -> String {
        index.formatted(.number.precision(.fractionLength(1)))
    }

    /// Power in watts, one decimal.
    static func watts(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " W"
    }

    /// Seconds, one decimal.
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    /// Compact duration through the shared Core formatter ("2d 3h");
    /// "—" for negative values, matching the previous nil fallback.
    static func duration(_ seconds: TimeInterval) -> String {
        seconds >= 0 ? seconds.formattedDuration : "—"
    }
}

/// The monitor card chrome: secondary background fill inside the card radius
/// plus the hairline border. One modifier instead of eight copies of the same
/// two lines.
private struct MonitorCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(.separator.opacity(0.5)))
    }
}

extension View {
    /// Standard monitor card: rounded secondary background + hairline border.
    func monitorCard() -> some View {
        modifier(MonitorCardChrome())
    }
}

/// Full history chart with an average/peak area, used on every metric tab.
struct HistoryChartView: View {
    let points: [MetricsHistoryStore.SeriesPoint]
    let tint: Color
    let unit: UsageMetric

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value(SparklineView.timeLabel, point.timestamp),
                    y: .value(SparklineView.valueLabel, point.average)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
            }
            ForEach(points.filter { $0.peak != nil }) { point in
                AreaMark(
                    x: .value(SparklineView.timeLabel, point.timestamp),
                    y: .value(SparklineView.valueLabel, point.peak ?? 0)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint.opacity(0.08))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(MetricFormatting.value(number, metric: unit))
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(minHeight: 180)
    }
}
