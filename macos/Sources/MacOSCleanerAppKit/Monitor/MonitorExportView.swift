import MacOSCleanerCore
import SwiftUI

/// A fixed-size export card for the monitor: the app name, the snapshot time,
/// the four headline readings, and the five busiest apps. Everything renders
/// from the one snapshot handed in — no live or scrolling content — so
/// ImageRenderer always captures a stable layout.
struct MonitorExportView: View {
    let snapshot: SystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            header
            Divider()
            readings
            Divider()
            busiest
        }
        .padding(Spacing.elementSection)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(.separator.opacity(0.5)))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(AppIdentity.displayName, systemImage: "waveform.path.ecg")
                .font(.title3.weight(.semibold))
            Spacer()
            Text(snapshot.timestamp.formatted(date: .abbreviated, time: .standard))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            readingRow(
                label: String(localized: "CPU", comment: "Export row"),
                value: String(localized: "\(Int(snapshot.cpu.usagePercent), specifier: "%d")%", comment: "Percent value"))
            readingRow(
                label: String(localized: "Memory", comment: "Export row"),
                value: MetricFormatting.byteCount(snapshot.memory.usedBytes))
            readingRow(
                label: String(localized: "Disk", comment: "Export row"),
                value: MetricFormatting.rate(snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond))
            readingRow(
                label: String(localized: "Network", comment: "Export row"),
                value: MetricFormatting.rate(
                    snapshot.network.downloadBytesPerSecond + snapshot.network.uploadBytesPerSecond))
        }
    }

    /// The busiest five at export time, CPU-ranked like the overview list.
    private var busiest: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(String(localized: "Busiest right now", comment: "Busiest apps heading"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(snapshot.busiest(metric: .cpu, limit: 5)) { group in
                HStack {
                    Text(group.name).font(.callout).lineLimit(1)
                    Spacer()
                    Text(MetricFormatting.value(group.value(for: .cpu), metric: .cpu))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func readingRow(label: String, value: String) -> some View {
        LabeledContent {
            Text(value).font(.callout.monospacedDigit())
        } label: {
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
