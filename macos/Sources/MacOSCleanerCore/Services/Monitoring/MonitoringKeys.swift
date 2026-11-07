import Foundation

/// UserDefaults keys and defaults for the monitoring feature, shared by the
/// Core services and the AppKit surfaces. One home so a key rename cannot
/// split the UI from the engine or from Settings.
public enum MonitoringKeys {
    /// Seconds between sampling ticks.
    public static let intervalSeconds = "monitor.intervalSeconds"
    /// Days of sampled history the store keeps.
    public static let historyRetentionDays = "monitor.historyRetentionDays"
    /// Master switch for the combined menu bar panel extra.
    public static let menuBarPanelEnabled = "monitor.menuBarEnabled"
    /// Threshold alerts on and their four rules.
    public static let alertsEnabled = "monitor.alertsEnabled"
    public static let alertCPUPercent = "monitor.alert.cpuPercent"
    public static let alertCPUWindowMinutes = "monitor.alert.cpuWindowMinutes"
    public static let alertMemoryGrowthBytes = "monitor.alert.memoryGrowthBytes"
    public static let alertDiskBytesPerSecond = "monitor.alert.diskBytesPerSecond"
    public static let alertNetworkBytesPerSecond = "monitor.alert.networkBytesPerSecond"
    /// Compact row density in the monitor window.
    public static let density = "monitor.density"
    /// Binary or decimal byte counts in the monitor's readouts.
    public static let byteUnits = "monitor.byteUnits"
    /// Colorblind-safe categorical palette for charts and tiles.
    public static let colorblindPalette = "monitor.colorblindPalette"
    /// Comma list of monitor tabs the user hid.
    public static let hiddenTabs = "monitor.hiddenTabs"

    /// The per-metric menu bar extras in MenuBarExtra declaration order,
    /// with the same defaults the scenes' @AppStorage declarations carry.
    public struct MenuBarMetric: Sendable {
        public var metric: UsageMetric
        public var key: String
        public var defaultEnabled: Bool

        public init(metric: UsageMetric, key: String, defaultEnabled: Bool) {
            self.metric = metric
            self.key = key
            self.defaultEnabled = defaultEnabled
        }
    }

    public static let menuBarCPU = MenuBarMetric(metric: .cpu, key: "monitor.metric.cpu", defaultEnabled: true)
    public static let menuBarMemory = MenuBarMetric(metric: .memory, key: "monitor.metric.memory", defaultEnabled: true)
    public static let menuBarNetwork = MenuBarMetric(metric: .network, key: "monitor.metric.network", defaultEnabled: true)
    public static let menuBarDisk = MenuBarMetric(metric: .disk, key: "monitor.metric.disk", defaultEnabled: false)
    public static let menuBarEnergy = MenuBarMetric(metric: .energy, key: "monitor.metric.energy", defaultEnabled: false)

    public static let menuBarMetrics: [MenuBarMetric] = [
        menuBarCPU, menuBarMemory, menuBarNetwork, menuBarDisk, menuBarEnergy
    ]

    public static func menuBarMetric(for metric: UsageMetric) -> MenuBarMetric {
        switch metric {
        case .cpu: menuBarCPU
        case .memory: menuBarMemory
        case .network: menuBarNetwork
        case .disk: menuBarDisk
        case .energy: menuBarEnergy
        }
    }
}
