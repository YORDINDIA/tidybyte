import Darwin
import Foundation
import os

public enum UndoManagerServiceError: Error, LocalizedError, Sendable {
    case undoUnavailable
    case undoExpired(Date)
    case trashItemMissing(URL)
    case restoreDestinationExists(URL)
    /// The archive copy is kept because the original file has not been restored yet.
    case archiveOriginalNotRestored(URL)
    /// The artifact at the restore location is not the exact file this undo record created.
    case restoreArtifactIdentityMismatch(URL)
    /// The identity of the artifact could not be verified, so nothing was deleted.
    case restoreArtifactIdentityUnknown(URL)
    /// The item in Trash is not the exact file this undo record trashed, so it was not restored.
    case trashArtifactIdentityMismatch(URL)
    /// The identity of the item in Trash could not be verified, so it was not restored.
    case trashArtifactIdentityUnknown(URL)
    /// The folded clone could not be re-split into a private copy (not enough
    /// free space, file in use, or a filesystem error). The record stays
    /// available so the undo can be retried later.
    case unfoldFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .undoUnavailable: String(localized: "Undo is not available for this operation.", comment: "Error when undo is not available")
        case .undoExpired(let validUntil): String(localized: "This undo expired on \(validUntil.formatted(date: .abbreviated, time: .omitted)) and can no longer be restored.", comment: "Error when an undo record has passed its validity window")
        case .trashItemMissing(let url): String(localized: "The item is no longer in Trash and cannot be restored: \(url.path)", comment: "Error when the trashed item is missing from its recorded location")
        case .trashArtifactIdentityMismatch(let url): String(localized: "The item in Trash at \(url.path) is not the file this undo record trashed, so it was not restored.", comment: "Error when the trashed item does not match the identity the undo record captured")
        case .trashArtifactIdentityUnknown(let url): String(localized: "The identity of the item in Trash at \(url.path) could not be verified, so it was not restored.", comment: "Error when an undo record cannot prove the trashed item's identity")
        case .restoreDestinationExists(let url): String(localized: "Restore destination already exists: \(url.path)", comment: "Error when restore destination already exists")
        case .archiveOriginalNotRestored(let url): String(localized: "The original file has not been restored yet, so the archive copy at \(url.path) is being kept.", comment: "Error when an archive undo is attempted before the original file was restored")
        case .restoreArtifactIdentityMismatch(let url): String(localized: "The item at \(url.path) is not the artifact this undo record created, so it was not deleted.", comment: "Error when the file at the restore location does not match the artifact the undo record owns")
        case .restoreArtifactIdentityUnknown(let url): String(localized: "The identity of the item at \(url.path) could not be verified, so it was not deleted.", comment: "Error when an undo record cannot prove it owns the artifact it would delete")
        case .unfoldFailed(let url): String(localized: "Could not give \(url.path) its own storage again (not enough free space, file in use, or a filesystem error). Try again later.", comment: "Error when unfolding a cloned file fails")
        }
    }
}

/// Device and inode identity of a filesystem artifact, captured when the artifact is
/// created so undo can verify ownership before deleting anything.
struct FileArtifactIdentity: Codable, Hashable, Sendable {
    var deviceID: UInt64
    var inodeID: UInt64

    /// Capture the identity of the item at `url` without following symlinks.
    static func capture(at url: URL) -> FileArtifactIdentity? {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else {
            return nil
        }
        return FileArtifactIdentity(deviceID: UInt64(statBuffer.st_dev), inodeID: statBuffer.st_ino)
    }

    var encodedString: String? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String) -> FileArtifactIdentity? {
        guard let data = string.data(using: .utf8),
              let identity = try? JSONDecoder().decode(FileArtifactIdentity.self, from: data) else {
            return nil
        }
        return identity
    }
}

/// Per-record failure detail for batch undo, so callers can report exactly which
/// action failed, at which path, and why.
public struct UndoRestoreFailure: Sendable {
    public let undoID: String
    /// Path the undo record attempted to restore or delete.
    public let restorePath: String?
    /// Human-readable reason the restore failed.
    public let errorDescription: String

    public init(undoID: String, restorePath: String?, errorDescription: String) {
        self.undoID = undoID
        self.restorePath = restorePath
        self.errorDescription = errorDescription
    }
}

public struct UndoRestoreBatchResult: Sendable {
    public let restored: [UndoRecord]
    public let failures: [UndoRestoreFailure]
    public var failureCount: Int { failures.count }

    public init(restored: [UndoRecord], failures: [UndoRestoreFailure]) {
        self.restored = restored
        self.failures = failures
    }
}

public actor UndoManagerService {
    private let store: SQLiteStore
    private let memory: MemoryEngine
    private let fileManager: FileManager
    private let trash: any TrashService
    private let policy: PathSafetyPolicy
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "UndoManagerService")

    /// `trash` receives the artifacts that undo removes (archive copies, aliases,
    /// symlinks). They go to the Trash, never straight to deletion.
    public init(
        store: SQLiteStore,
        memory: MemoryEngine,
        fileManager: FileManager = .default,
        trash: (any TrashService)? = nil,
        policy: PathSafetyPolicy = PathSafetyPolicy()
    ) {
        self.store = store
        self.memory = memory
        self.fileManager = fileManager
        self.trash = trash ?? FileSystemTrashProvider()
        self.policy = policy
    }

    /// Batch-restore with a simple success count. Prefer `restoreBatchDetailed` when
    /// the caller needs to report which actions failed and why.
    public func restoreBatch(_ undos: [UndoRecord], regretReason: String? = nil) async -> (restored: [UndoRecord], failureCount: Int) {
        let result = await restoreBatchDetailed(undos, regretReason: regretReason)
        return (result.restored, result.failures.count)
    }

    /// Batch-restore with per-record failure details. Defers archive-trash records
    /// until their restore sibling succeeded, and restores shallower paths first.
    public func restoreBatchDetailed(_ undos: [UndoRecord], regretReason: String? = nil) async -> UndoRestoreBatchResult {
        let archiveSiblingLogIDs = Self.archiveSiblingLogIDs(in: undos)
        let ordered = undos.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            let leftDefers = left.inverseAction == .moveToTrash && archiveSiblingLogIDs.contains(left.operationLogID)
            let rightDefers = right.inverseAction == .moveToTrash && archiveSiblingLogIDs.contains(right.operationLogID)
            if leftDefers != rightDefers {
                return !leftDefers
            }
            let leftDepth = left.restoreURL?.pathComponents.count ?? 0
            let rightDepth = right.restoreURL?.pathComponents.count ?? 0
            if leftDepth != rightDepth {
                return leftDepth < rightDepth
            }
            return lhs.offset < rhs.offset
        }
        var restored: [UndoRecord] = []
        var failures: [UndoRestoreFailure] = []
        for (_, undo) in ordered {
            do {
                let result = try await restore(undo, regretReason: regretReason)
                restored.append(result)
            } catch {
                let failure = UndoRestoreFailure(
                    undoID: undo.id,
                    restorePath: undo.restoreURL?.path,
                    errorDescription: error.localizedDescription
                )
                failures.append(failure)
                logger.warning("Failed to restore \(undo.id, privacy: .public) at \(undo.restoreURL?.path ?? "unknown path", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return UndoRestoreBatchResult(restored: restored, failures: failures)
    }

    /// Operation log IDs that pair an archive-trash record with a restore sibling in
    /// the same batch. Those archive-trash records are deferred until the sibling
    /// restore ran, so the only remaining copy is never deleted first.
    private static func archiveSiblingLogIDs(in undos: [UndoRecord]) -> Set<String> {
        let restoreLogIDs = Set(undos.filter { $0.inverseAction == .restore }.map(\.operationLogID))
        return Set(undos.filter { $0.inverseAction == .moveToTrash && restoreLogIDs.contains($0.operationLogID) }.map(\.operationLogID))
    }

    public func restore(_ undo: UndoRecord, regretReason: String? = nil) async throws -> UndoRecord {
        guard undo.status == .available else {
            throw UndoManagerServiceError.undoUnavailable
        }
        if let validUntil = undo.validUntil, Date() > validUntil {
            var expired = undo
            expired.status = .expired
            try await store.saveUndoRecord(expired)
            throw UndoManagerServiceError.undoExpired(validUntil)
        }

        // Check for externally moved/deleted file at the current location.
        // Mark the record as failed so the UI does not keep offering a broken undo.
        // Clone-fold records store the keeper in trashURL for context only —
        // unfolding the duplicate never touches the keeper, so a deleted keeper
        // must not kill the undo.
        if undo.inverseAction != .unfoldClone,
           let trashURL = undo.trashURL, !Self.itemExistsOnDisk(at: trashURL) {
            var failed = undo
            failed.status = .failed
            try await store.saveUndoRecord(failed)
            throw UndoManagerServiceError.trashItemMissing(trashURL)
        }

        switch undo.inverseAction {
        case .restore:
            guard let trashURL = undo.trashURL, let restoreURL = undo.restoreURL else {
                throw UndoManagerServiceError.undoUnavailable
            }
            if Self.itemExistsOnDisk(at: restoreURL) {
                throw UndoManagerServiceError.restoreDestinationExists(restoreURL)
            }
            try await verifyTrashIdentity(of: undo, trashURL: trashURL)
            try ensureParentDirectory(for: restoreURL)
            try fileManager.moveItem(at: trashURL, to: restoreURL)
        case .move:
            guard let currentURL = undo.trashURL, let restoreURL = undo.restoreURL else {
                throw UndoManagerServiceError.undoUnavailable
            }
            let destination = try collisionFreeRestoreURL(restoreURL, isDirectory: Self.isDirectoryOnDisk(at: currentURL))
            try await verifyMoveSourceIdentity(of: undo, currentURL: currentURL)
            try ensureParentDirectory(for: destination)
            try fileManager.moveItem(at: currentURL, to: destination)
        case .tag:
            guard let restoreURL = undo.restoreURL else {
                throw UndoManagerServiceError.undoUnavailable
            }
            let log = try await store.loadOperationLog(id: undo.operationLogID)
            guard let originalTags = log?.beforeState["tags"].flatMap(Self.decodeTags),
                  let addedTags = log?.afterState["tags"].flatMap(Self.decodeTags) else {
                throw UndoManagerServiceError.undoUnavailable
            }
            // Merge: start with current live tags (preserving color suffixes),
            // remove what was added, ensure originals are present.
            let currentTags = Set(try FinderTagHelper.read(from: restoreURL))
            let addedSet = Set(addedTags)
            let originalSet = Set(originalTags)
            let merged = currentTags.subtracting(addedSet).union(originalSet)
            try FinderTagHelper.write(Array(merged).sorted(), to: restoreURL)
        case .moveToTrash:
            guard let createdURL = undo.restoreURL else {
                throw UndoManagerServiceError.undoUnavailable
            }
            try await verifyOwnership(of: undo, artifactURL: createdURL)
            _ = try trash.trashItem(at: createdURL)
        case .rename:
            guard let currentURL = undo.trashURL, let restoreURL = undo.restoreURL else {
                throw UndoManagerServiceError.undoUnavailable
            }
            let destination = try collisionFreeRestoreURL(restoreURL, isDirectory: Self.isDirectoryOnDisk(at: currentURL))
            try await verifyMoveSourceIdentity(of: undo, currentURL: currentURL)
            try ensureParentDirectory(for: destination)
            try fileManager.moveItem(at: currentURL, to: destination)
        case .unfoldClone:
            guard let restoreURL = undo.restoreURL else {
                throw UndoManagerServiceError.undoUnavailable
            }
            // The file must still be the clone this record folded (its identity
            // was captured immediately after the fold succeeded). A file the
            // user replaced since is never overwritten with a private copy.
            let log = try await store.loadOperationLog(id: undo.operationLogID)
            if let identityString = log?.afterState["clone_identity"],
               let expected = FileArtifactIdentity.decode(identityString) {
                guard let actual = FileArtifactIdentity.capture(at: restoreURL),
                      actual == expected else {
                    throw UndoManagerServiceError.restoreArtifactIdentityMismatch(restoreURL)
                }
            }
            // Unfold needs real free space (it writes a private copy); not
            // enough space or a busy file leaves the record available to retry.
            guard APFSCloneService.unfold(path: restoreURL) else {
                throw UndoManagerServiceError.unfoldFailed(restoreURL)
            }
        case .cloneDeduplicate, .offloadLocalCopy, .createAlias, .createSymlink, .archive, .runProviderCleanup, .runPackageManagerCleanup, .inspectOnly:
            throw UndoManagerServiceError.undoUnavailable
        }

        var restored = undo
        restored.status = .restored
        try await store.saveUndoRecord(restored)
        if let regretReason {
            let log = try await store.loadOperationLog(id: undo.operationLogID)
            let originalTargetPath: String? = switch log?.operationType {
            case .createAlias, .createSymlink, .move, .rename, .moveToTrash, .archive:
                log?.beforeState["path"] ?? undo.restoreURL?.path
            default:
                undo.restoreURL?.path ?? log?.beforeState["path"]
            }
            let fileID = log?.beforeState["file_id"] ?? originalTargetPath
            if let fileID {
                try await memory.recordRegret(
                    operationLogID: undo.operationLogID,
                    restoredFileID: fileID,
                    reason: regretReason,
                    restoredFilePath: originalTargetPath
                )
            } else {
                logger.warning("Cannot record regret: no file_id in beforeState and no restoreURL for undo \(undo.id, privacy: .public)")
            }
        }
        return restored
    }

    /// Recreate a missing parent directory after validating safety policy and
    /// verifying no intermediate user ancestor is a symlink.
    private func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if case .deny = policy.decide(target: parent, isDirectory: true) {
            throw SafetyAuditError.unsafeDestination(parent)
        }
        try verifyNoSymlinkAncestors(for: parent)
        guard !Self.itemExistsOnDisk(at: parent) else {
            return
        }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func verifyNoSymlinkAncestors(for directory: URL) throws {
        let components = directory.pathComponents
        // Skip root ("/") and depth-1 system symlinks ("/var", "/tmp", "/etc").
        guard components.count > 2 else { return }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for index in 1..<components.count {
            current.appendPathComponent(components[index], isDirectory: true)
            guard index >= 2 else { continue }
            var st = Darwin.stat()
            if Darwin.lstat(current.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    throw SafetyAuditError.unsafeDestination(current)
                }
            } else if errno == ENOENT || errno == ENOTDIR {
                break
            } else {
                throw SafetyAuditError.unsafeDestination(current)
            }
        }
    }

    /// When the original restore location is occupied, restore alongside it
    /// with a numeric suffix instead of failing outright. Uses lstat so broken
    /// symlinks count as existing entries, and preserves dots inside folder names.
    private func collisionFreeRestoreURL(_ restoreURL: URL, isDirectory: Bool = false) throws -> URL {
        guard Self.itemExistsOnDisk(at: restoreURL) else {
            return restoreURL
        }
        let parent = restoreURL.deletingLastPathComponent()
        let base = isDirectory ? restoreURL.lastPathComponent : restoreURL.deletingPathExtension().lastPathComponent
        let ext = isDirectory ? "" : restoreURL.pathExtension
        for counter in 1...1000 {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let candidate = parent.appendingPathComponent("\(base)-restored-\(counter)\(suffix)", isDirectory: isDirectory)
            if !Self.itemExistsOnDisk(at: candidate) {
                return candidate
            }
        }
        throw UndoManagerServiceError.restoreDestinationExists(restoreURL)
    }

    nonisolated private static func itemExistsOnDisk(at url: URL) -> Bool {
        var st = Darwin.stat()
        return Darwin.lstat(url.path, &st) == 0
    }

    nonisolated private static func isDirectoryOnDisk(at url: URL) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Verify the moved-aside file is still the one this record moved (the
    /// move/rename executor now records the moved artifact's identity in
    /// afterState["moved_identity"]). Legacy records without it restore as before.
    private func verifyMoveSourceIdentity(of undo: UndoRecord, currentURL: URL) async throws {
        let log = try await store.loadOperationLog(id: undo.operationLogID)
        guard let identityString = log?.afterState["moved_identity"] ?? log?.afterState["artifact_identity"],
              let expected = FileArtifactIdentity.decode(identityString) else {
            return
        }
        guard let actual = FileArtifactIdentity.capture(at: currentURL), actual == expected else {
            throw UndoManagerServiceError.trashArtifactIdentityMismatch(currentURL)
        }
    }

    /// Verify the item currently in Trash is the one this undo record trashed.
    /// The identity was captured in the operation log's `afterState` at trash
    /// time; legacy records without a `trash_identity` key are restored as
    /// before (documented backward-compatibility choice — their 30-day
    /// `validUntil` window bounds the exposure).
    private func verifyTrashIdentity(of undo: UndoRecord, trashURL: URL) async throws {
        let log = try await store.loadOperationLog(id: undo.operationLogID)
        guard let identityString = log?.afterState["trash_identity"],
              let expected = FileArtifactIdentity.decode(identityString) else {
            // No identity recorded (legacy record) — nothing to verify against.
            if log?.afterState["trash_identity"] == nil {
                return
            }
            throw UndoManagerServiceError.trashArtifactIdentityUnknown(trashURL)
        }
        let actual = FileArtifactIdentity.capture(at: trashURL)
        guard actual == expected else {
            throw UndoManagerServiceError.trashArtifactIdentityMismatch(trashURL)
        }
    }

    /// Verify it is safe to delete `artifactURL` for this undo record:
    /// 1. For archive undo pairs, the original file must already be restored before
    ///    the archive copy (the only remaining copy) is deleted.
    /// 2. The artifact at `artifactURL` must be the exact file this record created
    ///    (device/inode match). A different file is never deleted.
    private func verifyOwnership(of undo: UndoRecord, artifactURL: URL) async throws {
        let siblingRecords = try await store.loadUndoRecords(operationLogID: undo.operationLogID)
        if let originalRestore = siblingRecords.first(where: { $0.inverseAction == .restore }),
           originalRestore.status != .restored {
            let originalPermanentlyGone: Bool = switch originalRestore.status {
            case .failed, .expired, .notUndoable:
                true
            case .available, .pending, .partiallyUndoable:
                originalRestore.trashURL.map { !Self.itemExistsOnDisk(at: $0) } ?? true
            case .restored, .reinstallable:
                false
            }
            if originalPermanentlyGone {
                if originalRestore.status == .available || originalRestore.status == .pending {
                    var failedOriginal = originalRestore
                    failedOriginal.status = .failed
                    try? await store.saveUndoRecord(failedOriginal)
                }
                var failedArchiveUndo = undo
                failedArchiveUndo.status = .failed
                try? await store.saveUndoRecord(failedArchiveUndo)
            }
            throw UndoManagerServiceError.archiveOriginalNotRestored(originalRestore.restoreURL ?? artifactURL)
        }
        let log = try await store.loadOperationLog(id: undo.operationLogID)
        guard let identityString = log?.afterState["artifact_identity"],
              let expected = FileArtifactIdentity.decode(identityString) else {
            throw UndoManagerServiceError.restoreArtifactIdentityUnknown(artifactURL)
        }
        let actual = FileArtifactIdentity.capture(at: artifactURL)
        guard actual == expected else {
            throw UndoManagerServiceError.restoreArtifactIdentityMismatch(artifactURL)
        }
    }

    nonisolated private static func decodeTags(_ value: String) -> [String] {
        guard !value.isEmpty else {
            return []
        }
        if value.hasPrefix("["),
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }
        return value.split(separator: ",").map(String.init)
    }
}
