import Foundation
import MacOSCleanerCore

// The store-selection ladder behind `bootstrap` (DP-04/05/06), extracted so
// each tier is directly testable with injected primary/temp locations.

extension AppViewModel {
    struct ResolvedStore {
        let store: SQLiteStore
        /// True when the primary Application Support database failed and a
        /// lesser store is in use — the flag behind the "temporary storage"
        /// notice.
        let usedTempDatabase: Bool
    }

    /// Primary Application Support database → fixed temp file → unique temp
    /// file → in-memory → an unavailable store that fails closed on access.
    static func resolveStore(
        primary: () throws -> SQLiteStore,
        tempURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSCleaner.sqlite", isDirectory: false)
    ) -> ResolvedStore {
        if let store = try? primary() {
            return ResolvedStore(store: store, usedTempDatabase: false)
        }
        if let store = try? SQLiteStore(databaseURL: tempURL) {
            return ResolvedStore(store: store, usedTempDatabase: true)
        }
        let uniqueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSCleaner-\(UUID().uuidString).sqlite", isDirectory: false)
        if let store = try? SQLiteStore(databaseURL: uniqueURL) {
            return ResolvedStore(store: store, usedTempDatabase: true)
        }
        return ResolvedStore(store: (try? SQLiteStore.inMemory()) ?? SQLiteStore.unavailable, usedTempDatabase: true)
    }
}
