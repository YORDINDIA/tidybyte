import MacOSCleanerCore
import SwiftUI

/// The monitoring menu bar surface: one extra per enabled metric plus the
/// combined panel. Metric extras are window-style, so their dropdown can show
/// the apps behind the number.
struct MonitorMenuBarExtras: Scene {
    let model: MonitorModel
    // Per-metric switches live in their own keys. Their @AppStorage bindings
    // are never handed to MenuBarExtra(isInserted:) raw: SwiftUI's menu bar
    // controller round-trips an insertion binding on every update pass (status
    // item KVO writes the same value back through the binding), and a raw
    // @AppStorage binding turns each round-trip into a UserDefaults write,
    // which invalidates the scene graph and re-queues the update — a 100% CPU
    // loop. The guarded bindings below (and the panel's) write only on a real
    // change, starving that cycle while keeping Settings toggles live.
    @AppStorage(MonitoringKeys.menuBarMetrics[0].key) private var cpuEnabled = MonitoringKeys.menuBarMetrics[0].defaultEnabled
    @AppStorage(MonitoringKeys.menuBarMetrics[1].key) private var memoryEnabled = MonitoringKeys.menuBarMetrics[1].defaultEnabled
    @AppStorage(MonitoringKeys.menuBarMetrics[2].key) private var networkEnabled = MonitoringKeys.menuBarMetrics[2].defaultEnabled
    @AppStorage(MonitoringKeys.menuBarMetrics[3].key) private var diskEnabled = MonitoringKeys.menuBarMetrics[3].defaultEnabled
    @AppStorage(MonitoringKeys.menuBarMetrics[4].key) private var energyEnabled = MonitoringKeys.menuBarMetrics[4].defaultEnabled
    @AppStorage(MonitoringKeys.menuBarPanelEnabled) private var panelEnabled = MonitoringDefaults.menuBarPanelEnabled

    var body: some Scene {
        // The combined panel is the home base: tiles, busiest apps, actions.
        MenuBarExtra(
            String(localized: "Tidybyte Monitor", comment: "Menu bar panel name"),
            systemImage: "waveform.path.ecg",
            isInserted: panelInserted
        ) {
            MonitorPanelView(model: model)
        }
        .menuBarExtraStyle(.window)

        // One item per enabled metric. Each extra is always declared and
        // shown only while its metric is enabled — Scene builders want
        // concrete scenes, and this keeps toggling live.
        metricExtra(.cpu)
        metricExtra(.memory)
        metricExtra(.network)
        metricExtra(.disk)
        metricExtra(.energy)
    }

    private func metricExtra(_ metric: UsageMetric) -> some Scene {
        MenuBarExtra(isInserted: insertionBinding(metric)) {
            MetricDropdownView(model: model, metric: metric)
        } label: {
            Text(model.menuBarLabel(metric))
        }
        .menuBarExtraStyle(.window)
    }

    /// The storage-backed insertion binding for one metric extra, guarded so
    /// the update-pass round-trip never reaches UserDefaults.
    private func insertionBinding(_ metric: UsageMetric) -> Binding<Bool> {
        Binding(
            get: { isEnabled(metric) },
            set: { if isEnabled(metric) != $0 { setEnabled($0, metric) } })
    }

    private func isEnabled(_ metric: UsageMetric) -> Bool {
        switch metric {
        case .cpu: cpuEnabled
        case .memory: memoryEnabled
        case .network: networkEnabled
        case .disk: diskEnabled
        case .energy: energyEnabled
        }
    }

    private func setEnabled(_ value: Bool, _ metric: UsageMetric) {
        switch metric {
        case .cpu: cpuEnabled = value
        case .memory: memoryEnabled = value
        case .network: networkEnabled = value
        case .disk: diskEnabled = value
        case .energy: energyEnabled = value
        }
    }

    /// Master switch for the combined panel; single-key get/set, guarded like
    /// the metric bindings above.
    private var panelInserted: Binding<Bool> {
        Binding(
            get: { panelEnabled },
            set: { if panelEnabled != $0 { panelEnabled = $0 } })
    }
}

extension MonitorModel {
    /// The menu bar label for one metric, e.g. "CPU 21%" or "20.3 GB".
    func menuBarLabel(_ metric: UsageMetric) -> String {
        guard let snapshot else { return metric.monitorTitle }
        switch metric {
        case .cpu:
            return String(localized: "CPU \(Int(snapshot.cpu.usagePercent))%", comment: "Menu bar CPU")
        case .memory:
            return MetricFormatting.byteCount(snapshot.memory.usedBytes)
        case .network:
            // Through MetricFormatting so the byte-units setting applies.
            return MetricFormatting.rate(snapshot.network.downloadBytesPerSecond)
        case .disk:
            // Read+write sum, matching the panel tile, the export card, and
            // the MCP/CLI output.
            return MetricFormatting.rate(snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond)
        case .energy:
            let total = snapshot.groups.prefix(3).reduce(0.0) { $0 + $1.energyIndex }
            return String(localized: "Energy \(Int(total))", comment: "Menu bar energy index")
        }
    }
}

extension UsageMetric {
    /// Human title for the monitor's menu bar surfaces and Settings — one
    /// source instead of two copies.
    var monitorTitle: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .network: String(localized: "Network")
        case .disk: String(localized: "Disk")
        case .energy: String(localized: "Energy")
        }
    }
}

/// One metric's dropdown: headline value, top apps behind it, open action.
struct MetricDropdownView: View {
    let model: MonitorModel
    let metric: UsageMetric
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            header
            Divider()
            BusiestListView(
                title: String(localized: "Top apps", comment: "Dropdown list heading"),
                groups: model.snapshot?.busiest(metric: metric) ?? [],
                metric: metric,
                onSelect: { group in
                    openWindow(id: "main")
                    model.selectedTab = .overview
                    model.select(group: group)
                    NSApp.activate()
                })
        }
        .padding(Spacing.elementNormal)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(metric.monitorTitle)
                .font(.callout.weight(.medium))
            Spacer()
            Text(model.menuBarLabel(metric))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
    }
}

/// The combined panel: overview tiles, busiest list, and the actions row.
struct MonitorPanelView: View {
    let model: MonitorModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if let snapshot = model.snapshot {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Spacing.elementTight)], spacing: Spacing.elementTight) {
                    MetricTileView(
                        title: String(localized: "CPU"), icon: "cpu",
                        value: String(format: "%.0f", snapshot.cpu.usagePercent), unit: "%",
                        context: nil, tint: MonitorTab.cpu.tint,
                        points: compact(model.livePoints(metric: .cpu)), scale: 100.0)
                    MetricTileView(
                        title: String(localized: "Memory"), icon: "memorychip",
                        value: MetricFormatting.byteCount(snapshot.memory.usedBytes), unit: nil,
                        context: nil, tint: MonitorTab.memory.tint,
                        points: compact(model.livePoints(metric: .memory)),
                        scale: Double(max(1, snapshot.memory.totalBytes)))
                    MetricTileView(
                        title: String(localized: "Network"), icon: "network",
                        value: MetricFormatting.rate(snapshot.network.downloadBytesPerSecond), unit: nil,
                        context: nil, tint: MonitorTab.network.tint,
                        points: compact(model.livePoints(metric: .network)))
                    MetricTileView(
                        title: String(localized: "Disk"), icon: "internaldrive",
                        value: MetricFormatting.rate(snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond), unit: nil,
                        context: nil, tint: MonitorTab.disk.tint,
                        points: compact(model.livePoints(metric: .disk)))
                }
                BusiestListView(
                    title: String(localized: "Busiest Right Now", comment: "Panel busiest heading"),
                    groups: snapshot.busiest(metric: .cpu, limit: 5),
                    metric: .cpu,
                    onSelect: { group in
                        openWindow(id: "main")
                        model.select(group: group)
                        NSApp.activate()
                    })
                if !snapshot.devServers.isEmpty || !snapshot.agents.isEmpty || !snapshot.containers.isEmpty {
                    HStack(spacing: Spacing.elementTight) {
                        if !snapshot.devServers.isEmpty {
                            chip(
                                icon: "curlybraces.square", text: String(snapshot.devServers.count),
                                tint: MonitorTab.projects.tint,
                                label: String(localized: "\(snapshot.devServers.count) dev servers", comment: "Panel chip a11y label"))
                        }
                        if !snapshot.agents.isEmpty {
                            chip(
                                icon: "sparkles", text: String(snapshot.agents.count),
                                tint: MonitorTab.agents.tint,
                                label: String(localized: "\(snapshot.agents.count) coding agents", comment: "Panel chip a11y label"))
                        }
                        if !snapshot.containers.isEmpty {
                            chip(
                                icon: "shippingbox", text: String(snapshot.containers.count),
                                tint: MonitorTab.containers.tint,
                                label: String(localized: "\(snapshot.containers.count) containers", comment: "Panel chip a11y label"))
                        }
                        Spacer()
                    }
                }
            } else {
                ProgressView(String(localized: "Reading the system…", comment: "Monitor first tick"))
                    .padding(.vertical, 20)
            }
            Divider()
            actions
        }
        .padding(Spacing.elementNormal)
        .frame(width: 300)
    }

    private var actions: some View {
        HStack {
            Button {
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Label(String(localized: "Open Tidybyte", comment: "Panel action"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                openSettings()
            } label: {
                Label(String(localized: "Settings…"), systemImage: "gearshape")
            }
            .controlSize(.small)
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(String(localized: "Quit", comment: "Panel action"), systemImage: "power")
            }
            .controlSize(.small)
        }
    }

    private func chip(icon: String, text: String, tint: Color, label: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            // VoiceOver hears what the chip means, not a bare number.
            .accessibilityLabel(Text(label))
    }

    /// Panels sample every few points to keep the sparkline readable at
    /// dropdown width.
    private func compact(_ points: [(Date, Double)]) -> [(Date, Double)] {
        guard points.count > 40 else { return points }
        let stride = points.count / 40
        return points.enumerated().compactMap { index, point in
            index % stride == 0 ? point : nil
        }
    }
}
