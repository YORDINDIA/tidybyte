import MacOSCleanerCore
import SwiftUI

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

        var isForce: Bool {
            switch self {
            case .quit: false
            case .forceQuit: true
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
            rows(groups, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
        }
        .sheet(item: $quitIntent) { intent in
            QuitConfirmView(
                sample: intent.sample,
                showsForceQuit: true,
                onQuit: { model.quit(pid: intent.sample.pid, force: false) },
                onForceQuit: { model.quit(pid: intent.sample.pid, force: true) })
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
        // The catalog already orders user apps first, busiest first; re-sort
        // only when the user asked for a different key.
        switch sort {
        case .cpu, .name:
            break
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

    private var header: some View {
        HStack {
            Text(String(localized: "Apps", comment: "Process table heading"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
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
            Picker(String(localized: "Group", comment: "Grouping picker"), selection: Binding(
                get: { model.groupingMode },
                set: { model.setGroupingMode($0) }
            )) {
                Text(String(localized: "By App", comment: "Grouping mode")).tag(AppProcessCatalog.GroupingMode.byApp)
                Text(String(localized: "By Process", comment: "Grouping mode")).tag(AppProcessCatalog.GroupingMode.byProcess)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            Spacer()
            if let snapshot = model.snapshot {
                Text(String(
                    localized: "\(snapshot.groups.count) apps · \(snapshot.processes.count) processes",
                    comment: "Process count footer"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func rows(_ groups: [AppProcessGroup], cpuMaximum: Double, memoryMaximum: Double) -> some View {
        let shown = groups.prefix(Self.rowLimit)
        return VStack(spacing: 0) {
            ForEach(shown) { group in
                row(group, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
                if group.id != shown.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
            if groups.count > shown.count {
                footer(shown: shown.count, total: groups.count)
            }
        }
        .monitorCard()
    }

    /// Tells people why the list stops at the cap, and what to do about it.
    private func footer(shown: Int, total: Int) -> some View {
        Text(String(
            localized: "Showing \(shown) of \(total) apps — search to narrow.",
            comment: "Process table row cap footer"))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.elementTight)
    }

    private func row(_ group: AppProcessGroup, cpuMaximum: Double, memoryMaximum: Double) -> some View {
        let isSelected = model.selectedGroupID == group.id
        return Button {
            model.select(group: group)
        } label: {
            HStack(spacing: Spacing.elementNormal) {
                MonitorAppIconView(bundlePath: group.bundlePath, name: group.name)
                    .frame(width: 22, height: 22)
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
                .frame(width: 190, alignment: .leading)
                ProgressBarView(fraction: min(1, group.cpuPercent / cpuMaximum), tint: MonitorTab.cpu.tint)
                    .frame(maxWidth: .infinity)
                tableValue(MetricFormatting.value(group.cpuPercent, metric: .cpu), width: 64)
                ProgressBarView(fraction: Double(group.memoryBytes) / memoryMaximum, tint: MonitorTab.memory.tint)
                    .frame(maxWidth: .infinity)
                tableValue(MetricFormatting.byteCount(group.memoryBytes), width: 84)
                tableValue(
                    MetricFormatting.rate(group.downloadPerSecond) + " ↓", width: 96)
                tableValue(
                    MetricFormatting.rate(group.diskReadPerSecond + group.diskWritePerSecond), width: 96)
                tableValue(MetricFormatting.energy(group.energyIndex), width: 56)
            }
            .padding(.horizontal, Spacing.cardInternal)
            .padding(.vertical, model.settings.isCompactDensity ? 4 : 7)
            .contentShape(Rectangle())
            .background(isSelected ? Primary.selection : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
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
        .help(group.name)
    }

    private func tableValue(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

/// The quit confirmation sheet the safety rules require before any signal.
/// Cancel only dismisses; the explicit Quit and Force Quit buttons perform.
struct QuitConfirmView: View {
    let sample: ProcessSample
    var showsForceQuit = false
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            Label(sample.name, systemImage: "power.dotted")
                .font(.headline)
            Text(String(
                localized: "Do you want to quit “\(sample.name)”? Unsaved work in this app could be lost.",
                comment: "Quit confirmation body"))
                .font(.callout)
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Dialog cancel")) {
                    // Dismissal only — nothing is signalled.
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if showsForceQuit {
                    Button(String(localized: "Force Quit", comment: "Dialog destructive"), role: .destructive) {
                        onForceQuit()
                        dismiss()
                    }
                }
                Button(String(localized: "Quit", comment: "Dialog confirm quit"), role: .destructive) {
                    onQuit()
                    dismiss()
                }
            }
        }
        .padding(Spacing.elementSection)
        .frame(width: 360)
    }
}

/// The inspector: identity, signature, parentage, command line, resources,
/// open files, and ports for the selected app's main process. Quitting always
/// goes through a confirmation dialog — the model never signals unasked.
struct ProcessInspectorView: View {
    let inspection: ProcessInspection
    /// Per-app CPU history behind the "Last 24 hours" sparkline.
    var history: [MetricsHistoryStore.SeriesPoint] = []
    let onQuit: (pid_t, Bool) -> Void
    @State private var confirmQuit = false
    @State private var confirmForce = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                header
                historySection
                identitySection
                signatureSection
                resourcesSection
                commandLineSection
                filesSection
                portsSection
            }
            .padding(Spacing.elementNormal)
        }
        .confirmationDialog(
            String(
                localized: "Quit \(processName)?", comment: "Quit dialog title"
            ),
            isPresented: $confirmQuit,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Quit", comment: "Confirm quit"), role: .destructive) {
                onQuit(inspection.pid, false)
            }
            Button(String(localized: "Cancel", comment: "Dialog cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "The app is asked to quit normally. Unsaved work could be lost.", comment: "Quit warning"))
        }
        .confirmationDialog(
            String(
                localized: "Force quit \(processName)?", comment: "Force quit dialog title"
            ),
            isPresented: $confirmForce,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Force Quit", comment: "Confirm force quit"), role: .destructive) {
                onQuit(inspection.pid, true)
            }
            Button(String(localized: "Cancel", comment: "Dialog cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "The process is killed immediately. Unsaved work is lost.", comment: "Force quit warning"))
        }
    }

    /// The process's file name for dialogs, falling back to the pid.
    private var processName: String {
        inspection.commandLine.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? String(localized: "pid \(inspection.pid)", comment: "Process identifier fallback")
    }

    /// The selected app's recent CPU, when the history store has points for it.
    @ViewBuilder
    private var historySection: some View {
        if history.count > 1 {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                Text(String(localized: "Last 24 hours", comment: "Per-app history heading"))
                    .font(.callout.weight(.medium))
                SparklineView(
                    points: history.map { ($0.timestamp, $0.average) },
                    tint: MonitorTab.cpu.tint)
                    .frame(height: 44)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "CPU over the last 24 hours", comment: "History chart label"))
        }
    }

    private var header: some View {
        HStack {
            Text(String(localized: "pid \(inspection.pid)", comment: "Inspector process identifier"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Quit", comment: "Inspector action")) {
                confirmQuit = true
            }
            Button(String(localized: "Force Quit", comment: "Inspector action"), role: .destructive) {
                confirmForce = true
            }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            let parent = inspection.parentName.map {
                String(localized: "\($0) (pid \(inspection.parentPID))", comment: "Parent process with identifier")
            } ?? String(localized: "pid \(inspection.parentPID)", comment: "Process identifier fallback")
            row(String(localized: "Parent", comment: "Inspector row"), parent)
            row(String(localized: "Children", comment: "Inspector row"), String(inspection.children.count))
            if let path = inspection.executablePath {
                Text(path).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let bundleID = inspection.bundleID {
                row(String(localized: "Bundle ID", comment: "Inspector row"), bundleID)
            }
            if let version = inspection.version {
                row(String(localized: "Version", comment: "Inspector row"), version)
            }
            if let started = inspection.startedAt {
                row(
                    String(localized: "Started", comment: "Inspector row"),
                    started.formatted(date: .abbreviated, time: .standard))
            }
        }
    }

    @ViewBuilder
    private var signatureSection: some View {
        if let signature = inspection.signature {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    if signature.isSigned {
                        Label(
                            signature.isValid
                                ? String(localized: "Signed and valid", comment: "Signature status")
                                : String(localized: "Signed, check failed", comment: "Signature status"),
                            systemImage: signature.isValid ? "checkmark.seal" : "exclamationmark.seal")
                    } else {
                        Label(String(localized: "Unsigned", comment: "Signature status"), systemImage: "seal")
                    }
                    if let team = signature.teamID {
                        Text(team).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if signature.isSandboxed {
                        Text(String(localized: "Sandboxed", comment: "Sandbox badge"))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Primary.selection))
                    }
                }
                .font(.callout)
                ForEach(signature.entitlements.sorted(by: { $0.key < $1.key }).prefix(6), id: \.key) { key, value in
                    Text("\(key) = \(value)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            row(
                String(localized: "CPU time", comment: "Inspector row"),
                String(localized: "\(MetricFormatting.seconds(inspection.cpuTimeSeconds)) s", comment: "CPU time"))
            row(String(localized: "Memory", comment: "Inspector row"), MetricFormatting.byteCount(inspection.residentBytes))
            row(String(localized: "Footprint", comment: "Inspector row"), MetricFormatting.byteCount(inspection.footprintBytes))
            row(String(localized: "Disk read", comment: "Inspector row"), MetricFormatting.byteCount(inspection.diskReadBytes))
            row(String(localized: "Disk written", comment: "Inspector row"), MetricFormatting.byteCount(inspection.diskWrittenBytes))
        }
    }

    @ViewBuilder
    private var commandLineSection: some View {
        if !inspection.commandLine.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Command line", comment: "Inspector section"))
                    .font(.callout.weight(.medium))
                ForEach(Array(inspection.commandLine.prefix(12).enumerated()), id: \.offset) { _, argument in
                    Text(argument)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(String(localized: "Open files", comment: "Inspector section"))
                .font(.callout.weight(.medium))
            if inspection.openFiles.isEmpty {
                Text(String(localized: "None visible to this user.", comment: "No open files"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(inspection.openFiles.prefix(30)) { file in
                    Text("\(file.kind) · \(file.path)")
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                }
            }
        }
    }

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(String(localized: "Listening ports", comment: "Inspector section"))
                .font(.callout.weight(.medium))
            if inspection.listeningPorts.isEmpty {
                Text(String(localized: "No open ports.", comment: "No ports"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(inspection.listeningPorts) { port in
                    Text("\(port.kind) \(port.address):\(port.port)")
                        .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        } label: {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
