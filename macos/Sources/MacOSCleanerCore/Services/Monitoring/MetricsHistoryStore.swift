import Foundation
import os
import SQLite3

/// A year of per-metric history in one local SQLite file. Raw samples are
/// kept for the recent window, then rolled up hourly so a year of history
/// stays a few megabytes, not gigabytes. Pure storage: it never interprets
/// the numbers it keeps.
public actor MetricsHistoryStore {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "MetricsHistory")
    nonisolated(unsafe) private var database: OpaquePointer?
    private var databaseURL: URL
    private var lastRollupAt: Date?
    private var lastPruneAt: Date?

    /// Raw samples older than this are folded into hourly rollups.
    static let rawSampleWindow: TimeInterval = 48 * 3600
    public static let minimumRetentionDays = 7

    public init(databaseURL: URL? = nil) throws {
        let base = databaseURL ?? Self.defaultLocation()
        self.databaseURL = base
        // A ":memory:" URL must reach SQLite as the literal ":memory:"; its
        // URL.path resolves to a real file, which would silently share state
        // between stores (the same trap SQLiteStore documents).
        let openPath = base.lastPathComponent == ":memory:" ? ":memory:" : base.path
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(openPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw DatabaseError.openFailed(base.path)
        }
        database = handle
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

    static func migrate(_ handle: OpaquePointer) throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS metric_samples (
                timestamp REAL NOT NULL,
                metric TEXT NOT NULL,
                value REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS metric_samples_lookup ON metric_samples (metric, timestamp);
            CREATE TABLE IF NOT EXISTS app_samples (
                timestamp REAL NOT NULL,
                metric TEXT NOT NULL,
                app_name TEXT NOT NULL,
                bundle_path TEXT,
                value REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS app_samples_lookup ON app_samples (metric, timestamp);
            CREATE TABLE IF NOT EXISTS metric_rollups (
                hour REAL NOT NULL,
                metric TEXT NOT NULL,
                average REAL NOT NULL,
                peak REAL NOT NULL,
                PRIMARY KEY (hour, metric)
            );
            CREATE TABLE IF NOT EXISTS app_rollups (
                hour REAL NOT NULL,
                metric TEXT NOT NULL,
                app_name TEXT NOT NULL,
                average REAL NOT NULL,
                peak REAL NOT NULL,
                PRIMARY KEY (hour, metric, app_name)
            );
            """
        ]
        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            sqlite3_exec(handle, statement, nil, nil, &error)
            if let error {
                let message = String(cString: error)
                sqlite3_free(error)
                throw DatabaseError.migrationFailed(message)
            }
        }
    }

    // MARK: - Recording

    /// Records one tick. System metrics always; the strongest apps per metric
    /// so per-app history answers "what was eating memory on Tuesday".
    public func record(_ snapshot: SystemSnapshot) async {
        let timestamp = snapshot.timestamp.timeIntervalSince1970
        var rows: [(String, Double)] = [
            ("cpu", snapshot.cpu.usagePercent),
            ("memory", Double(snapshot.memory.usedBytes)),
            ("swap", Double(snapshot.memory.swapUsedBytes)),
            // series(metric:) looks keys up by UsageMetric rawValue, so the
            // combined "disk" and "network" rows sit alongside the finer
            // read/write and down/up ones.
            ("disk", snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond),
            ("disk_read", snapshot.disk.readBytesPerSecond),
            ("disk_write", snapshot.disk.writeBytesPerSecond),
            ("network", snapshot.network.downloadBytesPerSecond + snapshot.network.uploadBytesPerSecond),
            ("network_down", snapshot.network.downloadBytesPerSecond),
            ("network_up", snapshot.network.uploadBytesPerSecond)
        ]
        // Absent readings write no row at all — a -1 sentinel would pollute
        // averages and peaks.
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
        exec("BEGIN IMMEDIATE")
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
        // A partial tick must never commit: undo the whole transaction when
        // either statement batch failed.
        guard metricsOK, appRowsOK else {
            exec("ROLLBACK")
            return
        }
        exec("COMMIT")
    }

    // MARK: - Rollups and pruning

    /// Folds raw samples older than the window into hourly rows. Runs at most
    /// every 30 minutes; retention pruning is the caller's decision.
    private func rollupAndPruneIfNeeded(now: Date) async {
        if let last = lastRollupAt, now.timeIntervalSince(last) < 1800 { return }
        let cutoff = now.addingTimeInterval(-Self.rawSampleWindow).timeIntervalSince1970
        exec("BEGIN IMMEDIATE")
        let rollupsOK = runWithParameter(
            """
            INSERT OR REPLACE INTO metric_rollups (hour, metric, average, peak)
            SELECT CAST(timestamp / 3600 AS INTEGER) * 3600, metric, AVG(value), MAX(value)
            FROM metric_samples WHERE timestamp < ? GROUP BY 1, 2;
            """, cutoff)
            && runWithParameter(
            """
            INSERT OR REPLACE INTO app_rollups (hour, metric, app_name, average, peak)
            SELECT CAST(timestamp / 3600 AS INTEGER) * 3600, metric, app_name, AVG(value), MAX(value)
            FROM app_samples WHERE timestamp < ? GROUP BY 1, 2, 3;
            """, cutoff)
            && runWithParameter("DELETE FROM metric_samples WHERE timestamp < ?;", cutoff)
            && runWithParameter("DELETE FROM app_samples WHERE timestamp < ?;", cutoff)
        // The watermark only moves once the rollup transaction committed, so
        // a failed pass is retried on the next tick instead of skipped for
        // another half hour.
        guard rollupsOK else {
            exec("ROLLBACK")
            return
        }
        exec("COMMIT")
        lastRollupAt = now
    }

    /// Retention pruning the engine can call every tick; the actual DELETE
    /// pass runs at most daily.
    public func pruneIfExpired(retentionDays: Int, now: Date) {
        if let last = lastPruneAt, now.timeIntervalSince(last) < 86_400 { return }
        lastPruneAt = now
        prune(olderThanDays: retentionDays)
    }

    /// Deletes everything older than the retention window.
    public func prune(olderThanDays days: Int) {
        let cutoff = Date.now.addingTimeInterval(-Double(max(days, Self.minimumRetentionDays)) * 86400)
            .timeIntervalSince1970
        exec("BEGIN IMMEDIATE")
        runWithParameter("DELETE FROM metric_samples WHERE timestamp < ?;", cutoff)
        runWithParameter("DELETE FROM app_samples WHERE timestamp < ?;", cutoff)
        runWithParameter("DELETE FROM metric_rollups WHERE hour < ?;", cutoff)
        runWithParameter("DELETE FROM app_rollups WHERE hour < ?;", cutoff)
        exec("COMMIT")
    }

    // MARK: - Queries

    /// One metric's series over a range, at the best available resolution:
    /// raw samples inside the window, hourly rollups beyond it.
    public func series(metric: UsageMetric, from start: Date, to end: Date) -> [SeriesPoint] {
        query(
            sql: """
            SELECT timestamp, value FROM metric_samples
            WHERE metric = ? AND timestamp BETWEEN ? AND ? ORDER BY timestamp;
            """,
            rollupSQL: """
            SELECT hour, average, peak FROM metric_rollups
            WHERE metric = ? AND hour BETWEEN ? AND ? ORDER BY hour;
            """,
            window: SeriesWindow(metric: metric.rawValue, appName: nil, start: start, end: end))
    }

    /// Per-app history for the inspector and the app drill-in.
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

    /// The apps that led one metric over a range — "what used my memory this week".
    public func topApps(metric: UsageMetric, from start: Date, to end: Date, limit: Int = 10) -> [(name: String, peak: Double)] {
        var statement: OpaquePointer?
        let sql = """
            SELECT app_name, MAX(value) FROM app_samples
            WHERE metric = ? AND timestamp BETWEEN ? AND ?
            GROUP BY app_name ORDER BY 2 DESC LIMIT ?;
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, metric.rawValue, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Int32(limit))
        var result: [(String, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            result.append((name, sqlite3_column_double(statement, 1)))
        }
        return result
    }

    private func query(sql: String, rollupSQL: String, window: SeriesWindow) -> [SeriesPoint] {
        var points = readSeries(sql: sql, window: window, includesPeak: false)
        points.append(contentsOf: readSeries(sql: rollupSQL, window: window, includesPeak: true))
        // Raw rows cover the recent window and rollups the older hours, so the
        // appended array is not time-ordered across the seam. Charts draw in
        // data order; sort or Year/Month ranges zigzag back on themselves.
        points.sort { $0.timestamp < $1.timestamp }
        return points
    }

    /// Runs one of the series queries. Rows are (time, value) or, for
    /// rollups, (time, average, peak).
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

    /// One statement, one bound double parameter. Table names in callers are
    /// compile-time literals; user data never reaches SQL as text. Returns
    /// false when the statement failed so transactions can roll back.
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

    private func exec(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        sqlite3_exec(database, sql, nil, nil, &error)
        if let error {
            Self.logger.error("Metrics SQL failed: \(String(cString: error), privacy: .public)")
            sqlite3_free(error)
        }
    }

    /// Binds and steps `count` rows through one prepared statement. Returns
    /// false on the first failed step so the caller can roll back; failures
    /// are logged once per statement, not once per row.
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

/// SQLITE_TRANSIENT: sqlite copies the bound string, so the buffer need not
/// outlive the step call. Shared by both SQLite actors in this module.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Stored types live in an extension so the actor body stays within lint
// bounds; the qualified names are unchanged.
extension MetricsHistoryStore {
    /// One per-app history row.
    struct AppSampleRow {
        var metric: String
        var appName: String
        var bundlePath: String?
        var value: Double
    }

    /// One point of a metric or per-app series.
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
