import Foundation
import os

/// Watches snapshots for misbehaving apps — sustained high CPU, fast memory
/// growth, heavy disk or network — and raises one notification per finding,
/// with a cooldown so an app cannot spam. All thresholds come from settings.
public actor AlertEngine {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "AlertEngine")
    private var settings: AlertThresholds
    private let notifier: AlertNotifier

    private var cpuWindows: [String: CPUWindow] = [:]
    private var memoryBaselines: [String: (value: Int64, at: Date)] = [:]
    private var lastRaised: [String: Date] = [:]

    public init(settings: AlertThresholds, notifier: AlertNotifier) {
        self.settings = settings
        self.notifier = notifier
    }

    public struct AlertThresholds: Sendable {
        public var isEnabled: Bool
        /// Sustained system-wide CPU share (0...100%, normalized across logical cores).
        public var cpuPercent: Double
        public var cpuWindowMinutes: Double
        public var memoryGrowthBytes: Int64
        public var diskBytesPerSecond: Double
        public var networkBytesPerSecond: Double
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

    public protocol AlertNotifier: Sendable {
        func raise(_ finding: Finding) async
    }

    public struct Finding: Sendable, Equatable {
        public enum Kind: String, CaseIterable, Sendable { case cpu, memory, disk, network }

        public var kind: Kind
        public var appName: String
        public var detail: String
        public var bundleID: String?
        var stateKey: String?

        public init(kind: Kind, appName: String, detail: String, bundleID: String?, stateKey: String? = nil) {
            self.kind = kind
            self.appName = appName
            self.detail = detail
            self.bundleID = bundleID
            self.stateKey = stateKey
        }

        public static func == (lhs: Finding, rhs: Finding) -> Bool {
            lhs.kind == rhs.kind && lhs.appName == rhs.appName
                && lhs.detail == rhs.detail && lhs.bundleID == rhs.bundleID
        }
    }

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

    static func groupKey(for group: AppProcessGroup) -> String {
        if let bundleID = group.bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let pid = group.members.first?.pid {
            return "\(group.name)#\(pid)"
        }
        return group.name
    }

    static func pruneStaleState(
        cpuWindows: inout [String: CPUWindow], memoryBaselines: inout [String: (value: Int64, at: Date)],
        lastRaised: inout [String: Date], groups: [AppProcessGroup], now: Date
    ) {
        let liveKeys = Set(groups.map(groupKey))
        cpuWindows = cpuWindows.filter { liveKeys.contains($0.key) }
        memoryBaselines = memoryBaselines.filter {
            liveKeys.contains($0.key) && now.timeIntervalSince($0.value.at) < 7200
        }
        let cooldownKeys = Set(groups.flatMap { group in
            let key = groupKey(for: group)
            return Finding.Kind.allCases.map { "\($0.rawValue)-\(key)" }
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
        "\(finding.kind.rawValue)-\(finding.stateKey ?? finding.bundleID ?? finding.appName)"
    }

    // MARK: - Pure evaluation (testable)

    private struct EvaluationContext {
        var coreScale: Double
        var thresholds: AlertThresholds
        var window: TimeInterval
        var now: Date
    }

    static func findings(
        in snapshot: SystemSnapshot, thresholds: AlertThresholds,
        cpuWindows: inout [String: CPUWindow], memoryBaselines: inout [String: (value: Int64, at: Date)],
        now: Date
    ) -> [Finding] {
        var findings: [Finding] = []
        let context = EvaluationContext(
            coreScale: Double(max(1, snapshot.cpu.logicalCoreCount)),
            thresholds: thresholds,
            window: thresholds.cpuWindowMinutes * 60,
            now: now)
        for group in snapshot.groups {
            let key = groupKey(for: group)
            findings.append(
                contentsOf: cpuFindings(group: group, key: key, context: context, cpuWindows: &cpuWindows))
            findings.append(
                contentsOf: growthFinding(
                    group: group, key: key, thresholds: thresholds,
                    memoryBaselines: &memoryBaselines, now: now))
            findings.append(contentsOf: rateFindings(group: group, key: key, thresholds: thresholds))
        }
        return findings
    }

    private static func cpuFindings(
        group: AppProcessGroup, key: String, context: EvaluationContext,
        cpuWindows: inout [String: CPUWindow]
    ) -> [Finding] {
        var state = cpuWindows[key] ?? CPUWindow()
        let normalizedCPU = group.cpuPercent / context.coreScale
        state.push(cpuPercent: normalizedCPU, at: context.now, window: context.window)
        cpuWindows[key] = state
        guard let average = state.average, average >= context.thresholds.cpuPercent,
              state.span >= context.window * 0.5 else { return [] }
        cpuWindows[key]?.clear()
        return [Finding(
            kind: .cpu, appName: group.name,
            detail: String(
                localized: "\(group.name) averaged \(Int(average))% CPU for \(Int(context.window / 60)) minutes.",
                comment: "CPU alert detail"),
            bundleID: group.bundleID,
            stateKey: key)]
    }

    private static func growthFinding(
        group: AppProcessGroup, key: String, thresholds: AlertThresholds,
        memoryBaselines: inout [String: (value: Int64, at: Date)], now: Date
    ) -> [Finding] {
        let memory = group.memoryBytes
        guard let baseline = memoryBaselines[key] else {
            memoryBaselines[key] = (value: memory, at: now)
            return []
        }
        let elapsed = now.timeIntervalSince(baseline.at)
        let growth = memory - baseline.value
        if elapsed >= 3600 {
            memoryBaselines[key] = (value: memory, at: now)
            guard growth >= thresholds.memoryGrowthBytes else { return [] }
            return [Finding(
                kind: .memory, appName: group.name,
                detail: String(
                    localized: "\(group.name) grew by \(growth.formattedByteCount) over the last hour.",
                    comment: "Memory alert detail"),
                bundleID: group.bundleID,
                stateKey: key)]
        }
        if elapsed >= 900 {
            let minimumSlopeBytes = max(Int64(500_000_000), thresholds.memoryGrowthBytes / 2)
            let projectedHourly = Double(growth) * (3600.0 / elapsed)
            if growth >= minimumSlopeBytes, projectedHourly >= Double(thresholds.memoryGrowthBytes) {
                memoryBaselines[key] = (value: memory, at: now)
                let minutes = max(1, Int((elapsed / 60).rounded()))
                return [Finding(
                    kind: .memory, appName: group.name,
                    detail: String(
                        localized: "\(group.name) grew rapidly by \(growth.formattedByteCount) in \(minutes) minutes.",
                        comment: "Rapid memory growth alert detail"),
                    bundleID: group.bundleID,
                    stateKey: key)]
            }
        }
        return []
    }

    private static func rateFindings(
        group: AppProcessGroup, key: String, thresholds: AlertThresholds
    ) -> [Finding] {
        var findings: [Finding] = []
        if group.diskReadPerSecond + group.diskWritePerSecond >= thresholds.diskBytesPerSecond {
            findings.append(Finding(
                kind: .disk, appName: group.name,
                detail: String(
                    localized: "\(group.name) is writing to disk heavily right now.",
                    comment: "Disk alert detail"),
                bundleID: group.bundleID,
                stateKey: key))
        }
        if group.downloadPerSecond + group.uploadPerSecond >= thresholds.networkBytesPerSecond {
            findings.append(Finding(
                kind: .network, appName: group.name,
                detail: String(
                    localized: "\(group.name) is moving a lot of data right now.",
                    comment: "Network alert detail"),
                bundleID: group.bundleID,
                stateKey: key))
        }
        return findings
    }

    /// O(1) circular ring buffer for rolling CPU samples within the alert window.
    struct CPUWindow {
        private var ring: [(at: Date, percent: Double)?] = Array(repeating: nil, count: 16)
        private var head = 0
        private var tail = 0
        private(set) var count = 0
        private var sum = 0.0

        var isEmpty: Bool { count < 1 }

        var span: TimeInterval {
            guard count >= 2, let first = ring[head],
                  let last = ring[(tail - 1 + ring.count) % ring.count] else { return 0 }
            return last.at.timeIntervalSince(first.at)
        }

        var average: Double? {
            isEmpty ? nil : sum / Double(count)
        }

        mutating func push(cpuPercent: Double, at date: Date, window: TimeInterval) {
            let cutoff = date.addingTimeInterval(-window)
            while !isEmpty, let oldest = ring[head], oldest.at < cutoff {
                sum -= oldest.percent
                ring[head] = nil
                head = (head + 1) % ring.count
                count -= 1
            }
            if count == ring.count {
                grow()
            }
            ring[tail] = (at: date, percent: cpuPercent)
            tail = (tail + 1) % ring.count
            count += 1
            sum += cpuPercent
        }

        mutating func clear() {
            ring = Array(repeating: nil, count: ring.count)
            head = 0
            tail = 0
            count = 0
            sum = 0
        }

        private mutating func grow() {
            let newCapacity = max(16, ring.count * 2)
            var next = [(at: Date, percent: Double)?](repeating: nil, count: newCapacity)
            for index in 0..<count {
                next[index] = ring[(head + index) % ring.count]
            }
            ring = next
            head = 0
            tail = count
        }
    }
}

public struct SystemAlertNotifier: AlertEngine.AlertNotifier {
    private let scheduler = NotificationScheduler()

    public init() {}

    public func raise(_ finding: AlertEngine.Finding) async {
        await scheduler.scheduleMonitorAlert(finding: finding)
    }
}
