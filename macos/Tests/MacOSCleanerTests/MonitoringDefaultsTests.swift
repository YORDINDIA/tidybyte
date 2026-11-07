import Foundation
@testable import MacOSCleanerCore
import XCTest

@MainActor
final class MonitoringDefaultsTests: XCTestCase {
    func testFreshSettingsAndSavedOverrides() {
        let defaults = makeIsolatedDefaults()
        let settings = MonitoringSettings(defaults: defaults)
        XCTAssertEqual(settings.intervalSeconds, 2)
        XCTAssertEqual(settings.historyRetentionDays, 365)
        XCTAssertFalse(settings.isAlertsEnabled)
        XCTAssertTrue(settings.isMenuBarPanelEnabled)
        XCTAssertEqual(settings.alertCPUPercent, 70)
        XCTAssertEqual(settings.alertCPUWindowMinutes, 10)
        XCTAssertEqual(settings.alertMemoryGrowthBytes, 1_500_000_000)
        XCTAssertEqual(settings.alertDiskBytesPerSecond, 80_000_000)
        XCTAssertEqual(settings.alertNetworkBytesPerSecond, 50_000_000)

        settings.intervalSeconds = 5
        settings.alertCPUPercent = 80
        XCTAssertEqual(MonitoringSettings(defaults: defaults).intervalSeconds, 5)
        XCTAssertEqual(MonitoringSettings(defaults: defaults).alertCPUPercent, 80)
    }

    func testEachMetricUsesItsOwnPersistedSetting() {
        let defaults = makeIsolatedDefaults()
        let settings = MonitoringSettings(defaults: defaults)
        let entries = UsageMetric.allCases.map { MonitoringKeys.menuBarMetric(for: $0) }
        XCTAssertEqual(Set(MonitoringKeys.menuBarMetrics.map(\.metric)), Set(UsageMetric.allCases))
        XCTAssertEqual(Set(entries.map(\.key)).count, UsageMetric.allCases.count)
        for entry in entries { defaults.set(false, forKey: entry.key) }
        XCTAssertFalse(settings.hasEnabledMenuBarMetric)
        defaults.set(true, forKey: MonitoringKeys.menuBarMetric(for: .disk).key)
        XCTAssertTrue(settings.hasEnabledMenuBarMetric)
        XCTAssertEqual(MonitoringKeys.menuBarMetric(for: .disk).key, "monitor.metric.disk")
        XCTAssertFalse(defaults.bool(forKey: MonitoringKeys.menuBarMetric(for: .energy).key))
    }

}
