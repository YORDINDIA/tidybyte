import Foundation
import os

/// Forecasts when disk space will run low based on recent growth trends.
public actor SpaceForecaster {
    private let store: SQLiteStore
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "SpaceForecaster")

    public init(store: SQLiteStore) {
        self.store = store
    }

    public struct Forecast: Sendable {
        public var dailyGrowthRate: Int64
        public var daysUntil80PercentFull: Int?
        public var daysUntil90PercentFull: Int?
        public var daysUntil95PercentFull: Int?
        public var message: String
    }

    /// Volume-based forecast: reads actual capacity and available space from the
    /// volume's resource values and delegates to `forecast(capacity:availableBytes:)`.
    public func forecast(volumeURL: URL, rootPath: String? = nil) async throws -> Forecast? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? volumeURL.resourceValues(forKeys: keys),
              let capacity = values.volumeTotalCapacity,
              let availableBytes = values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init) else {
            return nil
        }
        return try await forecast(capacity: Int64(capacity), availableBytes: availableBytes, rootPath: rootPath)
    }

    /// Core forecast: growth rate from historical storage snapshots, days-until-full
    /// projected from ACTUAL volume usage (capacity minus available), never from the
    /// scanned-bytes total in the snapshots. Capacity/available are injectable so
    /// tests can simulate any volume state.
    public func forecast(
        capacity: Int64,
        availableBytes: Int64,
        rootPath: String? = nil
    ) async throws -> Forecast? {
        guard capacity > 0, availableBytes >= 0, availableBytes <= capacity else {
            return nil
        }
        let allSnapshots = try await store.recentSnapshots(limit: 14).sorted { $0.createdAt < $1.createdAt }
        guard let latest = allSnapshots.last else { return nil }

        let comparable: [(createdAt: Date, bytes: Int64)]
        if let rootPath {
            comparable = allSnapshots.compactMap { snapshot in
                guard let rootBytes = snapshot.bytesByRootPath[rootPath] else { return nil }
                return (snapshot.createdAt, rootBytes)
            }
        } else {
            let latestRoots = Set(latest.bytesByRootPath.keys)
            comparable = allSnapshots
                .filter { Set($0.bytesByRootPath.keys) == latestRoots }
                .map { ($0.createdAt, $0.totalBytes) }
        }
        guard comparable.count >= 2, let oldest = comparable.first, let newest = comparable.last else {
            return nil
        }

        // Growth rate uses the real elapsed time normalized to days across matching scan roots.
        let elapsed = newest.createdAt.timeIntervalSince(oldest.createdAt)
        let daySpan = max(1.0 / 24.0, elapsed / 86_400)
        let totalGrowth = newest.bytes - oldest.bytes
        let rawRate = Double(totalGrowth) / daySpan
        let dailyGrowthRate: Int64 = (rawRate.isFinite && !rawRate.isNaN)
            ? Int64(min(rawRate, Double(Int64.max / 2)).rounded(.towardZero))
            : 0

        guard dailyGrowthRate > 0 else {
            return Forecast(
                dailyGrowthRate: 0,
                daysUntil80PercentFull: nil,
                daysUntil90PercentFull: nil,
                daysUntil95PercentFull: nil,
                message: String(localized: "Your disk usage is stable or shrinking. No forecast needed.", comment: "Space forecast when no growth detected")
            )
        }

        // Forecast against ACTUAL volume usage (capacity minus available), not the
        // scanned-bytes total: partial scans must not distort the days-until-full math.
        let usedBytes = capacity - availableBytes
        let thresholds: [(label: String, percent: Double, keyPath: WritableKeyPath<Forecast, Int?>)] = [
            ("80%", 0.80, \.daysUntil80PercentFull),
            ("90%", 0.90, \.daysUntil90PercentFull),
            ("95%", 0.95, \.daysUntil95PercentFull),
        ]

        var forecast = Forecast(
            dailyGrowthRate: dailyGrowthRate,
            daysUntil80PercentFull: nil,
            daysUntil90PercentFull: nil,
            daysUntil95PercentFull: nil,
            message: ""
        )

        for threshold in thresholds {
            let targetBytes = Int64(Double(capacity) * threshold.percent)
            let remainingBytes = targetBytes - usedBytes
            if remainingBytes > 0 {
                // Round up cleanly with overflow protection so sub-day remainders report "1 day".
                let (numerator, overflow) = remainingBytes.addingReportingOverflow(dailyGrowthRate - 1)
                let rawDays = overflow ? Int64.max : numerator / dailyGrowthRate
                forecast[keyPath: threshold.keyPath] = Int(min(rawDays, Int64(Int.max)))
            }
        }

        if let days95 = forecast.daysUntil95PercentFull {
            forecast.message = String(localized: "At your current growth rate, your disk could reach 95% full in approximately \(days95) days.", comment: "Space forecast warning message")
        } else if let days90 = forecast.daysUntil90PercentFull {
            forecast.message = String(localized: "At your current growth rate, your disk could reach 90% full in approximately \(days90) days.", comment: "Space forecast caution message")
        } else if let days80 = forecast.daysUntil80PercentFull {
            forecast.message = String(localized: "At your current growth rate, your disk could reach 80% full in approximately \(days80) days.", comment: "Space forecast info message")
        } else {
            forecast.message = String(localized: "Your disk is filling up fast. Consider running a cleanup scan.", comment: "Space forecast urgent message")
        }

        return forecast
    }

}
