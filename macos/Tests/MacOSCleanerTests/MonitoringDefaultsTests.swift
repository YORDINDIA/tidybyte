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
}
