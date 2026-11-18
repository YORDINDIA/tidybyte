public enum MonitoringDefaults {
    public static let intervalSeconds = 2.0
    public static let historyRetentionDays = 365
    public static let menuBarPanelEnabled = true
    public static let alertsEnabled = false
    /// Sustained system-CPU share (0...100%, normalized across logical cores)
    /// that triggers an alert, matching the Settings slider (20...100%).
    public static let alertCPUPercent = 70.0
    public static let alertCPUWindowMinutes = 10.0
    public static let alertMemoryGrowthBytes = 1_500_000_000
    public static let alertDiskBytesPerSecond = 80_000_000.0
    public static let alertNetworkBytesPerSecond = 50_000_000.0
}
