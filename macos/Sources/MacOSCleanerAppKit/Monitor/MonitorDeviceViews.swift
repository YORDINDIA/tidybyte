import MacOSCleanerCore
import SwiftUI

// MARK: - Sound

struct SoundTabView: View {
    let model: MonitorModel
    /// Bridges the slider between ticks so dragging does not snap back until
    /// the next probe reading confirms the hardware value.
    @State private var volumeOverride: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if let audio = model.snapshot?.audio {
                HStack(spacing: Spacing.elementNormal) {
                    deviceTile(
                        title: String(localized: "Output", comment: "Sound tile"),
                        icon: "speaker.wave.2", name: audio.outputName, volume: audio.outputVolume,
                        muted: audio.outputMuted)
                    deviceTile(
                        title: String(localized: "Microphone", comment: "Sound tile"),
                        icon: "mic", name: audio.inputName, volume: nil, muted: audio.inputMuted,
                        badge: audio.isMicrophoneActive
                            ? String(localized: "Live", comment: "Mic active badge") : nil)
                }
                outputControls(audio)
                appActivityList(audio)
            }
        }
    }

    /// The one volume control macOS gives apps: the default output device.
    /// Controls disable themselves while the probe cannot read the device.
    private func outputControls(_ audio: AudioReading) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(String(localized: "Output volume", comment: "Sound control heading"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.elementNormal) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { volumeOverride ?? audio.outputVolume ?? 0 },
                    set: { newValue in
                        volumeOverride = newValue
                        _ = AudioProbe.setOutputVolume(newValue)
                    }
                ), in: 0...1)
                .disabled(audio.outputVolume == nil)
                .accessibilityLabel(String(localized: "Output volume", comment: "Sound control heading"))
                .accessibilityValue(MetricFormatting.percent(volumeOverride ?? audio.outputVolume ?? 0))
                Image(systemName: (audio.outputMuted ?? false) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Toggle(String(localized: "Mute", comment: "Sound mute toggle"), isOn: Binding(
                    get: { audio.outputMuted ?? false },
                    set: { _ = AudioProbe.setOutputMuted($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(audio.outputMuted == nil)
            }
        }
        .padding(Spacing.cardInternal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(.background.secondary))
        .onChange(of: audio.outputVolume) { _, reading in
            volumeOverride = reading
        }
    }

    private func deviceTile(
        title: String, icon: String, name: String?, volume: Double?, muted: Bool?, badge: String? = nil
    ) -> some View {
        MetricTileView(
            title: title, icon: icon,
            value: volume.map { MetricFormatting.percent($0) } ?? "—",
            unit: nil,
            context: [name, muted == true ? String(localized: "Muted", comment: "Audio muted") : nil, badge]
                .compactMap { $0 }
                .joined(separator: " · "),
            tint: MonitorTab.sound.tint)
    }

    /// Which apps are audible or recording right now. macOS does not let one
    /// app set another's volume, so the list reports activity and links to the
    /// app rather than promising sliders it cannot honor.
    private func appActivityList(_ audio: AudioReading) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(String(localized: "Playing or recording now", comment: "Audio apps heading"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if audio.apps.isEmpty {
                Text(String(localized: "Nothing is using sound right now.", comment: "Audio apps empty"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(audio.apps) { app in
                    HStack(spacing: Spacing.elementTight) {
                        Circle()
                            .fill(app.isMuted ? SemanticScale.success.opacity(0.4) : MonitorTab.sound.tint)
                            .frame(width: 8, height: 8)
                        Text(app.processName).font(.callout)
                        Spacer()
                        if app.isMuted {
                            Label(String(localized: "Silent", comment: "Inaudible app"), systemImage: "speaker.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(String(localized: "Audible", comment: "Audible app"), systemImage: "speaker.wave.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(String(
                    localized: "macOS does not let apps change other apps' volume; control each app from its own window.",
                    comment: "Per-app volume explanation"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Spacing.cardInternal)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(.background.secondary))
    }
}

// MARK: - Bluetooth

struct BluetoothTabView: View {
    let model: MonitorModel

    var body: some View {
        let devices = model.snapshot?.bluetooth ?? []
        if devices.isEmpty {
            ContentUnavailableView(
                    String(localized: "No Bluetooth accessories"),
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(String(
                        localized: "Paired devices show up here with their battery levels.",
                        comment: "Bluetooth empty state")))
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.elementNormal)], spacing: Spacing.elementNormal) {
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: Spacing.elementTight) {
                        Label(device.name, systemImage: "dot.radiowaves.left.and.right")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if device.isConnected {
                            if device.batteryLevels.isEmpty {
                                Text(String(localized: "Connected", comment: "Bluetooth connected, no battery"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(device.batteryLevels.sorted(by: { $0.key < $1.key }), id: \.key) { label, level in
                                    HStack {
                                        Text(label).font(.caption).foregroundStyle(.secondary)
                                        ProgressBarView(fraction: level, tint: level > 0.2 ? SemanticScale.success : SemanticScale.error)
                                            .frame(maxWidth: .infinity)
                                        Text(MetricFormatting.percent(level))
                                            .font(.caption.monospacedDigit())
                                    }
                                }
                            }
                        } else {
                            Text(String(localized: "Not connected", comment: "Bluetooth disconnected"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(Spacing.cardInternal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .monitorCard()
                }
            }
        }
    }
}

// MARK: - Projects (dev servers)

struct ProjectsTabView: View {
    let model: MonitorModel

    var body: some View {
        let servers = model.snapshot?.devServers ?? []
        if servers.isEmpty {
            ContentUnavailableView(
                    String(localized: "No dev servers"),
                    systemImage: "curlybraces.square",
                    description: Text(String(
                        localized: "Listening servers on your projects show up here, idle ones pointed out.",
                        comment: "Projects empty state")))
        } else {
            let grouped = Dictionary(grouping: servers, by: { $0.project })
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                ForEach(grouped.keys.sorted(), id: \.self) { project in
                    VStack(alignment: .leading, spacing: Spacing.elementTight) {
                        Label(project, systemImage: "curlybraces.square")
                            .font(.callout.weight(.medium))
                        ForEach(grouped[project] ?? []) { server in
                            HStack {
                                if server.isIdle {
                                    Text(String(localized: "Idle", comment: "Idle server badge"))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(SemanticScale.warningSoft))
                                        .foregroundStyle(SemanticScale.warning)
                                }
                                Text("\(server.processName) · :\(server.port.formatted(.number.grouping(.never)))")
                                    .font(.callout.monospacedDigit())
                                Spacer()
                                Text(MetricFormatting.value(server.cpuPercent, metric: .cpu))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(Spacing.cardInternal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .monitorCard()
                }
            }
        }
    }

}

// MARK: - Agents

struct AgentsTabView: View {
    let model: MonitorModel

    var body: some View {
        let agents = model.snapshot?.agents ?? []
        if agents.isEmpty {
            ContentUnavailableView(
                    String(localized: "No coding agents running"),
                    systemImage: "sparkles",
                    description: Text(String(
                        localized: "Agent CLIs appear here with their project, what they started, and any local plan usage.",
                        comment: "Agents empty state")))
        } else {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                ForEach(agents) { agent in
                    VStack(alignment: .leading, spacing: Spacing.elementTight) {
                        HStack {
                            Label(agent.kind.displayName, systemImage: "sparkles")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text(MetricFormatting.value(agent.cpuPercent, metric: .cpu))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let root = agent.projectRoot {
                            Text(root)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if !agent.children.isEmpty {
                            Text(String(localized: "Started \(agent.children.count) processes", comment: "Agent children count"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(agent.children.prefix(6).map(\.name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if let usage = agent.usage {
                            usageRow(usage)
                        }
                    }
                    .padding(Spacing.cardInternal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .monitorCard()
                }
            }
        }
    }

    @ViewBuilder
    private func usageRow(_ usage: AgentUsageReading) -> some View {
        HStack {
            Text(usage.planName).font(.caption.weight(.medium))
            if let fraction = usage.usedFraction {
                ProgressBarView(fraction: fraction, tint: fraction > 0.85 ? SemanticScale.warning : MonitorTab.agents.tint)
                    .frame(maxWidth: 160)
                Text(MetricFormatting.percent(fraction))
                    .font(.caption.monospacedDigit())
            }
            Spacer()
            if let resetsAt = usage.resetsAt {
                Text(String(localized: "Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))", comment: "Usage reset time"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Containers

struct ContainersTabView: View {
    let model: MonitorModel
    @State private var sort: ContainerSort = .cpu

    enum ContainerSort: String, CaseIterable, Identifiable {
        case cpu, memory, name
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cpu: String(localized: "Sort by CPU", comment: "Container sort menu")
            case .memory: String(localized: "Sort by memory", comment: "Container sort menu")
            case .name: String(localized: "Sort by name", comment: "Container sort menu")
            }
        }
    }

    var body: some View {
        let containers = sortedContainers
        if containers.isEmpty {
            ContentUnavailableView(
                    String(localized: "No containers"),
                    systemImage: "shippingbox",
                    description: Text(String(
                        localized: "Running containers appear here with memory, CPU, and ports. Docker Desktop must be running.",
                        comment: "Containers empty state")))
        } else {
            HStack {
                Menu {
                    Picker(String(localized: "Sort", comment: "Sort menu title"), selection: $sort) {
                        ForEach(ContainerSort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(String(localized: "Sort", comment: "Sort menu title"), systemImage: "arrow.up.arrow.down")
                }
                .help(String(localized: "Order containers by a metric", comment: "Container sort help"))
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Spacing.elementNormal)], spacing: Spacing.elementNormal) {
                ForEach(containers) { container in
                    VStack(alignment: .leading, spacing: Spacing.elementTight) {
                        HStack {
                            Text(container.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(container.state)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(SemanticScale.successSoft))
                                .foregroundStyle(SemanticScale.success)
                        }
                        Text(container.image)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack {
                            Label(container.memoryBytes.formattedByteCount, systemImage: "memorychip")
                            Spacer()
                            Label(MetricFormatting.value(container.cpuPercent, metric: .cpu), systemImage: "cpu")
                        }
                        .font(.caption.monospacedDigit())
                        if !container.ports.isEmpty {
                            Text(container.ports.joined(separator: "  "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(Spacing.cardInternal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .monitorCard()
                }
            }
        }
    }

    private var sortedContainers: [ContainerReading] {
        let containers = model.snapshot?.containers ?? []
        switch sort {
        case .cpu: return containers.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return containers.sorted { $0.memoryBytes > $1.memoryBytes }
        case .name: return containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
