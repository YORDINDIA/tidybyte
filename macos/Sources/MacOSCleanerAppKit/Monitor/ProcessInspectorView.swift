import MacOSCleanerCore
import SwiftUI

/// The quit confirmation sheet required before any process signal.
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
            if sample.startedAt == nil {
                Text(ProcessInspectorView.unknownStartMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Dialog cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if showsForceQuit {
                    Button(String(localized: "Force Quit", comment: "Dialog destructive"), role: .destructive) {
                        onForceQuit()
                        dismiss()
                    }
                    .disabled(sample.startedAt == nil)
                }
                Button(String(localized: "Quit", comment: "Dialog confirm quit"), role: .destructive) {
                    onQuit()
                    dismiss()
                }
                .disabled(sample.startedAt == nil)
            }
        }
        .padding(Spacing.elementSection)
        .frame(width: 360)
    }
}

/// Process inspector: identity, signature, parentage, command line, resources,
/// open files, listening ports, and outbound network connections.
struct ProcessInspectorView: View {
    private struct PendingQuitTarget: Equatable {
        let pid: pid_t
        let startedAt: Date
        let processName: String
        let isForce: Bool
    }

    let inspection: ProcessInspection
    var history: [MetricsHistoryStore.SeriesPoint] = []
    let onQuit: (pid_t, Bool) -> Void

    @State private var pendingQuit: PendingQuitTarget?
    @State private var showsConnections = true
    @State private var showsOpenFiles = true

    init(
        inspection: ProcessInspection,
        history: [MetricsHistoryStore.SeriesPoint] = [],
        onQuit: @escaping (pid_t, Bool) -> Void
    ) {
        self.inspection = inspection
        self.history = history
        self.onQuit = onQuit
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                header
                historySection
                identitySection
                signatureSection
                resourcesSection
                commandLineSection
                connectionsSection
                portsSection
                filesSection
            }
            .padding(Spacing.elementNormal)
        }
        .onChange(of: inspection.pid) { cancelStaleQuitIfProcessChanged() }
        .onChange(of: inspection.startedAt) { cancelStaleQuitIfProcessChanged() }
        .confirmationDialog(
            String(localized: "Quit \(pendingQuit?.processName ?? processName)?", comment: "Quit dialog title"),
            isPresented: quitConfirmationPresented(force: false),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Quit", comment: "Confirm quit"), role: .destructive) {
                executeConfirmedQuit(expectingForce: false)
            }
            Button(String(localized: "Cancel", comment: "Dialog cancel"), role: .cancel) {
                pendingQuit = nil
            }
        } message: {
            Text(String(localized: "The app is asked to quit normally. Unsaved work could be lost.", comment: "Quit warning"))
        }
        .confirmationDialog(
            String(localized: "Force quit \(pendingQuit?.processName ?? processName)?", comment: "Force quit dialog title"),
            isPresented: quitConfirmationPresented(force: true),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Force Quit", comment: "Confirm force quit"), role: .destructive) {
                executeConfirmedQuit(expectingForce: true)
            }
            Button(String(localized: "Cancel", comment: "Dialog cancel"), role: .cancel) {
                pendingQuit = nil
            }
        } message: {
            Text(String(localized: "The process is killed immediately. Unsaved work is lost.", comment: "Force quit warning"))
        }
    }

    private func quitConfirmationPresented(force: Bool) -> Binding<Bool> {
        Binding(
            get: { pendingQuit?.isForce == force },
            set: { isShown in
                if !isShown { pendingQuit = nil }
            })
    }

    private func beginQuit(force: Bool) {
        guard let startedAt = inspection.startedAt else { return }
        pendingQuit = PendingQuitTarget(
            pid: inspection.pid,
            startedAt: startedAt,
            processName: processName,
            isForce: force)
    }

    private func cancelStaleQuitIfProcessChanged() {
        guard let target = pendingQuit else { return }
        if inspection.pid != target.pid || inspection.startedAt != target.startedAt {
            pendingQuit = nil
        }
    }

    private func executeConfirmedQuit(expectingForce: Bool) {
        guard let target = pendingQuit,
              target.isForce == expectingForce,
              inspection.pid == target.pid,
              inspection.startedAt == target.startedAt else {
            pendingQuit = nil
            return
        }
        pendingQuit = nil
        onQuit(target.pid, target.isForce)
    }

    private var processName: String {
        inspection.commandLine.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? String(localized: "pid \(inspection.pid)", comment: "Process identifier fallback")
    }

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
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "CPU over the last 24 hours", comment: "History chart label"))
            .accessibilityValue(HistoryChartView.summary(history, unit: .cpu))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Text(String(localized: "pid \(inspection.pid)", comment: "Inspector process identifier"))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Quit", comment: "Inspector action")) {
                    beginQuit(force: false)
                }
                .disabled(inspection.startedAt == nil)
                Button(String(localized: "Force Quit", comment: "Inspector action"), role: .destructive) {
                    beginQuit(force: true)
                }
                .disabled(inspection.startedAt == nil)
            }
            if inspection.startedAt == nil {
                Text(Self.unknownStartMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static let unknownStartMessage = String(
        localized: "The start time of this process is unavailable, so it cannot be quit safely.",
        comment: "Quit disabled: unknown process start time")
}

// MARK: - Inspector Sections

private extension ProcessInspectorView {
    var identitySection: some View {
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
    var signatureSection: some View {
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

    var resourcesSection: some View {
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
    var commandLineSection: some View {
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
}

private extension ProcessInspectorView {
    var connectionsSection: some View {
        DisclosureGroup(isExpanded: $showsConnections) {
            VStack(alignment: .leading, spacing: 4) {
                if inspection.outboundConnections.isEmpty {
                    Text(String(localized: "No active outbound connections.", comment: "No outbound connections"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(inspection.outboundConnections.prefix(50)) { connection in
                        connectionRow(connection)
                    }
                    if inspection.outboundConnections.count > 50 {
                        Text(String(
                            localized: "Showing 50 of \(inspection.outboundConnections.count) connections.",
                            comment: "Outbound connection truncation notice"))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(String(localized: "Network connections", comment: "Inspector section"))
                    .font(.callout.weight(.medium))
                Spacer()
                if !inspection.outboundConnections.isEmpty {
                    Text("\(inspection.outboundConnections.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    func connectionRow(_ connection: ProcessInspection.OutboundConnection) -> some View {
        HStack(spacing: 6) {
            Text(connection.kind)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(connection.remoteAddress)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if let state = connection.state, !state.isEmpty {
                Text(state)
                    .font(.caption2.monospaced())
                    .foregroundStyle(connectionStateColor(state))
            }
        }
        .help("\(connection.localAddress) → \(connection.remoteAddress)")
    }

    func connectionStateColor(_ state: String) -> Color {
        switch state.uppercased() {
        case "ESTABLISHED": return SemanticScale.success
        case "CLOSE_WAIT", "TIME_WAIT", "FIN_WAIT_1", "FIN_WAIT_2": return SemanticScale.warning
        default: return .secondary
        }
    }

    var portsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(String(localized: "Listening ports", comment: "Inspector section"))
                .font(.callout.weight(.medium))
            if inspection.listeningPorts.isEmpty {
                Text(String(localized: "No open ports.", comment: "No ports"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(inspection.listeningPorts) { port in
                    Text("\(port.kind) \(port.address):\(port.port.formatted(.number.grouping(.never)))")
                        .font(.caption.monospacedDigit())
                        .textSelection(.enabled)
                }
            }
        }
    }

    var filesSection: some View {
        DisclosureGroup(isExpanded: $showsOpenFiles) {
            VStack(alignment: .leading, spacing: 4) {
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
            .padding(.top, 4)
        } label: {
            HStack {
                Text(String(localized: "Open files", comment: "Inspector section"))
                    .font(.callout.weight(.medium))
                Spacer()
                if !inspection.openFiles.isEmpty {
                    Text("\(inspection.openFiles.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    func row(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.callout.monospacedDigit())
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
