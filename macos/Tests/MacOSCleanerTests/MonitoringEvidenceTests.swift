import XCTest
@testable import MacOSCleanerCore

/// Evidence tests for the monitor's alerting and history paths, driven at the
/// actor boundary (AlertEngine) and against an in-memory MetricsHistoryStore.
/// All fixtures are synthetic.
final class MonitoringEvidenceTests: XCTestCase {
    private func sample(
        pid: pid_t, parent: pid_t = 1, name: String, path: String? = nil,
        bundlePath: String? = nil, bundleName: String? = nil, cpu: Double = 0, memory: Int64 = 0,
        kernel: Bool = false
    ) -> ProcessSample {
        ProcessSample(
            pid: pid, parentPID: parent, name: name, state: .running, isKernelProcess: kernel,
            executablePath: path, bundlePath: bundlePath, bundleName: bundleName,
            residentBytes: memory, cpuPercent: cpu)
    }

    /// Captures findings at the actor boundary — the protocol exists exactly
    /// for this (AlertEngine.swift "Protocol-injected so tests can capture").
    private actor CaptureNotifier: AlertEngine.AlertNotifier {
        var raised: [AlertEngine.Finding] = []
        func raise(_ finding: AlertEngine.Finding) async {
            raised.append(finding)
        }
    }

    /// VAL-MON-008 primary evidence: the full actor path — evaluate() through
    /// a capturing notifier — raises one notification per sustained breach and
    /// the cooldown suppresses a second breach inside the window.
    func testAlertEngineActorRaisesOneNotificationPerBreachAndCooldownSuppresses() async throws {
        let notifier = CaptureNotifier()
        let engine = AlertEngine(
            settings: AlertEngine.AlertThresholds(
                isEnabled: true, cpuPercent: 50, cpuWindowMinutes: 10, memoryGrowthBytes: 1_000_000_000,
                diskBytesPerSecond: 1_000_000_000, networkBytesPerSecond: 1_000_000_000),
            notifier: notifier)
        let start = Date(timeIntervalSince1970: 2_000_000)

        func burner(at seconds: Double) -> SystemSnapshot {
            let group = AppProcessGroup(
                id: "app:burner", name: "Burner", kind: .app, bundlePath: nil, bundleID: "com.burner",
                members: [sample(pid: 7, name: "Burner", cpu: 90)])
            return SystemSnapshot(timestamp: start.addingTimeInterval(seconds), groups: [group])
        }

        // Ticks below half the alert window (span < 5 min) never fire.
        await engine.evaluate(burner(at: 0))
        await engine.evaluate(burner(at: 100))
        await engine.evaluate(burner(at: 200))
        let warmup = await notifier.raised
        XCTAssertTrue(warmup.isEmpty)

        // Span reaches half the 10-minute window at 300 s: exactly one raise.
        await engine.evaluate(burner(at: 300))
        let afterBreach = await notifier.raised
        XCTAssertEqual(afterBreach.count, 1)
        XCTAssertEqual(afterBreach.first?.kind, .cpu)
        XCTAssertEqual(afterBreach.first?.appName, "Burner")

        // A second breach seven minutes later is inside the 30-minute default
        // cooldown: evaluate still detects it, but nothing is raised.
        await engine.evaluate(burner(at: 400))
        await engine.evaluate(burner(at: 500))
        await engine.evaluate(burner(at: 600))
        await engine.evaluate(burner(at: 700))
        let insideCooldown = await notifier.raised
        XCTAssertEqual(insideCooldown.count, 1)
    }

    /// Settings reach the running engine without a restart: flipping the
    /// master switch off through updateThresholds silences a live breach and
    /// flipping it back on lets the next breach fire again.
    func testAlertEngineUpdateThresholdsDisablesAndReEnablesAlerting() async throws {
        let notifier = CaptureNotifier()
        let engine = AlertEngine(
            settings: AlertEngine.AlertThresholds(
                isEnabled: true, cpuPercent: 50, cpuWindowMinutes: 1, memoryGrowthBytes: 1_000_000_000,
                diskBytesPerSecond: 1_000_000_000, networkBytesPerSecond: 1_000_000_000),
            notifier: notifier)
        let start = Date(timeIntervalSince1970: 3_000_000)

        func burner(at seconds: Double, enabled: Bool) -> SystemSnapshot {
            let group = AppProcessGroup(
                id: "app:burner", name: "Burner", kind: .app, bundlePath: nil, bundleID: "com.burner",
                members: [sample(pid: 7, name: "Burner", cpu: 90)])
            return SystemSnapshot(timestamp: start.addingTimeInterval(seconds), groups: [group])
        }
        func thresholds(enabled: Bool) -> AlertEngine.AlertThresholds {
            AlertEngine.AlertThresholds(
                isEnabled: enabled, cpuPercent: 50, cpuWindowMinutes: 1, memoryGrowthBytes: 1_000_000_000,
                diskBytesPerSecond: 1_000_000_000, networkBytesPerSecond: 1_000_000_000)
        }

        await engine.updateThresholds(thresholds(enabled: false))
        // Disabled ticks are skipped wholesale (no window state builds up).
        await engine.evaluate(burner(at: 0, enabled: false))
        await engine.evaluate(burner(at: 35, enabled: false))
        let disabled = await notifier.raised
        XCTAssertTrue(disabled.isEmpty, "Alerts off in settings must raise nothing")

        await engine.updateThresholds(thresholds(enabled: true))
        await engine.evaluate(burner(at: 70, enabled: true))
        await engine.evaluate(burner(at: 100, enabled: true))
        let enabled = await notifier.raised
        XCTAssertEqual(enabled.count, 1, "Re-enabling lets the same breach fire")
    }

    /// VAL-MON-009: raw samples older than the 48-hour window fold into
    /// hourly rollup rows and their raw rows are deleted. A point in the aged
    /// range with a peak can only come from the rollup table — the raw row is
    /// gone — and the recent sample stays raw (peak == nil).
    func testHistoryRollupFoldsOldRawSamplesIntoHourlyRowsAndDeletesThem() async throws {
        let store = try MetricsHistoryStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let now = Date.now
        let aged = now.addingTimeInterval(-72 * 3600)

        var oldSnapshot = SystemSnapshot(timestamp: aged, interval: 2)
        oldSnapshot.cpu.usagePercent = 42
        oldSnapshot.memory.usedBytes = 8_000_000_000
        oldSnapshot.groups = [
            AppProcessGroup(
                id: "g", name: "Hog", kind: .app, bundlePath: nil, bundleID: nil,
                members: [sample(pid: 1, name: "Hog", cpu: 42, memory: 8_000_000_000)])
        ]
        await store.record(oldSnapshot)

        var freshSnapshot = SystemSnapshot(timestamp: now, interval: 2)
        freshSnapshot.cpu.usagePercent = 11
        await store.record(freshSnapshot)

        // Aged range: exactly one point, carrying a peak ⇒ a metric_rollups
        // row (the raw metric_samples row was deleted by the fold). The
        // hourly bucket starts up to 3600 s before the sample, so the range
        // must reach back that far.
        let agedRange = aged.addingTimeInterval(-3600)...aged
        let host = await store.series(metric: .cpu, from: agedRange.lowerBound, to: agedRange.upperBound)
        XCTAssertEqual(host.count, 1)
        XCTAssertEqual(host.first?.average ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(host.first?.peak ?? -1, 42, accuracy: 0.001)

        // The app-level fold works the same way (app_rollups).
        let app = await store.appSeries(
            metric: .memory, appName: "Hog", from: agedRange.lowerBound, to: agedRange.upperBound)
        XCTAssertEqual(app.count, 1)
        XCTAssertEqual(app.first?.average ?? 0, 8_000_000_000, accuracy: 0.001)
        XCTAssertEqual(app.first?.peak ?? -1, 8_000_000_000, accuracy: 0.001)

        // Recent range: the fresh sample is still raw (no peak ⇒ metric_samples).
        let fresh = await store.series(
            metric: .cpu, from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(fresh.first?.average ?? 0, 11, accuracy: 0.001)
        XCTAssertNil(fresh.first?.peak)
    }
}
