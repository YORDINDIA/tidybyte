import MacOSCleanerCore
import SwiftUI

/// One monitor screen. The list mirrors the competitor's tab set so people
/// coming from that tool find every same surface; names and layout are
/// Tidybyte's own.
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

    /// The accent color used across the tab's tiles and charts; categorical
    /// data color, per the design rules. Switches to the colorblind-safe
    /// variant when that setting is on.
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

    /// Colorblind-safe variants of the same hues.
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

    /// Tabs the user hid in Settings, decoded from the hiddenTabs comma
    /// list. Overview can never hide.
    static var hiddenTabs: Set<MonitorTab> {
        let raw = UserDefaults.standard.string(forKey: MonitoringKeys.hiddenTabs) ?? ""
        return Set(raw.split(separator: ",").compactMap { MonitorTab(rawValue: String($0)) })
    }

    /// The rail's tabs: everything not hidden, Overview always kept.
    static var visibleTabs: [MonitorTab] {
        let hidden = hiddenTabs
        var tabs = allCases.filter { !hidden.contains($0) }
        if !tabs.contains(.overview) { tabs.insert(.overview, at: 0) }
        return tabs
    }

    var isHidden: Bool { Self.hiddenTabs.contains(self) }
}

/// Main-actor facade over the monitoring engine. Owns the sampling task and
/// publishes the latest snapshot to every surface: window tabs, menu bar
/// items, and the history charts.
@MainActor
@Observable
final class MonitorModel {
    private(set) var snapshot: SystemSnapshot?
    private(set) var isRunning = false
    private(set) var lastError: String?

    var selectedTab: MonitorTab = .overview
    var groupingMode: AppProcessCatalog.GroupingMode = .byApp
    var searchText = ""
    var selectedGroupID: String?
    var selectedProcessPID: pid_t?
    var inspection: ProcessInspection?
    var historyRange: HistoryRange = .hour
    /// Per-app CPU series behind the inspector's "Last 24 hours" chart,
    /// fetched when a group is selected.
    private(set) var selectedAppHistory: [MetricsHistoryStore.SeriesPoint] = []

    let settings: MonitoringSettings
    private var engine: MonitoringEngine?
    private var history: MetricsHistoryStore?
    private var alertEngine: AlertEngine?
    private var samplingTask: Task<Void, Never>?

    /// The recent in-memory tick series, for live charts without hitting
    /// SQLite on every frame.
    private(set) var liveSeries: [LivePoint] = []

    struct LivePoint: Identifiable, Equatable {
        var id: Date { timestamp }
        var timestamp: Date
        var cpu: Double
        var memory: Double
        var network: Double
        var disk: Double
    }

    init(settings: MonitoringSettings = .init()) {
        self.settings = settings
    }

    /// Acknowledges the history-store failure banner in StatusNotices.
    func dismissError() {
        lastError = nil
    }

    /// Boots the engine once; safe to call repeatedly.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        do {
            history = try MetricsHistoryStore()
        } catch {
            // History is optional: monitoring runs fine without persistence.
            lastError = error.localizedDescription
        }
        alertEngine = AlertEngine(settings: freshThresholds(), notifier: SystemAlertNotifier())
        let engine = MonitoringEngine(history: history, alertEngine: alertEngine)
        self.engine = engine
        samplingTask = Task { [weak self] in
            await self?.runLoop(engine: engine)
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        isRunning = false
        if let engine {
            // Best-effort: this task usually cannot finish before the app
            // exits (applicationWillTerminate), but it still runs for ordinary
            // stops. Never block the main thread waiting for it.
            Task { await engine.shutdown() }
        }
        engine = nil
    }

    /// Marks whether the window's Monitor surface is showing. The menu bar
    /// side is read from settings every tick instead.
    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
    }

    private var isWindowVisible = false

    /// True when any surface shows monitor data: the Monitor tab, the menu
    /// bar panel, or any per-metric extra.
    private func isConsumerAttached() -> Bool {
        isWindowVisible || settings.isMenuBarPanelEnabled || settings.hasEnabledMenuBarMetric
    }

    /// Seconds between ticks when no surface is attached. History records at
    /// most every 15 s and slow probes rotate per tick, so a 30 s heartbeat
    /// keeps history, alerts and retention alive at near-zero cost.
    private static let heartbeatSeconds: Double = 30

    private func runLoop(engine: MonitoringEngine) async {
        while !Task.isCancelled {
            // Full cadence with a consumer attached. The keys are re-read
            // every iteration so Settings toggles apply from the next tick —
            // no observers, and no extra @AppStorage on the App struct (that
            // spins a 100% CPU update loop — see MacOSCleanerApp).
            let interval = isConsumerAttached() ? max(1, settings.intervalSeconds) : Self.heartbeatSeconds
            let snapshot = await engine.sample(interval: interval)
            apply(snapshot: snapshot)
            // Thresholds and retention are read fresh every tick so changes
            // in Settings apply without restarting the engine.
            if let alertEngine {
                await alertEngine.updateThresholds(freshThresholds())
            }
            await engine.setRetentionDays(settings.historyRetentionDays)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    /// Current alert thresholds, re-read from settings on every tick.
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
            network: snapshot.network.downloadBytesPerSecond + snapshot.network.uploadBytesPerSecond,
            disk: snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond)
        liveSeries.append(point)
        if liveSeries.count > 180 {
            liveSeries.removeFirst(liveSeries.count - 180)
        }
        // A tick can retire the selected group (process exited, regrouping);
        // keeping it selected would leave the inspector on stale data.
        if let selectedGroupID, !snapshot.groups.contains(where: { $0.id == selectedGroupID }) {
            clearSelection()
        }
    }

    /// Re-groups the latest snapshot when the user changes grouping.
    func setGroupingMode(_ mode: AppProcessCatalog.GroupingMode) {
        groupingMode = mode
        guard var snapshot, let engine else { return }
        snapshot.groups = []
        selectedGroupID = nil
        selectedProcessPID = nil
        inspection = nil
        selectedAppHistory = []
        self.snapshot = snapshot
        Task {
            // The engine groups every tick with its own mode; without this the
            // next sample would silently revert the picker to By App.
            await engine.setGroupingMode(mode)
            let regrouped = await engine.regroup(snapshot: snapshot, mode: mode)
            if let regrouped { self.snapshot = regrouped }
        }
    }

    /// Queries the history store for one metric's series.
    func series(metric: UsageMetric) async -> [MetricsHistoryStore.SeriesPoint] {
        guard let history else { return [] }
        let range = historyRange
        return await history.series(metric: metric, from: range.start, to: .now)
    }

    /// Live points of one metric, from the in-memory ring.
    func livePoints(metric: UsageMetric) -> [(Date, Double)] {
        // The live ring has no energy samples yet; an empty series beats
        // silently showing CPU data under the Energy tab.
        guard metric != .energy else { return [] }
        return liveSeries.map { point -> (Date, Double) in
            switch metric {
            case .cpu: (point.timestamp, point.cpu)
            case .memory: (point.timestamp, point.memory)
            case .network: (point.timestamp, point.network)
            case .disk: (point.timestamp, point.disk)
            // Unreachable (guarded above): the live ring has no energy samples.
            case .energy: (point.timestamp, 0)
            }
        }
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
        Task {
            // The inspector and the history query are independent; run them
            // together. A second click can select another group while this
            // Task is in flight — drop the stale result instead of painting
            // it over the newer selection.
            async let inspection = ProcessInspector.inspect(sample, all: all)
            async let history = appHistory(appName: appName)
            let (newInspection, newHistory) = await (inspection, history)
            guard selectedGroupID == group.id else { return }
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

    /// One app's CPU series for the inspector's "Last 24 hours" chart. The
    /// history store stays private to the model; callers get points only.
    func appHistory(appName: String) async -> [MetricsHistoryStore.SeriesPoint] {
        guard let history else { return [] }
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: .now) ?? .now
        return await history.appSeries(metric: .cpu, appName: appName, from: start, to: .now)
    }

    /// Quit with confirmation handled by the caller (sheet); the model only
    /// performs the kill after the user confirmed.
    func quit(pid: pid_t, force: Bool) {
        if force {
            ProcessActions.forceQuit(pid: pid)
        } else {
            ProcessActions.quit(pid: pid)
        }
        clearSelection()
    }

    /// Renders the current tab into a PNG for export; returns the data or
    /// nil when rendering is unavailable (headless/test hosts).
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
        case .hour: String(localized: "Hour")
        case .day: String(localized: "Day")
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .year: String(localized: "Year")
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
