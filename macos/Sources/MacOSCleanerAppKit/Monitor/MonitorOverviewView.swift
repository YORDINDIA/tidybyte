import MacOSCleanerCore
import SwiftUI

// MARK: - Overview

struct OverviewTabView: View {
    let model: MonitorModel
    @State private var topMetric: UsageMetric = .cpu

    var body: some View {
        if let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                statusHeader(snapshot)
                tiles(snapshot)
                hardwareSection(snapshot)
                OverviewTopAppsCard(
                    snapshot: snapshot,
                    metric: $topMetric,
                    onSelect: { model.select(group: $0) })
            }
        } else {
            ProgressView(String(localized: "Reading the system…", comment: "Monitor first tick"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 60)
        }
    }

    private func statusHeader(_ snapshot: SystemSnapshot) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            Text(String(localized: "Up \(MetricFormatting.duration(snapshot.uptime))", comment: "Uptime headline"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Label(snapshot.thermalPressure.label, systemImage: snapshot.thermalPressure.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(snapshot.thermalPressure.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(snapshot.thermalPressure.tint.opacity(0.12)))
                .accessibilityLabel(String(
                    localized: "Thermal pressure: \(snapshot.thermalPressure.label)",
                    comment: "Thermal pressure badge a11y"))
            Spacer()
            Text(processHeadline(snapshot))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func processHeadline(_ snapshot: SystemSnapshot) -> String {
        if model.groupingMode == .byProcess {
            return MetricFormatting.processCount(snapshot.processes.count)
        }
        let apps = MetricFormatting.appCount(snapshot.groups.count)
        let procs = MetricFormatting.processCount(snapshot.processes.count)
        return String(localized: "\(apps) · \(procs)", comment: "Overview app and process count")
    }

    private func tiles(_ snapshot: SystemSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.elementNormal)],
            spacing: Spacing.elementNormal
        ) {
            coreTiles(snapshot)
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
            context: memoryContext(snapshot.memory),
            tint: snapshot.memory.pressure == .normal ? MonitorTab.memory.tint : snapshot.memory.pressure.tint,
            points: model.livePoints(metric: .memory),
            scale: Double(max(1, snapshot.memory.totalBytes)))
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
        if let gpu = snapshot.gpu.devices.first, let utilization = gpu.primaryUtilization {
            MetricTileView(
                title: String(localized: "GPU"), icon: "bolt",
                value: String(format: "%.0f", utilization), unit: "%",
                context: gpu.overviewContext, tint: MonitorTab.gpu.tint)
        }
        if snapshot.power.hasBattery, let level = snapshot.power.level {
            MetricTileView(
                title: String(localized: "Battery"), icon: snapshot.power.batterySymbolName,
                value: MetricFormatting.percent(level), unit: nil,
                context: snapshot.power.batteryStatusContext,
                tint: MonitorTab.battery.tint)
        }
    }

    private func memoryContext(_ memory: MemoryReading) -> String {
        let total = MetricFormatting.byteCount(memory.totalBytes)
        guard memory.pressure != .normal else { return total }
        return String(localized: "\(total) · \(memory.pressure.localizedTitle)", comment: "Memory total with pressure")
    }

    @ViewBuilder
    private func devTiles(_ snapshot: SystemSnapshot) -> some View {
        if !snapshot.devServers.isEmpty {
            Button { model.openTab(.projects) } label: {
                MetricTileView(
                    title: String(localized: "Projects"), icon: "curlybraces.square",
                    value: String(snapshot.devServers.count), unit: nil,
                    context: String(localized: "\(snapshot.devServers.filter(\.isIdle).count) idle", comment: "Idle dev servers context"),
                    tint: MonitorTab.projects.tint)
            }
            .buttonStyle(.plain)
        }
        if !snapshot.agents.isEmpty {
            Button { model.openTab(.agents) } label: {
                MetricTileView(
                    title: String(localized: "Agents"), icon: "sparkles",
                    value: String(snapshot.agents.count), unit: nil,
                    context: snapshot.agents.first?.kind.displayName,
                    tint: MonitorTab.agents.tint)
            }
            .buttonStyle(.plain)
        }
        if !snapshot.containers.isEmpty {
            Button { model.openTab(.containers) } label: {
                MetricTileView(
                    title: String(localized: "Containers"), icon: "shippingbox",
                    value: String(snapshot.containers.count), unit: nil,
                    context: MetricFormatting.byteCount(snapshot.containers.reduce(0) { $0 + $1.memoryBytes }),
                    tint: MonitorTab.containers.tint)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func hardwareSection(_ snapshot: SystemSnapshot) -> some View {
        HStack(alignment: .top, spacing: Spacing.elementNormal) {
            SummaryCardView(
                title: String(localized: "Thermal Pressure", comment: "Overview card"),
                icon: snapshot.thermalPressure.symbol,
                tint: snapshot.thermalPressure.tint,
                value: snapshot.thermalPressure.label,
                context: snapshot.thermalPressure.detail)
            SummaryCardView(
                title: String(localized: "Load Average", comment: "Overview card"),
                icon: "gauge",
                tint: .secondary,
                value: String(format: "%.2f", snapshot.cpu.loadAverage1),
                context: String(
                    localized: "\(snapshot.cpu.logicalCoreCount) cores · 5m \(snapshot.cpu.loadAverage5, specifier: "%.2f")",
                    comment: "Load card context"))
        }
        if let gpu = snapshot.gpu.devices.first, gpu.hasDetailedTelemetry {
            AppleSiliconGPUCard(gpu: gpu)
        }
        SMCSensorsCard(sensors: snapshot.sensors)
        if !snapshot.fans.isEmpty {
            FanReadingsCard(fans: snapshot.fans)
        }
    }
}

// MARK: - Hardware Cards

struct SummaryCardView: View {
    let title: String
    var icon: String = "gauge"
    var tint: Color = .secondary
    let value: String
    let context: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(context)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Spacing.cardInternal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monitorCard()
    }
}

struct AppleSiliconGPUCard: View {
    let gpu: GPUDeviceReading

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Label(gpu.name, systemImage: "bolt")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let cores = gpu.coreCount {
                    Text(cores == 1
                        ? String(localized: "1 core", comment: "GPU core count, singular")
                        : String(localized: "\(cores) cores", comment: "GPU core count"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.elementNormal)],
                spacing: Spacing.elementTight
            ) {
                if let renderer = gpu.rendererUtilizationPercent {
                    detailMetric(
                        String(localized: "Renderer", comment: "GPU renderer metric"),
                        value: String(format: "%.0f%%", renderer))
                }
                if let tiler = gpu.tilerUtilizationPercent {
                    detailMetric(
                        String(localized: "Tiler", comment: "GPU tiler metric"),
                        value: String(format: "%.0f%%", tiler))
                }
                if let inUse = gpu.inUseMemoryBytes {
                    detailMetric(
                        String(localized: "GPU Memory Used", comment: "GPU in-use memory"),
                        value: MetricFormatting.byteCount(inUse))
                }
                if let allocated = gpu.allocatedMemoryBytes {
                    detailMetric(
                        String(localized: "Allocated", comment: "GPU allocated memory"),
                        value: MetricFormatting.byteCount(allocated))
                }
            }
        }
        .padding(Spacing.cardInternal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorCard()
    }

    private func detailMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SMCSensorsCard: View {
    let sensors: [SensorReading]

    var body: some View {
        if sensors.isEmpty {
            Label(
                String(localized: "Sensor readings are not available on this Mac.", comment: "Sensors unavailable note"),
                systemImage: "thermometer.medium")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    Label(String(localized: "Temperature Sensors", comment: "SMC sensors heading"), systemImage: "thermometer.medium")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(sensorCountLabel(sensors.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: Spacing.elementNormal)],
                    spacing: Spacing.elementTight
                ) {
                    ForEach(sensors.prefix(12)) { sensor in
                        HStack(spacing: Spacing.elementTight) {
                            Circle()
                                .fill(sensorColor(sensor.celsius))
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(sensor.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(String(format: "%.0f°C", sensor.celsius))
                                .font(.caption.monospacedDigit().weight(.medium))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(Spacing.cardInternal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .monitorCard()
        }
    }

    private func sensorCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 sensor", comment: "Sensor count, singular")
            : String(localized: "\(count) sensors", comment: "Sensor count, plural")
    }

    private func sensorColor(_ celsius: Double) -> Color {
        if celsius >= 95 { return SemanticScale.error }
        if celsius >= 80 { return SemanticScale.warning }
        return SemanticScale.success
    }
}

private struct FanReadingsCard: View {
    let fans: [FanReading]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Label(String(localized: "Cooling Fans", comment: "Fans card heading"), systemImage: "wind")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if fans.allSatisfy({ !$0.isUserControllable }) {
                    Text(String(localized: "Automatic (Apple SMC)", comment: "Fan control status when SMC writes are disabled"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
            }
            ForEach(fans) { fan in
                fanRow(fan)
            }
        }
        .padding(Spacing.cardInternal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorCard()
    }

    private func fanRow(_ fan: FanReading) -> some View {
        let span = max(1, fan.maximumRPM - fan.minimumRPM)
        let fraction = (fan.rpm - fan.minimumRPM) / span
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(fan.name).font(.callout).lineLimit(1)
                Spacer()
                Text(String(localized: "\(MetricFormatting.whole(fan.rpm), specifier: "%d") rpm", comment: "Fan speed"))
                    .font(.callout.monospacedDigit().weight(.medium))
                Text(String(
                    localized: "(\(MetricFormatting.whole(fan.minimumRPM))–\(MetricFormatting.whole(fan.maximumRPM)))",
                    comment: "Fan min-max RPM range"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ProgressBarView(fraction: fraction, tint: MonitorTab.cpu.tint)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewTopAppsCard: View {
    let snapshot: SystemSnapshot
    @Binding var metric: UsageMetric
    let onSelect: (AppProcessGroup) -> Void

    var body: some View {
        let groups = rankedGroups
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Text(headingTitle(count: groups.count))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(String(localized: "Metric", comment: "Top apps metric picker"), selection: $metric) {
                    Text(String(localized: "CPU", comment: "Top apps CPU option")).tag(UsageMetric.cpu)
                    Text(String(localized: "Memory", comment: "Top apps Memory option")).tag(UsageMetric.memory)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            if groups.isEmpty {
                Text(String(localized: "Nothing active right now.", comment: "Empty top apps list"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(groups) { group in
                    topRow(group, maximum: max(1, groups.map { $0.value(for: metric) }.max() ?? 1))
                }
            }
        }
        .padding(Spacing.cardInternal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorCard()
    }

    private var rankedGroups: [AppProcessGroup] {
        if metric == .memory {
            return Array(
                snapshot.groups
                    .filter { $0.memoryBytes > 0 }
                    .sorted { $0.memoryBytes > $1.memoryBytes }
                    .prefix(8))
        }
        return snapshot.busiest(metric: .cpu, limit: 8)
    }

    private func headingTitle(count: Int) -> String {
        if metric == .memory {
            return count == 0
                ? String(localized: "Top by Memory", comment: "Overview top memory heading, empty")
                : String(localized: "Top \(count) by Memory", comment: "Overview top memory heading with count")
        }
        return count == 0
            ? String(localized: "Top by CPU", comment: "Overview top CPU heading, empty")
            : String(localized: "Top \(count) by CPU", comment: "Overview top CPU heading with count")
    }

    private func topRow(_ group: AppProcessGroup, maximum: Double) -> some View {
        Button {
            onSelect(group)
        } label: {
            HStack(spacing: Spacing.elementTight) {
                MonitorAppIconView(bundlePath: group.bundlePath)
                Text(group.name)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(minWidth: 90, maxWidth: 170, alignment: .leading)
                ProgressBarView(fraction: group.value(for: metric) / maximum, tint: MonitorTab.tab(for: metric).tint)
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
}
