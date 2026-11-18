import AppKit
import Darwin
import Foundation
import os

/// Abstraction over the platform Trash operation so the Core executor stays
/// free of AppKit. The AppKit layer provides the FileManager.trashItem
/// implementation; tests inject a recording double.
public protocol TrashService: Sendable {
    func trashItem(at url: URL) throws -> URL?
}

public struct ExecutionSummary: Sendable {
    public var logs: [OperationLog]
    public var undoRecords: [UndoRecord]
    public var failures: [String]
    /// Action IDs that had at least one failed target. Used to mark actions as `.failed` instead of `.completed`.
    public var failedActionIDs: Set<String>
    /// True when the safety auditor required manual review, so the caller can
    /// guide the user to refresh file identities with a new scan — without
    /// matching on localized failure strings.
    public var requiresRescan = false
}

public enum ActionExecutorError: Error, LocalizedError, Sendable {
    case missingDestination
    case missingTarget(String)
    case unsupportedAction(ActionType)
    case packageCandidateMissing(String)
    case processFailed(String)
    case manualReviewRequired(ActionType)
    /// The action already ran once (executedAt stamped); refusing to run it again.
    case alreadyExecuted(String)
    case batchLimitExceeded(String)
    /// The caller cancelled the batch. Actions not yet started were not run.
    case cancelled(remaining: Int)
    /// The undo trail could not be persisted ahead of the mutation, so the
    /// mutation was refused — deleting without a recoverable trail is never acceptable.
    case undoTrailUnavailable(String)
    /// A tool the command depends on is running (e.g. Simulator during simctl).
    case toolRunning(String)
    /// Another batch execution is already in progress on this executor.
    case executionInProgress
    /// The package-cleanup candidate is not on the approved command allowlist.
    case disallowedPackageCommand(String)

    public var errorDescription: String? {
        switch self {
        case .missingDestination: String(localized: "The planned action is missing a destination.")
        case .missingTarget(let id): String(localized: "Missing target \(id).")
        case .unsupportedAction(let action): String(localized: "Unsupported action: \(action.rawValue)")
        case .packageCandidateMissing(let id): String(localized: "Missing package cleanup candidate: \(id).")
        case .processFailed(let message): message
        case .manualReviewRequired(let action): String(localized: "Manual review is still required before executing \(action.rawValue).")
        case .alreadyExecuted(let id): String(localized: "Action \(id) was already executed and cannot run again.")
        case .batchLimitExceeded(let reason): String(localized: "Batch limit exceeded: \(reason)")
        case .cancelled(let remaining): String(localized: "Execution cancelled; \(remaining) remaining actions were not run.")
        case .undoTrailUnavailable(let reason): String(localized: "Could not record the undo trail (\(reason)); the action was not performed.")
        case .toolRunning(let name): String(localized: "Quit \(name) first, then try again.")
        case .executionInProgress:
            String(localized: "Another cleanup batch is already running. Wait for it to finish before starting a new one.")
        case .disallowedPackageCommand(let command):
            String(localized: "Package cleanup command is not on the approved allowlist: \(command).")
        }
    }
}

public actor ActionExecutor {
    private let store: SQLiteStore
    private let auditor: SafetyAuditor
    private let fileManager: FileManager
    private let trash: TrashService
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ActionExecutor")
    private let executorVersion = "1.0"
    private let commandTimeout: TimeInterval
    private let policy: PathSafetyPolicy
    private let homeDirectoryOverride: URL?
    /// Set by cancelExecution(); checked between actions so long batches can
    /// stop after the current action instead of running everything.
    private var isCancelled = false
    /// Prevents concurrent reentrancy on execute(actions:...) across suspension points.
    private var isExecuting = false

    private struct ActionOutcome {
        var summary: ExecutionSummary
        var persistFailed: Bool
    }

    public init(
        store: SQLiteStore,
        auditor: SafetyAuditor = SafetyAuditor(),
        fileManager: FileManager = .default,
        trash: TrashService? = nil,
        commandTimeout: TimeInterval = 600,
        policy: PathSafetyPolicy = PathSafetyPolicy(),
        homeDirectoryOverride: URL? = nil
    ) {
        self.store = store
        self.auditor = auditor
        self.fileManager = fileManager
        self.trash = trash ?? FileSystemTrashProvider()
        self.commandTimeout = commandTimeout
        self.policy = policy
        self.homeDirectoryOverride = homeDirectoryOverride
    }

    /// Stop the in-flight batch after the currently executing action completes.
    public func cancelExecution() {
        isCancelled = true
    }

    public func execute(
        actions: [PlannedAction],
        filesByID: [String: FileRecord],
        packageCandidates: [PackageCleanupCandidate] = [],
        progress: (@Sendable (Int) async -> Void)? = nil
    ) async -> ExecutionSummary {
        guard !isExecuting else {
            return ExecutionSummary(
                logs: [],
                undoRecords: [],
                failures: [ActionExecutorError.executionInProgress.localizedDescription],
                failedActionIDs: Set(actions.map(\.id))
            )
        }
        isExecuting = true
        defer { isExecuting = false }

        let executableActions = actions.filter { $0.userDecision == .approved || $0.userDecision == .alwaysDoThis }
        if let capError = validateBatchLimits(executableActions, filesByID: filesByID) {
            return capError
        }

        let filesByPath = Dictionary(filesByID.values.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        var state = BatchAccumulation()
        isCancelled = false

        for action in executableActions {
            if isCancelled || Task.isCancelled {
                let remaining = executableActions.count - state.completed
                state.failures.append(ActionExecutorError.cancelled(remaining: remaining).localizedDescription)
                break
            }
            await runBatchStep(
                action: action, filesByID: filesByID, filesByPath: filesByPath,
                packageCandidates: packageCandidates, state: &state
            )
            state.completed += 1
            await progress?(state.completed)
        }

        return ExecutionSummary(
            logs: state.logs, undoRecords: state.undoRecords, failures: state.failures,
            failedActionIDs: state.failedActionIDs, requiresRescan: state.requiresRescan
        )
    }

    private struct BatchAccumulation {
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var failures: [String] = []
        var failedActionIDs: Set<String> = []
        var completed = 0
        var requiresRescan = false
    }

    private func validateBatchLimits(
        _ executableActions: [PlannedAction],
        filesByID: [String: FileRecord]
    ) -> ExecutionSummary? {
        if executableActions.count > ExecutionLimits.maxActionsPerBatch {
            let reason = "\(executableActions.count) approved actions exceeds the per-batch cap of "
                + "\(ExecutionLimits.maxActionsPerBatch). Approve fewer actions at a time."
            return ExecutionSummary(
                logs: [], undoRecords: [],
                failures: [ActionExecutorError.batchLimitExceeded(reason).localizedDescription],
                failedActionIDs: Set(executableActions.map(\.id))
            )
        }
        let byteCountedTypes: Set<ActionType> = [.moveToTrash, .move, .rename, .archive]
        let byteTargetIDs = Set(executableActions.filter { byteCountedTypes.contains($0.actionType) }.flatMap(\.targets))
        let batchBytes = byteTargetIDs.compactMap { filesByID[$0]?.sizeBytes }.reduce(Int64(0), +)
        if batchBytes > ExecutionLimits.maxBytesPerBatch {
            let reason = "Selected actions total \(batchBytes.formattedByteCount), over the per-batch cap of "
                + "\(ExecutionLimits.maxBytesPerBatch.formattedByteCount)."
            return ExecutionSummary(
                logs: [], undoRecords: [],
                failures: [ActionExecutorError.batchLimitExceeded(reason).localizedDescription],
                failedActionIDs: Set(executableActions.map(\.id))
            )
        }
        return nil
    }

    private func runBatchStep(
        action: PlannedAction,
        filesByID: [String: FileRecord],
        filesByPath: [String: FileRecord],
        packageCandidates: [PackageCleanupCandidate],
        state: inout BatchAccumulation
    ) async {
        do {
            if action.executedAt != nil {
                throw ActionExecutorError.alreadyExecuted(action.id)
            }
            let audit = try await auditor.audit(action: action, filesByID: filesByID, filesByPath: filesByPath)
            guard audit.decision == .allowed else {
                throw ActionExecutorError.manualReviewRequired(action.actionType)
            }
            let outcome = try await execute(
                action: action, filesByID: filesByID, filesByPath: filesByPath, packageCandidates: packageCandidates
            )
            state.logs.append(contentsOf: outcome.summary.logs)
            state.undoRecords.append(contentsOf: outcome.summary.undoRecords)
            state.failedActionIDs.formUnion(outcome.summary.failedActionIDs)
            if outcome.persistFailed {
                state.failures.append(String(
                    localized: "Undo records may not persist across app restart.",
                    comment: "Execution summary note when the undo trail could not be written"
                ))
            }
            if !outcome.summary.failures.isEmpty {
                state.failedActionIDs.insert(action.id)
                state.failures.append(contentsOf: outcome.summary.failures)
            }
        } catch {
            logger.error("Action failed: \(error.localizedDescription, privacy: .public)")
            if case ActionExecutorError.manualReviewRequired = error {
                state.requiresRescan = true
            }
            state.failedActionIDs.insert(action.id)
            state.failures.append(error.localizedDescription)
        }
    }

    private func execute(
        action: PlannedAction,
        filesByID: [String: FileRecord],
        filesByPath: [String: FileRecord],
        packageCandidates: [PackageCleanupCandidate]
    ) async throws -> ActionOutcome {
        switch action.actionType {
        case .moveToTrash:
            return await moveToTrash(action: action, filesByID: filesByID)
        case .move:
            return try await move(action: action, filesByID: filesByID)
        case .tag:
            return await tag(action: action, filesByID: filesByID)
        case .createAlias:
            return await createAlias(action: action, filesByID: filesByID)
        case .createSymlink:
            return await createSymlink(action: action, filesByID: filesByID)
        case .archive:
            return try await archive(action: action, filesByID: filesByID)
        case .runPackageManagerCleanup:
            return try await runPackageCleanup(action: action, packageCandidates: packageCandidates)
        case .rename:
            return try await rename(action: action, filesByID: filesByID)
        case .cloneDeduplicate:
            return await cloneDeduplicate(action: action, filesByID: filesByID, filesByPath: filesByPath)
        case .offloadLocalCopy, .runProviderCleanup, .inspectOnly, .restore, .unfoldClone:
            throw ActionExecutorError.unsupportedAction(action.actionType)
        }
    }

    private func moveToTrash(action: PlannedAction, filesByID: [String: FileRecord]) async -> ActionOutcome {
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var errors: [String] = []
        var persistFailed = false
        let home = homeDirectoryOverride ?? PathSafetyPolicy.realHomeDirectory
        for targetID in action.targets {
            guard let record = filesByID[targetID] else {
                errors.append(ActionExecutorError.missingTarget(targetID).localizedDescription)
                continue
            }
            let validUntil = Calendar.current.date(byAdding: .day, value: 30, to: Date())
            let (log, undo) = makeLogAndUndo(
                action: action,
                type: .moveToTrash,
                before: ["path": record.displayPath, "file_id": record.id],
                after: [:],
                result: "moving_to_trash",
                inverse: .restore,
                restoreURL: record.url,
                trashURL: nil,
                validUntil: validUntil,
                undoStatus: .pending
            )
            do {
                try await persistPendingTrail(log, undo)
            } catch {
                errors.append(error.localizedDescription)
                continue
            }
            let launchAgentLabel = LaunchItems.userAgentLabel(at: record.url, homeDirectory: home)
            let trashURL: URL?
            do {
                try await auditor.verifyTargetUnchanged(record)
                trashURL = try trash.trashItem(at: record.url)
            } catch {
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
                continue
            }
            if let launchAgentLabel {
                await LaunchItems.bootoutUserAgent(label: launchAgentLabel, plistURL: record.url, homeDirectory: home)
            }
            let finalized = await finalizeTrashTrail(log: log, undo: undo, trashURL: trashURL)
            persistFailed = persistFailed || finalized.persistFailed
            logs.append(finalized.log)
            undoRecords.append(finalized.undo)
        }
        return ActionOutcome(
            summary: ExecutionSummary(logs: logs, undoRecords: undoRecords, failures: errors, failedActionIDs: []),
            persistFailed: persistFailed
        )
    }

    private struct FinalizedTrashTrail {
        let log: OperationLog
        let undo: UndoRecord
        let persistFailed: Bool
    }

    private func finalizeTrashTrail(
        log: OperationLog, undo: UndoRecord, trashURL: URL?
    ) async -> FinalizedTrashTrail {
        var finalizedLog = log
        finalizedLog.result = "moved_to_trash"
        finalizedLog.afterState = ["trash_path": trashURL?.path ?? ""]
        if let trashURL {
            finalizedLog.afterState["trash_identity"] = FileArtifactIdentity.capture(at: trashURL)?.encodedString
        }
        var finalizedUndo = undo
        finalizedUndo.trashURL = trashURL
        finalizedUndo.status = .available
        let persistFailed = await persistFinalizedTrail(log: finalizedLog, undoRecords: [finalizedUndo])
        return FinalizedTrashTrail(log: finalizedLog, undo: finalizedUndo, persistFailed: persistFailed)
    }

    private func cloneDeduplicate(
        action: PlannedAction,
        filesByID: [String: FileRecord],
        filesByPath: [String: FileRecord]
    ) async -> ActionOutcome {
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var errors: [String] = []
        var hadFailure = false
        var persistFailed = false

        guard let keeperURL = action.destination else {
            return ActionOutcome(
                summary: ExecutionSummary(
                    logs: [], undoRecords: [],
                    failures: [ActionExecutorError.missingDestination.localizedDescription],
                    failedActionIDs: [action.id]
                ),
                persistFailed: false
            )
        }
        guard let keeper = filesByPath[keeperURL.path] ?? filesByID.values.first(where: { $0.url.path == keeperURL.path }) else {
            return ActionOutcome(
                summary: ExecutionSummary(
                    logs: [], undoRecords: [],
                    failures: [SafetyAuditError.missingKeeper(keeperURL).localizedDescription],
                    failedActionIDs: [action.id]
                ),
                persistFailed: false
            )
        }

        for targetID in action.targets {
            guard let record = filesByID[targetID] else {
                errors.append(ActionExecutorError.missingTarget(targetID).localizedDescription)
                hadFailure = true
                continue
            }
            let (log, undo) = makeLogAndUndo(
                action: action,
                type: .cloneDeduplicate,
                before: ["path": record.displayPath, "file_id": record.id],
                after: [:],
                result: "folding_into_clone",
                inverse: .unfoldClone,
                restoreURL: record.url,
                trashURL: keeper.url,
                validUntil: nil,
                undoStatus: .pending
            )
            do {
                try await persistPendingTrail(log, undo)
            } catch {
                errors.append(error.localizedDescription)
                hadFailure = true
                continue
            }
            do {
                try await auditor.verifyTargetUnchanged(record)
                try await auditor.verifyTargetUnchanged(keeper)
            } catch {
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
                hadFailure = true
                continue
            }

            switch APFSCloneService.fold(duplicate: record.url, keeper: keeper.url) {
            case .folded(let freedBytes):
                var finalizedLog = log
                finalizedLog.result = "folded_into_clone"
                finalizedLog.afterState = [
                    "keeper_path": keeper.displayPath,
                    "freed_bytes": String(freedBytes)
                ]
                if let identity = FileArtifactIdentity.capture(at: record.url) {
                    finalizedLog.afterState["clone_identity"] = identity.encodedString
                }
                var finalizedUndo = undo
                finalizedUndo.status = .available
                if await persistFinalizedTrail(log: finalizedLog, undoRecords: [finalizedUndo]) {
                    persistFailed = true
                }
                logs.append(finalizedLog)
                undoRecords.append(finalizedUndo)
            case .alreadyShared:
                var infoLog = log
                infoLog.result = "already_shared"
                var droppedUndo = undo
                droppedUndo.status = .failed
                if await persistFinalizedTrail(log: infoLog, undoRecords: [droppedUndo]) {
                    persistFailed = true
                }
                logs.append(infoLog)
            case .skipped(let reason), .changed(let reason), .failed(let reason):
                await downgradePendingTrail(log, undo, error: reason)
                errors.append("\(record.displayPath): \(reason)")
                hadFailure = true
            }
        }
        return ActionOutcome(
            summary: ExecutionSummary(
                logs: logs, undoRecords: undoRecords, failures: errors, failedActionIDs: hadFailure ? [action.id] : []
            ),
            persistFailed: persistFailed
        )
    }

    private func move(action: PlannedAction, filesByID: [String: FileRecord]) async throws -> ActionOutcome {
        guard let destination = action.destination else {
            throw ActionExecutorError.missingDestination
        }
        try validatedDestination(destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var errors: [String] = []
        var persistFailed = false
        for targetID in action.targets {
            guard let record = filesByID[targetID] else {
                errors.append(ActionExecutorError.missingTarget(targetID).localizedDescription)
                continue
            }
            let (log, undo) = makeLogAndUndo(
                action: action,
                type: .move,
                before: ["path": record.displayPath],
                after: [:],
                result: "moving",
                inverse: .move,
                restoreURL: record.url,
                trashURL: nil,
                undoStatus: .pending
            )
            do {
                try await persistPendingTrail(log, undo)
            } catch {
                errors.append(error.localizedDescription)
                continue
            }
            do {
                try await auditor.verifyTargetUnchanged(record)
                let newURL = try moveItem(from: record, to: destination)
                var afterState: [String: String] = ["path": newURL.path]
                if let identity = FileArtifactIdentity.capture(at: newURL) {
                    afterState["moved_identity"] = identity.encodedString
                }
                var finalizedLog = log
                finalizedLog.result = "moved"
                finalizedLog.afterState = afterState
                var finalizedUndo = undo
                finalizedUndo.trashURL = newURL
                finalizedUndo.status = .available
                logs.append(finalizedLog)
                undoRecords.append(finalizedUndo)
                if await persistFinalizedTrail(log: finalizedLog, undoRecords: [finalizedUndo]) {
                    persistFailed = true
                }
            } catch {
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
            }
        }
        return ActionOutcome(
            summary: ExecutionSummary(logs: logs, undoRecords: undoRecords, failures: errors, failedActionIDs: []),
            persistFailed: persistFailed
        )
    }

    private func tag(action: PlannedAction, filesByID: [String: FileRecord]) async -> ActionOutcome {
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var errors: [String] = []
        var persistFailed = false
        for targetID in action.targets {
            guard let record = filesByID[targetID] else {
                errors.append(ActionExecutorError.missingTarget(targetID).localizedDescription)
                continue
            }
            let (log, undo) = makeLogAndUndo(
                action: action,
                type: .tag,
                before: ["tags": "[]"],
                after: [:],
                result: "tagging",
                inverse: .tag,
                restoreURL: record.url,
                undoStatus: .pending
            )
            do {
                try await persistPendingTrail(log, undo)
            } catch {
                errors.append(error.localizedDescription)
                continue
            }
            do {
                try await auditor.verifyTargetUnchanged(record)
                let oldTags = try FinderTagHelper.read(from: record.url)
                let tagName = OrganizationPlanner.taxonomyTagName(for: record, risk: action.risk)
                var updatedTags = oldTags
                let alreadyTagged = oldTags.contains { existing in
                    let base = existing.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? existing
                    return base == tagName
                }
                if !alreadyTagged {
                    updatedTags.append(tagName)
                }
                let sortedTags = updatedTags.sorted()
                try FinderTagHelper.write(sortedTags, to: record.url)
                var finalizedLog = log
                finalizedLog.beforeState = ["tags": Self.encodeTags(oldTags)]
                finalizedLog.afterState = ["tags": Self.encodeTags(sortedTags)]
                finalizedLog.result = "tagged"
                var finalizedUndo = undo
                finalizedUndo.status = .available
                logs.append(finalizedLog)
                undoRecords.append(finalizedUndo)
                if await persistFinalizedTrail(log: finalizedLog, undoRecords: [finalizedUndo]) {
                    persistFailed = true
                }
            } catch {
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
            }
        }
        return ActionOutcome(
            summary: ExecutionSummary(logs: logs, undoRecords: undoRecords, failures: errors, failedActionIDs: []),
            persistFailed: persistFailed
        )
    }

    nonisolated private static func encodeTags(_ tags: [String]) -> String {
        guard let data = try? JSONEncoder().encode(tags),
              let json = String(data: data, encoding: .utf8) else {
            return tags.joined(separator: ",")
        }
        return json
    }

    private func createAlias(action: PlannedAction, filesByID: [String: FileRecord]) async -> ActionOutcome {
        let destination: URL
        do {
            destination = try preparedOrganizationDestination(action.destination, folderName: AppIdentity.aliasesFolderName)
        } catch {
            return ActionOutcome(
                summary: ExecutionSummary(logs: [], undoRecords: [], failures: [error.localizedDescription], failedActionIDs: []),
                persistFailed: false
            )
        }
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var errors: [String] = []
        var persistFailed = false
        for targetID in action.targets {
            guard let record = filesByID[targetID] else {
                errors.append(ActionExecutorError.missingTarget(targetID).localizedDescription)
                continue
            }
            let aliasURL = collisionFreeArtifactURL(for: record.fileName, suffix: ".alias", in: destination)
            let (log, undo) = makeLogAndUndo(
                action: action,
                type: .createAlias,
                before: ["path": record.displayPath],
                after: [:],
                result: "creating_alias",
                inverse: .moveToTrash,
                restoreURL: aliasURL,
                undoStatus: .pending
            )
            do {
                try await persistPendingTrail(log, undo)
            } catch {
                errors.append(error.localizedDescription)
                continue
            }
            do {
                try await auditor.verifyTargetUnchanged(record)
                let data = try record.url.bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: aliasURL)
                var afterState: [String: String] = ["alias_path": aliasURL.path]
                if let identity = FileArtifactIdentity.capture(at: aliasURL) {
                    afterState["artifact_identity"] = identity.encodedString
                }
                var finalizedLog = log
                finalizedLog.result = "alias_created"
                finalizedLog.afterState = afterState
                var finalizedUndo = undo
                finalizedUndo.status = .available
                logs.append(finalizedLog)
                undoRecords.append(finalizedUndo)
                if await persistFinalizedTrail(log: finalizedLog, undoRecords: [finalizedUndo]) {
                    persistFailed = true
                }
            } catch {
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
            }
        }
        return ActionOutcome(
            summary: ExecutionSummary(
                logs: logs, undoRecords: undoRecords, failures: errors, failedActionIDs: errors.isEmpty ? [] : [action.id]
            ),
            persistFailed: persistFailed
        )
    }

    private func createSymlink(action: PlannedAction, filesByID: [String: FileRecord]) async -> ActionOutcome {
        let destination: URL
        do {
            destination = try preparedOrganizationDestination(action.destination, folderName: AppIdentity.linksFolderName)
        } catch {
            return ActionOutcome(
                summary: ExecutionSummary(logs: [], undoRecords: [], failures: [error.localizedDescription], failedActionIDs: []),
                persistFailed: false
            )
        }
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var errors: [String] = []
        var persistFailed = false
        for targetID in action.targets {
            guard let record = filesByID[targetID] else {
                errors.append(ActionExecutorError.missingTarget(targetID).localizedDescription)
                continue
            }
            let linkURL = collisionFreeArtifactURL(for: record.fileName, suffix: "", in: destination)
            let (log, undo) = makeLogAndUndo(
                action: action,
                type: .createSymlink,
                before: ["path": record.displayPath],
                after: [:],
                result: "creating_symlink",
                inverse: .moveToTrash,
                restoreURL: linkURL,
                undoStatus: .pending
            )
            do {
                try await persistPendingTrail(log, undo)
            } catch {
                errors.append(error.localizedDescription)
                continue
            }
            do {
                try await auditor.verifyTargetUnchanged(record)
                try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: record.url)
                var afterState: [String: String] = ["link_path": linkURL.path]
                if let identity = FileArtifactIdentity.capture(at: linkURL) {
                    afterState["artifact_identity"] = identity.encodedString
                }
                var finalizedLog = log
                finalizedLog.result = "symlink_created"
                finalizedLog.afterState = afterState
                var finalizedUndo = undo
                finalizedUndo.status = .available
                logs.append(finalizedLog)
                undoRecords.append(finalizedUndo)
                if await persistFinalizedTrail(log: finalizedLog, undoRecords: [finalizedUndo]) {
                    persistFailed = true
                }
            } catch {
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
            }
        }
        return ActionOutcome(
            summary: ExecutionSummary(
                logs: logs, undoRecords: undoRecords, failures: errors, failedActionIDs: errors.isEmpty ? [] : [action.id]
            ),
            persistFailed: persistFailed
        )
    }

    private func archive(action: PlannedAction, filesByID: [String: FileRecord]) async throws -> ActionOutcome {
        let destination = try preparedOrganizationDestination(action.destination, folderName: AppIdentity.archiveFolderName)
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var errors: [String] = []
        var persistFailed = false
        for targetID in action.targets {
            guard let record = filesByID[targetID] else {
                errors.append(ActionExecutorError.missingTarget(targetID).localizedDescription)
                continue
            }
            let archiveName = "\(record.fileName)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).zip"
            let archiveURL = destination.appendingPathComponent(archiveName, isDirectory: false)
            let (log, undo) = makeLogAndUndo(
                action: action,
                type: .archive,
                before: ["path": record.displayPath, "file_id": record.id],
                after: [:],
                result: "archiving",
                inverse: .restore,
                restoreURL: record.url,
                trashURL: nil,
                validUntil: Calendar.current.date(byAdding: .day, value: 30, to: Date()),
                undoStatus: .pending
            )
            do {
                try await persistPendingTrail(log, undo)
            } catch {
                errors.append(error.localizedDescription)
                continue
            }
            do {
                try await auditor.verifyTargetUnchanged(record)
            } catch {
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
                continue
            }
            if let archiveError = await writeZipArchive(of: record.url, to: archiveURL) {
                if fileManager.fileExists(atPath: archiveURL.path) {
                    try? fileManager.removeItem(at: archiveURL)
                }
                await downgradePendingTrail(log, undo, error: archiveError)
                errors.append(ActionExecutorError.processFailed(archiveError).localizedDescription)
                continue
            }
            var trashURL: URL?
            do {
                try await auditor.verifyTargetUnchanged(record)
                trashURL = try trash.trashItem(at: record.url)
            } catch {
                do {
                    try fileManager.removeItem(at: archiveURL)
                } catch {
                    let msg = error.localizedDescription
                    logger.warning("Failed to clean up orphan archive \(archiveURL.path, privacy: .public): \(msg, privacy: .public)")
                }
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
                continue
            }
            var afterState: [String: String] = ["archive_path": archiveURL.path, "trash_path": trashURL?.path ?? ""]
            if let identity = FileArtifactIdentity.capture(at: archiveURL) {
                afterState["artifact_identity"] = identity.encodedString
            }
            if let trashURL {
                afterState["trash_identity"] = FileArtifactIdentity.capture(at: trashURL)?.encodedString
            }
            var finalizedLog = log
            finalizedLog.result = "archived_and_moved_original_to_trash"
            finalizedLog.afterState = afterState
            var finalizedUndo = undo
            finalizedUndo.trashURL = trashURL
            finalizedUndo.status = trashURL == nil ? .failed : .available
            let archiveTrashUndo = UndoRecord(
                id: UUID().uuidString,
                operationLogID: log.id,
                inverseAction: .moveToTrash,
                restoreURL: archiveURL,
                trashURL: nil,
                validUntil: nil,
                status: .available
            )
            logs.append(finalizedLog)
            undoRecords.append(finalizedUndo)
            undoRecords.append(archiveTrashUndo)
            if await persistFinalizedTrail(log: finalizedLog, undoRecords: [finalizedUndo, archiveTrashUndo]) {
                persistFailed = true
            }
        }
        return ActionOutcome(
            summary: ExecutionSummary(logs: logs, undoRecords: undoRecords, failures: errors, failedActionIDs: []),
            persistFailed: persistFailed
        )
    }

    private func writeZipArchive(of sourceURL: URL, to archiveURL: URL) async -> String? {
        if let coordError = Self.createZipArchiveWithCoordinator(of: sourceURL, to: archiveURL, fileManager: fileManager) {
            if DistributionChannel.supportsAdvanced {
                let result = await ProcessRunner.run(
                    URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: ["-c", "-k", "--keepParent", sourceURL.path, archiveURL.path],
                    timeout: commandTimeout
                )
                if result.exitCode == 0 {
                    return nil
                }
                return result.stderr.isEmpty ? coordError : result.stderr
            }
            return coordError
        }
        return nil
    }

    nonisolated private static func createZipArchiveWithCoordinator(
        of sourceURL: URL,
        to archiveURL: URL,
        fileManager: FileManager
    ) -> String? {
        let stagingDir = fileManager.temporaryDirectory
            .appendingPathComponent("tidybyte-archive-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        defer { try? fileManager.removeItem(at: stagingDir) }

        let stagedTarget = stagingDir.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
                return CocoaError(.fileNoSuchFile).localizedDescription
            }
            if isDir.boolValue {
                try fileManager.copyItem(at: sourceURL, to: stagedTarget)
            } else {
                do {
                    try fileManager.linkItem(at: sourceURL, to: stagedTarget)
                } catch {
                    try fileManager.copyItem(at: sourceURL, to: stagedTarget)
                }
            }
        } catch {
            return error.localizedDescription
        }

        var coordinationError: NSError?
        let copyErrorBox = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: stagingDir, options: [.forUploading], error: &coordinationError) { zippedURL in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: archiveURL.path) {
                    try fm.removeItem(at: archiveURL)
                }
                try fm.copyItem(at: zippedURL, to: archiveURL)
            } catch {
                copyErrorBox.withLock { $0 = error }
            }
        }
        let copyError = copyErrorBox.withLock { $0 }
        return (coordinationError ?? copyError)?.localizedDescription
    }

    /// First process name with a running instance, checked via NSWorkspace and libproc (sandbox-safe).
    static func firstRunning(_ names: [String]) async -> String? {
        guard !names.isEmpty else { return nil }
        let workspaceNames = await MainActor.run {
            var collected: Set<String> = []
            for app in NSWorkspace.shared.runningApplications {
                if let localized = app.localizedName?.lowercased() { collected.insert(localized) }
                if let bundle = app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() {
                    collected.insert(bundle)
                }
                if let exec = app.executableURL?.lastPathComponent.lowercased() { collected.insert(exec) }
            }
            return collected
        }
        if let hit = names.first(where: { workspaceNames.contains($0.lowercased()) }) {
            return hit
        }
        let posixSet = Set(runningExecutableNames().map { $0.lowercased() })
        return names.first { posixSet.contains($0.lowercased()) }
    }

    nonisolated private static func runningExecutableNames() -> Set<String> {
        var names: Set<String> = []
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return names }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return names }
        let actualCount = Int(bytes) / MemoryLayout<pid_t>.stride
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for idx in 0..<actualCount {
            let pid = pids[idx]
            guard pid > 0 else { continue }
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if len > 0 {
                let utf8 = pathBuffer.prefix(Int(len)).map { UInt8(bitPattern: $0) }
                let path = String(bytes: utf8, encoding: .utf8) ?? ""
                let executable = URL(fileURLWithPath: path).lastPathComponent
                if !executable.isEmpty {
                    names.insert(executable)
                }
            }
        }
        return names
    }

    private static let allowedPackageCommands: [String: Set<[String]>] = [
        "brew": [["cleanup", "--prune=all"], ["autoremove"]],
        "docker": [
            ["builder", "prune", "--force"],
            ["system", "prune", "--force"],
            ["system", "prune", "--volumes", "--force"],
            ["volume", "prune", "--force"]
        ],
        "npm": [["cache", "ls"], ["cache", "clean", "--force"]],
        "pip": [["cache", "list"], ["cache", "purge"]],
        "pip3": [["cache", "list"], ["cache", "purge"]],
        "pnpm": [["store", "prune"]],
        "xcrun": [["simctl", "delete", "unavailable"]]
    ]

    static func isAllowedPackageCommand(_ candidate: PackageCleanupCandidate) -> Bool {
        guard candidate.commandPath.isFileURL,
              !candidate.commandPath.pathComponents.contains("..") else {
            return false
        }
        let binary = candidate.commandPath.lastPathComponent
        if binary == "xcrun" && candidate.commandPath.path != "/usr/bin/xcrun" {
            return false
        }
        guard let allowedArgSets = allowedPackageCommands[binary] else {
            return false
        }
        return allowedArgSets.contains(candidate.arguments)
    }

    private func runPackageCleanup(
        action: PlannedAction,
        packageCandidates: [PackageCleanupCandidate]
    ) async throws -> ActionOutcome {
        guard DistributionChannel.supportsAdvanced else {
            throw ActionExecutorError.unsupportedAction(.runPackageManagerCleanup)
        }
        var logs: [OperationLog] = []
        var errors: [String] = []
        var persistFailed = false
        for targetID in action.targets {
            guard let candidate = packageCandidates.first(where: { $0.id == targetID }) else {
                errors.append(ActionExecutorError.packageCandidateMissing(targetID).localizedDescription)
                continue
            }
            guard Self.isAllowedPackageCommand(candidate) else {
                let commandText = ([candidate.commandPath.path] + candidate.arguments).joined(separator: " ")
                errors.append(ActionExecutorError.disallowedPackageCommand(commandText).localizedDescription)
                continue
            }
            if let running = await Self.firstRunning(candidate.blockingProcesses ?? []) {
                errors.append(ActionExecutorError.toolRunning(running).localizedDescription)
                continue
            }
            let result = await ProcessRunner.run(candidate.commandPath, arguments: candidate.arguments, timeout: commandTimeout)
            guard result.exitCode == 0 else {
                errors.append(ActionExecutorError.processFailed(result.stderr).localizedDescription)
                continue
            }
            let log = OperationLog(
                id: UUID().uuidString,
                plannedActionID: action.id,
                operationType: .runPackageManagerCleanup,
                beforeState: ["command": ([candidate.commandPath.path] + candidate.arguments).joined(separator: " ")],
                afterState: ["output": result.stdout],
                executorVersion: executorVersion,
                result: "command_completed",
                error: nil,
                timestamp: Date()
            )
            logs.append(log)
            if await persistFinalizedTrail(log: log, undoRecords: []) {
                persistFailed = true
            }
        }
        return ActionOutcome(
            summary: ExecutionSummary(logs: logs, undoRecords: [], failures: errors, failedActionIDs: []),
            persistFailed: persistFailed
        )
    }

    private func makeLogAndUndo(
        action: PlannedAction,
        type: ActionType,
        before: [String: String],
        after: [String: String],
        result: String,
        inverse: ActionType,
        restoreURL: URL?,
        trashURL: URL? = nil,
        validUntil: Date? = nil,
        undoStatus: UndoStatus = .available
    ) -> (OperationLog, UndoRecord) {
        let logID = UUID().uuidString
        let log = OperationLog(
            id: logID,
            plannedActionID: action.id,
            operationType: type,
            beforeState: before,
            afterState: after,
            executorVersion: executorVersion,
            result: result,
            error: nil,
            timestamp: Date()
        )
        let undo = UndoRecord(
            id: UUID().uuidString,
            operationLogID: logID,
            inverseAction: inverse,
            restoreURL: restoreURL,
            trashURL: trashURL,
            validUntil: validUntil,
            status: undoStatus
        )
        return (log, undo)
    }

    /// Write-ahead step shared by every mutating action: persist the PENDING
    /// log+undo BEFORE the filesystem mutation. Throws `undoTrailUnavailable`
    /// when persistence fails — the caller must then refuse the mutation.
    private func persistPendingTrail(_ log: OperationLog, _ undo: UndoRecord) async throws {
        do {
            try await store.saveOperationLog(log)
            try await store.saveUndoRecord(undo)
        } catch {
            throw ActionExecutorError.undoTrailUnavailable(error.localizedDescription)
        }
    }

    private func persistFinalizedTrail(log: OperationLog, undoRecords: [UndoRecord]) async -> Bool {
        var persistFailed = false
        do {
            try await store.saveOperationLog(log)
        } catch {
            logger.error("Failed to persist operation log: \(error.localizedDescription, privacy: .public)")
            persistFailed = true
        }
        for undo in undoRecords {
            do {
                try await store.saveUndoRecord(undo)
            } catch {
                logger.error("Failed to persist undo record: \(error.localizedDescription, privacy: .public)")
                persistFailed = true
            }
        }
        return persistFailed
    }

    /// Downgrades a pending trail after a failed step so the startup sweep
    /// never reports a phantom interrupted operation.
    private func downgradePendingTrail(
        _ log: OperationLog,
        _ undo: UndoRecord,
        error errorMessage: String? = nil
    ) async {
        var failedLog = log
        failedLog.result = "failed"
        if let errorMessage, !errorMessage.isEmpty {
            failedLog.error = errorMessage
        }
        var failedUndo = undo
        failedUndo.status = .failed
        try? await store.saveOperationLog(failedLog)
        try? await store.saveUndoRecord(failedUndo)
    }

    private func preparedOrganizationDestination(_ destination: URL?, folderName: String) throws -> URL {
        let home = homeDirectoryOverride ?? PathSafetyPolicy.realHomeDirectory
        let resolved = destination ?? home.appendingPathComponent(folderName, isDirectory: true)
        try validatedDestination(resolved)
        try fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
        return resolved
    }

    /// Reject destinations the policy forbids (protected, cloud-synced, Trash).
    /// An existing symlinked destination is judged by where it points: a leaf
    /// symlink into a protected area must not become a move/rename target.
    private func validatedDestination(_ destination: URL) throws {
        let resolved = destination.resolvingSymlinksInPath()
        if case .deny = policy.decide(target: resolved, isDirectory: true) {
            throw SafetyAuditError.unsafeDestination(destination)
        }
    }

    /// Moves each target into the destination folder under its own name (the
    /// action name suggests an in-place rename, but no name is set here).
    private func rename(action: PlannedAction, filesByID: [String: FileRecord]) async throws -> ActionOutcome {
        guard let destination = action.destination else {
            throw ActionExecutorError.missingDestination
        }
        try validatedDestination(destination)
        var logs: [OperationLog] = []
        var undoRecords: [UndoRecord] = []
        var errors: [String] = []
        var persistFailed = false
        for targetID in action.targets {
            guard let record = filesByID[targetID] else {
                errors.append(ActionExecutorError.missingTarget(targetID).localizedDescription)
                continue
            }
            let (log, undo) = makeLogAndUndo(
                action: action,
                type: .rename,
                before: ["path": record.displayPath],
                after: [:],
                result: "renaming",
                inverse: .rename,
                restoreURL: record.url,
                trashURL: nil,
                undoStatus: .pending
            )
            do {
                try await persistPendingTrail(log, undo)
            } catch {
                errors.append(error.localizedDescription)
                continue
            }
            do {
                try await auditor.verifyTargetUnchanged(record)
                let newURL = try moveItem(from: record, to: destination)
                var afterState: [String: String] = ["path": newURL.path]
                if let identity = FileArtifactIdentity.capture(at: newURL) {
                    afterState["moved_identity"] = identity.encodedString
                }
                var finalizedLog = log
                finalizedLog.result = "renamed"
                finalizedLog.afterState = afterState
                var finalizedUndo = undo
                finalizedUndo.trashURL = newURL
                finalizedUndo.status = .available
                logs.append(finalizedLog)
                undoRecords.append(finalizedUndo)
                if await persistFinalizedTrail(log: finalizedLog, undoRecords: [finalizedUndo]) {
                    persistFailed = true
                }
            } catch {
                await downgradePendingTrail(log, undo, error: error.localizedDescription)
                errors.append(error.localizedDescription)
            }
        }
        return ActionOutcome(
            summary: ExecutionSummary(logs: logs, undoRecords: undoRecords, failures: errors, failedActionIDs: []),
            persistFailed: persistFailed
        )
    }

    /// Collision-free artifact path inside `destination`: appends a numeric
    /// suffix when the name is taken so two same-named targets in one batch
    /// cannot silently overwrite each other's alias or symlink.
    private func collisionFreeArtifactURL(for fileName: String, suffix: String, in destination: URL) -> URL {
        var candidate = destination.appendingPathComponent(fileName + suffix, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let nsName = fileName as NSString
        let baseName = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var counter = 1
        repeat {
            let name = ext.isEmpty ? "\(baseName)-\(counter)\(suffix)" : "\(baseName)-\(counter).\(ext)\(suffix)"
            candidate = destination.appendingPathComponent(name, isDirectory: false)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Shared relocation helper for `.move` and `.rename`. Resolves a
    /// collision-free destination URL for `record` inside `destination`
    /// (appending a numeric suffix when the name is taken), then moves the
    /// item there. Identity capture and undo-record creation stay in the
    /// caller so each action keeps its own `OperationLog`/`UndoRecord` shape.
    private func moveItem(from record: FileRecord, to destination: URL) throws -> URL {
        var newURL = destination.appendingPathComponent(record.fileName, isDirectory: record.kind == .directory)
        if fileManager.fileExists(atPath: newURL.path) {
            let ext = record.url.pathExtension
            let baseName = record.url.deletingPathExtension().lastPathComponent
            var counter = 1
            repeat {
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                newURL = destination.appendingPathComponent("\(baseName)-\(counter)\(suffix)", isDirectory: record.kind == .directory)
                counter += 1
            } while fileManager.fileExists(atPath: newURL.path)
        }
        try fileManager.moveItem(at: record.url, to: newURL)
        return newURL
    }
}
