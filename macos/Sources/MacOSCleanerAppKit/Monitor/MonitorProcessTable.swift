import MacOSCleanerCore
import SwiftUI

/// Width tiers so narrower windows drop rightmost columns before clipping.
enum ProcessTableTier: CaseIterable {
    case wide, full, medium, compact

    var showsSeparateUpload: Bool { self == .wide }
    var showsNetwork: Bool { self == .wide || self == .full || self == .medium }
    var showsDisk: Bool { self == .wide || self == .full }
    var showsEnergy: Bool { self != .compact }
}

private enum ProcessTableWidth {
    static let icon: CGFloat = 22
    static let name: CGFloat = 164
    static let bar: CGFloat = 28
    static let cpu: CGFloat = 56
    static let memory: CGFloat = 76
    static let network: CGFloat = 92
    static let upload: CGFloat = 84
    static let disk: CGFloat = 82
    static let energy: CGFloat = 48
}

/// The apps / processes table below every monitor tab.
struct ProcessTableView: View {
    @Bindable var model: MonitorModel
    @State private var quitIntent: QuitIntent?
    @State private var sort: SortField = .cpu
    @State private var sortAscending = false
    @State private var filter: GroupFilter = .all

    enum SortField: String, CaseIterable, Identifiable {
        case cpu, memory, disk, network, upload, energy, name
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cpu: String(localized: "Sort by CPU", comment: "Sort menu")
            case .memory: String(localized: "Sort by memory", comment: "Sort menu")
            case .disk: String(localized: "Sort by disk", comment: "Sort menu")
            case .network: String(localized: "Sort by network", comment: "Sort menu")
            case .upload: String(localized: "Sort by upload", comment: "Sort menu")
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

    enum QuitIntent: Identifiable {
        case quit(ProcessSample)
        case forceQuit(ProcessSample)

        var id: String {
            let stamp = sample.startedAt?.timeIntervalSince1970 ?? -1
            switch self {
            case .quit(let sample): return "quit-\(sample.pid)-\(stamp)"
            case .forceQuit(let sample): return "force-\(sample.pid)-\(stamp)"
            }
        }

        var sample: ProcessSample {
            switch self {
            case .quit(let sample), .forceQuit(let sample): return sample
            }
        }
    }

    private static let rowLimit = 40

    var body: some View {
        let groups = filteredGroups
        let cpuMaximum = max(groups.map(\.cpuPercent).filter(\.isFinite).max() ?? 1, 1)
        let memoryMaximum = max(Double(groups.map(\.memoryBytes).max() ?? 1), 1)
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            header(filteredCount: groups.count)
            ViewThatFits(in: .horizontal) {
                table(groups, tier: .wide, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
                table(groups, tier: .full, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
                table(groups, tier: .medium, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
                ScrollView(.horizontal) {
                    table(groups, tier: .compact, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
                }
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
}

// MARK: - Sorting & Filtering

private extension ProcessTableView {
    var filteredGroups: [AppProcessGroup] {
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
        return groups.sorted { compareGroups($0, $1) }
    }

    func compareGroups(_ lhs: AppProcessGroup, _ rhs: AppProcessGroup) -> Bool {
        switch sort {
        case .cpu:
            if !sortAscending, lhs.kind != rhs.kind { return lhs.kind.rank < rhs.kind.rank }
            return compareNumeric(lhs.cpuPercent, rhs.cpuPercent, lhs: lhs, rhs: rhs)
        case .name:
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame {
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
            return lhs.id < rhs.id
        case .memory:
            return compareNumeric(Double(lhs.memoryBytes), Double(rhs.memoryBytes), lhs: lhs, rhs: rhs)
        case .disk:
            return compareNumeric(
                lhs.diskReadPerSecond + lhs.diskWritePerSecond,
                rhs.diskReadPerSecond + rhs.diskWritePerSecond, lhs: lhs, rhs: rhs)
        case .network:
            return compareNumeric(
                lhs.downloadPerSecond + lhs.uploadPerSecond,
                rhs.downloadPerSecond + rhs.uploadPerSecond, lhs: lhs, rhs: rhs)
        case .upload:
            return compareNumeric(lhs.uploadPerSecond, rhs.uploadPerSecond, lhs: lhs, rhs: rhs)
        case .energy:
            return compareNumeric(lhs.energyIndex, rhs.energyIndex, lhs: lhs, rhs: rhs)
        }
    }

    func compareNumeric(_ left: Double, _ right: Double, lhs: AppProcessGroup, rhs: AppProcessGroup) -> Bool {
        if left != right {
            return sortAscending ? left < right : left > right
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    func selectSort(_ field: SortField) {
        if sort == field {
            sortAscending.toggle()
        } else {
            sort = field
            sortAscending = (field == .name)
        }
    }
}

// MARK: - Header & Table Rows

private extension ProcessTableView {
    func header(filteredCount: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Text(model.groupingMode == .byProcess
                    ? String(localized: "Processes", comment: "Process table heading in by-process mode")
                    : String(localized: "Apps", comment: "Process table heading in by-app mode"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let snapshot = model.snapshot {
                    Text(countSummary(snapshot: snapshot, filteredCount: filteredCount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            controlsRow
        }
    }

    func countSummary(snapshot: SystemSnapshot, filteredCount: Int) -> String {
        if model.groupingMode == .byProcess {
            return MetricFormatting.processCount(filteredCount)
        }
        let apps = MetricFormatting.appCount(snapshot.groups.count)
        let procs = MetricFormatting.processCount(snapshot.processes.count)
        return String(localized: "\(apps) · \(procs)", comment: "Process count footer")
    }

    var controlsRow: some View {
        HStack(spacing: Spacing.elementTight) {
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
                ForEach(SortField.allCases) { field in
                    Button {
                        selectSort(field)
                    } label: {
                        if sort == field {
                            Label(field.label, systemImage: sortAscending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(field.label)
                        }
                    }
                }
            } label: {
                Label(String(localized: "Sort", comment: "Sort menu title"), systemImage: "arrow.up.arrow.down")
            }
            .help(String(localized: "Order the rows by a metric or name", comment: "Sort help"))

            Button {
                sortAscending.toggle()
            } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
            }
            .help(sortAscending
                ? String(localized: "Sorted ascending. Click to sort descending.", comment: "Sort direction toggle")
                : String(localized: "Sorted descending. Click to sort ascending.", comment: "Sort direction toggle"))
            .accessibilityLabel(sortAscending
                ? String(localized: "Sort descending", comment: "Sort direction a11y")
                : String(localized: "Sort ascending", comment: "Sort direction a11y"))

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

    func table(_ groups: [AppProcessGroup], tier: ProcessTableTier, cpuMaximum: Double, memoryMaximum: Double) -> some View {
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

    func columnHeader(_ tier: ProcessTableTier) -> some View {
        HStack(spacing: Spacing.elementTight) {
            sortHeaderButton(
                model.groupingMode == .byProcess
                    ? String(localized: "Process", comment: "Process table column")
                    : String(localized: "App", comment: "Process table column"),
                field: .name,
                width: ProcessTableWidth.icon + ProcessTableWidth.name + Spacing.elementNormal,
                alignment: .leading)
            Spacer(minLength: ProcessTableWidth.bar)
            sortHeaderButton(
                String(localized: "CPU", comment: "Process table column"),
                field: .cpu, width: ProcessTableWidth.cpu)
            Spacer(minLength: ProcessTableWidth.bar)
            sortHeaderButton(
                String(localized: "Memory", comment: "Process table column"),
                field: .memory, width: ProcessTableWidth.memory)
            if tier.showsSeparateUpload {
                sortHeaderButton(
                    String(localized: "Download", comment: "Process table column"),
                    field: .network, width: ProcessTableWidth.network)
                sortHeaderButton(
                    String(localized: "Upload", comment: "Process table column"),
                    field: .upload, width: ProcessTableWidth.upload)
            } else if tier.showsNetwork {
                sortHeaderButton(
                    String(localized: "Network", comment: "Process table column"),
                    field: .network, width: ProcessTableWidth.network)
            }
            if tier.showsDisk {
                sortHeaderButton(
                    String(localized: "Disk", comment: "Process table column"),
                    field: .disk, width: ProcessTableWidth.disk)
            }
            if tier.showsEnergy {
                sortHeaderButton(
                    String(localized: "Energy", comment: "Process table column"),
                    field: .energy, width: ProcessTableWidth.energy)
            }
        }
        .padding(.horizontal, Spacing.cardInternal)
        .padding(.vertical, Spacing.elementTight)
    }

    func sortHeaderButton(
        _ text: String, field: SortField, width: CGFloat? = nil, alignment: Alignment = .trailing
    ) -> some View {
        Button {
            selectSort(field)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(text)
                    .font(.caption.weight(sort == field ? .semibold : .medium))
                    .foregroundStyle(sort == field ? .primary : .tertiary)
                    .lineLimit(1)
                if sort == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var emptyMessage: some View {
        Text(emptyMessageText)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(Spacing.cardInternal)
    }

    var emptyMessageText: String {
        let isSearching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        if model.groupingMode == .byProcess {
            return isSearching
                ? String(localized: "No processes match the search.", comment: "Process table empty search (by process)")
                : String(localized: "No processes in this filter.", comment: "Process table empty filter (by process)")
        }
        return isSearching
            ? String(localized: "No apps match the search.", comment: "Process table empty search")
            : String(localized: "No apps in this filter.", comment: "Process table empty filter")
    }

    func footer(shown: Int, total: Int) -> some View {
        let message = model.groupingMode == .byProcess
            ? String(
                localized: "Showing \(shown) of \(total) processes. Search to narrow the list.",
                comment: "Process table row cap footer (by process)")
            : String(
                localized: "Showing \(shown) of \(total) apps. Search to narrow the list.",
                comment: "Process table row cap footer (by app)")
        return Text(message)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.elementTight)
    }

    func row(_ group: AppProcessGroup, tier: ProcessTableTier, cpuMaximum: Double, memoryMaximum: Double) -> some View {
        let isSelected = model.selectedGroupID == group.id
        return Button {
            model.select(group: group)
        } label: {
            HStack(spacing: Spacing.elementTight) {
                nameCell(group)
                ProgressBarView(fraction: group.cpuPercent / cpuMaximum, tint: MonitorTab.cpu.tint)
                    .frame(minWidth: ProcessTableWidth.bar, maxWidth: .infinity)
                tableValue(MetricFormatting.value(group.cpuPercent, metric: .cpu), width: ProcessTableWidth.cpu)
                ProgressBarView(fraction: Double(group.memoryBytes) / memoryMaximum, tint: MonitorTab.memory.tint)
                    .frame(minWidth: ProcessTableWidth.bar, maxWidth: .infinity)
                tableValue(MetricFormatting.byteCount(group.memoryBytes), width: ProcessTableWidth.memory)
                networkCells(group, tier: tier)
                if tier.showsDisk {
                    tableValue(
                        MetricFormatting.rate(group.diskReadPerSecond + group.diskWritePerSecond),
                        width: ProcessTableWidth.disk)
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

    @ViewBuilder
    func networkCells(_ group: AppProcessGroup, tier: ProcessTableTier) -> some View {
        if tier.showsSeparateUpload {
            tableValue("↓ \(MetricFormatting.rate(group.downloadPerSecond))", width: ProcessTableWidth.network)
            tableValue("↑ \(MetricFormatting.rate(group.uploadPerSecond))", width: ProcessTableWidth.upload)
        } else if tier.showsNetwork {
            VStack(alignment: .trailing, spacing: 1) {
                Text("↓ \(MetricFormatting.rate(group.downloadPerSecond))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("↑ \(MetricFormatting.rate(group.uploadPerSecond))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: ProcessTableWidth.network, alignment: .trailing)
        }
    }

    func nameCell(_ group: AppProcessGroup) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            MonitorAppIconView(bundlePath: group.bundlePath)
                .frame(width: ProcessTableWidth.icon, height: ProcessTableWidth.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(.callout, design: .default).weight(.medium))
                    .lineLimit(1)
                if group.members.count > 1 {
                    Text(MetricFormatting.processCount(group.members.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: ProcessTableWidth.name, alignment: .leading)
        }
    }

    @ViewBuilder
    func rowMenu(_ group: AppProcessGroup) -> some View {
        Button(String(localized: "Inspect", comment: "Context action")) { model.select(group: group) }
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

    func tableValue(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}
