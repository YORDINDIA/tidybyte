import MacOSCleanerCore
import SwiftUI

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
                    // MON-03: ports are identifiers — no locale digit
                    // grouping ("*:5,000" is unreadable against lsof output).
                    Text("\(port.kind) \(port.address):\(port.port.formatted(.number.grouping(.never)))")
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
