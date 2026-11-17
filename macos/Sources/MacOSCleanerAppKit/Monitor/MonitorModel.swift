import MacOSCleanerCore
import SwiftUI

/// One monitor screen.
enum MonitorTab: String, CaseIterable, Identifiable {
    case overview, cpu, memory, disk, network, gpu, neural, battery, sound, bluetooth, projects, agents, containers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .disk: String(localized: "Disk")
        case .network: String(localized: "Network")
        case .gpu: String(localized: "GPU")
        case .neural: String(localized: "Neural")
        case .battery: String(localized: "Battery")
        case .sound: String(localized: "Sound")
        case .bluetooth: String(localized: "Bluetooth")
        case .projects: String(localized: "Projects")
        case .agents: String(localized: "Agents")
        case .containers: String(localized: "Containers")
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .gpu: "bolt"
        case .neural: "gearshape.2"
        case .battery: "battery.100"
        case .sound: "speaker.wave.2"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .projects: "curlybraces.square"
        case .agents: "sparkles"
        case .containers: "shippingbox"
        }
    }

    var tint: Color {
        UserDefaults.standard.bool(forKey: MonitoringKeys.colorblindPalette) ? accessibleTint : baseTint
    }

    private var baseTint: Color {
        switch self {
        case .overview: .accentColor
        case .cpu: .blue
        case .memory: .purple
        case .disk: .orange
        case .network: .green
        case .gpu: .pink
        case .neural: .indigo
        case .battery: .green
        case .sound: .pink
        case .bluetooth: .blue
        case .projects: .teal
        case .agents: .orange
        case .containers: .blue
        }
    }

    var accessibleTint: Color {
        switch self {
        case .overview: .accentColor
        case .cpu, .bluetooth, .containers: .blue
        case .memory, .neural: .indigo
        case .disk, .projects, .agents: .orange
        case .network, .battery: .teal
        case .gpu, .sound: .brown
        }
    }

    /// contrasting secondary tint for split Read/Write and Download/Upload charts.
    var secondarySeriesTint: Color {
        let colorblind = UserDefaults.standard.bool(forKey: MonitoringKeys.colorblindPalette)
        switch self {
        case .disk:
            return .blue
        case .network:
            return colorblind ? .orange : .purple
        default:
            return .secondary
        }
    }

    static var hiddenTabs: Set<MonitorTab> {
        let raw = UserDefaults.standard.string(forKey: MonitoringKeys.hiddenTabs) ?? ""
        return Set(raw.split(separator: ",").compactMap { MonitorTab(rawValue: String($0)) })
    }

    static var visibleTabs: [MonitorTab] {
        let hidden = hiddenTabs
        var tabs = allCases.filter { !hidden.contains($0) }
        if !tabs.contains(.overview) { tabs.insert(.overview, at: 0) }
        return tabs
    }

    var isHidden: Bool { Self.hiddenTabs.contains(self) }

    static func tab(for metric: UsageMetric) -> MonitorTab {
        switch metric {
        case .cpu: .cpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .energy: .overview
        }
    }
}

/// Main-actor facade over the monitoring engine. Owns the sampling task and
/// publishes the latest snapshot to window tabs, menu bar items, and history charts.
@MainActor
@Observable
final class MonitorModel {
    static let openMonitorNotification = Notification.Name("\(AppIdentity.bundleIdentifier).openMonitor")

    var snapshot: SystemSnapshot?
    private(set) var isRunning = false
    var lastError: String?

    var selectedTab: MonitorTab = .overview
    var groupingMode: AppProcessCatalog.GroupingMode = .byApp
    var searchText = ""
    var searchFocusRequest = 0
    var selectedGroupID: String?
    var selectedProcessPID: pid_t?
    var inspection: ProcessInspection?
    var historyRange: HistoryRange = .hour
    private(set) var selectedAppHistory: [MetricsHistoryStore.SeriesPoint] = []

    let settings: MonitoringSettings
    private var engine: MonitoringEngine?
    private var history: MetricsHistoryStore?
    private var alertEngine: AlertEngine?
    private var samplingTask: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var isWindowVisible = false
    private var defaultsObserver: NSObjectProtocol?

    private(set) var liveSeries: [LivePoint] = []

    struct LivePoint: Identifiable, Equatable {
        var id: Date { timestamp }
        var timestamp: Date
        var cpu: Double
        var memory: Double
        var networkDown: Double
        var networkUp: Double
        var diskRead: Double
        var diskWrite: Double

        var network: Double { networkDown + networkUp }
        var disk: Double { diskRead + diskWrite }
    }

    init(settings: MonitoringSettings = .init()) {
        self.settings = settings
    }

    func dismissError() {
        lastError = nil
    }

    /// Boots the engine once; safe to call repeatedly. Polling runs only while
    /// a surface (Monitor window or menu bar extra) is active.
    func start() {
        guard !isRunning else {
            syncSamplingLoop()
            return
        }
        isRunning = true
        do {
            history = try MetricsHistoryStore()
        } catch {
            lastError = error.localizedDescription
        }
        alertEngine = AlertEngine(settings: freshThresholds(), notifier: SystemAlertNotifier())
        engine = MonitoringEngine(history: history, alertEngine: alertEngine)
        observeSettings()
        syncSamplingLoop()
    }

    private func observeSettings() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncSamplingLoop() }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        drainingTask?.cancel()
        drainingTask = nil
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        isRunning = false
        if let engine {
            Task { await engine.shutdown() }
        }
        engine = nil
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        syncSamplingLoop()
    }

    /// True when either the Monitor window tab is showing or the master menu
    /// bar switch is enabled. Disabling the master toggle with the window
    /// closed pauses background polling completely.
    private func isConsumerAttached() -> Bool {
        isWindowVisible || settings.isMenuBarPanelEnabled
    }

    private func syncSamplingLoop() {
        guard isRunning, let engine else { return }
        if isConsumerAttached() {
            guard samplingTask == nil else { return }
            let previous = drainingTask
            drainingTask = nil
            samplingTask = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                await self?.runLoop(engine: engine)
            }
        } else if let active = samplingTask {
            active.cancel()
            drainingTask = active
            samplingTask = nil
        }
    }

    private func runLoop(engine: MonitoringEngine) async {
        while !Task.isCancelled, isConsumerAttached() {
            let interval = max(1, settings.intervalSeconds)
            let snapshot = await engine.sample(interval: interval)
            guard !Task.isCancelled else { break }
            apply(snapshot: snapshot)
            if let alertEngine {
                await alertEngine.updateThresholds(freshThresholds())
            }
            await engine.setRetentionDays(settings.historyRetentionDays)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func freshThresholds() -> AlertEngine.AlertThresholds {
        AlertEngine.AlertThresholds(
            isEnabled: settings.isAlertsEnabled,
            cpuPercent: settings.alertCPUPercent,
            cpuWindowMinutes: settings.alertCPUWindowMinutes,
            memoryGrowthBytes: settings.alertMemoryGrowthBytes,
            diskBytesPerSecond: settings.alertDiskBytesPerSecond,
            networkBytesPerSecond: settings.alertNetworkBytesPerSecond)
    }

    private func apply(snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        let point = LivePoint(
            timestamp: snapshot.timestamp,
            cpu: snapshot.cpu.usagePercent,
            memory: Double(snapshot.memory.usedBytes),
            networkDown: snapshot.network.downloadBytesPerSecond,
            networkUp: snapshot.network.uploadBytesPerSecond,
            diskRead: snapshot.disk.readBytesPerSecond,
            diskWrite: snapshot.disk.writeBytesPerSecond)
        liveSeries.append(point)
        if liveSeries.count > 180 {
            liveSeries.removeFirst(liveSeries.count - 180)
        }
        reconcileSelection(against: snapshot)
    }

    private func reconcileSelection(against snapshot: SystemSnapshot) {
        guard let selectedGroupID else { return }
        guard let group = snapshot.groups.first(where: { $0.id == selectedGroupID }) else {
            clearSelection()
            return
        }
        guard let pid = selectedProcessPID else { return }
        guard let live = snapshot.processes.first(where: { $0.pid == pid }) else {
            select(group: group)
            return
        }
        if let current = inspection {
            if current.startedAt != live.startedAt {
                select(group: group)
            } else {
                inspection?.cpuTimeSeconds = live.cpuTimeSeconds
                inspection?.residentBytes = live.residentBytes
                inspection?.footprintBytes = live.physFootprintBytes
                inspection?.diskReadBytes = live.diskReadBytes
                inspection?.diskWrittenBytes = live.diskWrittenBytes
                inspection?.children = snapshot.processes.filter { $0.parentPID == pid }
            }
        }
    }

    func setGroupingMode(_ mode: AppProcessCatalog.GroupingMode) {
        groupingMode = mode
        guard var snapshot, let engine else { return }
        snapshot.groups = []
        clearSelection()
        self.snapshot = snapshot
        Task {
            await engine.setGroupingMode(mode)
            let regrouped = await engine.regroup(snapshot: snapshot, mode: mode)
            if let regrouped { self.snapshot = regrouped }
        }
    }

    func openTab(_ tab: MonitorTab) {
        selectedTab = MonitorTab.visibleTabs.contains(tab) ? tab : .overview
    }

    func openMonitor(tab: MonitorTab? = nil, selecting group: AppProcessGroup? = nil) {
        if let tab { openTab(tab) }
        if let group { select(group: group) }
        NotificationCenter.default.post(name: Self.openMonitorNotification, object: selectedTab.rawValue)
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    func series(metric: UsageMetric) async -> [MetricsHistoryStore.SeriesPoint] {
        await series(metricKey: metric.rawValue)
    }

    func series(metricKey: String) async -> [MetricsHistoryStore.SeriesPoint] {
        guard let history else { return [] }
        return await history.series(metricKey: metricKey, from: historyRange.start, to: .now)
    }

    func livePoints(metric: UsageMetric) -> [(Date, Double)] {
        guard metric != .energy else { return [] }
        return livePoints(metricKey: metric.rawValue)
    }

    func livePoints(metricKey: String) -> [(Date, Double)] {
        liveSeries.compactMap { point -> (Date, Double)? in
            switch metricKey {
            case "cpu": return (point.timestamp, point.cpu)
            case "memory": return (point.timestamp, point.memory)
            case "disk": return (point.timestamp, point.disk)
            case "disk_read": return (point.timestamp, point.diskRead)
            case "disk_write": return (point.timestamp, point.diskWrite)
            case "network": return (point.timestamp, point.network)
            case "network_down": return (point.timestamp, point.networkDown)
            case "network_up": return (point.timestamp, point.networkUp)
            default: return nil
            }
        }
    }

    /// Combines stored SQLite history with recent in-memory live ticks so
    /// charts stay live as samples arrive, downsampled to <= 180 points.
    func chartPoints(metricKey: String, stored: [MetricsHistoryStore.SeriesPoint]) -> [MetricsHistoryStore.SeriesPoint] {
        let live = livePoints(metricKey: metricKey).map {
            MetricsHistoryStore.SeriesPoint(timestamp: $0.0, average: $0.1, peak: nil)
        }
        guard !stored.isEmpty else {
            return ChartDownsampler.downsample(live, targetCount: 180)
        }
        let cutoff = stored.last?.timestamp ?? .distantPast
        let tail = live.filter { $0.timestamp > cutoff }
        var combined = stored
        if historyRange == .hour || historyRange == .day {
            combined.append(contentsOf: tail)
        } else if let latest = tail.last {
            combined.append(latest)
        }
        return ChartDownsampler.downsample(combined, targetCount: 180)
    }

    func select(group: AppProcessGroup) {
        selectedGroupID = group.id
        selectedProcessPID = group.members.max { $0.cpuPercent < $1.cpuPercent }?.pid
        selectedAppHistory = []
        guard let sample = snapshot?.processes.first(where: { $0.pid == selectedProcessPID }) ?? group.members.first,
              let all = snapshot?.processes else {
            inspection = nil
            return
        }
        let appName = group.name
        let expectedPID = sample.pid
        Task {
            async let inspection = ProcessInspector.inspect(sample, all: all)
            async let history = appHistory(appName: appName)
            let (newInspection, newHistory) = await (inspection, history)
            guard self.selectedGroupID == group.id, self.selectedProcessPID == expectedPID else { return }
            self.inspection = newInspection
            self.selectedAppHistory = newHistory
        }
    }

    func clearSelection() {
        selectedGroupID = nil
        selectedProcessPID = nil
        inspection = nil
        selectedAppHistory = []
    }

    func appHistory(appName: String) async -> [MetricsHistoryStore.SeriesPoint] {
        guard let history else { return [] }
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: .now) ?? .now
        return await history.appSeries(metric: .cpu, appName: appName, from: start, to: .now)
    }

    func quit(pid: pid_t, confirmedStart: Date?, force: Bool) {
        if force {
            ProcessActions.forceQuit(pid: pid, confirmedStart: confirmedStart)
        } else {
            ProcessActions.quit(pid: pid, confirmedStart: confirmedStart)
        }
        clearSelection()
    }

    @MainActor
    func exportImage(of view: some View) async -> Data? {
        guard !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") else { return nil }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}

public enum HistoryRange: String, CaseIterable, Identifiable {
    case hour, day, week, month, year

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: String(localized: "1h", comment: "History range picker: 1 hour")
        case .day: String(localized: "24h", comment: "History range picker: 24 hours")
        case .week: String(localized: "7d", comment: "History range picker: 7 days")
        case .month: String(localized: "30d", comment: "History range picker: 30 days")
        case .year: String(localized: "1y", comment: "History range picker: 1 year")
        }
    }

    var headingTitle: String {
        switch self {
        case .hour: String(localized: "Last hour", comment: "History chart heading: 1 hour")
        case .day: String(localized: "Last 24 hours", comment: "History chart heading: 24 hours")
        case .week: String(localized: "Last 7 days", comment: "History chart heading: 7 days")
        case .month: String(localized: "Last 30 days", comment: "History chart heading: 30 days")
        case .year: String(localized: "Last year", comment: "History chart heading: 1 year")
        }
    }

    var start: Date {
        let calendar = Calendar.current
        return switch self {
        case .hour: calendar.date(byAdding: .hour, value: -1, to: .now) ?? .now
        case .day: calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
        case .week: calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
        case .month: calendar.date(byAdding: .month, value: -1, to: .now) ?? .now
        case .year: calendar.date(byAdding: .year, value: -1, to: .now) ?? .now
        }
    }
}
