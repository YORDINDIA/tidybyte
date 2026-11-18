import MacOSCleanerCore
import SwiftUI

/// The monitor screen: an icon rail of tabs across the top and one dashboard per
/// tab. Process inspection is hosted by ContentView's top-level `.inspector`.
struct MonitorView: View {
    @Bindable var model: MonitorModel
    @FocusState private var isSearchFocused: Bool
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
        .searchFocused($isSearchFocused)
        .task { model.start() }
        .onAppear {
            model.setWindowVisible(true)
            normalizeTabSelection()
        }
        .onDisappear { model.setWindowVisible(false) }
        .onChange(of: hiddenTabsRaw) { normalizeTabSelection() }
        .onChange(of: model.selectedTab) { normalizeTabSelection() }
        .onChange(of: model.searchFocusRequest) { isSearchFocused = true }
    }

    /// Falls back to Overview when the selected tab was hidden in Settings.
    private func normalizeTabSelection() {
        if !MonitorTab.visibleTabs.contains(model.selectedTab) {
            model.selectedTab = .overview
        }
    }

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
        .help(index < 9 ? "\(tab.title) (⌘⌥\(index + 1))" : tab.title)
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
            MonitorSkeletonView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    activeTabView
                    ProcessTableView(model: model)
                        .padding(.bottom, Spacing.elementSection)
                }
                .padding(Spacing.elementSection)
            }
        }
    }

    @ViewBuilder
    private var activeTabView: some View {
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
    }
}

// MARK: - CPU / Memory / Disk / Network

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
            HistoryChartHeading(range: model.historyRange)
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
                        scale: Double(max(1, memory.totalBytes)))
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
                        context: memory.pressure.localizedTitle,
                        tint: memory.pressure.tint)
                }
                HistoryChartHeading(range: model.historyRange)
                HistoryChartSeries(model: model, metric: .memory, tint: MonitorTab.memory.tint)
            }
        }
    }
}

struct DiskTabView: View {
    let model: MonitorModel

    var body: some View {
        let disk = model.snapshot?.disk
        let readOps = disk?.readOperationsPerSecond ?? 0
        let writeOps = disk?.writeOperationsPerSecond ?? 0
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            HStack(spacing: Spacing.elementNormal) {
                MetricTileView(
                    title: String(localized: "Read", comment: "Disk tile"),
                    icon: "arrow.down.circle", value: MetricFormatting.rate(disk?.readBytesPerSecond ?? 0),
                    unit: nil,
                    context: readOps > 0 ? "\(MetricFormatting.whole(readOps)) IOPS" : nil,
                    tint: MonitorTab.disk.tint,
                    points: model.livePoints(metricKey: "disk_read"))
                MetricTileView(
                    title: String(localized: "Write", comment: "Disk tile"),
                    icon: "arrow.up.circle", value: MetricFormatting.rate(disk?.writeBytesPerSecond ?? 0),
                    unit: nil,
                    context: writeOps > 0 ? "\(MetricFormatting.whole(writeOps)) IOPS" : nil,
                    tint: MonitorTab.disk.secondarySeriesTint,
                    points: model.livePoints(metricKey: "disk_write"))
            }
            HistoryChartHeading(range: model.historyRange)
            DualHistoryChartSeries(
                model: model,
                unit: .disk,
                primaryKey: "disk_read",
                primaryLabel: String(localized: "Read", comment: "Disk read chart legend"),
                primaryColor: MonitorTab.disk.tint,
                secondaryKey: "disk_write",
                secondaryLabel: String(localized: "Write", comment: "Disk write chart legend"),
                secondaryColor: MonitorTab.disk.secondarySeriesTint)
        }
    }
}

struct NetworkTabView: View {
    let model: MonitorModel

    var body: some View {
        let network = model.snapshot?.network
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            HStack(spacing: Spacing.elementNormal) {
                MetricTileView(
                    title: String(localized: "Download", comment: "Network tile"),
                    icon: "arrow.down", value: MetricFormatting.rate(network?.downloadBytesPerSecond ?? 0),
                    unit: nil, context: network?.primaryInterface,
                    tint: MonitorTab.network.tint,
                    points: model.livePoints(metricKey: "network_down"))
                MetricTileView(
                    title: String(localized: "Upload", comment: "Network tile"),
                    icon: "arrow.up", value: MetricFormatting.rate(network?.uploadBytesPerSecond ?? 0),
                    unit: nil,
                    context: network.map { MetricFormatting.byteCount($0.totalUploadBytes) },
                    tint: MonitorTab.network.secondarySeriesTint,
                    points: model.livePoints(metricKey: "network_up"))
            }
            HistoryChartHeading(range: model.historyRange)
            DualHistoryChartSeries(
                model: model,
                unit: .network,
                primaryKey: "network_down",
                primaryLabel: String(localized: "Download", comment: "Network download chart legend"),
                primaryColor: MonitorTab.network.tint,
                secondaryKey: "network_up",
                secondaryLabel: String(localized: "Upload", comment: "Network upload chart legend"),
                secondaryColor: MonitorTab.network.secondarySeriesTint)
        }
    }
}

/// Time-range heading above every metric tab's history chart.
struct HistoryChartHeading: View {
    var range: HistoryRange = .day

    var body: some View {
        Text(range.headingTitle)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// Single-series history chart with range picker and live tail updates.
struct HistoryChartSeries: View {
    let model: MonitorModel
    let metric: UsageMetric
    let tint: Color

    @State private var storedPoints: [MetricsHistoryStore.SeriesPoint] = []

    var body: some View {
        let displayed = model.chartPoints(metricKey: metric.rawValue, stored: storedPoints)
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HistoryRangePicker(selection: Binding(
                get: { model.historyRange },
                set: { model.historyRange = $0 }
            ))
            if displayed.count > 1 {
                HistoryChartView(points: displayed, tint: tint, unit: metric)
            } else {
                Text(String(localized: "History builds up as the monitor runs.", comment: "Empty history note"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
        }
        .task(id: "\(metric.rawValue)-\(model.historyRange.rawValue)") {
            while !Task.isCancelled {
                storedPoints = await model.series(metric: metric)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

/// Dual-series history chart (Disk Read/Write, Network Download/Upload).
struct DualHistoryChartSeries: View {
    let model: MonitorModel
    let unit: UsageMetric
    let primaryKey: String
    let primaryLabel: String
    let primaryColor: Color
    let secondaryKey: String
    let secondaryLabel: String
    let secondaryColor: Color

    @State private var primaryStored: [MetricsHistoryStore.SeriesPoint] = []
    @State private var secondaryStored: [MetricsHistoryStore.SeriesPoint] = []

    var body: some View {
        let primary = model.chartPoints(metricKey: primaryKey, stored: primaryStored)
        let secondary = model.chartPoints(metricKey: secondaryKey, stored: secondaryStored)
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HistoryRangePicker(selection: Binding(
                get: { model.historyRange },
                set: { model.historyRange = $0 }
            ))
            if primary.count > 1 || secondary.count > 1 {
                DualHistoryChartView(
                    primaryLabel: primaryLabel,
                    primaryColor: primaryColor,
                    primaryPoints: primary,
                    secondaryLabel: secondaryLabel,
                    secondaryColor: secondaryColor,
                    secondaryPoints: secondary,
                    unit: unit)
            } else {
                Text(String(localized: "History builds up as the monitor runs.", comment: "Empty history note"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
        }
        .task(id: "\(primaryKey)-\(secondaryKey)-\(model.historyRange.rawValue)") {
            while !Task.isCancelled {
                async let first = model.series(metricKey: primaryKey)
                async let second = model.series(metricKey: secondaryKey)
                (primaryStored, secondaryStored) = await (first, second)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

private struct HistoryRangePicker: View {
    @Binding var selection: HistoryRange

    var body: some View {
        Picker(String(localized: "Range", comment: "History range picker"), selection: $selection) {
            ForEach(HistoryRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - GPU / Neural / Battery

struct GPUTabView: View {
    let model: MonitorModel

    var body: some View {
        let devices = model.snapshot?.gpu.devices ?? []
        if devices.isEmpty {
            ContentUnavailableView(
                String(localized: "No GPU readings"), systemImage: "bolt.slash",
                description: Text(String(localized: "This Mac did not report GPU statistics.", comment: "GPU empty state")))
        } else {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.elementNormal)], spacing: Spacing.elementNormal) {
                    ForEach(devices) { device in
                        MetricTileView(
                            title: device.name, icon: "bolt",
                            value: device.primaryUtilization.map { String(format: "%.0f", $0) } ?? "-",
                            unit: device.primaryUtilization == nil ? nil : "%",
                            context: gpuCoreContext(device),
                            tint: MonitorTab.gpu.tint)
                    }
                }
                ForEach(devices) { device in
                    if device.hasDetailedTelemetry {
                        AppleSiliconGPUCard(gpu: device)
                    }
                }
            }
        }
    }

    private func gpuCoreContext(_ device: GPUDeviceReading) -> String? {
        guard let cores = device.coreCount else { return nil }
        return cores == 1
            ? String(localized: "1 core", comment: "GPU core count, singular")
            : String(localized: "\(cores) cores", comment: "GPU core count")
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
                        icon: power.batterySymbolName,
                        value: power.level.map { MetricFormatting.percent($0) } ?? "-", unit: nil,
                        context: power.batteryStatusContext,
                        tint: MonitorTab.battery.tint)
                    if let wattage = power.wattage {
                        MetricTileView(
                            title: String(localized: "Power", comment: "Wattage tile"),
                            icon: "bolt.badge.clock",
                            value: MetricFormatting.watts(abs(wattage)), unit: nil,
                            context: power.powerDirectionLabel,
                            tint: MonitorTab.battery.tint)
                    }
                    if let health = power.healthFraction {
                        MetricTileView(
                            title: String(localized: "Health", comment: "Battery health tile"),
                            icon: "heart.text.square",
                            value: MetricFormatting.percent(health), unit: nil,
                            context: power.cycleCount.map {
                                $0 == 1
                                    ? String(localized: "1 cycle", comment: "Battery cycle count, singular")
                                    : String(localized: "\($0) cycles", comment: "Cycle count")
                            },
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
                        Text(assertion.processName)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
