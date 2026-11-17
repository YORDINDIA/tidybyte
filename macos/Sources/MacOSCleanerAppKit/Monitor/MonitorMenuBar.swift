import MacOSCleanerCore
import SwiftUI

/// The monitoring menu bar surface: the combined panel plus one extra per
/// enabled metric. Disabling the master switch hides all six menu bar extras.
struct MonitorMenuBarExtras: Scene {
    let model: MonitorModel
    @AppStorage(MonitoringKeys.menuBarCPU.key) private var cpuEnabled = MonitoringKeys.menuBarCPU.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarMemory.key) private var memoryEnabled = MonitoringKeys.menuBarMemory.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarNetwork.key) private var networkEnabled = MonitoringKeys.menuBarNetwork.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarDisk.key) private var diskEnabled = MonitoringKeys.menuBarDisk.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarEnergy.key) private var energyEnabled = MonitoringKeys.menuBarEnergy.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarPanelEnabled) private var panelEnabled = MonitoringDefaults.menuBarPanelEnabled

    var body: some Scene {
        MenuBarExtra(
            String(localized: "Tidybyte Monitor", comment: "Menu bar panel name"),
            systemImage: "waveform.path.ecg",
            isInserted: panelInserted
        ) {
            MonitorPanelView(model: model)
        }
        .menuBarExtraStyle(.window)

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

    /// Change-guarded insertion binding gated by `panelEnabled`. Never writes
    /// back when `panelEnabled` is off so toggling the master switch preserves
    /// per-metric choices and avoids SwiftUI's KVO round-trip CPU loop.
    private func insertionBinding(_ metric: UsageMetric) -> Binding<Bool> {
        Binding(
            get: { panelEnabled && isEnabled(metric) },
            set: { newValue in
                guard panelEnabled else { return }
                if isEnabled(metric) != newValue { setEnabled(newValue, metric) }
            })
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

    private var panelInserted: Binding<Bool> {
        Binding(
            get: { panelEnabled },
            set: { if panelEnabled != $0 { panelEnabled = $0 } })
    }
}

extension MonitorModel {
    /// Opens the main window on the Monitor destination and activates the app.
    @MainActor
    func activateAndOpenMonitor(
        tab: MonitorTab? = nil,
        selecting group: AppProcessGroup? = nil,
        openWindow: OpenWindowAction
    ) {
        openMonitor(tab: tab, selecting: group)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
        let targetTab = tab ?? selectedTab
        if Bundle.main.bundleURL.pathExtension == "app",
           let url = URL(string: "\(AppIdentity.urlScheme)://monitor/\(targetTab.rawValue)") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
        }
    }

    func menuBarLabel(_ metric: UsageMetric) -> String {
        guard let snapshot else { return metric.monitorTitle }
        switch metric {
        case .cpu:
            return String(localized: "CPU \(MetricFormatting.whole(snapshot.cpu.usagePercent))%", comment: "Menu bar CPU")
        case .memory:
            return MetricFormatting.byteCount(snapshot.memory.usedBytes)
        case .network:
            return MetricFormatting.rate(snapshot.network.downloadBytesPerSecond)
        case .disk:
            return MetricFormatting.rate(snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond)
        case .energy:
            let total = snapshot.groups.prefix(3).reduce(0.0) { $0 + $1.energyIndex }
            return String(localized: "Energy \(MetricFormatting.whole(total))", comment: "Menu bar energy index")
        }
    }
}

extension UsageMetric {
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
                    model.activateAndOpenMonitor(
                        tab: MonitorTab.tab(for: metric),
                        selecting: group,
                        openWindow: openWindow)
                })
            Button {
                model.activateAndOpenMonitor(tab: MonitorTab.tab(for: metric), openWindow: openWindow)
            } label: {
                Label(String(localized: "Open Monitor", comment: "Dropdown open monitor button"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
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

/// The combined panel: overview tiles, busiest list, developer chips, and actions.
struct MonitorPanelView: View {
    let model: MonitorModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if let snapshot = model.snapshot {
                tileGrid(snapshot)
                BusiestListView(
                    title: String(localized: "Busiest right now", comment: "Panel busiest heading"),
                    groups: snapshot.busiest(metric: .cpu, limit: 5),
                    metric: .cpu,
                    onSelect: { group in
                        model.activateAndOpenMonitor(tab: .overview, selecting: group, openWindow: openWindow)
                    })
                developerChips(snapshot)
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

    private func tileGrid(_ snapshot: SystemSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: Spacing.elementTight)],
            spacing: Spacing.elementTight
        ) {
            metricButton(tab: .cpu) {
                MetricTileView(
                    title: String(localized: "CPU"), icon: "cpu",
                    value: String(format: "%.0f", snapshot.cpu.usagePercent), unit: "%",
                    context: nil, tint: MonitorTab.cpu.tint,
                    points: compact(model.livePoints(metric: .cpu)), scale: 100.0)
            }
            metricButton(tab: .memory) {
                MetricTileView(
                    title: String(localized: "Memory"), icon: "memorychip",
                    value: MetricFormatting.byteCount(snapshot.memory.usedBytes), unit: nil,
                    context: nil, tint: MonitorTab.memory.tint,
                    points: compact(model.livePoints(metric: .memory)),
                    scale: Double(max(1, snapshot.memory.totalBytes)))
            }
            metricButton(tab: .network) {
                MetricTileView(
                    title: String(localized: "Network"), icon: "network",
                    value: MetricFormatting.rate(snapshot.network.downloadBytesPerSecond), unit: nil,
                    context: nil, tint: MonitorTab.network.tint,
                    points: compact(model.livePoints(metric: .network)))
            }
            metricButton(tab: .disk) {
                MetricTileView(
                    title: String(localized: "Disk"), icon: "internaldrive",
                    value: MetricFormatting.rate(snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond), unit: nil,
                    context: nil, tint: MonitorTab.disk.tint,
                    points: compact(model.livePoints(metric: .disk)))
            }
        }
    }

    private func metricButton<Content: View>(tab: MonitorTab, @ViewBuilder content: () -> Content) -> some View {
        Button {
            model.activateAndOpenMonitor(tab: tab, openWindow: openWindow)
        } label: {
            content()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func developerChips(_ snapshot: SystemSnapshot) -> some View {
        if !snapshot.devServers.isEmpty || !snapshot.agents.isEmpty || !snapshot.containers.isEmpty {
            HStack(spacing: Spacing.elementTight) {
                if !snapshot.devServers.isEmpty {
                    chip(
                        icon: "curlybraces.square", text: String(snapshot.devServers.count),
                        tint: MonitorTab.projects.tint,
                        label: devServerCountLabel(snapshot.devServers.count),
                        tab: .projects)
                }
                if !snapshot.agents.isEmpty {
                    chip(
                        icon: "sparkles", text: String(snapshot.agents.count),
                        tint: MonitorTab.agents.tint,
                        label: agentCountLabel(snapshot.agents.count),
                        tab: .agents)
                }
                if !snapshot.containers.isEmpty {
                    chip(
                        icon: "shippingbox", text: String(snapshot.containers.count),
                        tint: MonitorTab.containers.tint,
                        label: containerCountLabel(snapshot.containers.count),
                        tab: .containers)
                }
                Spacer()
            }
        }
    }

    private var actions: some View {
        HStack {
            Button {
                model.activateAndOpenMonitor(tab: .overview, openWindow: openWindow)
            } label: {
                Label(String(localized: "Open Monitor", comment: "Panel action: open the monitor"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(String(localized: "Settings…"), systemImage: "gearshape")
            }
            .controlSize(.small)
            Button(role: .destructive) {
                AppDelegate.shared?.requestQuit()
            } label: {
                Label(String(localized: "Quit", comment: "Panel action"), systemImage: "power")
            }
            .controlSize(.small)
        }
    }

    private func chip(icon: String, text: String, tint: Color, label: String, tab: MonitorTab) -> some View {
        Button {
            model.activateAndOpenMonitor(tab: tab, openWindow: openWindow)
        } label: {
            Label(text, systemImage: icon)
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func devServerCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 dev server", comment: "Panel chip a11y label, singular")
            : String(localized: "\(count) dev servers", comment: "Panel chip a11y label")
    }

    private func agentCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 coding agent", comment: "Panel chip a11y label, singular")
            : String(localized: "\(count) coding agents", comment: "Panel chip a11y label")
    }

    private func containerCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 container", comment: "Panel chip a11y label, singular")
            : String(localized: "\(count) containers", comment: "Panel chip a11y label")
    }

    private func compact(_ points: [(Date, Double)]) -> [(Date, Double)] {
        ChartDownsampler.downsampleTuples(points, targetCount: 40)
    }
}
