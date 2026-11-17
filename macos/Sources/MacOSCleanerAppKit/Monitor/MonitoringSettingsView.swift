import MacOSCleanerCore
import SwiftUI

/// Settings › Monitoring: menu bar items, sampling, history retention,
/// misbehaving-app alerts, and appearance (density, colorblind palette).
struct MonitoringSettingsView: View {
    @AppStorage(MonitoringKeys.menuBarPanelEnabled) private var showsMenuBarExtras = MonitoringDefaults.menuBarPanelEnabled
    @AppStorage(MonitoringKeys.intervalSeconds) private var intervalSeconds = MonitoringDefaults.intervalSeconds
    @AppStorage(MonitoringKeys.historyRetentionDays) private var retentionDays = MonitoringDefaults.historyRetentionDays
    @AppStorage(MonitoringKeys.alertsEnabled) private var alertsEnabled = MonitoringDefaults.alertsEnabled
    @AppStorage(MonitoringKeys.alertCPUPercent) private var alertCPUPercent = MonitoringDefaults.alertCPUPercent
    @AppStorage(MonitoringKeys.alertCPUWindowMinutes) private var alertCPUWindowMinutes = MonitoringDefaults.alertCPUWindowMinutes
    @AppStorage(MonitoringKeys.alertMemoryGrowthBytes) private var alertMemoryGrowthBytes = MonitoringDefaults.alertMemoryGrowthBytes
    @AppStorage(MonitoringKeys.alertDiskBytesPerSecond) private var alertDiskBytesPerSecond = MonitoringDefaults.alertDiskBytesPerSecond
    @AppStorage(MonitoringKeys.alertNetworkBytesPerSecond) private var alertNetworkBytesPerSecond =
        MonitoringDefaults.alertNetworkBytesPerSecond
    @AppStorage(MonitoringKeys.density) private var compactDensity = false
    @AppStorage(MonitoringKeys.colorblindPalette) private var colorblindPalette = false
    @AppStorage(MonitoringKeys.hiddenTabs) private var hiddenTabsRaw = ""
    @AppStorage(MonitoringKeys.byteUnits) private var byteUnits = MetricFormatting.ByteUnitsStyle.automatic.rawValue
    @AppStorage(MonitoringKeys.menuBarCPU.key) private var cpuItem = MonitoringKeys.menuBarCPU.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarMemory.key) private var memoryItem = MonitoringKeys.menuBarMemory.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarNetwork.key) private var networkItem = MonitoringKeys.menuBarNetwork.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarDisk.key) private var diskItem = MonitoringKeys.menuBarDisk.defaultEnabled
    @AppStorage(MonitoringKeys.menuBarEnergy.key) private var energyItem = MonitoringKeys.menuBarEnergy.defaultEnabled

    var body: some View {
        Form {
            menuBarSection
            samplingSection
            alertsSection
            tabsSection
            unitsSection
            appearanceSection
        }
        .formStyle(.grouped)
    }

    private var menuBarSection: some View {
        Section(String(localized: "Menu Bar", comment: "Settings section")) {
            Toggle(String(localized: "Show the monitor in the menu bar"), isOn: $showsMenuBarExtras)
            Text(String(
                localized: """
                Controls the Monitor panel and all metric menu bar items. \
                Turning this off hides every monitor icon and pauses background polling \
                while the Monitor window is closed.
                """,
                comment: "Master menu bar toggle explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if showsMenuBarExtras {
                ForEach(UsageMetric.allCases) { metric in
                    Toggle(menuBarToggleLabel(for: metric), isOn: metricBinding(metric))
                }
                Text(String(
                    localized: "Each item shows a live reading and opens a list of the apps behind it.",
                    comment: "Menu bar explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func menuBarToggleLabel(for metric: UsageMetric) -> String {
        switch metric {
        case .disk:
            return String(localized: "Menu bar item: Disk (Read + Write)", comment: "Menu bar disk metric toggle")
        case .network:
            return String(localized: "Menu bar item: Network (Download)", comment: "Menu bar network metric toggle")
        default:
            return String(localized: "Menu bar item: \(metric.monitorTitle)", comment: "Menu bar metric toggle")
        }
    }

    private var samplingSection: some View {
        Section(String(localized: "Sampling", comment: "Settings section")) {
            Picker(String(localized: "Update every"), selection: $intervalSeconds) {
                Text(String(localized: "1 second", comment: "Sampling interval")).tag(1.0)
                Text(String(localized: "2 seconds", comment: "Sampling interval")).tag(2.0)
                Text(String(localized: "5 seconds", comment: "Sampling interval")).tag(5.0)
            }
            .pickerStyle(.segmented)
            Text(String(
                localized: "Faster updates draw smoother charts and use slightly more battery.",
                comment: "Sampling explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(String(localized: "Keep history for"), selection: $retentionDays) {
                Text(String(localized: "1 month", comment: "History retention")).tag(30)
                Text(String(localized: "6 months", comment: "History retention")).tag(180)
                Text(String(localized: "1 year", comment: "History retention")).tag(365)
            }
            Text(String(
                localized: "Per-app history is kept for up to 90 days.",
                comment: "Per-app history retention note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var alertsSection: some View {
        Section(String(localized: "Alerts", comment: "Settings section")) {
            Toggle(String(localized: "Notify me when an app misbehaves"), isOn: $alertsEnabled)
                .onChange(of: alertsEnabled) { _, enabled in
                    guard enabled else { return }
                    Task { await NotificationScheduler().requestAuthorization() }
                }
            if alertsEnabled {
                Stepper(
                    String(localized: "CPU exceeds \(Int(alertCPUPercent))%", comment: "CPU threshold alert rule"),
                    value: $alertCPUPercent, in: 20...100, step: 5)
                    .monospacedDigit()
                Stepper(
                    cpuWindowLabel,
                    value: $alertCPUWindowMinutes, in: 1...60, step: 1)
                    .monospacedDigit()
                Stepper(
                    String(
                        localized: "Memory grows by \(formattedGrowthGB) GB in an hour",
                        comment: "Memory alert rule"),
                    value: growthBinding, in: 0.5...16, step: 0.5)
                    .monospacedDigit()
                Stepper(
                    String(
                        localized: "Disk read & write exceed \(Int(diskMB)) MB/s",
                        comment: "Disk read/write alert rule"),
                    value: diskBinding, in: 10...500, step: 10)
                    .monospacedDigit()
                Stepper(
                    String(localized: "Network traffic exceeds \(Int(networkMB)) MB/s", comment: "Network alert rule"),
                    value: networkBinding, in: 5...500, step: 5)
                    .monospacedDigit()
            }
        }
    }

    private var cpuWindowLabel: String {
        let minutes = max(1, Int(alertCPUWindowMinutes.rounded()))
        return minutes == 1
            ? String(localized: "Sustained for 1 minute", comment: "CPU alert window, singular")
            : String(localized: "Sustained for \(minutes) minutes", comment: "CPU alert window, plural")
    }

    private var tabsSection: some View {
        Section(String(localized: "Tabs", comment: "Settings section")) {
            ForEach(MonitorTab.allCases) { tab in
                Toggle(tab.title, isOn: tabVisibilityBinding(tab))
                    .disabled(tab == .overview)
            }
            Text(String(
                localized: "Hidden tabs disappear from the monitor's tab rail. Overview always stays.",
                comment: "Tab visibility explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unitsSection: some View {
        Section(String(localized: "Units", comment: "Settings section")) {
            Picker(String(localized: "Byte sizes"), selection: $byteUnits) {
                Text(String(localized: "Automatic", comment: "Byte units style")).tag("auto")
                Text(String(localized: "Binary (KiB, MiB)", comment: "Byte units style")).tag("binary")
                Text(String(localized: "Decimal (kB, MB)", comment: "Byte units style")).tag("decimal")
            }
        }
    }

    private var appearanceSection: some View {
        Section(String(localized: "Appearance", comment: "Settings section")) {
            Toggle(String(localized: "Compact rows"), isOn: $compactDensity)
            Toggle(String(localized: "Colorblind-friendly chart colors"), isOn: $colorblindPalette)
        }
    }

    private var hiddenTabs: Set<MonitorTab> {
        Set(hiddenTabsRaw.split(separator: ",").compactMap { MonitorTab(rawValue: String($0)) })
    }

    private func tabVisibilityBinding(_ tab: MonitorTab) -> Binding<Bool> {
        Binding(
            get: { !hiddenTabs.contains(tab) },
            set: { visible in
                var current = hiddenTabs
                if visible { current.remove(tab) } else { current.insert(tab) }
                hiddenTabsRaw = current.map(\.rawValue).sorted().joined(separator: ",")
            })
    }

    private var growthGB: Double { Double(alertMemoryGrowthBytes) / 1_000_000_000.0 }

    private var formattedGrowthGB: String {
        growthGB.formatted(.number.precision(.fractionLength(1)))
    }

    private var growthBinding: Binding<Double> {
        Binding(
            get: { growthGB },
            set: { alertMemoryGrowthBytes = Int(($0 * 1_000_000_000.0).rounded()) })
    }

    private var diskMB: Double { alertDiskBytesPerSecond / 1_000_000.0 }

    private var diskBinding: Binding<Double> {
        Binding(
            get: { diskMB },
            set: { alertDiskBytesPerSecond = $0 * 1_000_000.0 })
    }

    private var networkMB: Double { alertNetworkBytesPerSecond / 1_000_000.0 }

    private var networkBinding: Binding<Double> {
        Binding(
            get: { networkMB },
            set: { alertNetworkBytesPerSecond = $0 * 1_000_000.0 })
    }

    private func metricBinding(_ metric: UsageMetric) -> Binding<Bool> {
        Binding(
            get: { isMetricItemOn(metric) },
            set: { setMetricItem($0, metric) })
    }

    private func isMetricItemOn(_ metric: UsageMetric) -> Bool {
        switch metric {
        case .cpu: cpuItem
        case .memory: memoryItem
        case .network: networkItem
        case .disk: diskItem
        case .energy: energyItem
        }
    }

    private func setMetricItem(_ value: Bool, _ metric: UsageMetric) {
        switch metric {
        case .cpu: cpuItem = value
        case .memory: memoryItem = value
        case .network: networkItem = value
        case .disk: diskItem = value
        case .energy: energyItem = value
        }
    }
}
