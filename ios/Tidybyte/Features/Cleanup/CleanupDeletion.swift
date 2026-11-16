import Foundation
import Photos

/// Shared delete pipeline for cleanup tools. Owns delete → ledger → reconcile;
/// callers own the re-entry guard + isDeleting flag (an inout flag cannot cross
/// the service await). Each tool supplies list surgery as `apply`.
@MainActor
enum CleanupDeletion {
    /// Shown in every delete confirm. PhotoKit deletes go to Recently Deleted,
    /// so "cannot be undone" was false and scared users.
    ///
    /// Computed, not stored: a `static let` would cache the launch-time
    /// language and keep serving it after a language switch.
    static var recoverableNote: String {
        L10n.string("iOS will ask you to confirm. Deleted items go to Recently Deleted in Photos, where you can restore them for 30 days.")
    }

    /// The ids in `known` that the library no longer has. Empty when the library
    /// cannot be read: `existingIds` then reports nothing present, which would
    /// read as every item deleted, so the caller keeps its groups.
    static func vanishedIds(
        among known: Set<String>,
        authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    ) async -> Set<String> {
        guard !known.isEmpty, CompressionJournal.canReadLibrary(authorization) else { return [] }
        let present = await PhotoLibraryService.shared.existingIds(Array(known))
        return known.subtracting(present)
    }

    /// Title of every bulk delete confirm: "Delete N Items". One noun in every
    /// tool, so the same action reads the same in each screen.
    static func confirmTitle(count: Int) -> String {
        count == 1 ? L10n.string("Delete 1 Item") : L10n.format("Delete %lld Items", count)
    }

    /// Body of every delete confirm: the tool's own sentence, then the shared
    /// recoverable note.
    static func confirmMessage(_ scope: String) -> String {
        "\(scope) \(recoverableNote)"
    }

    struct Outcome {
        let removed: Set<String>       // confirmed deleted or already absent
        let errorMessage: String?      // nil on full success; set on partial + hard failure
        /// Only ids PhotoKit really deleted. Gate success UI on this, not on
        /// `removed`: an all-absent run deletes nothing and shows no prompt.
        var deleted: Set<String> = []
    }

    /// `requestedIds` must be pre-resolved by the caller (tab-union, or
    /// visible-intersection for LargeFiles). `recordDeleted` nil for tools
    /// without deletedCount (LargeFiles, Bursts).
    static func delete(
        requestedIds: Set<String>,
        kind: CleanupActivityKind,
        sizeById: [String: Int64],
        performDelete: @MainActor ([String]) async throws -> PhotoDeletionOutcome = {
            try await PhotoLibraryService.shared.deleteAssets(identifiers: $0)
        },
        apply: (Set<String>) -> Void,
        recordDeleted: ((Int) -> Void)? = nil
    ) async -> Outcome {
        // Every path that deletes nothing reports 0, so a tool's
        // `deletedCount` never keeps a stale value from an earlier delete.
        guard !requestedIds.isEmpty else {
            recordDeleted?(0)
            return Outcome(removed: [], errorMessage: nil)
        }
        do {
            let result = try await performDelete(Array(requestedIds))
            let deletedIds = result.deletedIds
            recordDeleted?(deletedIds.count)
            CleanupLedger.shared.record(kind: kind, deletedIds: deletedIds, sizeOf: { sizeById[$0] ?? 0 })
            apply(result.removedIds)
            return Outcome(removed: result.removedIds, errorMessage: nil, deleted: deletedIds)
        } catch is CancellationError {
            // A cancel is not a deletion failure: nothing was deleted, so stay
            // quiet rather than reporting "Deleted 0 of N items. N couldn't be
            // deleted. Try again." and inviting a pointless re-confirm.
            recordDeleted?(0)
            return Outcome(removed: [], errorMessage: nil)
        } catch let error as PhotoServiceError {
            if let result = error.deletionOutcome {
                let succeededIds = result.deletedIds
                recordDeleted?(succeededIds.count)
                CleanupLedger.shared.record(kind: kind, deletedIds: succeededIds, sizeOf: { sizeById[$0] ?? 0 })
                apply(result.removedIds)
                return Outcome(removed: result.removedIds, errorMessage: error.localizedDescription, deleted: succeededIds)
            }
            // "Don't Allow" keeps its "Nothing was deleted." message: the
            // views gate the success celebration on `errorMessage == nil`.
            recordDeleted?(0)
            return Outcome(removed: [], errorMessage: error.localizedDescription)
        } catch {
            recordDeleted?(0)
            return Outcome(removed: [], errorMessage: error.localizedDescription)
        }
    }
}
