import Foundation
import os

/// Watches snapshots for misbehaving apps — sustained high CPU, fast memory
/// growth, heavy disk or network — and raises one notification per finding,
/// with a cooldown so an app cannot spam. All thresholds come from settings.
public actor AlertEngine {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "AlertEngine")
    private var settings: AlertThresholds
    private let notifier: AlertNotifier

    /// Sliding windows per app, keyed by app id.
    private var cpuWindows: [String: CPUWindow] = [:]
    private var memoryBaselines: [String: (value: Int64, at: Date)] = [:]
    private var lastRaised: [String: Date] = [:]

    public init(settings: AlertThresholds, notifier: AlertNotifier) {
        self.settings = settings
        self.notifier = notifier
    }

    public struct AlertThresholds: Sendable {
        public var isEnabled: Bool
        public var cpuPercent: Double
        public var cpuWindowMinutes: Double
        public var memoryGrowthBytes: Int64
        public var diskBytesPerSecond: Double
        public var networkBytesPerSecond: Double
        /// Minimum minutes between two alerts about the same app.
        public var cooldownMinutes: Double

        public init(
            isEnabled: Bool, cpuPercent: Double, cpuWindowMinutes: Double, memoryGrowthBytes: Int64,
            diskBytesPerSecond: Double, networkBytesPerSecond: Double, cooldownMinutes: Double = 30
        ) {
            self.isEnabled = isEnabled
            self.cpuPercent = cpuPercent
            self.cpuWindowMinutes = cpuWindowMinutes
            self.memoryGrowthBytes = memoryGrowthBytes
            self.diskBytesPerSecond = diskBytesPerSecond
            self.networkBytesPerSecond = networkBytesPerSecond
            self.cooldownMinutes = cooldownMinutes
        }
    }

    /// Delivers a finding. Protocol-injected so tests can capture instead.
    public protocol AlertNotifier: Sendable {
        func raise(_ finding: Finding) async
    }

    public struct Finding: Sendable, Equatable {
        public enum Kind: String, CaseIterable, Sendable { case cpu, memory, disk, network }

        public var kind: Kind
        public var appName: String
        public var detail: String
        public var bundleID: String?
    }

    /// Swaps in new thresholds from Settings; windows and cooldowns persist.
    public func updateThresholds(_ thresholds: AlertThresholds) {
        settings = thresholds
    }

    public func evaluate(_ snapshot: SystemSnapshot) async {
        guard settings.isEnabled, !snapshot.groups.isEmpty else { return }
        let findings = Self.findings(
            in: snapshot, thresholds: settings,
            cpuWindows: &cpuWindows, memoryBaselines: &memoryBaselines, now: snapshot.timestamp)
        for finding in findings where isCool(finding: finding, at: snapshot.timestamp) {
            lastRaised[cooldownKey(finding)] = snapshot.timestamp
            await notifier.raise(finding)
        }
        Self.pruneStaleState(
            cpuWindows: &cpuWindows, memoryBaselines: &memoryBaselines, lastRaised: &lastRaised,
            groups: snapshot.groups, now: snapshot.timestamp)
    }

    /// Bounds the per-app state so a long session cannot grow it forever:
    /// entries leave when their app leaves the snapshot, and baselines and
    /// cooldowns expire after 2 and 24 hours respectively. Pure so tests can
    /// drive it.
    static func pruneStaleState(
        cpuWindows: inout [String: CPUWindow], memoryBaselines: inout [String: (value: Int64, at: Date)],
        lastRaised: inout [String: Date], groups: [AppProcessGroup], now: Date
    ) {
        let liveKeys = Set(groups.map { $0.bundleID ?? $0.name })
        cpuWindows = cpuWindows.filter { liveKeys.contains($0.key) }
        memoryBaselines = memoryBaselines.filter {
            liveKeys.contains($0.key) && now.timeIntervalSince($0.value.at) < 7200
        }
        // Cooldown entries carry the finding kind as a prefix, so their live
        // key set is the cartesian product of kinds and group keys.
        let cooldownKeys = Set(groups.flatMap { group in
            Finding.Kind.allCases.map { "\($0.rawValue)-\(group.bundleID ?? group.name)" }
        })
        lastRaised = lastRaised.filter {
            cooldownKeys.contains($0.key) && now.timeIntervalSince($0.value) < 86_400
        }
    }

    private func isCool(finding: Finding, at date: Date) -> Bool {
        guard let last = lastRaised[cooldownKey(finding)] else { return true }
        return date.timeIntervalSince(last) > settings.cooldownMinutes * 60
    }

    private func cooldownKey(_ finding: Finding) -> String {
        "\(finding.kind.rawValue)-\(finding.bundleID ?? finding.appName)"
    }

    // MARK: - Pure evaluation (testable)

    /// Finds alert-worthy apps in one snapshot. Mutating the windows here
    /// keeps the sliding state in one place.
    static func findings(
        in snapshot: SystemSnapshot, thresholds: AlertThresholds,
        cpuWindows: inout [String: CPUWindow], memoryBaselines: inout [String: (value: Int64, at: Date)],
        now: Date
    ) -> [Finding] {
        var findings: [Finding] = []
        let window = thresholds.cpuWindowMinutes * 60
        for group in snapshot.groups {
            let key = group.bundleID ?? group.name
            findings.append(
                contentsOf: cpuFindings(
                    group: group, thresholds: thresholds, window: window, cpuWindows: &cpuWindows, now: now))
            findings.append(
                contentsOf: growthFinding(
                    group: group, thresholds: thresholds,
                    memoryBaselines: &memoryBaselines, now: now))
            findings.append(contentsOf: rateFindings(group: group, thresholds: thresholds))
        }
        return findings
    }

    /// Sustained CPU: the average across the window must exceed the bar.
    private static func cpuFindings(
        group: AppProcessGroup, thresholds: AlertThresholds, window: TimeInterval,
        cpuWindows: inout [String: CPUWindow], now: Date
    ) -> [Finding] {
        let key = group.bundleID ?? group.name
        var state = cpuWindows[key] ?? CPUWindow()
        state.push(cpuPercent: group.cpuPercent, at: now, window: window)
        cpuWindows[key] = state
        guard let average = state.average, average >= thresholds.cpuPercent,
            state.span >= window * 0.5 else { return [] }
        cpuWindows[key]?.clear()
        return [Finding(
            kind: .cpu, appName: group.name,
            detail: String(
                localized: "\(group.name) averaged \(Int(average))% CPU for \(Int(window / 60)) minutes.",
                comment: "CPU alert detail"),
            bundleID: group.bundleID)]
    }

    /// Memory growth: grown steadily over an hour from a baseline.
    private static func growthFinding(
        group: AppProcessGroup, thresholds: AlertThresholds,
        memoryBaselines: inout [String: (value: Int64, at: Date)], now: Date
    ) -> [Finding] {
        let key = group.bundleID ?? group.name
        let memory = group.memoryBytes
        if let baseline = memoryBaselines[key] {
            guard now.timeIntervalSince(baseline.at) >= 3600 else { return [] }
            let growth = memory - baseline.value
            memoryBaselines[key] = (value: memory, at: now)
            guard growth >= thresholds.memoryGrowthBytes else { return [] }
            return [Finding(
                kind: .memory, appName: group.name,
                detail: String(
                    localized: "\(group.name) grew by \(growth.formattedByteCount) over the last hour.",
                    comment: "Memory alert detail"),
                bundleID: group.bundleID)]
        }
        memoryBaselines[key] = (value: memory, at: now)
        return []
    }

    /// Disk and network: instantaneous hammering is worth one ping.
    private static func rateFindings(group: AppProcessGroup, thresholds: AlertThresholds) -> [Finding] {
        var findings: [Finding] = []
        if group.diskReadPerSecond + group.diskWritePerSecond >= thresholds.diskBytesPerSecond {
            findings.append(Finding(
                kind: .disk, appName: group.name,
                detail: String(
                    localized: "\(group.name) is writing to disk heavily right now.",
                    comment: "Disk alert detail"),
                bundleID: group.bundleID))
        }
        if group.downloadPerSecond + group.uploadPerSecond >= thresholds.networkBytesPerSecond {
            findings.append(Finding(
                kind: .network, appName: group.name,
                detail: String(
                    localized: "\(group.name) is moving a lot of data right now.",
                    comment: "Network alert detail"),
                bundleID: group.bundleID))
        }
        return findings
    }

    /// Rolling CPU samples for one app, bounded to the alert window.
    struct CPUWindow {
        var samples: [(at: Date, percent: Double)] = []

        var span: TimeInterval {
            guard let first = samples.first, let last = samples.last else { return 0 }
            return last.at.timeIntervalSince(first.at)
        }

        var average: Double? {
            guard !samples.isEmpty else { return nil }
            return samples.reduce(0.0) { $0 + $1.percent } / Double(samples.count)
        }

        mutating func push(cpuPercent: Double, at date: Date, window: TimeInterval) {
            samples.append((date, cpuPercent))
            let cutoff = date.addingTimeInterval(-window)
            samples.removeAll { $0.at < cutoff }
        }

        mutating func clear() {
            samples.removeAll()
        }
    }
}

/// Posts findings through the shared NotificationScheduler, which gates on a
/// real app bundle — UNUserNotificationCenter raises an uncatchable exception
/// in unbundled hosts (tests, the `tidybyte monitor` CLI).
public struct SystemAlertNotifier: AlertEngine.AlertNotifier {
    private let scheduler = NotificationScheduler()

    public init() {}

    public func raise(_ finding: AlertEngine.Finding) async {
        await scheduler.scheduleMonitorAlert(finding: finding)
    }
}
