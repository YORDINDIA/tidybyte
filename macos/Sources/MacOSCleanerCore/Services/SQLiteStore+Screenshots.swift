import Foundation
import SQLite3

extension SQLiteStore {
    public func saveScreenshotRename(_ record: ScreenshotRenameRecord) throws {
        try upsert(record, id: record.id, table: .screenshotRenames)
    }

    public func saveScreenshotRenames(_ records: [ScreenshotRenameRecord]) throws {
        try saveAll(records, idKeyPath: \.id, table: .screenshotRenames)
    }

    public func loadScreenshotRenames(limit: Int = 500) throws -> [ScreenshotRenameRecord] {
        try selectJSON(
            "SELECT json FROM \(SQLiteTable.screenshotRenames.rawValue) ORDER BY created_at DESC LIMIT ?",
            values: [.integer(Int64(max(1, limit)))],
            as: ScreenshotRenameRecord.self
        )
    }

    public func loadScreenshotRenameBatch(batchID: String) throws -> [ScreenshotRenameRecord] {
        try selectJSON(
            "SELECT json FROM \(SQLiteTable.screenshotRenames.rawValue) WHERE batch_id = ? ORDER BY created_at DESC",
            values: [.text(batchID)],
            as: ScreenshotRenameRecord.self
        )
    }

    public func saveStyleExample(_ example: StyleLearningExample) throws {
        try upsert(example, id: example.id, table: .screenshotStyleExamples)
    }

    public func loadStyleExamples(limit: Int = 50) throws -> [StyleLearningExample] {
        try selectJSON(
            "SELECT json FROM \(SQLiteTable.screenshotStyleExamples.rawValue) ORDER BY created_at DESC LIMIT ?",
            values: [.integer(Int64(max(1, limit)))],
            as: StyleLearningExample.self
        )
    }

    public func deleteStyleExample(id: String) throws {
        try execute(
            "DELETE FROM \(SQLiteTable.screenshotStyleExamples.rawValue) WHERE id = ?",
            values: [.text(id)]
        )
    }

    public func clearScreenshotHistory() throws {
        try withTransaction {
            try execute("DELETE FROM \(SQLiteTable.screenshotRenames.rawValue)", values: [])
            try execute("DELETE FROM \(SQLiteTable.screenshotStyleExamples.rawValue)", values: [])
        }
    }

    static func migrateV8(database: OpaquePointer) throws {
        if !hasColumn("screenshot_renames", "batch_id", database: database) {
            try executeMigration("ALTER TABLE screenshot_renames ADD COLUMN batch_id TEXT", database: database)
        }
        if !hasColumn("screenshot_renames", "status", database: database) {
            try executeMigration("ALTER TABLE screenshot_renames ADD COLUMN status TEXT", database: database)
        }
        try executeMigration(
            "UPDATE screenshot_renames SET batch_id = json_extract(json, '$.batchID') WHERE batch_id IS NULL",
            database: database
        )
        try executeMigration(
            "UPDATE screenshot_renames SET status = json_extract(json, '$.status') WHERE status IS NULL",
            database: database
        )
        try executeMigration(
            "CREATE INDEX IF NOT EXISTS idx_screenshot_renames_batch_id ON screenshot_renames(batch_id)",
            database: database
        )
        try executeMigration(
            "CREATE INDEX IF NOT EXISTS idx_screenshot_renames_status ON screenshot_renames(status)",
            database: database
        )
    }
}
