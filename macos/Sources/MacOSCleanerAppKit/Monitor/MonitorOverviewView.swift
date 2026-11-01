import MacOSCleanerCore
import SwiftUI

// MARK: - Overview

struct OverviewTabView: View {
    let model: MonitorModel

    var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if let snapshot {
                HStack {
                    Text(String(localized: "Up \(MetricFormatting.duration(snapshot.uptime))", comment: "Uptime headline"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(
                        localized: "\(snapshot.groups.count) apps · \(snapshot.processes.count) processes",
                        comment: "Process count headline"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                tiles(snapshot)
                if snapshot.sensors.isEmpty {
                    // Honest empty state: some Macs expose no SMC sensors.
                    Label(
                        String(
                            localized: "Sensor readings are not available on this Mac.",
                            comment: "Sensors unavailable note"),
                        systemImage: "thermometer.medium")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                summaryCards(snapshot)
                BusiestListView(
                    title: String(localized: "Busiest right now", comment: "Busiest apps heading"),
                    groups: snapshot.busiest(metric: .cpu),
                    metric: .cpu,
                    onSelect: { model.select(group: $0) })
            } else {
                ProgressView(String(localized: "Reading the system…", comment: "Monitor first tick"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 60)
            }
        }
    }

    private func tiles(_ snapshot: SystemSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.elementNormal)], spacing: Spacing.elementNormal) {
            coreTiles(snapshot)
            deviceTiles(snapshot)
            devTiles(snapshot)
        }
    }

    @ViewBuilder
    private func coreTiles(_ snapshot: SystemSnapshot) -> some View {
        MetricTileView(
            title: String(localized: "CPU"), icon: "cpu",
            value: String(format: "%.0f", snapshot.cpu.usagePercent), unit: "%",
            context: String(localized: "Load \(snapshot.cpu.loadAverage1, specifier: "%.1f")", comment: "Load average context"),
            tint: MonitorTab.cpu.tint, points: model.livePoints(metric: .cpu), scale: 100.0)
        MetricTileView(
            title: String(localized: "Memory"), icon: "memorychip",
            value: MetricFormatting.byteCount(snapshot.memory.usedBytes), unit: nil,
            context: MetricFormatting.byteCount(snapshot.memory.totalBytes),
            tint: MonitorTab.memory.tint, points: model.livePoints(metric: .memory),
            scale: Double(snapshot.memory.totalBytes))
        MetricTileView(
            title: String(localized: "Network"), icon: "network",
            value: MetricFormatting.rate(snapshot.network.downloadBytesPerSecond), unit: nil,
            context: String(localized: "↑ \(MetricFormatting.rate(snapshot.network.uploadBytesPerSecond))", comment: "Upload context"),
            tint: MonitorTab.network.tint, points: model.livePoints(metric: .network))
        MetricTileView(
            title: String(localized: "Disk"), icon: "internaldrive",
            value: MetricFormatting.rate(snapshot.disk.readBytesPerSecond), unit: nil,
            context: String(localized: "Write \(MetricFormatting.rate(snapshot.disk.writeBytesPerSecond))", comment: "Disk write context"),
            tint: MonitorTab.disk.tint, points: model.livePoints(metric: .disk))
        if let gpu = snapshot.gpu.devices.first, let utilization = gpu.utilizationPercent {
            MetricTileView(
                title: String(localized: "GPU"), icon: "bolt",
                value: String(format: "%.0f", utilization), unit: "%",
                context: gpu.name, tint: MonitorTab.gpu.tint)
        }
        if snapshot.power.hasBattery, let level = snapshot.power.level {
            MetricTileView(
                title: String(localized: "Battery"), icon: "battery.100",
                value: MetricFormatting.percent(level), unit: nil,
                context: snapshot.power.isCharging
                    ? String(localized: "Charging", comment: "Battery tile context")
                    : snapshot.power.timeToEmptySeconds.map { MetricFormatting.duration($0) },
                tint: MonitorTab.battery.tint)
        }
        if let temperature = snapshot.sensors.first {
            sensorsCell(temperature, fans: snapshot.fans)
        }
    }

    /// One grid cell: the sensors tile with the fan rows under it.
    private func sensorsCell(_ temperature: SensorReading, fans: [FanReading]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            MetricTileView(
                title: String(localized: "Sensors"), icon: "thermometer.medium",
                value: String(format: "%.0f", temperature.celsius), unit: "°C",
                context: fans.first.map {
                    String(localized: "Fans at \(Int($0.rpm), specifier: "%d") rpm", comment: "Fan speed context")
                },
                tint: MonitorTab.disk.tint)
            ForEach(fans.prefix(3)) { fan in
                HStack {
                    Label(fan.name, systemImage: "wind")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(String(localized: "\(Int(fan.rpm), specifier: "%d") rpm", comment: "Fan speed"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func devTiles(_ snapshot: SystemSnapshot) -> some View {
        if !snapshot.devServers.isEmpty {
            MetricTileView(
                title: String(localized: "Projects"), icon: "curlybraces.square",
                value: String(snapshot.devServers.count), unit: nil,
                context: String(localized: "\(snapshot.devServers.filter(\.isIdle).count) idle", comment: "Idle dev servers context"),
                tint: MonitorTab.projects.tint)
        }
        if !snapshot.agents.isEmpty {
            MetricTileView(
                title: String(localized: "Agents"), icon: "sparkles",
                value: String(snapshot.agents.count), unit: nil,
                context: snapshot.agents.first?.kind.displayName,
                tint: MonitorTab.agents.tint)
        }
        if !snapshot.containers.isEmpty {
            MetricTileView(
                title: String(localized: "Containers"), icon: "shippingbox",
                value: String(snapshot.containers.count), unit: nil,
                context: MetricFormatting.byteCount(snapshot.containers.reduce(0) { $0 + $1.memoryBytes }),
                tint: MonitorTab.containers.tint)
        }
    }

    @ViewBuilder
    private func deviceTiles(_ snapshot: SystemSnapshot) -> some View {
        // Device-specific tiles (audio, Bluetooth) join here as probes report.
    }

    private func summaryCards(_ snapshot: SystemSnapshot) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            SummaryCardView(
                title: String(localized: "Load Average", comment: "Overview card"),
                value: String(format: "%.2f", snapshot.cpu.loadAverage1),
                context: String(localized: "Across \(snapshot.cpu.logicalCoreCount) cores", comment: "Load card context"))
            if let temperature = snapshot.sensors.first {
                SummaryCardView(
                    title: String(localized: "Temperature", comment: "Overview card"),
                    value: String(format: "%.0f", temperature.celsius),
                    context: temperature.name)
            } else {
                SummaryCardView(
                    title: String(localized: "Load Average", comment: "Overview card"),
                    value: String(format: "%.2f", snapshot.cpu.loadAverage5),
                    context: String(localized: "5 minute window", comment: "Load card context"))
            }
        }
    }
}

struct SummaryCardView: View {
    let title: String
    let value: String
    let context: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "gauge")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(context)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.cardInternal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorCard()
    }
}
