import MacOSCleanerCore
import SwiftUI

/// The monitor screen: an icon rail of tabs across the top, one dashboard per
/// tab, and the process inspector on the side. Lives inside the main window's
/// detail column when the user picks Monitor in the sidebar.
struct MonitorView: View {
    @Bindable var model: MonitorModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MonitoringKeys.hiddenTabs) private var hiddenTabsRaw = ""

    var body: some View {
        VStack(spacing: 0) {
            tabRail
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: String(localized: "Search processes", comment: "Monitor search prompt"))
        .inspector(isPresented: Binding(
            get: { model.inspection != nil },
            set: { shown in
                // Closing the column (toggle, Esc, drag) ends the selection;
                // the inspector could otherwise never be dismissed.
                if !shown { model.clearSelection() }
            }
        )) {
            if let inspection = model.inspection {
                ProcessInspectorView(
                    inspection: inspection,
                    history: model.selectedAppHistory
                ) { pid, force in
                    model.quit(pid: pid, force: force)
                }
                .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
            } else {
                ContentUnavailableView(
                    String(localized: "No selection"),
                    systemImage: "sidebar.trailing",
                    description: Text(String(localized: "Select an app to see its details.")))
                    .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
            }
        }
        // The engine boots at app scope; with no surface attached it
        // self-throttles to a 30 s heartbeat, so appearing here restores the
        // full cadence. start() is idempotent (guards on isRunning).
        .task { model.start() }
        .onAppear {
            model.setWindowVisible(true)
            normalizeTabSelection()
        }
        .onDisappear { model.setWindowVisible(false) }
        .onChange(of: hiddenTabsRaw) { normalizeTabSelection() }
    }

    /// Falls back to Overview when the selected tab was hidden in Settings.
    private func normalizeTabSelection() {
        if !MonitorTab.visibleTabs.contains(model.selectedTab) {
            model.selectedTab = .overview
        }
    }

    /// The icon rail mirrors the visible tab set; tooltips carry the names for
    /// keyboard and VoiceOver users. ⌘⌥1–⌘⌥9 pick the first nine tabs.
    private var tabRail: some View {
        let tabs = MonitorTab.visibleTabs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.elementTight) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    railButton(tab, index: index)
                }
            }
            .padding(.horizontal, Spacing.elementNormal)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func railButton(_ tab: MonitorTab, index: Int) -> some View {
        let button = Button {
            model.selectedTab = tab
        } label: {
            Label(tab.title, systemImage: tab.icon)
                .labelStyle(.iconOnly)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Radius.cardCompact)
                        .fill(model.selectedTab == tab ? tab.tint.opacity(0.16) : .clear))
                .foregroundStyle(model.selectedTab == tab ? tab.tint : .secondary)
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(model.selectedTab == tab ? [.isSelected] : [])
        if index < 9 {
            button
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
        } else {
            button
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.snapshot == nil {
            // First tick has not landed yet (~1–2s). Every tab would otherwise
            // render fake zeros ("0.0% CPU", "0 B/s") or false empties ("This
            // Mac does not have a battery", "No GPU readings") during warmup;
            // one gate shows an honest loading state everywhere instead.
            VStack {
                ProgressView(String(localized: "Reading the system…", comment: "Monitor first tick"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 60)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    switch model.selectedTab {
                    case .overview: OverviewTabView(model: model)
                    case .cpu: CPUTabView(model: model)
                    case .memory: MemoryTabView(model: model)
                    case .disk: DiskTabView(model: model)
                    case .network: NetworkTabView(model: model)
                    case .gpu: GPUTabView(model: model)
                    case .neural: NeuralTabView(model: model)
                    case .battery: BatteryTabView(model: model)
                    case .sound: SoundTabView(model: model)
                    case .bluetooth: BluetoothTabView(model: model)
                    case .projects: ProjectsTabView(model: model)
                    case .agents: AgentsTabView(model: model)
                    case .containers: ContainersTabView(model: model)
                    }
                    ProcessTableView(model: model)
                        .padding(.bottom, Spacing.elementSection)
                }
                .padding(Spacing.elementSection)
            }
        }
    }
}

// MARK: - CPU / Memory / Disk / Network

/// "User 19% · System 8%" for the CPU tile.
private func cpuSplitContext(_ cpu: CPUReading?) -> String {
    guard let cpu else { return "" }
    return String(
        localized: "User \(cpu.userPercent, specifier: "%.0f")% · System \(cpu.systemPercent, specifier: "%.0f")%",
        comment: "CPU split context")
}

struct CPUTabView: View {
    let model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            MetricTileView(
                title: String(localized: "CPU", comment: "Tile title"),
                icon: "cpu",
                value: String(format: "%.1f", model.snapshot?.cpu.usagePercent ?? 0), unit: "%",
                context: cpuSplitContext(model.snapshot?.cpu),
                tint: MonitorTab.cpu.tint, points: model.livePoints(metric: .cpu), scale: 100.0)
            HistoryChartHeading()
            HistoryChartSeries(model: model, metric: .cpu, tint: MonitorTab.cpu.tint)
        }
    }
}

struct MemoryTabView: View {
    let model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if let memory = model.snapshot?.memory {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.elementNormal)], spacing: Spacing.elementNormal) {
                    MetricTileView(
                        title: String(localized: "App Memory", comment: "Memory tile"),
                        icon: "memorychip", value: MetricFormatting.byteCount(memory.appBytes), unit: nil,
                        context: MetricFormatting.byteCount(memory.totalBytes),
                        tint: MonitorTab.memory.tint, points: model.livePoints(metric: .memory),
                        scale: Double(memory.totalBytes))
                    MetricTileView(
                        title: String(localized: "Wired", comment: "Memory tile"),
                        icon: "cable", value: MetricFormatting.byteCount(memory.wiredBytes), unit: nil,
                        context: nil, tint: MonitorTab.memory.tint)
                    MetricTileView(
                        title: String(localized: "Compressed", comment: "Memory tile"),
                        icon: "arrow.uturn.compress", value: MetricFormatting.byteCount(memory.compressedBytes), unit: nil,
                        context: nil, tint: MonitorTab.memory.tint)
                    MetricTileView(
                        title: String(localized: "Swap Used", comment: "Memory tile"),
                        icon: "arrow.triangle.swap", value: MetricFormatting.byteCount(memory.swapUsedBytes), unit: nil,
                        context: memory.pressure == .normal ? nil : String(localized: "Pressure high", comment: "Swap context"),
                        tint: memory.pressure == .normal ? MonitorTab.memory.tint : SemanticScale.warning)
                }
                HistoryChartHeading()
                HistoryChartSeries(model: model, metric: .memory, tint: MonitorTab.memory.tint)
            }
        }
    }
}

struct DiskTabView: View {
    let model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            HStack(spacing: Spacing.elementNormal) {
                MetricTileView(
                    title: String(localized: "Read", comment: "Disk tile"),
                    icon: "arrow.down.circle", value: MetricFormatting.rate(model.snapshot?.disk.readBytesPerSecond ?? 0),
                    unit: nil, context: nil, tint: MonitorTab.disk.tint, points: model.livePoints(metric: .disk))
                MetricTileView(
                    title: String(localized: "Write", comment: "Disk tile"),
                    icon: "arrow.up.circle", value: MetricFormatting.rate(model.snapshot?.disk.writeBytesPerSecond ?? 0),
                    unit: nil, context: nil, tint: MonitorTab.disk.tint, points: model.livePoints(metric: .disk))
            }
            HistoryChartHeading()
            HistoryChartSeries(model: model, metric: .disk, tint: MonitorTab.disk.tint)
        }
    }
}

struct NetworkTabView: View {
    let model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            HStack(spacing: Spacing.elementNormal) {
                MetricTileView(
                    title: String(localized: "Download", comment: "Network tile"),
                    icon: "arrow.down", value: MetricFormatting.rate(model.snapshot?.network.downloadBytesPerSecond ?? 0),
                    unit: nil, context: model.snapshot?.network.primaryInterface,
                    tint: MonitorTab.network.tint, points: model.livePoints(metric: .network))
                MetricTileView(
                    title: String(localized: "Upload", comment: "Network tile"),
                    icon: "arrow.up", value: MetricFormatting.rate(model.snapshot?.network.uploadBytesPerSecond ?? 0),
                    unit: nil, context: nil, tint: MonitorTab.network.tint, points: model.livePoints(metric: .network))
            }
            HistoryChartHeading()
            HistoryChartSeries(model: model, metric: .network, tint: MonitorTab.network.tint)
        }
    }
}

/// The "Average today" heading above every metric tab's history chart.
struct HistoryChartHeading: View {
    var body: some View {
        Text(String(localized: "Average today", comment: "History chart heading"))
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// History chart with a range picker; data comes from SQLite when open.
struct HistoryChartSeries: View {
    let model: MonitorModel
    let metric: UsageMetric
    let tint: Color

    @State private var points: [MetricsHistoryStore.SeriesPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Picker(String(localized: "Range", comment: "History range picker"), selection: Binding(
                get: { model.historyRange },
                // The .task(id:) below reloads on the same change; a manual
                // Task here would run every range switch twice.
                set: { model.historyRange = $0 }
            )) {
                ForEach(HistoryRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320, alignment: .leading)
            if points.count > 1 {
                HistoryChartView(points: points, tint: tint, unit: metric)
            } else {
                liveFallback
            }
        }
        .task(id: model.historyRange) { await reload() }
    }

    /// No stored points yet (fresh install): the live ring stands in so the
    /// chart is never an empty box.
    private var liveFallback: some View {
        let live = model.livePoints(metric: metric).map { timestamp, value in
            MetricsHistoryStore.SeriesPoint(timestamp: timestamp, average: value, peak: nil)
        }
        return Group {
            if live.count > 1 {
                HistoryChartView(points: live, tint: tint, unit: metric)
            } else {
                Text(String(localized: "History builds up as the monitor runs.", comment: "Empty history note"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
        }
    }

    private func reload() async {
        let stored = await model.series(metric: metric)
        points = stored.isEmpty
            ? model.livePoints(metric: metric).map { MetricsHistoryStore.SeriesPoint(timestamp: $0.0, average: $0.1, peak: nil) }
            : stored
    }
}

// MARK: - GPU / Neural / Battery

struct GPUTabView: View {
    let model: MonitorModel

    var body: some View {
        let devices = model.snapshot?.gpu.devices ?? []
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Spacing.elementNormal)], spacing: Spacing.elementNormal) {
            ForEach(devices) { device in
                MetricTileView(
                    title: device.name, icon: "bolt",
                    value: device.utilizationPercent.map { String(format: "%.0f", $0) } ?? "—",
                    unit: device.utilizationPercent == nil ? nil : "%",
                    context: device.coreCount.map { String(localized: "\($0) cores", comment: "GPU core count") },
                    tint: MonitorTab.gpu.tint)
            }
            if devices.isEmpty {
                ContentUnavailableView(
                    String(localized: "No GPU readings"), systemImage: "bolt.slash",
                    description: Text(String(localized: "This Mac did not report GPU statistics.", comment: "GPU empty state")))
            }
        }
    }
}

struct NeuralTabView: View {
    let model: MonitorModel

    var body: some View {
        let neural = model.snapshot?.neural
        Group {
            if neural?.isAppleSilicon == true, neural?.isMeasurable == true, let value = neural?.utilizationPercent {
                MetricTileView(
                    title: String(localized: "Neural Engine"), icon: "gearshape.2",
                    value: String(format: "%.0f", value), unit: "%",
                    context: nil, tint: MonitorTab.neural.tint)
            } else {
                ContentUnavailableView(
                    String(localized: "Neural Engine"),
                    systemImage: "gearshape.2",
                    description: Text(String(
                        localized: "macOS does not report Neural Engine load to third-party apps, so this reading is not available.",
                        comment: "Neural Engine empty state")))
            }
        }
    }
}

struct BatteryTabView: View {
    let model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if let power = model.snapshot?.power, power.hasBattery {
                HStack(spacing: Spacing.elementNormal) {
                    MetricTileView(
                        title: String(localized: "Battery", comment: "Battery tile"),
                        icon: "battery.100",
                        value: power.level.map { MetricFormatting.percent($0) } ?? "—", unit: nil,
                        context: power.isCharging
                            ? String(localized: "Charging", comment: "Battery state")
                            : power.timeToEmptySeconds.map { MetricFormatting.duration($0) },
                        tint: MonitorTab.battery.tint)
                    if let wattage = power.wattage {
                        MetricTileView(
                            title: String(localized: "Power", comment: "Wattage tile"),
                            icon: "bolt.badge.clock",
                            value: MetricFormatting.watts(abs(wattage)), unit: nil,
                            // MON-01: the direction follows the same
                            // isCharging source as the Battery tile — the
                            // SMC amperage sign disagrees with IOPS on some
                            // hardware and used to show "Discharging" next
                            // to a charging battery.
                            context: power.isCharging
                                ? String(localized: "Charging", comment: "Power direction")
                                : String(localized: "Discharging", comment: "Power direction"),
                            tint: MonitorTab.battery.tint)
                    }
                    if let health = power.healthFraction {
                        MetricTileView(
                            title: String(localized: "Health", comment: "Battery health tile"),
                            icon: "heart.text.square",
                            value: MetricFormatting.percent(health), unit: nil,
                            context: power.cycleCount.map { String(localized: "\($0) cycles", comment: "Cycle count") },
                            tint: MonitorTab.battery.tint)
                    }
                }
                assertionList(power)
            } else {
                ContentUnavailableView(
                    String(localized: "No battery"), systemImage: "powerplug",
                    description: Text(String(localized: "This Mac does not have a battery.", comment: "Battery empty state")))
            }
        }
    }

    /// What keeps the Mac awake, strongest claim first.
    private func assertionList(_ power: PowerReading) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(String(localized: "Keeping the Mac awake", comment: "Assertions heading"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if power.assertions.isEmpty {
                Text(String(localized: "Nothing is preventing sleep right now.", comment: "No assertions"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(power.assertions.prefix(10)) { assertion in
                    HStack {
                        Text(assertion.processName).font(.callout)
                        Spacer()
                        Text(assertion.kind).font(.callout).foregroundStyle(.secondary)
                        if assertion.heldSeconds > 0 {
                            Text(MetricFormatting.duration(assertion.heldSeconds))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(Spacing.cardInternal)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(.background.secondary))
    }
}
