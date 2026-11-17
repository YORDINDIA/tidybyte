import Foundation
import os
import SQLite3

/// A year of per-metric history in one local SQLite file. Raw samples are
/// kept for the recent window, then rolled up hourly so a year of history
/// stays compact. Pure storage: it never interprets the numbers it keeps.
public actor MetricsHistoryStore {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "MetricsHistory")
    nonisolated(unsafe) private var database: OpaquePointer?
    private var databaseURL: URL
    private var lastRollupAt: Date?
    private var lastPruneAt: Date?

    static let rawSampleWindow: TimeInterval = 48 * 3600
    public static let minimumRetentionDays = 7
    public static let appRollupRetentionDays = 90
    private static let schemaVersion: Int32 = 1

    public init(databaseURL: URL? = nil) throws {
        let base = databaseURL ?? Self.defaultLocation()
        self.databaseURL = base
        let isMemory = base.lastPathComponent == ":memory:"
        let openPath = isMemory ? ":memory:" : base.path
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            openPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw DatabaseError.openFailed(base.path)
        }
        database = handle
        try Self.configurePragmas(handle, isMemory: isMemory)
        try Self.migrate(handle)
    }

    deinit {
        if database != nil {
            sqlite3_close_v2(database)
            database = nil
        }
    }

    public static func defaultLocation() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let directory = support.appendingPathComponent("Tidybyte", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("metrics-history.sqlite")
    }

    // MARK: - Recording

    public func record(_ snapshot: SystemSnapshot) async {
        let timestamp = snapshot.timestamp.timeIntervalSince1970
        var rows: [(String, Double)] = [
            ("cpu", snapshot.cpu.usagePercent),
            ("memory", Double(snapshot.memory.usedBytes)),
            ("swap", Double(snapshot.memory.swapUsedBytes)),
            ("disk", snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond),
            ("disk_read", snapshot.disk.readBytesPerSecond),
            ("disk_write", snapshot.disk.writeBytesPerSecond),
            ("network", snapshot.network.downloadBytesPerSecond + snapshot.network.uploadBytesPerSecond),
            ("network_down", snapshot.network.downloadBytesPerSecond),
            ("network_up", snapshot.network.uploadBytesPerSecond)
        ]
        if let wattage = snapshot.power.wattage {
            rows.append(("energy", abs(wattage)))
        } else if !snapshot.groups.isEmpty {
            rows.append(("energy", snapshot.groups.reduce(0) { $0 + $1.energyIndex }))
        }
        if let level = snapshot.power.level { rows.append(("battery", level)) }
        if let temperature = snapshot.sensors.first?.celsius { rows.append(("temperature", temperature)) }
        for device in snapshot.gpu.devices {
            if let utilization = device.utilizationPercent { rows.append(("gpu", utilization)) }
        }
        var appRows: [AppSampleRow] = []
        for metric in UsageMetric.allCases {
            for group in snapshot.busiest(metric: metric, limit: 12) {
                appRows.append(
                    AppSampleRow(
                        metric: metric.rawValue, appName: group.name, bundlePath: group.bundlePath,
                        value: group.value(for: metric)))
            }
        }
        insert(rows: rows, appRows: appRows, timestamp: timestamp)
        await rollupAndPruneIfNeeded(now: snapshot.timestamp)
    }

    private func insert(rows: [(String, Double)], appRows: [AppSampleRow], timestamp: Double) {
        guard exec("BEGIN IMMEDIATE") else { return }
        let metricsOK = prepareAndRun(
            "INSERT INTO metric_samples (timestamp, metric, value) VALUES (?, ?, ?)", rows.count) { statement, index in
            let row = rows[index]
            sqlite3_bind_double(statement, 1, timestamp)
            sqlite3_bind_text(statement, 2, row.0, -1, sqliteTransient)
            sqlite3_bind_double(statement, 3, row.1)
        }
        let appRowsOK = prepareAndRun(
            "INSERT INTO app_samples (timestamp, metric, app_name, bundle_path, value) VALUES (?, ?, ?, ?, ?)",
            appRows.count) { statement, index in
            let row = appRows[index]
            sqlite3_bind_double(statement, 1, timestamp)
            sqlite3_bind_text(statement, 2, row.metric, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, row.appName, -1, sqliteTransient)
            if let bundlePath = row.bundlePath {
                sqlite3_bind_text(statement, 4, bundlePath, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_double(statement, 5, row.value)
        }
        guard metricsOK, appRowsOK, exec("COMMIT") else {
            _ = exec("ROLLBACK")
            return
        }
    }

    // MARK: - Rollups and pruning

    private func rollupAndPruneIfNeeded(now: Date) async {
        if let last = lastRollupAt, now.timeIntervalSince(last) < 1800 { return }
        let windowStart = now.addingTimeInterval(-Self.rawSampleWindow).timeIntervalSince1970
        let cutoff = (windowStart / 3600).rounded(.down) * 3600
        guard exec("BEGIN IMMEDIATE") else { return }
        let rollupsOK = runWithParameter(
            """
            INSERT INTO metric_rollups (hour, metric, average, peak, sample_count)
            SELECT CAST(timestamp / 3600 AS INTEGER) * 3600, metric, AVG(value), MAX(value), COUNT(*)
            FROM metric_samples WHERE timestamp < ? GROUP BY 1, 2
            ON CONFLICT(metric, hour) DO UPDATE SET
                average = (metric_rollups.average * metric_rollups.sample_count
                    + excluded.average * excluded.sample_count)
                    / (metric_rollups.sample_count + excluded.sample_count),
                peak = MAX(metric_rollups.peak, excluded.peak),
                sample_count = metric_rollups.sample_count + excluded.sample_count;
            """, cutoff)
            && runWithParameter(
            """
            INSERT INTO app_rollups (hour, metric, app_name, average, peak, sample_count)
            SELECT CAST(timestamp / 3600 AS INTEGER) * 3600, metric, app_name, AVG(value), MAX(value), COUNT(*)
            FROM app_samples WHERE timestamp < ? GROUP BY 1, 2, 3
            ON CONFLICT(metric, app_name, hour) DO UPDATE SET
                average = (app_rollups.average * app_rollups.sample_count
                    + excluded.average * excluded.sample_count)
                    / (app_rollups.sample_count + excluded.sample_count),
                peak = MAX(app_rollups.peak, excluded.peak),
                sample_count = app_rollups.sample_count + excluded.sample_count;
            """, cutoff)
            && runWithParameter("DELETE FROM metric_samples WHERE timestamp < ?;", cutoff)
            && runWithParameter("DELETE FROM app_samples WHERE timestamp < ?;", cutoff)
        guard rollupsOK, exec("COMMIT") else {
            _ = exec("ROLLBACK")
            return
        }
        lastRollupAt = now
    }

    public func pruneIfExpired(retentionDays: Int, now: Date) {
        if let last = lastPruneAt, now.timeIntervalSince(last) < 86_400 { return }
        prune(olderThanDays: retentionDays, now: now)
        lastPruneAt = now
    }

    public func prune(olderThanDays days: Int, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Double(max(days, Self.minimumRetentionDays)) * 86_400)
            .timeIntervalSince1970
        let appCutoff = max(
            cutoff,
            now.addingTimeInterval(-Double(Self.appRollupRetentionDays) * 86_400).timeIntervalSince1970)
        guard exec("BEGIN IMMEDIATE") else { return }
        let ok = runWithParameter("DELETE FROM metric_samples WHERE timestamp < ?;", cutoff)
            && runWithParameter("DELETE FROM app_samples WHERE timestamp < ?;", cutoff)
            && runWithParameter("DELETE FROM metric_rollups WHERE hour < ?;", cutoff)
            && runWithParameter("DELETE FROM app_rollups WHERE hour < ?;", appCutoff)
        guard ok, exec("COMMIT") else {
            _ = exec("ROLLBACK")
            return
        }
    }

    // MARK: - Queries

    public func series(metric: UsageMetric, from start: Date, to end: Date) -> [SeriesPoint] {
        series(metricKey: metric.rawValue, from: start, to: end)
    }

    public func series(metricKey: String, from start: Date, to end: Date) -> [SeriesPoint] {
        query(
            sql: """
            SELECT timestamp, value FROM metric_samples
            WHERE metric = ? AND timestamp BETWEEN ? AND ? ORDER BY timestamp;
            """,
            rollupSQL: """
            SELECT hour, average, peak FROM metric_rollups
            WHERE metric = ? AND hour BETWEEN ? AND ? ORDER BY hour;
            """,
            window: SeriesWindow(metric: metricKey, appName: nil, start: start, end: end))
    }

    public func appSeries(
        metric: UsageMetric, appName: String, from start: Date, to end: Date
    ) -> [SeriesPoint] {
        query(
            sql: """
            SELECT timestamp, value FROM app_samples
            WHERE metric = ? AND app_name = ? AND timestamp BETWEEN ? AND ? ORDER BY timestamp;
            """,
            rollupSQL: """
            SELECT hour, average, peak FROM app_rollups
            WHERE metric = ? AND app_name = ? AND hour BETWEEN ? AND ? ORDER BY hour;
            """,
            window: SeriesWindow(metric: metric.rawValue, appName: appName, start: start, end: end))
    }

    private func query(sql: String, rollupSQL: String, window: SeriesWindow) -> [SeriesPoint] {
        var points = readSeries(sql: sql, window: window, includesPeak: false)
        points.append(contentsOf: readSeries(sql: rollupSQL, window: window, includesPeak: true))
        points.sort { $0.timestamp < $1.timestamp }
        return points
    }

    private func readSeries(sql: String, window: SeriesWindow, includesPeak: Bool) -> [SeriesPoint] {
        var points: [SeriesPoint] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let handle = statement else {
            return points
        }
        defer { sqlite3_finalize(handle) }
        sqlite3_bind_text(handle, 1, window.metric, -1, sqliteTransient)
        if let second = window.appName { sqlite3_bind_text(handle, 2, second, -1, sqliteTransient) }
        let firstValue = window.appName == nil ? 2 : 3
        sqlite3_bind_double(handle, Int32(firstValue), window.start.timeIntervalSince1970)
        sqlite3_bind_double(handle, Int32(firstValue + 1), window.end.timeIntervalSince1970)
        while sqlite3_step(handle) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(handle, 0))
            let peak = includesPeak ? sqlite3_column_double(handle, 2) : nil
            points.append(SeriesPoint(timestamp: timestamp, average: sqlite3_column_double(handle, 1), peak: peak))
        }
        return points
    }

    private struct SeriesWindow {
        var metric: String
        var appName: String?
        var start: Date
        var end: Date
    }

    // MARK: - SQLite plumbing

    @discardableResult
    private func runWithParameter(_ sql: String, _ value: Double) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError("Metrics prepare failed")
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, value)
        if sqlite3_step(statement) != SQLITE_DONE {
            logSQLiteError("Metrics write failed")
            return false
        }
        return true
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "SQLite error \(status)"
            sqlite3_free(error)
            Self.logger.error("Metrics SQL failed: \(message, privacy: .public)")
            return false
        }
        return true
    }

    @discardableResult
    private func prepareAndRun(_ sql: String, _ count: Int, _ bind: (OpaquePointer, Int) -> Void) -> Bool {
        guard count > 0 else { return true }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let handle = statement else {
            logSQLiteError("Metrics prepare failed")
            return false
        }
        defer { sqlite3_finalize(handle) }
        for index in 0..<count {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
            bind(handle, index)
            if sqlite3_step(handle) != SQLITE_DONE {
                logSQLiteError("Metrics write failed at row \(index)")
                return false
            }
        }
        return true
    }

    private func logSQLiteError(_ label: String) {
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown error"
        Self.logger.error("\(label, privacy: .public): \(message, privacy: .public)")
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension MetricsHistoryStore {
    static func configurePragmas(_ handle: OpaquePointer, isMemory: Bool) throws {
        try execStatic(handle, "PRAGMA busy_timeout = 5000;")
        if !isMemory {
            try execStatic(handle, "PRAGMA journal_mode = WAL;")
        }
        try execStatic(handle, "PRAGMA synchronous = NORMAL;")
    }

    static func migrate(_ handle: OpaquePointer) throws {
        let currentVersion = userVersion(handle)
        guard currentVersion < schemaVersion else { return }

        let hasLegacyRollups = tableExists(handle, name: "metric_rollups")
        try execStatic(handle, "BEGIN IMMEDIATE;")
        do {
            try createSampleTables(handle)
            if hasLegacyRollups {
                try migrateLegacyRollups(handle)
            } else {
                try createRollupTables(handle)
            }
            try execStatic(handle, "PRAGMA user_version = \(schemaVersion);")
            try execStatic(handle, "COMMIT;")
        } catch {
            try? execStatic(handle, "ROLLBACK;")
            throw error
        }
    }

    private static func createSampleTables(_ handle: OpaquePointer) throws {
        try execStatic(handle, """
        CREATE TABLE IF NOT EXISTS metric_samples (
            timestamp REAL NOT NULL,
            metric TEXT NOT NULL,
            value REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS metric_samples_lookup ON metric_samples (metric, timestamp);
        CREATE INDEX IF NOT EXISTS metric_samples_ts ON metric_samples (timestamp);
        CREATE TABLE IF NOT EXISTS app_samples (
            timestamp REAL NOT NULL,
            metric TEXT NOT NULL,
            app_name TEXT NOT NULL,
            bundle_path TEXT,
            value REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS app_samples_lookup ON app_samples (metric, app_name, timestamp);
        CREATE INDEX IF NOT EXISTS app_samples_ts ON app_samples (timestamp);
        """)
    }

    private static func createRollupTables(_ handle: OpaquePointer) throws {
        try execStatic(handle, """
        CREATE TABLE IF NOT EXISTS metric_rollups (
            hour REAL NOT NULL,
            metric TEXT NOT NULL,
            average REAL NOT NULL,
            peak REAL NOT NULL,
            sample_count INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (metric, hour)
        );
        CREATE INDEX IF NOT EXISTS metric_rollups_hour ON metric_rollups (hour);
        CREATE TABLE IF NOT EXISTS app_rollups (
            hour REAL NOT NULL,
            metric TEXT NOT NULL,
            app_name TEXT NOT NULL,
            average REAL NOT NULL,
            peak REAL NOT NULL,
            sample_count INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (metric, app_name, hour)
        );
        CREATE INDEX IF NOT EXISTS app_rollups_hour ON app_rollups (hour);
        """)
    }

    private static func migrateLegacyRollups(_ handle: OpaquePointer) throws {
        try execStatic(handle, """
        CREATE TABLE metric_rollups_v1 (
            hour REAL NOT NULL,
            metric TEXT NOT NULL,
            average REAL NOT NULL,
            peak REAL NOT NULL,
            sample_count INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (metric, hour)
        );
        INSERT OR IGNORE INTO metric_rollups_v1 (hour, metric, average, peak, sample_count)
        SELECT hour, metric, average, peak, 1 FROM metric_rollups;
        DROP TABLE metric_rollups;
        ALTER TABLE metric_rollups_v1 RENAME TO metric_rollups;
        CREATE INDEX IF NOT EXISTS metric_rollups_hour ON metric_rollups (hour);

        CREATE TABLE app_rollups_v1 (
            hour REAL NOT NULL,
            metric TEXT NOT NULL,
            app_name TEXT NOT NULL,
            average REAL NOT NULL,
            peak REAL NOT NULL,
            sample_count INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (metric, app_name, hour)
        );
        INSERT OR IGNORE INTO app_rollups_v1 (hour, metric, average, peak, sample_count)
        SELECT hour, metric, app_name, average, peak, 1 FROM app_rollups;
        DROP TABLE app_rollups;
        ALTER TABLE app_rollups_v1 RENAME TO app_rollups;
        CREATE INDEX IF NOT EXISTS app_rollups_hour ON app_rollups (hour);
        """)
    }

    private static func userVersion(_ handle: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    private static func tableExists(_ handle: OpaquePointer, name: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, sqliteTransient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func execStatic(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "SQLite error \(status)"
            sqlite3_free(error)
            throw DatabaseError.migrationFailed(message)
        }
    }

    struct AppSampleRow {
        var metric: String
        var appName: String
        var bundlePath: String?
        var value: Double
    }

    public struct SeriesPoint: Sendable, Equatable, Identifiable {
        public var timestamp: Date
        public var average: Double
        public var peak: Double?

        public var id: Date { timestamp }

        public init(timestamp: Date, average: Double, peak: Double? = nil) {
            self.timestamp = timestamp
            self.average = average
            self.peak = peak
        }
    }
}
