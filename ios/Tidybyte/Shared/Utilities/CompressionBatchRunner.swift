import BackgroundTasks
import Photos
import SwiftData
import UIKit

/// Keeps a batch going while the user is away, and keeps the screen awake.
///
/// - iOS 26 and later: a `BGContinuedProcessingTask` lets the batch run in the
///   background, with a system progress view. When that task ends (the user's
///   Cancel there, or the system; iOS reports both the same way), the batch
///   pauses like below and goes on when the app is back. Stop is in the app.
/// - Earlier systems, or when iOS refuses that task: iOS gives a short grant
///   (about 30 seconds). When it ends, the batch waits at the next item and
///   goes on once the app is active again (`waitWhilePaused`).
///
/// A pause never deletes originals: the batch keeps its saved copies and
/// deletes every original in one commit at the end, in the foreground
/// (`waitForForeground`), so iOS still asks once. Every path must call `end()`.
@MainActor
final class CompressionSession {
    /// Batches running now. The screen setting is restored when the last one ends.
    private static var active = 0
    private static var idleTimerWasDisabled = false
    /// Sessions that lost their background time and have not resumed yet.
    private static var pausedCount = 0

    /// True while any batch waits for the app to come back, or while the app is
    /// off screen. An item that throws then was interrupted, not broken (no GPU
    /// in the background, a suspended read): the loop runs it again on return,
    /// and its journal row is settled as skipped, not failed.
    static var isInterrupted: Bool {
        pausedCount > 0 || UIApplication.shared.applicationState != .active
    }

    /// What a batch loop does after an item throws.
    enum AfterFailure: Equatable, Sendable {
        /// The user stopped the batch.
        case stop
        /// Interrupted: run the item again once the app is back.
        case retry
        /// A real failure of this item.
        case fail
    }

    nonisolated static func afterFailure(
        userStopped: Bool,
        paused: Bool,
        appActive: Bool,
        isCancellationError: Bool
    ) -> AfterFailure {
        if userStopped { return .stop }
        // Before the cancel check: suspension can end work with a cancel error
        // that the user never asked for.
        if paused || !appActive { return .retry }
        if isCancellationError { return .stop }
        return .fail
    }

    private let title: String
    private var total: Int
    private var done = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The running `BGContinuedProcessingTask` (iOS 26+). `AnyObject` so the
    /// stored property needs no availability check.
    private var continuedTask: AnyObject?
    private var ended = false
    /// iOS ended this session's background time. It asks again on return.
    private var lostBackgroundTime = false {
        didSet {
            guard lostBackgroundTime != oldValue else { return }
            Self.pausedCount += lostBackgroundTime ? 1 : -1
        }
    }

    /// The loop's decision for an item that just threw.
    func afterFailure(userStopped: Bool, error: Error) -> AfterFailure {
        Self.afterFailure(
            userStopped: userStopped,
            paused: lostBackgroundTime,
            appActive: UIApplication.shared.applicationState == .active,
            isCancellationError: error is CancellationError
        )
    }

    /// Waits before an interrupted item runs again: for new background time
    /// after a pause, otherwise for the app to be on screen.
    func waitToRetry() async {
        if lostBackgroundTime {
            await waitWhilePaused()
        } else {
            await AppForeground.wait()
        }
    }

    private init(title: String, total: Int) {
        self.title = title
        self.total = total
    }

    /// `title` names the batch in the system progress view ("Compressing Videos").
    static func begin(title: String, total: Int) -> CompressionSession {
        let app = UIApplication.shared
        if active == 0 { idleTimerWasDisabled = app.isIdleTimerDisabled }
        active += 1
        app.isIdleTimerDisabled = true
        let session = CompressionSession(title: title, total: total)
        session.requestBackgroundTime()
        return session
    }

    /// Returns at once, unless iOS ended the background time. Then it waits
    /// until the app is active again (or the task is cancelled) and asks for
    /// new background time, so the next app switch is covered too.
    func waitWhilePaused() async {
        guard lostBackgroundTime else { return }
        await AppForeground.wait()
        guard UIApplication.shared.applicationState == .active else { return }
        lostBackgroundTime = false
        requestBackgroundTime()
    }

    /// Sets the item count once the batch knows it. A session can begin before
    /// the batch reads its list, so that read is covered too.
    func setTotal(_ total: Int) {
        self.total = total
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(total)
        }
    }

    /// Records finished items for the system progress view.
    func report(done: Int) {
        self.done = done
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(done)
            task.updateTitle(title, subtitle: L10n.format("%lld of %lld", done, total))
        }
    }

    /// The iOS delete prompt needs the app on screen. Call this before the
    /// commit: it returns at once in the foreground, and otherwise tells the
    /// user to open the app and waits for it.
    func waitForForeground() async {
        guard UIApplication.shared.applicationState != .active else { return }
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.updateTitle(title, subtitle: L10n.string("Open TidyByte to finish"))
        }
        await AppForeground.wait()
    }

    /// Idempotent. Restores the screen setting once no batch is running.
    func end() {
        guard !ended else { return }
        ended = true
        lostBackgroundTime = false
        Self.active -= 1
        if Self.active == 0 {
            UIApplication.shared.isIdleTimerDisabled = Self.idleTimerWasDisabled
        }
        stopBackgroundTime()
        finishContinuedTask(success: true)
    }

    private func requestBackgroundTime() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "TidyByte compression") {
            // iOS calls this on the main thread and needs the task ended before
            // it returns, or the watchdog can end the app. Stays synchronous.
            MainActor.assumeIsolated { self.backgroundTimeEnded() }
        }
        if #available(iOS 26.0, *) { submitContinuedTask() }
    }

    private func backgroundTimeEnded() {
        lostBackgroundTime = true
        stopBackgroundTime()
        finishContinuedTask(success: false)
    }

    private func stopBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        // One identifier per request: iOS ends the app on a second registration
        // of the same identifier. Info.plist permits `<bundle id>.batch.*`.
        let identifier = "\(bundleId).batch.\(UUID().uuidString)"
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask, let self, !self.ended else {
                    task.setTaskCompleted(success: true)
                    return
                }
                self.attach(continued)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: L10n.format("%lld of %lld", done, total)
        )
        // Start now or not at all. The short grant covers a refusal.
        request.strategy = .fail
        do {
            try scheduler.submit(request)
        } catch {
            AppLog.compression.info("Background processing not granted: \(error.localizedDescription, privacy: .public)")
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        task.progress.totalUnitCount = Int64(total)
        task.progress.completedUnitCount = Int64(done)
        task.expirationHandler = { [weak self] in
            // The user's Cancel in the system progress view, or the system: iOS
            // reports both here. The user chose "keep going and resume", so this
            // pauses like the short grant; Stop in the app ends the batch.
            Task { @MainActor in self?.backgroundTimeEnded() }
        }
        // This task keeps the app running now. Without this, the short grant's
        // expiry would pause a batch that may keep going.
        stopBackgroundTime()
    }

    private func finishContinuedTask(success: Bool) {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        continuedTask = nil
        task.setTaskCompleted(success: success)
    }
}

@MainActor
enum AppForeground {
    /// Returns once the app is active: at once when it already is, and also
    /// when the calling task is cancelled.
    static func wait() async {
        guard UIApplication.shared.applicationState != .active else { return }
        for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
            return
        }
    }
}

/// Runs `operation` in a new task, so the caller's cancellation does not reach
/// it. For a step that must finish once started: after Stop, the originals of
/// the copies already saved must still be deleted, and `deleteAssets` refuses
/// to start in a cancelled task.
func ignoringCancellation<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await Task { try await operation() }.value
}

/// Shared per-item loop for the photo + video batch compressions (COMP-12).
///
/// Both stacks share one loop shape: deterministic order, already-completed
/// skip, per-item journal swap, skipped/completed/cancel/sizeUnknown/failed
/// branches, and a counted summary. The loop bodies differed in exactly four
/// places (preset resolution, journal mediaType, skip-error type, service
/// entry), so the runner owns counting/summary/row-state while each VM's
/// `execute` closure owns the full journal-swap lifecycle (it alone knows the
/// resolved exportPreset id).

enum CompressionItemOutcome: Sendable {
    case skipped
    /// The copy is saved; the original waits for the batch's one delete commit.
    case saved(PendingOriginal)
}

/// A saved copy whose original is still in the library. The batch deletes all
/// originals in one `OriginalsCommit.commit` call, so iOS shows one delete
/// prompt per batch instead of one per item.
struct PendingOriginal: Sendable {
    let assetId: String
    let originalSize: Int64
    let compressedSize: Int64
    let swap: CompressionSwap
}

/// Status text for the two steps of a replace batch.
enum ReplacePhase: Equatable, Sendable {
    case idle
    case savingCopies(done: Int, total: Int)
    case removingOriginals(count: Int)
}

/// Owns one journal row: begin → optional progress hooks → exactly one terminal.
/// `finished` guard makes double-finalize impossible.
///
/// The initializer throws when the pending row cannot be persisted
/// (`CompressionJournalError`): callers must let that abort the item's swap —
/// running the save-then-delete without a durable journal row is what strands
/// unrecoverable duplicates.
@MainActor
final class CompressionSwap {
    private let record: CompressionRecord
    private let modelContext: ModelContext
    private let assetId: String
    private var finished = false

    /// Swaps that are still running or waiting for the delete-originals
    /// commit. Weak, so a swap dropped with its view model stops counting.
    private struct WeakSwap { weak var swap: CompressionSwap? }
    private static var liveSwaps: [String: WeakSwap] = [:]

    /// True while an in-memory swap still owns the pending row for this
    /// asset. `reconcile` must skip such rows: they are not crash leftovers,
    /// and deleting their copies would race the Originals Kept choice.
    static func isLive(assetId: String) -> Bool {
        liveSwaps[assetId]?.swap != nil
    }

    /// Marks the swap finished. Returns false when it already was.
    private func finish() -> Bool {
        guard beginFinish() else { return false }
        endFinish()
        return true
    }

    /// Claims the finished flag without unregistering the live swap. The async
    /// terminal paths (markFailed/markSkipped) use this plus `endFinish`, so
    /// `reconcile` (which skips live rows) cannot grab the row while the
    /// journal resolution is still in flight.
    private func beginFinish() -> Bool {
        guard !finished else { return false }
        finished = true
        return true
    }

    private func endFinish() {
        // Only clear our own entry: a newer swap for the same asset may own it.
        if Self.liveSwaps[assetId]?.swap === self {
            Self.liveSwaps[assetId] = nil
        }
    }

    init(
        mediaType: CompressionMediaType,
        assetId: String,
        originalSize: Int64,
        exportPreset: String,
        // True when the batch deletes the original after the copy is saved.
        deletesOriginal: Bool = false,
        modelContext: ModelContext
    ) throws {
        self.modelContext = modelContext
        self.assetId = assetId
        self.record = try CompressionJournal.beginPending(
            modelContext: modelContext,
            mediaType: mediaType,
            assetId: assetId,
            originalSize: originalSize,
            compressedSize: 0,
            exportPreset: exportPreset,
            deletesOriginal: deletesOriginal
        )
        Self.liveSwaps[assetId] = WeakSwap(swap: self)
    }

    var replacementId: String? { record.replacementAssetLocalIdentifier }

    /// Settles a row whose original was kept. The row stops being pending, so
    /// reconcile never deletes anything for it later. When both versions stay
    /// (`copyRemoved == false`) the row records the kept-both outcome and the
    /// copy's id is kept on the row, so Photo Compression knows it is a copy
    /// and never lists it for compression.
    func finalizeOriginalKept(copyRemoved: Bool) {
        if copyRemoved {
            guard finish() else { return }
            record.replacementAssetLocalIdentifier = nil
            record.compressedSizeBytes = 0
            CompressionJournal.finalize(record, outcome: .skipped, modelContext: modelContext)
        } else {
            // `finalizeKeptBoth` owns this path and deliberately does NOT
            // claim `finish()`, so that a later Try Again can promote
            // kept → completed. Claiming it here first made that impossible:
            // `finalizeCompleted` hit `guard finish()` and returned silently,
            // leaving the row `.kept` with savedBytes 0 for good, so History
            // and lifetime-freed under-reported the compression forever.
            finalizeKeptBoth()
        }
    }

    /// Settles a decline durably the moment it happens: the row leaves
    /// "pending" with the kept-both outcome, so killing the app with the
    /// Originals Kept alert open can never turn into a reconcile
    /// `deleteOrphanThenFail` that deletes the saved copy on next launch.
    /// Deliberately does NOT consume `finish()`: a later Try Again promotes
    /// kept → completed through `finalizeCompleted`, and Remove Copies
    /// settles through `finalizeOriginalKept`.
    func finalizeKeptBoth() {
        // `.completed` is terminal. Before the F2 fix this path inherited that
        // protection from the caller's `guard finish()`, and that guard cannot
        // come back — it was exactly what blocked the kept → completed
        // promotion this path exists to allow. So the invariant is stated here:
        // settling a finished compression as "kept-both" would wipe savedBytes
        // from both History and lifetime-freed.
        guard record.outcome != CompressionOutcome.completed.rawValue else { return }
        CompressionJournal.finalize(record, outcome: .kept, modelContext: modelContext)
    }

    func markSaveAttempted() {
        CompressionJournal.markSaveAttempted(record, modelContext: modelContext)
    }

    func recordReplacement(id: String, size: Int64) {
        CompressionJournal.recordReplacement(
            record,
            replacementId: id,
            compressedSize: size,
            modelContext: modelContext
        )
    }

    func finalizeCompleted(compressedSize: Int64) {
        guard finish() else { return }
        record.compressedSizeBytes = compressedSize
        CompressionJournal.finalize(record, outcome: .completed, modelContext: modelContext)
    }

    func finalizeSkipped() {
        guard finish() else { return }
        CompressionJournal.finalize(record, outcome: .skipped, modelContext: modelContext)
    }

    /// Pass `replacementAbsent: true` when the caller already proved the
    /// journaled copy is gone: the journal then settles the row instead of
    /// asking PhotoKit to delete an asset it knows is absent.
    func markFailed(replacementAbsent: Bool = false) async {
        guard beginFinish() else { return }
        await CompressionJournal.markPendingFailed(
            assetId: assetId,
            replacementAbsent: replacementAbsent,
            modelContext: modelContext
        )
        endFinish()
    }

    func markSkipped() async {
        guard beginFinish() else { return }
        await CompressionJournal.markPendingSkipped(assetId: assetId, modelContext: modelContext)
        endFinish()
    }
}

@MainActor
enum CompressionBatchRunner {
    struct Handlers: Sendable {
        /// Sets the row state at an index into the VM's list.
        var setState: @MainActor @Sendable (Int, CompressionState) -> Void
        var setPhase: @MainActor @Sendable (ReplacePhase) -> Void
    }

    /// The batch's failure line, or nil when none is due.
    nonisolated static func failureSummary(completed: Int, failed: Int) -> String? {
        guard failed > 0 else { return nil }
        // Through `L10n`: an interpolated literal is not a catalog key.
        return L10n.format("Compressed %lld of %lld. %lld failed.", completed, completed + failed, failed)
    }

    struct Result: Sendable {
        var successfulIds: Set<String>
        var summary: CompressionBatchSummary
        /// Saved copies whose originals are still in the library (the user
        /// tapped "Don't Allow", or the delete failed). The view offers
        /// Try Again / Remove Copies for these.
        var kept: [PendingOriginal]
        /// Selected ids whose row no longer exists. They are counted as skipped
        /// here, and returned so the caller can drop them from the selection: a
        /// phantom selection leaves the toolbar reading "N selected" with fewer
        /// than N rows, and every later batch retries an id that cannot resolve.
        var idsWithoutRow: Set<String> = []
    }

    // Runs the per-item loop. `execute` creates its CompressionSwap (it alone
    // knows the resolved preset id) and MUST terminally settle it on every path.
    // `title` names the batch in the system progress view.
    static func run(
        title: String,
        selected: Set<String>,
        fileSizes: [String: Int64],
        indexById: [String: Int],
        alreadyCompletedIds: Set<String>,
        isCancelled: @MainActor @Sendable () -> Bool,
        isSizeUnknown: @MainActor @Sendable (Error) -> Bool,
        modelContext: ModelContext,
        handlers: Handlers,
        deleteOriginals: Bool = true,
        execute: @MainActor @Sendable (String, Int, @escaping @MainActor @Sendable (Float) -> Void) async throws
            -> CompressionItemOutcome
    ) async -> Result {
        let orderedIds = sortedBatchIds(selected: selected, fileSizes: fileSizes)
        // Ends on every path: finish, cancel, error and return from the loop.
        let session = CompressionSession.begin(title: title, total: orderedIds.count)
        defer { session.end() }
        var saved: [PendingOriginal] = []
        var failed = 0, skipped = 0
        var idsWithoutRow: Set<String> = []
        itemLoop: for (offset, id) in orderedIds.enumerated() {
            if offset % 20 == 0 { await Task.yield() }
            await session.waitWhilePaused()
            if isCancelled() { break }
            handlers.setPhase(.savingCopies(done: offset, total: orderedIds.count))
            defer { session.report(done: offset + 1) }
            // A selected id with no row index cannot be reported through
            // `setState`, but it must still land in the tally. Skipping it
            // outright left completed + failed + skipped short of `selected`,
            // so the run summary under-reported what actually happened. It is
            // also reported back so the caller can drop it from the selection.
            guard let index = indexById[id] else {
                skipped += 1
                idsWithoutRow.insert(id)
                continue
            }
            if alreadyCompletedIds.contains(id) {
                handlers.setState(index, .keptOriginal(reason: L10n.string("Already compressed")))
                skipped += 1
                continue
            }
            // Repeats only for an interrupted item (the background time ended,
            // or it failed while the app was off screen): it runs again once
            // the app is back.
            while true {
                handlers.setState(index, .exporting(0))
                do {
                    let outcome = try await execute(id, index, { p in handlers.setState(index, .exporting(p)) })
                    switch outcome {
                    case .skipped:
                        skipped += 1
                    case .saved(let pending):
                        saved.append(pending)
                        handlers.setState(index, .copySaved)
                    }
                } catch {
                    switch session.afterFailure(userStopped: isCancelled(), error: error) {
                    case .stop:
                        handlers.setState(index, .waiting)
                        break itemLoop
                    case .retry:
                        handlers.setState(index, .waiting)
                        await session.waitToRetry()
                        if isCancelled() { break itemLoop }
                        continue
                    case .fail:
                        break
                    }
                    if isSizeUnknown(error) {
                        handlers.setState(index, .keptOriginal(reason: L10n.string("Size unknown (iCloud-only) — skipped")))
                        skipped += 1
                        continue itemLoop
                    }
                    // The full error, for the journal, load and save steps. The
                    // export step logs its NSError where it throws.
                    AppLog.compression.error("Compression failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                    failed += 1
                    handlers.setState(index, .failed(error.localizedDescription))
                }
                break
            }
        }

        // Step 2: every copy is saved. Delete all originals at once — one iOS
        // prompt. This also runs after a cancel, so finished items finish.
        var successfulIds: Set<String> = []
        var kept: [PendingOriginal] = []
        var copiesOnly = 0
        if !saved.isEmpty, !deleteOriginals {
            // Copy-only mode: the user chose to keep the originals before the
            // batch, so there is no delete prompt. Settle each row as kept-both.
            for item in saved {
                item.swap.finalizeKeptBoth()
                if let index = indexById[item.assetId] {
                    handlers.setState(index, .keptOriginal(reason: L10n.format(
                        "Copy saved (%@) — original kept", item.compressedSize.formattedFileSize)))
                }
            }
            copiesOnly = saved.count
        } else if !saved.isEmpty {
            // The delete prompt needs the app on screen.
            await session.waitForForeground()
            handlers.setPhase(.removingOriginals(count: saved.count))
            let outcome = await OriginalsCommit.commit(saved)
            for item in outcome.committed {
                successfulIds.insert(item.assetId)
                if let index = indexById[item.assetId] {
                    handlers.setState(index, .completed(savedBytes: max(0, item.originalSize - item.compressedSize)))
                }
            }
            // A vanished replacement fails the item during the commit phase.
            // Those failures used to be dropped, so the batch could report
            // `failed: 0` while journal rows were marked failed.
            failed += outcome.failed.count
            for item in outcome.failed {
                if let index = indexById[item.assetId] {
                    handlers.setState(index, .failed(OriginalsCommit.missingReplacementMessage))
                }
            }
            kept = outcome.kept
        }
        handlers.setPhase(.idle)
        return Result(
            successfulIds: successfulIds,
            summary: CompressionBatchSummary(
                completed: successfulIds.count + copiesOnly,
                failed: failed,
                skipped: skipped,
                cancelled: isCancelled()
            ),
            kept: kept,
            idsWithoutRow: idsWithoutRow
        )
    }
}

/// Step 2 of every replace flow (video, photo, Live Photo): delete the
/// originals of saved copies in ONE PhotoKit call, so the user sees one iOS
/// prompt per batch.
@MainActor
enum OriginalsCommit {
    /// What `OriginalsCommit` reports when an item's replacement copy is gone,
    /// so every surface names the same failure.
    ///
    /// Computed, not stored: a `static let` would freeze the launch-time
    /// language, which is the whole reason `L10n` resolves per lookup.
    static var missingReplacementMessage: String { L10n.string("The compressed copy is missing from your library.") }

    /// Same failure for Live Photo → still conversions: the saved replacement
    /// is a still, not a compressed copy, so the shared wording would mislead.
    static var missingStillMessage: String { L10n.string("The converted still is missing from your library.") }

    struct Outcome: Sendable {
        var committed: [PendingOriginal]
        var kept: [PendingOriginal]
        /// Items whose replacement copy was already gone when the commit ran.
        /// Their originals were never touched, so the caller must report these
        /// as failures instead of producing a zero-failure summary.
        var failed: [PendingOriginal] = []
    }

    /// What `removeCopies` did, so callers stop showing rows the library has
    /// already settled. A plain `Bool` could not name the rows whose original
    /// vanished externally, so those stayed on screen as "both versions in
    /// your library" even though the swap was done.
    struct CopiesOutcome: Sendable {
        /// Original vanished outside the app: the swap is complete and the
        /// saved copy is the library's surviving asset. Callers drop these rows.
        var completed: [PendingOriginal] = []
        /// Copies still in the library (the user declined). Both versions
        /// remain, so the row stays a kept original.
        var kept: [PendingOriginal] = []
        /// True when every copy this call targeted is gone.
        var allCopiesRemoved: Bool = false
    }

    /// Splits items by whether their original is still in the library. The
    /// library is the truth, not `deleteAssets`' return set: an original that
    /// vanished outside the app is also done.
    nonisolated static func partition<T>(
        _ items: [T],
        id: (T) -> String,
        stillPresent: Set<String>
    ) -> (committed: [T], kept: [T]) {
        var committed: [T] = [], kept: [T] = []
        for item in items {
            if stillPresent.contains(id(item)) { kept.append(item) } else { committed.append(item) }
        }
        return (committed, kept)
    }

    /// Shown when the user also declines Remove Copies.
    static var copiesKeptMessage: String { L10n.string("Copies kept. Both versions are in your library; delete either one in Photos.") }

    /// `commit`, with the bottom bar showing "removing originals" while it runs.
    static func commit(
        _ pending: [PendingOriginal],
        setPhase: (ReplacePhase) -> Void
    ) async -> Outcome {
        setPhase(.removingOriginals(count: pending.count))
        let outcome = await commit(pending)
        setPhase(.idle)
        return outcome
    }

    static func commit(
        _ pending: [PendingOriginal],
        photoService: PhotoLibraryService = .shared
    ) async -> Outcome {
        guard !pending.isEmpty else { return Outcome(committed: [], kept: []) }
        // Never delete an original whose copy is gone: verify replacements
        // first and fail those items out without touching their originals.
        let replacementIds = pending.compactMap(\.swap.replacementId)
        let existingReplacements = await photoService.existingIds(replacementIds)
        var viable: [PendingOriginal] = []
        var failed: [PendingOriginal] = []
        viable.reserveCapacity(pending.count)
        for item in pending {
            guard let replacementId = item.swap.replacementId,
                  existingReplacements.contains(replacementId) else {
                // The copy is already gone, so tell the journal that rather than
                // asking it to delete an asset we just proved absent — that
                // delete reports not-gone and would leave the row pending
                // forever, retried by every later reconcile.
                await item.swap.markFailed(replacementAbsent: true)
                failed.append(item)
                continue
            }
            viable.append(item)
        }
        guard !viable.isEmpty else { return Outcome(committed: [], kept: [], failed: failed) }
        let ids = viable.map(\.assetId)
        // A decline or a partial failure throws; the presence check below
        // decides what happened either way.
        var deleted = Set<String>()
        do {
            // Also after Stop: the copies are saved, so their originals must go.
            deleted = try await ignoringCancellation { try await photoService.deleteAssets(identifiers: ids).deletedIds }
        } catch {
            deleted = (error as? PhotoServiceError)?.deletionOutcome?.deletedIds ?? []
        }
        let sizes = Dictionary(viable.map { ($0.assetId, $0.originalSize) }, uniquingKeysWith: { first, _ in first })
        CleanupLedger.shared.publishDeletion(deletedIds: deleted, sizeOf: { sizes[$0] ?? 0 })
        let split = partition(viable, id: \.assetId, stillPresent: await photoService.existingIds(ids))
        for item in split.committed {
            item.swap.finalizeCompleted(compressedSize: item.compressedSize)
        }
        // Decline path: settle every kept row durably NOW (kept-both outcome),
        // not via the in-memory alert alone — otherwise killing the app before
        // Try Again / Remove Copies leaves pending rows whose copies the next
        // reconcile deletes as orphans. The swap stays promotable, so Try
        // Again still finalizes these rows as completed on success.
        for item in split.kept {
            item.swap.finalizeKeptBoth()
        }
        return Outcome(committed: split.committed, kept: split.kept, failed: failed)
    }

    /// The user kept the originals and chose "Remove Copies": delete the new
    /// copies in one call (one iOS prompt). If they decline that too, both
    /// versions stay and the journal stops tracking the copies.
    ///
    /// Reports which rows it settled, so callers can drop the ones whose
    /// original had already vanished instead of continuing to show them as
    /// "both versions in your library".
    static func removeCopies(
        _ kept: [PendingOriginal],
        photoService: PhotoLibraryService = .shared
    ) async -> CopiesOutcome {
        // An original that vanished outside the app is already replaced: the
        // end state holds, so complete those rows and never touch their copies.
        let existingOriginals = await photoService.existingIds(kept.map(\.assetId))
        var active: [PendingOriginal] = []
        var completed: [PendingOriginal] = []
        active.reserveCapacity(kept.count)
        for item in kept {
            if existingOriginals.contains(item.assetId) {
                active.append(item)
            } else {
                item.swap.finalizeCompleted(compressedSize: item.compressedSize)
                completed.append(item)
            }
        }
        let copyIds = active.compactMap(\.swap.replacementId)
        if !copyIds.isEmpty {
            _ = try? await photoService.deleteAssets(identifiers: copyIds)
        }
        let stillPresent = await photoService.existingIds(copyIds)
        var keptRows: [PendingOriginal] = []
        for item in active {
            let copyGone = item.swap.replacementId.map { !stillPresent.contains($0) } ?? true
            item.swap.finalizeOriginalKept(copyRemoved: copyGone)
            if !copyGone { keptRows.append(item) }
        }
        return CopiesOutcome(
            completed: completed,
            kept: keptRows,
            allCopiesRemoved: stillPresent.isEmpty
        )
    }
}
