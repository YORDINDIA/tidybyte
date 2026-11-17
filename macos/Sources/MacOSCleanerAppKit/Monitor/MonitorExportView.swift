import MacOSCleanerCore
import SwiftUI

/// Fixed-size export card for the monitor snapshot.
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
                value: String(
                    localized: "\(MetricFormatting.whole(snapshot.cpu.usagePercent), specifier: "%d")%",
                    comment: "Percent value"))
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
            if let gpu = snapshot.gpu.devices.first, let utilization = gpu.primaryUtilization {
                readingRow(
                    label: String(localized: "GPU", comment: "Export row"),
                    value: String(format: "%.0f%%", utilization))
            }
            readingRow(
                label: String(localized: "Thermal Pressure", comment: "Export row"),
                value: snapshot.thermalPressure.label)
        }
    }

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

// MARK: - Domain Presentation Helpers

extension ThermalPressure {
    var label: String {
        switch self {
        case .nominal: String(localized: "Nominal", comment: "Thermal pressure state")
        case .fair: String(localized: "Fair", comment: "Thermal pressure state")
        case .serious: String(localized: "Serious", comment: "Thermal pressure state")
        case .critical: String(localized: "Critical", comment: "Thermal pressure state")
        }
    }

    var detail: String {
        switch self {
        case .nominal: String(localized: "No throttling", comment: "Thermal pressure detail")
        case .fair: String(localized: "Slightly warm", comment: "Thermal pressure detail")
        case .serious: String(localized: "Thermal throttling active", comment: "Thermal pressure detail")
        case .critical: String(localized: "Heavy thermal throttling", comment: "Thermal pressure detail")
        }
    }

    var symbol: String {
        switch self {
        case .nominal: "thermometer.low"
        case .fair: "thermometer.medium"
        case .serious: "thermometer.high"
        case .critical: "flame.fill"
        }
    }

    var tint: Color {
        switch self {
        case .nominal: SemanticScale.success
        case .fair: SemanticScale.warning
        case .serious: Color(nsColor: .systemOrange)
        case .critical: SemanticScale.error
        }
    }
}

extension MemoryReading.Level {
    var localizedTitle: String {
        switch self {
        case .normal: String(localized: "Pressure normal", comment: "Memory pressure normal")
        case .warning: String(localized: "Pressure warning", comment: "Memory pressure warning")
        case .critical: String(localized: "Pressure critical", comment: "Memory pressure critical")
        }
    }

    var tint: Color {
        switch self {
        case .normal: MonitorTab.memory.tint
        case .warning: SemanticScale.warning
        case .critical: SemanticScale.error
        }
    }
}

extension GPUDeviceReading {
    var primaryUtilization: Double? {
        utilizationPercent ?? rendererUtilizationPercent
    }

    var hasDetailedTelemetry: Bool {
        rendererUtilizationPercent != nil
            || tilerUtilizationPercent != nil
            || inUseMemoryBytes != nil
            || allocatedMemoryBytes != nil
    }

    var overviewContext: String {
        if let renderer = rendererUtilizationPercent, let tiler = tilerUtilizationPercent {
            return String(
                localized: "\(name) · R \(Int(renderer.rounded()))% · T \(Int(tiler.rounded()))%",
                comment: "GPU overview context with renderer and tiler utilization")
        }
        return name
    }
}

extension PowerReading {
    var isEffectivelyCharged: Bool {
        isCharged || (isPluggedIn && !isCharging && (level ?? 0) >= 0.995)
    }

    var batteryStatusContext: String? {
        if isEffectivelyCharged {
            return String(localized: "Charged", comment: "Battery fully charged on AC power")
        }
        if isCharging {
            if let timeToFullSeconds {
                return String(
                    localized: "Charging · \(MetricFormatting.duration(timeToFullSeconds))",
                    comment: "Battery charging with remaining time")
            }
            return String(localized: "Charging", comment: "Battery state")
        }
        if isPluggedIn {
            return String(localized: "On AC power", comment: "Battery plugged into AC without charging")
        }
        return timeToEmptySeconds.map { MetricFormatting.duration($0) }
    }

    var powerDirectionLabel: String {
        if isEffectivelyCharged {
            return String(localized: "Charged", comment: "Power direction: charged on AC")
        }
        if isCharging {
            return String(localized: "Charging", comment: "Power direction")
        }
        if isPluggedIn {
            return String(localized: "AC power", comment: "Power direction: AC adapter")
        }
        return String(localized: "Discharging", comment: "Power direction")
    }

    var batterySymbolName: String {
        if isCharging { return "battery.100.bolt" }
        guard let level else { return "battery.100" }
        switch level {
        case 0.875...: return "battery.100"
        case 0.625..<0.875: return "battery.75"
        case 0.375..<0.625: return "battery.50"
        case 0.125..<0.375: return "battery.25"
        default: return "battery.0"
        }
    }
}
