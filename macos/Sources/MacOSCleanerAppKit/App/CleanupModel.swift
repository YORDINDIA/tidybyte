import AppKit
import Foundation
import MacOSCleanerCore
import Observation

@MainActor @Observable
final class CleanupModel {
    let store: SQLiteStore
    let access: FolderAccess
    let photos: PhotoLibraryService
    let executor: ReviewExecutor
    private let inventory: ReviewInventory
    private let analysis: MediaAnalysisService
    var scope = ReviewScope() {
        didSet {
            if scope != oldValue {
                result?.isFresh = false
                selection = []
                explicitlySelectedIDs = []
            }
        }
    }
    /// Every change persists from the model, so any surface that binds to a
    /// setting saves it, whether or not its view stays on screen (MAC-29).
    var settings = CleanupSettings() {
        didSet {
            guard !suppressSettingsSave, settings != oldValue else { return }
            scheduleSettingsSave()
        }
    }
    var suppressSettingsSave = false
    var settingsSaveTask: Task<Void, Never>?
    var settingsSaveEpoch = 0
    var result: AnalysisResult?
    var session: ReviewSession?
    var reviewed: [String: ReviewChoice] = [:]
    var activity: [ActivityEvent] = []
    var snapshots: [CleanupSnapshot] = []
    var jobs: [CompressionJob] = []
    var progress = CleanupProgress("", completed: 0, total: 0)
    var isBusy = false
    var isSaving = false
    private(set) var scanRequestCount = 0
    var error: String?
    var photosAccessDenied = false
    var photoAuthorizationState: PhotoAuthorizationState = PhotoLibraryService.currentAuthorizationState()
    var notice: String?
    var showsScope = false
    var selectedTool: CleanupTool?
    var selection = Set<String>()
    var explicitlySelectedIDs = Set<String>()
    var downloadingItemIDs: [String: Double] = [:]
    var measuredCompressionSizes: [String: Int64] = [:]
    var isMeasuringSizes = false
    var selectedItem: ReviewItem?
    var sessionResults: [ActivityEvent] = []
    var completedSession: ReviewSession?
    var filter: ReviewFilter = .unreviewed
    var filterDate = Date()
    var filterFolder: URL?
    var task: Task<Void, Never>?
    private var loaded = false
    private(set) var hasLoaded = false
    var monitoredGrants: [URL] = []
    var freshness: CleanupFreshnessMonitor?
    var freshnessEpoch = 0
    var rescanEpoch = 0
    var selfMutationDepth = 0
    var suppressFreshnessUntil: Date = .distantPast
    var hasFreshnessMonitor: Bool { freshness != nil }
    var changeGeneration = 0

    var hasInterruptedOperations: Bool {
        activity.contains {
            $0.state == .prepared || $0.state == .outputReady || $0.state == .interrupted
                || ($0.restoreStartedAt != nil && !$0.restored)
        }
    }

    init(store: SQLiteStore) {
        self.store = store
        let access = FolderAccess(store: store)
        let photos = PhotoLibraryService()
        self.access = access
        self.photos = photos
        inventory = ReviewInventory(access: access)
        analysis = MediaAnalysisService(photos: photos, store: store)
        executor = ReviewExecutor(store: store, access: access, photos: photos)
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        defer { hasLoaded = true }
        refreshPhotoAuthorizationState()
        do {
            scope = try await store.loadCleanupState(ReviewScope.self, key: "scope") ?? scope
            if let stored = try await store.loadCleanupState(CleanupSettings.self, key: "settings") {
                suppressSettingsSave = true
                settings = stored
                suppressSettingsSave = false
            }
            session = (try await store.loadCleanupState(ReviewSession?.self, key: "draft")).flatMap { $0 }
            result = try await store.loadCleanupState(AnalysisResult.self, key: "inventory")
            result?.isFresh = false
            reviewed = try await store.loadCleanupState([String: ReviewChoice].self, key: "review:" + scope.id) ?? [:]
            filter = settings.defaultFilter
            try await reloadHistory()
            try await reconcileSessionDraftOnLoad()
            if hasInterruptedOperations {
                error = String(
                    localized: """
                        An earlier operation stopped. Check Activity before retrying. No changes \
                        will resume automatically.
                        """
                )
            }
        } catch {
            loaded = false
            self.error = error.localizedDescription
        }
    }

    private func reconcileSessionDraftOnLoad() async throws {
        guard var draft = session else { return }
        sessionResults = draft.pendingChanges.compactMap { decision in
            activity.first { $0.id == draft.id + "|" + decision.item.id }
        }
        if !sessionResults.isEmpty, draft.applicationStartedAt == nil {
            draft.applicationStartedAt = sessionResults.map(\.date).min()
            try await store.saveCleanupState(Optional(draft), key: "draft")
            session = draft
        }
    }

    func refreshPhotoAuthorizationState() {
        photoAuthorizationState = PhotoLibraryService.currentAuthorizationState()
    }

    func grant(_ urls: [URL]) async {
        do {
            for url in urls { try await access.grant(url) }
            result?.isFresh = false
            scope.roots =
                scope.mode == .folder
                ? Array(urls.prefix(1)) : Array(Set(scope.roots + urls)).sorted { $0.path < $1.path }
            try await store.saveCleanupState(scope, key: "scope")
        } catch { self.error = error.localizedDescription }
    }

    func scanChatFolder(_ url: URL) async {
        scope.mode = .folder
        scope.includesPhotos = false
        scope.exportedChatFolder = url
        await grant([url])
        if scope.roots == [url] { scan() }
    }

    func scan() {
        scanRequestCount += 1
        guard !isBusy else {
            notice = String(localized: "A media scan is already running.", comment: "Duplicate scan request while busy")
            return
        }
        guard !scope.roots.isEmpty || scope.includesPhotos else {
            showsScope = true
            return
        }
        isBusy = true
        error = nil
        notice = nil
        result?.isFresh = false
        let currentScope = scope
        let currentSettings = settings
        startMonitoring()
        let generation = changeGeneration
        task = Task { await performScan(scope: currentScope, settings: currentSettings, generation: generation) }
    }

    private func performScan(scope: ReviewScope, settings: CleanupSettings, generation: Int) async {
        var grants: [URL] = []
        defer {
            for grant in grants { grant.stopAccessingSecurityScopedResource() }
            isBusy = false
            task = nil
            refreshPhotoAuthorizationState()
        }
        do {
            for root in scope.roots { grants.append(try await access.acquire(root)) }
            for grant in monitoredGrants { grant.stopAccessingSecurityScopedResource() }
            monitoredGrants = []
            for root in scope.roots { monitoredGrants.append(try await access.acquire(root)) }
            try await store.saveCleanupState(scope, key: "scope")
            let report: @Sendable (CleanupProgress) async -> Void = { [self] value in
                await MainActor.run { self.progress = value }
            }
            var items = try await inventory.scan(scope, progress: report)
            if scope.includesPhotos { items += try await photos.scan(progress: report) }
            var analyzed = try await analysis.analyze(items, scopeID: scope.id, settings: settings, progress: report)
            try Task.checkCancellation()
            analyzed.isFresh = generation == changeGeneration && self.scope.id == scope.id
                && self.settings.analysisVersion == settings.analysisVersion
            try await store.saveCleanupState(analyzed, key: "inventory")
            result = analyzed
            measuredCompressionSizes = [:]
            reviewed =
                try await store.loadCleanupState([String: ReviewChoice].self, key: "review:" + scope.id) ?? [:]
            let date = Calendar.current.startOfDay(for: Date())
            let snapshot = CleanupSnapshot(
                id: scope.id + "|\(date.timeIntervalSince1970)", scopeID: scope.id,
                date: date, bytes: items.reduce(0) { $0 + $1.bytes }, count: items.count)
            if analyzed.isFresh { try await store.saveCleanupSnapshot(snapshot) }
            try await reloadHistory()
            startMonitoring()
            await refreshReminder()
        } catch is CancellationError {
            result?.isFresh = false
        } catch {
            surfaceError(error)
        }
    }

    func refreshReminder() async {
        do { try await updateReminder() } catch { notice = error.localizedDescription }
    }

    func cancel() { task?.cancel() }

    func items(for tool: CleanupTool) -> [ReviewItem] {
        guard let result else { return [] }
        return MediaAnalysisService.candidates(tool, in: result)
    }

    func reloadHistory() async throws {
        activity = try await store.cleanupActivity()
        snapshots = try await store.cleanupSnapshots(scopeID: scope.id)
    }

    private func surfaceError(_ error: Error) {
        photosAccessDenied = false
        if case CleanupError.photosAccessDenied = error {
            photosAccessDenied = true
        }
        self.error = error.localizedDescription
    }
}

extension CleanupModel {
    func startSession(items: [ReviewItem]? = nil, tool: CleanupTool = .swipe) async {
        guard session == nil, let result, result.isFresh, result.scopeID == scope.id else { return }
        let candidates = items ?? filteredItems()
        var draft = ReviewSession(scopeID: scope.id, items: candidates, tool: tool)
        draft.protectedGroups = result.groups
        do {
            try await store.saveCleanupState(Optional(draft), key: "draft")
            session = draft
            sessionResults = []
            completedSession = nil
        } catch { self.error = error.localizedDescription }
    }

    func filteredItems() -> [ReviewItem] {
        let candidates = (result?.items ?? []).filter { item in
            switch filter {
            case .unreviewed: reviewed[item.reviewKey] == nil
            case .beforeDate:
                (item.modifiedAt ?? .distantFuture)
                    < (Calendar.current.date(
                        byAdding: .day, value: 1,
                        to: Calendar.current.startOfDay(for: filterDate)) ?? filterDate)
            case .subfolder:
                if let filterFolder, let url = item.url { ReviewSafety.contains(url, in: filterFolder) } else { false }
            case .everything, .largest: true
            }
        }
        return candidates.sorted {
            if filter == .largest, $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            if $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            return $0.id < $1.id
        }
    }

    /// - Returns: true when the decision was recorded (callers register undo only then).
    @discardableResult
    func decide(_ choice: ReviewChoice, destination: URL? = nil) async -> Bool {
        guard !isSaving, !isBusy, var draft = session, draft.applicationStartedAt == nil,
            let item = draft.current
        else { return false }
        let allowed = choice == .keep || choice == .skip || (choice == .trash ? item.canDelete : item.canEditLocally)
        guard allowed else { return false }
        if choice == .trash {
            let removing = Set(draft.decisions.filter { $0.choice == .trash }.map(\.item.id)).union([item.id])
            if draft.protectedGroups?.contains(where: { $0.memberIDs.allSatisfy(removing.contains) }) == true {
                error = String(
                    localized: "Keep at least one member of each group. Keep this item or undo an earlier decision.")
                return false
            }
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if let destination { try await access.grant(destination) }
            draft.decisions.append(ReviewDecision(item: item, choice: choice, destination: destination))
            try await store.saveCleanupState(Optional(draft), key: "draft")
            session = draft
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func discardSession() async {
        guard !isBusy, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.saveCleanupState(Optional<ReviewSession>.none, key: "draft")
            session = nil
        } catch { self.error = error.localizedDescription }
    }

    func undoDecision() async {
        guard var draft = session, !draft.decisions.isEmpty, draft.applicationStartedAt == nil,
            !isBusy, !isSaving
        else { return }
        isSaving = true
        defer { isSaving = false }
        draft.decisions.removeLast()
        do {
            try await store.saveCleanupState(Optional(draft), key: "draft")
            session = draft
        } catch { self.error = error.localizedDescription }
    }

    func commitSession() async {
        guard var draft = session, draft.current == nil, !isBusy, !isSaving else { return }
        isSaving = true
        draft.applicationStartedAt = draft.applicationStartedAt ?? Date()
        do {
            try await store.saveCleanupState(Optional(draft), key: "draft")
            session = draft
        } catch {
            isSaving = false
            self.error = error.localizedDescription
            return
        }
        isSaving = false
        execute(draft.pendingChanges, tool: draft.tool, batchID: draft.id) { [weak self] in
            guard let self else { return }
            var history =
                try await store.loadCleanupState([String: ReviewChoice].self, key: "review:" + draft.scopeID) ?? [:]
            for decision in draft.decisions where decision.choice == .keep { history[decision.item.reviewKey] = .keep }
            for event in sessionResults where event.state == .complete {
                history[event.item.reviewKey] = event.action == "move" ? .move : .trash
            }
            try await store.saveCleanupState(history, key: "review:" + draft.scopeID)
            if scope.id == draft.scopeID { reviewed = history }
            completedSession = draft
            try await store.saveCleanupState(Optional<ReviewSession>.none, key: "draft")
            session = nil
        }
    }
}

extension CleanupModel {
    func trashSelection(_ batch: CleanupBatch) {
        guard !batch.tool.isCompression, batch.tool != .livePhotos, validate(batch) else { return }
        let decisions = batch.items.map { ReviewDecision(item: $0, choice: .trash) }
        execute(decisions, tool: batch.tool, batchID: batch.id.uuidString) {}
    }

    private func execute(
        _ decisions: [ReviewDecision], tool: CleanupTool, batchID: String,
        completion: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy else {
            error = String(localized: "Wait until the current cleanup finishes, then try again.")
            return
        }
        isBusy = true
        beginSelfMutation()
        error = nil
        notice = nil
        sessionResults = []
        task = Task {
            defer {
                isBusy = false
                task = nil
                endSelfMutation()
            }
            do {
                for (index, decision) in decisions.enumerated() {
                    try Task.checkCancellation()
                    progress = CleanupProgress(
                        String(localized: "Applying approved changes"), completed: index, total: decisions.count)
                    let event = await executor.apply(
                        decision, tool: tool, operationID: batchID + "|" + decision.item.id)
                    sessionResults.append(event)
                }
                try Task.checkCancellation()
                if sessionResults.allSatisfy({ $0.state == .complete }) {
                    let trashed = sessionResults.filter { $0.action == "trash" }
                    if !trashed.isEmpty {
                        let bytes = trashed.reduce(Int64(0)) { $0 + $1.bytes }.formattedByteCount
                        notice = trashed.count == 1
                            ? String(localized: """
                                1 item · \(bytes) removed. Files are in Trash; Photos assets are in \
                                Recently Deleted. Empty them in Finder or Photos to return space.
                                """)
                            : String(localized: """
                                \(trashed.count) items · \(bytes) removed. Files are in Trash; Photos \
                                assets are in Recently Deleted. Empty them in Finder or Photos to return space.
                                """)
                    }
                    try await completion()
                } else {
                    error = String(localized: "Some changes did not complete. Check each result in Activity.")
                }
            } catch is CancellationError {
                error = String(
                    localized: "Cancelled. Completed changes remain in Activity; remaining items were not changed.")
            } catch { self.error = error.localizedDescription }
            await applyMutationOutcomes(sessionResults, tool: tool, deleteOriginals: true, settings: nil)
        }
    }

    func keepResource(_ item: ReviewItem, index: Int) {
        guard !isBusy, result?.isFresh == true, result?.scopeID == scope.id else { return }
        isBusy = true
        beginSelfMutation()
        notice = nil
        error = nil
        task = Task {
            defer {
                isBusy = false
                task = nil
                endSelfMutation()
            }
            let event = await executor.keepPhotoResource(item, index: index)
            if let error = event.error { self.error = error }
            await applyMutationOutcomes([event], tool: .formatPairs, deleteOriginals: true, settings: nil)
        }
    }

    func restore(_ event: ActivityEvent) async {
        guard !isBusy, !isSaving else {
            error = String(localized: "Wait until the current cleanup finishes, then restore again.")
            return
        }
        isBusy = true
        beginSelfMutation()
        defer {
            isBusy = false
            endSelfMutation()
        }
        do {
            try await executor.restore(event)
            result?.isFresh = false
            selection = []
            explicitlySelectedIDs = []
            await finishMutationHousekeeping()
        } catch { self.error = error.localizedDescription }
    }

    func dismissInterruptedOperations() async {
        guard !isBusy, !isSaving else { return }
        do {
            let dismissed = try await executor.dismissInterruptedOperations()
            try await reloadHistory()
            if !hasInterruptedOperations { error = nil }
            if dismissed > 0 {
                notice = dismissed == 1
                    ? String(localized: "Dismissed 1 interrupted operation.")
                    : String(localized: "Dismissed \(dismissed) interrupted operations.")
            }
        } catch { self.error = error.localizedDescription }
    }

    func resetHistory() async {
        guard !isBusy, !isSaving else { return }
        do {
            try await store.resetReviewHistory()
            reviewed = [:]
            session = nil
            completedSession = nil
            sessionResults = []
        } catch { self.error = error.localizedDescription }
    }

    func localURL(_ item: ReviewItem) async throws -> URL {
        guard !item.isLink, item.isDownloaded else {
            throw CleanupError.message(
                String(localized: "Links and files that are not downloaded have no content preview."))
        }
        if let url = item.url { return url }
        return try await photos.previewURL(for: item)
    }
}
