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

    var body: some View {
        Form {
            Section(String(localized: "Menu Bar", comment: "Settings section")) {
                Toggle(String(localized: "Show the monitor in the menu bar"), isOn: $showsMenuBarExtras)
                if showsMenuBarExtras {
                    ForEach(UsageMetric.allCases) { metric in
                        Toggle(
                            String(localized: "Menu bar item: \(metric.monitorTitle)", comment: "Menu bar metric toggle"),
                            isOn: metricBinding(metric))
                    }
                    Text(String(
                        localized: "Each item shows a live reading and opens a list of the apps behind it.",
                        comment: "Menu bar explanation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
            }

            Section(String(localized: "Alerts", comment: "Settings section")) {
                Toggle(String(localized: "Notify me when an app misbehaves"), isOn: $alertsEnabled)
                    .onChange(of: alertsEnabled) { _, enabled in
                        guard enabled else { return }
                        // Notifications need explicit authorization; ask in
                        // context when alerts turn on. Idempotent once granted.
                        Task { await NotificationScheduler().requestAuthorization() }
                    }
                if alertsEnabled {
                    Stepper(
                        String(
                            localized: "CPU above \(Int(alertCPUPercent))% for \(Int(alertCPUWindowMinutes)) minutes",
                            comment: "CPU alert rule"),
                        value: $alertCPUPercent, in: 20...100, step: 5)
                    Stepper(
                        String(localized: "Memory grows by \(Int(growthGB)) GB in an hour", comment: "Memory alert rule"),
                        value: growthBinding, in: 0.5...16, step: 0.5)
                    Stepper(
                        String(localized: "Disk writes exceed \(Int(diskMB)) MB/s", comment: "Disk alert rule"),
                        value: diskBinding, in: 10...500, step: 10)
                    Stepper(
                        String(localized: "Network traffic exceeds \(Int(networkMB)) MB/s", comment: "Network alert rule"),
                        value: networkBinding, in: 5...500, step: 5)
                }
            }

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

            Section(String(localized: "Units", comment: "Settings section")) {
                Picker(String(localized: "Byte sizes"), selection: $byteUnits) {
                    Text(String(localized: "Automatic", comment: "Byte units style")).tag("auto")
                    Text(String(localized: "Binary (KiB, MiB)", comment: "Byte units style")).tag("binary")
                    Text(String(localized: "Decimal (kB, MB)", comment: "Byte units style")).tag("decimal")
                }
            }

            Section(String(localized: "Appearance", comment: "Settings section")) {
                Toggle(String(localized: "Compact rows"), isOn: $compactDensity)
                Toggle(String(localized: "Colorblind-friendly chart colors"), isOn: $colorblindPalette)
            }
        }
        .formStyle(.grouped)
    }

    /// Hidden tabs persist as a comma list (see MonitoringKeys.hiddenTabs).
    private var hiddenTabs: Set<MonitorTab> {
        Set(hiddenTabsRaw.split(separator: ",").compactMap { MonitorTab(rawValue: String($0)) })
    }

    private func tabVisibilityBinding(_ tab: MonitorTab) -> Binding<Bool> {
        Binding(
            get: { !hiddenTabs.contains(tab) },
            set: { visible in
                var current = hiddenTabs
                if visible {
                    current.remove(tab)
                } else {
                    current.insert(tab)
                }
                hiddenTabsRaw = current.map(\.rawValue).sorted().joined(separator: ",")
            })
    }

    private var growthGB: Double { Double(alertMemoryGrowthBytes) / 1_000_000_000 }

    private var growthBinding: Binding<Double> {
        Binding(
            get: { growthGB },
            set: { alertMemoryGrowthBytes = Int($0 * 1_000_000_000) })
    }

    private var diskMB: Double { alertDiskBytesPerSecond / 1_000_000 }

    private var diskBinding: Binding<Double> {
        Binding(
            get: { diskMB },
            set: { alertDiskBytesPerSecond = $0 * 1_000_000 })
    }

    private var networkMB: Double { alertNetworkBytesPerSecond / 1_000_000 }

    private var networkBinding: Binding<Double> {
        Binding(
            get: { networkMB },
            set: { alertNetworkBytesPerSecond = $0 * 1_000_000 })
    }

    private func metricBinding(_ metric: UsageMetric) -> Binding<Bool> {
        // Same per-metric keys and defaults the menu bar extras bind to, so
        // both surfaces stay in sync; the shared table is the one source.
        let entry = MonitoringKeys.menuBarMetric(for: metric)
        return Binding(
            get: { UserDefaults.standard.object(forKey: entry.key) as? Bool ?? entry.defaultEnabled },
            set: { UserDefaults.standard.set($0, forKey: entry.key) })
    }
}
