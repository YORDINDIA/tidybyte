import MacOSCleanerCore
import SwiftUI

/// The columns a width can hold. The full table needs about 600 points, so
/// narrower windows drop the rightmost columns first and nothing clips.
enum ProcessTableTier: CaseIterable {
    case full, medium, compact

    var showsEnergy: Bool { self != .compact }
    var showsDownload: Bool { self == .full }
    var showsDisk: Bool { self == .full }
}

/// Fixed column widths, shared by the header and every row so they line up.
private enum ProcessTableWidth {
    static let icon: CGFloat = 22
    static let name: CGFloat = 190
    static let bar: CGFloat = 40
    static let cpu: CGFloat = 64
    static let memory: CGFloat = 84
    static let download: CGFloat = 96
    static let disk: CGFloat = 96
    static let energy: CGFloat = 56
}

/// The "apps, not processes" table below every tab, and the per-tab drill-in.
/// Rows are app groups; expanding a group shows its helper processes. Context
/// menu offers Quit (confirm) and Inspect.
struct ProcessTableView: View {
    @Bindable var model: MonitorModel
    /// One pending quit gesture. Both context-menu items land here so the
    /// sheet always presents before any signal reaches the target process.
    @State private var quitIntent: QuitIntent?
    @State private var sort: SortField = .cpu
    @State private var filter: GroupFilter = .all

    enum SortField: String, CaseIterable, Identifiable {
        case cpu, memory, disk, network, energy, name
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cpu: String(localized: "Sort by CPU", comment: "Sort menu")
            case .memory: String(localized: "Sort by memory", comment: "Sort menu")
            case .disk: String(localized: "Sort by disk", comment: "Sort menu")
            case .network: String(localized: "Sort by network", comment: "Sort menu")
            case .energy: String(localized: "Sort by energy", comment: "Sort menu")
            case .name: String(localized: "Sort by name", comment: "Sort menu")
            }
        }
    }

    enum GroupFilter: String, CaseIterable, Identifiable {
        case all, userApps, system
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: String(localized: "All apps", comment: "Filter menu")
            case .userApps: String(localized: "My apps", comment: "Filter menu: user-launched apps")
            case .system: String(localized: "System & background", comment: "Filter menu")
            }
        }
    }

    /// Which quit action the presented sheet will perform once confirmed.
    enum QuitIntent: Identifiable {
        case quit(ProcessSample)
        case forceQuit(ProcessSample)

        var id: String {
            switch self {
            case .quit(let sample): "quit-\(sample.pid)"
            case .forceQuit(let sample): "force-\(sample.pid)"
            }
        }

        var sample: ProcessSample {
            switch self {
            case .quit(let sample), .forceQuit(let sample): sample
            }
        }
    }

    /// Row cap: past this the table shows a footer instead of the tail.
    private static let rowLimit = 40

    var body: some View {
        // Computed once per body evaluation and passed down; the row list and
        // the bar maxima were previously re-derived per row per render.
        let groups = filteredGroups
        let cpuMaximum = max(groups.map(\.cpuPercent).max() ?? 1, 1)
        let memoryMaximum = max(Double(groups.map(\.memoryBytes).max() ?? 1), 1)
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            header
            ViewThatFits(in: .horizontal) {
                table(groups, tier: .full, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
                table(groups, tier: .medium, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
                table(groups, tier: .compact, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
            }
        }
        .sheet(item: $quitIntent) { intent in
            QuitConfirmView(
                sample: intent.sample,
                showsForceQuit: true,
                onQuit: { model.quit(pid: intent.sample.pid, confirmedStart: intent.sample.startedAt, force: false) },
                onForceQuit: { model.quit(pid: intent.sample.pid, confirmedStart: intent.sample.startedAt, force: true) })
        }
    }

    private var filteredGroups: [AppProcessGroup] {
        guard let snapshot = model.snapshot else { return [] }
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        var groups = snapshot.groups
        if filter == .userApps { groups = groups.filter { $0.kind == .app } }
        if filter == .system { groups = groups.filter { $0.kind != .app } }
        if !query.isEmpty {
            groups = groups.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.members.contains { $0.name.localizedCaseInsensitiveContains(query) }
            }
        }
        // The catalog already orders user apps first, busiest first; the CPU sort
        // keeps that order. Other keys re-sort.
        switch sort {
        case .cpu:
            break
        case .name:
            groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .memory:
            groups.sort { $0.memoryBytes > $1.memoryBytes }
        case .disk:
            groups.sort {
                $0.diskReadPerSecond + $0.diskWritePerSecond > $1.diskReadPerSecond + $1.diskWritePerSecond
            }
        case .network:
            groups.sort { $0.downloadPerSecond + $0.uploadPerSecond > $1.downloadPerSecond + $1.uploadPerSecond }
        case .energy:
            groups.sort { $0.energyIndex > $1.energyIndex }
        }
        return groups
    }

    /// Two lines: the title and count, then the controls. One line needs about
    /// 560 points, so the count and the controls cannot share it on a narrow window.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Text(String(localized: "Apps", comment: "Process table heading"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let snapshot = model.snapshot {
                    // MON-02: in By Process mode the rows ARE processes, so the
                    // footer must not call them apps.
                    Text(model.groupingMode == .byProcess
                        ? String(localized: "\(snapshot.processes.count) processes", comment: "Process count footer, by process")
                        : String(
                            localized: "\(snapshot.groups.count) apps · \(snapshot.processes.count) processes",
                            comment: "Process count footer"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            HStack {
                Menu {
                    Picker(String(localized: "Filter", comment: "Filter menu title"), selection: $filter) {
                        ForEach(GroupFilter.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(String(localized: "Filter", comment: "Filter menu title"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .help(String(localized: "Show user apps, system background, or everything", comment: "Filter help"))
                Menu {
                    Picker(String(localized: "Sort", comment: "Sort menu title"), selection: $sort) {
                        ForEach(SortField.allCases) { field in
                            Text(field.label).tag(field)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(String(localized: "Sort", comment: "Sort menu title"), systemImage: "arrow.up.arrow.down")
                }
                .help(String(localized: "Order the rows by a metric", comment: "Sort help"))
                Spacer()
                Picker(String(localized: "Group", comment: "Grouping picker"), selection: Binding(
                    get: { model.groupingMode },
                    set: { model.setGroupingMode($0) }
                )) {
                    Text(String(localized: "By App", comment: "Grouping mode")).tag(AppProcessCatalog.GroupingMode.byApp)
                    Text(String(localized: "By Process", comment: "Grouping mode")).tag(AppProcessCatalog.GroupingMode.byProcess)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }

    /// One width tier of the table: column titles, the rows, and the cap footer.
    private func table(_ groups: [AppProcessGroup], tier: ProcessTableTier, cpuMaximum: Double, memoryMaximum: Double) -> some View {
        let shown = groups.prefix(Self.rowLimit)
        return VStack(alignment: .leading, spacing: 0) {
            columnHeader(tier)
            Divider()
            if groups.isEmpty {
                emptyMessage
            }
            ForEach(shown) { group in
                row(group, tier: tier, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
                if group.id != shown.last?.id {
                    Divider().padding(.leading, Spacing.cardInternal)
                }
            }
            if groups.count > shown.count {
                footer(shown: shown.count, total: groups.count)
            }
        }
        .monitorCard()
    }

    private func columnHeader(_ tier: ProcessTableTier) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            columnTitle(String(localized: "App", comment: "Process table column"))
                .frame(width: ProcessTableWidth.icon + ProcessTableWidth.name + Spacing.elementNormal, alignment: .leading)
            Spacer(minLength: ProcessTableWidth.bar)
            columnTitle(String(localized: "CPU", comment: "Process table column"), width: ProcessTableWidth.cpu)
            Spacer(minLength: ProcessTableWidth.bar)
            columnTitle(String(localized: "Memory", comment: "Process table column"), width: ProcessTableWidth.memory)
            if tier.showsDownload {
                columnTitle(String(localized: "Download", comment: "Process table column"), width: ProcessTableWidth.download)
            }
            if tier.showsDisk {
                columnTitle(String(localized: "Disk", comment: "Process table column"), width: ProcessTableWidth.disk)
            }
            if tier.showsEnergy {
                columnTitle(String(localized: "Energy", comment: "Process table column"), width: ProcessTableWidth.energy)
            }
        }
        .padding(.horizontal, Spacing.cardInternal)
        .padding(.vertical, Spacing.elementTight)
    }

    private func columnTitle(_ text: String, width: CGFloat? = nil) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: width, alignment: width == nil ? .leading : .trailing)
    }

    /// Shown when the filter or the search leaves no app.
    private var emptyMessage: some View {
        Text(model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(localized: "No apps in this filter.", comment: "Process table empty filter")
            : String(localized: "No apps match the search.", comment: "Process table empty search"))
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(Spacing.cardInternal)
    }

    /// Tells people why the list stops at the cap, and what to do about it.
    private func footer(shown: Int, total: Int) -> some View {
        Text(String(
            localized: "Showing \(shown) of \(total) apps. Search to narrow the list.",
            comment: "Process table row cap footer"))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.elementTight)
    }

    private func row(_ group: AppProcessGroup, tier: ProcessTableTier, cpuMaximum: Double, memoryMaximum: Double) -> some View {
        let isSelected = model.selectedGroupID == group.id
        return Button {
            model.select(group: group)
        } label: {
            HStack(spacing: Spacing.elementNormal) {
                nameCell(group)
                ProgressBarView(fraction: min(1, group.cpuPercent / cpuMaximum), tint: MonitorTab.cpu.tint)
                    .frame(minWidth: ProcessTableWidth.bar, maxWidth: .infinity)
                tableValue(MetricFormatting.value(group.cpuPercent, metric: .cpu), width: ProcessTableWidth.cpu)
                ProgressBarView(fraction: Double(group.memoryBytes) / memoryMaximum, tint: MonitorTab.memory.tint)
                    .frame(minWidth: ProcessTableWidth.bar, maxWidth: .infinity)
                tableValue(MetricFormatting.byteCount(group.memoryBytes), width: ProcessTableWidth.memory)
                if tier.showsDownload {
                    tableValue(
                        String(localized: "\(MetricFormatting.rate(group.downloadPerSecond)) ↓", comment: "Download rate cell"),
                        width: ProcessTableWidth.download)
                }
                if tier.showsDisk {
                    tableValue(
                        MetricFormatting.rate(group.diskReadPerSecond + group.diskWritePerSecond), width: ProcessTableWidth.disk)
                }
                if tier.showsEnergy {
                    tableValue(MetricFormatting.energy(group.energyIndex), width: ProcessTableWidth.energy)
                }
            }
            .padding(.horizontal, Spacing.cardInternal)
            .padding(.vertical, model.settings.isCompactDensity ? 4 : 7)
            .contentShape(Rectangle())
            .background(isSelected ? Primary.selection : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu { rowMenu(group) }
        .help(group.name)
    }

    /// The app icon and name, with the helper count under a multi-process app.
    private func nameCell(_ group: AppProcessGroup) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            MonitorAppIconView(bundlePath: group.bundlePath)
                .frame(width: ProcessTableWidth.icon, height: ProcessTableWidth.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(.callout, design: .default).weight(.medium))
                    .lineLimit(1)
                if group.members.count > 1 {
                    Text(String(localized: "\(group.members.count) processes", comment: "Helper count"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: ProcessTableWidth.name, alignment: .leading)
        }
    }

    @ViewBuilder
    private func rowMenu(_ group: AppProcessGroup) -> some View {
        Button(String(localized: "Inspect", comment: "Context action")) { model.select(group: group) }
        // Quit items need a real leading process; a group with no members
        // (transient read) has nobody to signal, so omit the dead buttons.
        if let leading = group.members.max(by: { $0.cpuPercent < $1.cpuPercent }) {
            Divider()
            Button(String(localized: "Quit…", comment: "Context action")) {
                quitIntent = .quit(leading)
            }
            Button(String(localized: "Force Quit…", comment: "Context action"), role: .destructive) {
                quitIntent = .forceQuit(leading)
            }
        }
    }

    private func tableValue(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}
