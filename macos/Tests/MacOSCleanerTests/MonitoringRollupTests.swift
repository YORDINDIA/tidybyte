import XCTest
@testable import MacOSCleanerCore

/// Hourly rollup behavior for MetricsHistoryStore. Split from the parser tests
/// because the class there is already at its type-length budget.
final class MonitoringRollupTests: XCTestCase {
    /// An hour rolled up across two passes keeps its full average and peak. The
    /// first pass cuts mid-hour, and the second must not overwrite that row with
    /// only the later half.
    func testHistoryRollupKeepsWholeHourAverageAndPeak() async throws {
        let store = try MetricsHistoryStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let hour: TimeInterval = 100 * 3600
        func tick(at offset: TimeInterval, cpu: Double) -> SystemSnapshot {
            var sample = SystemSnapshot(timestamp: Date(timeIntervalSince1970: hour + offset), interval: 2)
            sample.cpu.usagePercent = cpu
            return sample
        }
        // Twelve samples across the hour: 10% in the first half, 50% in the second.
        for offset in stride(from: 0.0, to: 1800, by: 300) { await store.record(tick(at: offset, cpu: 10)) }
        for offset in stride(from: 1800.0, to: 3600, by: 300) { await store.record(tick(at: offset, cpu: 50)) }
        // Ticks 48h plus 30 minutes and 48h plus 90 minutes past the hour trigger the
        // rollups. The first lands mid-hour, the second after the hour has aged out.
        await store.record(tick(at: 48 * 3600 + 1800, cpu: 0))
        await store.record(tick(at: 48 * 3600 + 5400, cpu: 0))
        let series = await store.series(
            metric: .cpu, from: Date(timeIntervalSince1970: hour), to: Date(timeIntervalSince1970: hour + 3599))
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.average ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(series.first?.peak ?? 0, 50, accuracy: 0.001)
    }
}
