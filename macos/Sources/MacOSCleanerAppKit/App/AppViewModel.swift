import AppKit
import Foundation
import MacOSCleanerCore
import Observation
import os
import SwiftUI

/// App-only UserDefaults keys. Autoscan keys are shared with Core.
enum SettingsKey: String, CaseIterable {
    case selectedMode
    case cleanupPosture
    case includeAI
    case providerName
    case apiBaseURL
    case textModel
    case maxTokens
    case temperature
    case privacyMode
    case exploreViewKind
    case exploreGrouping
    case exploreDepth
    case duplicateStrategy
    case inboxRootPath
    case inboxBookmarkData
    case selectedFolderBookmarks
    case lastDestination
    case dismissedNoticeSession
    case dismissedNoticeIDs
}

@MainActor
@Observable
final class AppViewModel {
    /// Live localization + RTL state shared across every scene.
    let languageStore: LanguageStore
    /// The system monitor. One instance for the whole app so the window tabs,
    /// menu bar items, and alerts share a single sampling loop.
    let monitor = MonitorModel()
    var selectedMode: ScanMode = .selectedFolders
    var selectedFolders: [URL] = []
    var cleanupPosture: CleanupPosture = .balanced
    var duplicateStrategy: DuplicateStrategy = .apfsClone
    var autoscanEnabled = false {
        didSet {
            guard !suppressAutoscanObserver, oldValue != autoscanEnabled else { return }
            if autoscanEnabled {
                do {
                    try LaunchAgentInstaller.install()
                } catch {
                    suppressAutoscanObserver = true
                    autoscanEnabled = false
                    suppressAutoscanObserver = false
                    errorMessage = error.localizedDescription
                }
            } else {
                LaunchAgentInstaller.remove()
            }
        }
    }
    var suppressAutoscanObserver = false
    var lastAutoScanDate: Date? {
        defaults.object(forKey: AutoScanRunner.lastRunKey) as? Date
    }
    var providerSettings = ProviderSettings()
    var includeAI = false
    var apiKeyInput = ""
    var isScanning = false
    var isExecuting = false
    private(set) var isPlanning = false
    private(set) var scanGeneration = 0
    private var _statusMessage: String
    private(set) var statusMessageEpoch = 0
    var statusMessage: String {
        get { _statusMessage }
        set {
            _statusMessage = newValue
            statusMessageEpoch += 1
        }
    }
    var errorMessage: String?

    /// Single source of truth: derived from `OnboardingView.stepKey` in `defaults`.
    var showOnboarding: Bool {
        defaults.integer(forKey: OnboardingView.stepKey) < OnboardingView.doneStep
    }

    var outcome: ScanOutcome? {
        didSet {
            _cachedFilesByID = nil
            _cachedSubtreeTotals = nil
            exploreCache.invalidate()
        }
    }
    var plan: Plan?
    var selectedActionID: String?
    var selectedActionIDs: Set<String> = []
    var reviewRiskFilter: RiskLevel?
    var naturalLanguageCommand = ""
    var executionSummary: ExecutionSummary?
    var lastExecutionActionIDs: Set<String> = []
    var executionProgress: Double = 0
    var executionTotalActions: Int = 0
    var executionCompletedActions: Int = 0
    private(set) var scanCurrentStep: Int = 0
    private(set) var scanTotalSteps: Int = 0
    private(set) var scanPhaseText = ""
    var generatedReportURL: URL?
    private(set) var showScanSummaryToast = false
    private(set) var activeScanSummary: String?
    var undoRecords: [UndoRecord] = []
    var pendingUndoRestore: PendingUndoRestore?
    var historyActions: [PlannedAction] = []
    var historyShowsMedia = false
    var isLoadingUndoHistory = false
    var isUsingTempDatabase = false
    var fullDiskAccessHint: String?
    var dismissedScanNoticeIDs: Set<String> = []
    var selectedRegretReason: String?
    var spaceForecast: SpaceForecaster.Forecast?
    var isLoadingTimeline = false
    @ObservationIgnored var timelineLoadsInFlight = 0

    // MARK: - Top-level tabs

    var destination: AppDestination = .overview {
        didSet {
            guard oldValue != destination else { return }
            defaults.set(destination.rawValue, forKey: SettingsKey.lastDestination.rawValue)
        }
    }
    var settingsSection = SettingsSection.general
    var selectedApplicationID: String?
    var selectedHistoryID: String?
    var selectedSnapshotID: String?
    var searchText = ""
    var showsScanSetup = false
    var showsPlanner = false
    var showsInspector = false
    var searchFocusRequest = 0
    var installedApplications: [InstalledApplication] = []
    var isLoadingApplications = false
    var footprintItemsByAppID: [String: [ApplicationFootprintItem]] = [:]
    var stagedUninstallAppIDs: Set<String> = []
    var removedApplications: [String: InstalledApplication] = [:]
    @ObservationIgnored var removalWatcher: ApplicationRemovalWatcher?

    // MARK: - Explore visualizations

    var exploreViewKindRaw: String = "list"
    var exploreGroupingRaw: String = "byFolder"
    var exploreDepth: Int = 7
    var selectedExploreRecordID: String?
    var focusedExploreRecordID: String?
    @ObservationIgnored let exploreCache = ExploreSnapshotCache()

    var storageSnapshots: [StorageSnapshot] = []
    var isLoadingSnapshots = false
    var olderSnapshotID: String?
    var newerSnapshotID: String?
    var snapshotDiff: SnapshotDiff?
    var snapshotDiffError: String?

    struct ScanSummary: Equatable {
        let duration: TimeInterval
        let totalCandidates: Int
        let reviewableActions: Int
        let highRiskActions: Int
    }

    private var _cachedFilesByID: [String: FileRecord]?
    private var _cachedSubtreeTotals: [String: Int64]?
    private var scanTask: Task<Void, Never>?
    private var scanToastTask: Task<Void, Never>?
    @ObservationIgnored var deferredMaintenanceTask: Task<Void, Never>?
    @ObservationIgnored var activeSecurityScopedURLs: [URL] = []
    private var activeScanID = UUID()
    @ObservationIgnored private var lastProgressPaintAt = Date.distantPast
    private var cancelledScanID: UUID?
    private(set) var planRevision = 0
    var planSaveTask: Task<Void, Never>?

    let cleanup: CleanupModel
    let screenshots: ScreenshotRenameModel
    let store: SQLiteStore
    let keychain: KeychainStore
    let memory: MemoryEngine
    let orchestrator: ScanOrchestrator
    let executor: ActionExecutor
    let undoService: UndoManagerService
    let reportGenerator: ReportGenerator
    let notifications: NotificationScheduler
    let planner: PlannerAgent
    let inboxManager: InboxManager
    let inboxRoot: URL?
    let defaults: UserDefaults
    let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "AppViewModel")

    init(
        store: SQLiteStore,
        keychain: KeychainStore,
        memory: MemoryEngine,
        orchestrator: ScanOrchestrator,
        executor: ActionExecutor,
        undoService: UndoManagerService,
        reportGenerator: ReportGenerator,
        notifications: NotificationScheduler,
        planner: PlannerAgent,
        inboxManager: InboxManager = InboxManager(),
        defaults: UserDefaults = .standard,
        inboxRoot: URL? = nil
    ) {
        let langStore = LanguageStore(defaults: defaults)
        self.languageStore = langStore
        self._statusMessage = L10n.string(
            "Choose folders or a scan mode to begin.",
            language: langStore.activeOverride
        )
        self.store = store
        self.cleanup = CleanupModel(store: store)
        self.screenshots = ScreenshotRenameModel(store: store, defaults: defaults)
        self.keychain = keychain
        self.memory = memory
        self.orchestrator = orchestrator
        self.executor = executor
        self.undoService = undoService
        self.reportGenerator = reportGenerator
        self.notifications = notifications
        self.planner = planner
        self.inboxManager = inboxManager
        self.inboxRoot = inboxRoot
        self.defaults = defaults
        loadSettings()
        sweepInterruptedOperations()
        resolveSavedBookmarksAsync()
    }

    func claimPlanning() -> Bool {
        guard !isScanning, !isExecuting, !isPlanning else { return false }
        isPlanning = true
        return true
    }

    func releasePlanning() {
        isPlanning = false
    }

    func setErrorMessage(_ message: String) {
        errorMessage = message
    }

    func setStatusMessage(_ message: String) {
        statusMessage = message
    }

    /// Graceful termination cleanup without abrupt `exit(0)`.
    func prepareForTermination() {
        planSaveTask?.cancel()
        scanToastTask?.cancel()
        deferredMaintenanceTask?.cancel()
        scanTask?.cancel()
        removalWatcher?.stop()
        removalWatcher = nil
        cleanup.cancel()
        screenshots.stop()
        monitor.stop()
        stopAllSecurityScopedAccess()
    }

    func schedulePlanPersistence() {
        planRevision += 1
        guard let currentPlan = plan else { return }
        planSaveTask?.cancel()
        planSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            do {
                try await self?.store.savePlan(currentPlan)
            } catch {
                self?.logger.warning("Plan persistence failed: \(error.localizedDescription)")
            }
        }
    }

    func resetExecutionState() {
        executionSummary = nil
        lastExecutionActionIDs = []
        executionProgress = 0
        executionTotalActions = 0
        executionCompletedActions = 0
        showScanSummaryToast = false
        activeScanSummary = nil
        scanToastTask?.cancel()
        scanToastTask = nil
    }
}

// MARK: - Indexed caches & scan/execution lifecycle

extension AppViewModel {
    var subtreeTotals: [String: Int64] {
        if let cached = _cachedSubtreeTotals { return cached }
        guard let outcome else { return [:] }
        let totals = ExploreSubtreeIndex.totals(files: outcome.files)
        _cachedSubtreeTotals = totals
        return totals
    }

    var filesByID: [String: FileRecord] {
        if let cached = _cachedFilesByID { return cached }
        guard let outcome else { return [:] }
        let dict = Dictionary(outcome.files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        _cachedFilesByID = dict
        return dict
    }

    var selectedAction: PlannedAction? {
        guard let selectedActionID, let plan else { return nil }
        return plan.actions.first { $0.id == selectedActionID }
    }

    var selectedActionFiles: [FileRecord] {
        guard let selectedAction else { return [] }
        return selectedAction.targets.compactMap { filesByID[$0] }
    }

    func runScan(postureOverride: CleanupPosture? = nil) {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting, !isPlanning else { return }
        guard !selectedFolders.isEmpty || selectedMode != .selectedFolders else {
            errorMessage = L10n.string("Please select folders to scan.", language: override)
            return
        }
        let scanID = UUID()
        activeScanID = scanID
        cancelledScanID = nil
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        resetExecutionState()
        errorMessage = nil
        clearScanProgress()
        scanCurrentStep = 1
        scanPhaseText = L10n.string("Resolving scan scope", language: override)
        let postureToUse = postureOverride ?? cleanupPosture
        statusMessage = L10n.format("Scan %lld/%lld: %@.", language: override, scanCurrentStep, scanTotalSteps, scanPhaseText)
        scanTask = Task { @MainActor in
            await executeScanTask(scanID: scanID, generation: generation, postureToUse: postureToUse, startedAt: Date())
        }
    }

    private func executeScanTask(
        scanID: UUID,
        generation: Int,
        postureToUse: CleanupPosture,
        startedAt: Date
    ) async {
        let override = languageStore.activeOverride
        var showedPartialResults = false
        defer {
            if generation == scanGeneration {
                isScanning = false
                let isCancelled = Task.isCancelled || cancelledScanID == scanID
                if isCancelled, !showedPartialResults {
                    cancelledScanID = nil
                    statusMessage = L10n.string("Scan cancelled.", language: override)
                }
            }
        }
        do {
            let (scanOutcome, scanPlan) = try await orchestrator.scan(
                mode: selectedMode,
                selectedFolders: selectedFolders,
                providerSettings: providerSettings,
                includeAI: includeAI,
                posture: postureToUse,
                duplicateStrategy: duplicateStrategy,
                progress: makeScanProgressSink(for: scanID)
            )
            guard activeScanID == scanID || (scanOutcome.wasCancelled && cancelledScanID == scanID) else { return }
            if scanOutcome.wasCancelled {
                applyScanResults(scanOutcome: scanOutcome, scanPlan: scanPlan)
                statusMessage = L10n.string("Scan stopped early — showing what was found so far.", language: override)
                showedPartialResults = true
                cancelledScanID = nil
                return
            }
            guard !Task.isCancelled else {
                statusMessage = L10n.string("Scan cancelled.", language: override)
                return
            }
            await finishScanSuccessfully(scanOutcome: scanOutcome, scanPlan: scanPlan, startedAt: startedAt, override: override)
        } catch {
            if Task.isCancelled || cancelledScanID == scanID {
                cancelledScanID = nil
                statusMessage = L10n.string("Scan cancelled.", language: override)
                return
            }
            errorMessage = error.localizedDescription
            statusMessage = L10n.string("Scan failed.", language: override)
        }
    }

    private func finishScanSuccessfully(
        scanOutcome: ScanOutcome,
        scanPlan: Plan,
        startedAt: Date,
        override: AppLanguage?
    ) async {
        applyScanResults(scanOutcome: scanOutcome, scanPlan: scanPlan)
        let summary = ScanSummary(
            duration: Date().timeIntervalSince(startedAt),
            totalCandidates: scanPlan.actions.count,
            reviewableActions: scanPlan.actions.count,
            highRiskActions: scanPlan.actions.filter { $0.risk == .high || $0.risk == .forbidden }.count
        )
        showScanSummaryToast = true
        activeScanSummary = formattedScanSummary(summary)
        statusMessage = L10n.string("Scan complete. Review every action before execution.", language: override)
        await notifications.scheduleScanCompletedNotification(reclaimedBytes: scanPlan.estimatedReclaimableBytes)
        await notifications.scheduleWeeklyGrowthDigest()
        await loadStorageTimeline()
        scheduleScanSummaryDismissal()
    }

    private func applyScanResults(scanOutcome: ScanOutcome, scanPlan: Plan) {
        outcome = scanOutcome
        plan = scanPlan
        reviewRiskFilter = nil
        stagedUninstallAppIDs = []
        selectedActionID = scanPlan.actions.first?.id
        selectedActionIDs = selectedActionID.map { [$0] } ?? []
        markOnboardingImplicitlyDismissed()
        clearScanProgress()
        evaluateFullDiskAccessHint(scanOutcome: scanOutcome, mode: selectedMode)
    }

    private func scheduleScanSummaryDismissal() {
        scanToastTask?.cancel()
        scanToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            showScanSummaryToast = false
            activeScanSummary = nil
        }
    }

    func runSaferScan() {
        let saferPosture: CleanupPosture = switch cleanupPosture {
        case .aggressive: .balanced
        case .balanced: .conservative
        case .conservative: .conservative
        }
        runScan(postureOverride: saferPosture)
    }

    func stopScan() { cancelScan() }

    func cancelScan() {
        guard isScanning else { return }
        cancelledScanID = activeScanID
        scanTask?.cancel()
        scanTask = nil
        activeScanID = UUID()
        clearScanProgress()
        scanToastTask?.cancel()
        showScanSummaryToast = false
        activeScanSummary = nil
        statusMessage = L10n.string("Cancelling scan…", language: languageStore.activeOverride)
    }

    func cancelExecution() {
        guard isExecuting else { return }
        Task { await executor.cancelExecution() }
        statusMessage = L10n.string(
            "Cancelling execution after the current action…",
            language: languageStore.activeOverride
        )
    }

    private func makeScanProgressSink(for scanID: UUID) -> @Sendable (ScanOrchestrator.ScanProgress) async -> Void {
        { [weak self] progress in
            guard let self else { return }
            await MainActor.run {
                guard self.activeScanID == scanID else { return }
                let isStepChange = self.scanCurrentStep != progress.currentStep
                self.scanCurrentStep = progress.currentStep
                self.scanTotalSteps = progress.totalSteps
                let now = Date()
                guard isStepChange || now.timeIntervalSince(self.lastProgressPaintAt) >= 0.5 else { return }
                self.lastProgressPaintAt = now
                let override = self.languageStore.activeOverride
                if let seen = progress.filesSeen {
                    self.scanPhaseText = (progress.currentPath?.isEmpty == false)
                        ? L10n.format("Crawling… %lld items · %@", language: override, seen, progress.currentPath ?? "")
                        : L10n.format("Crawling… %lld items", language: override, seen)
                } else {
                    self.scanPhaseText = progress.phase
                }
                self.statusMessage = L10n.format(
                    "Scan %lld/%lld: %@.",
                    language: override,
                    self.scanCurrentStep,
                    self.scanTotalSteps,
                    self.scanPhaseText
                )
            }
        }
    }

    private func clearScanProgress() {
        scanCurrentStep = 0
        scanTotalSteps = 5
        scanPhaseText = ""
    }

    private func formattedScanSummary(_ summary: ScanSummary) -> String {
        L10n.format(
            "What changed? %@, %lld candidates, %lld reviewable actions, %lld high-risk.",
            language: languageStore.activeOverride,
            formattedDuration(summary.duration),
            summary.totalCandidates,
            summary.reviewableActions,
            summary.highRiskActions
        )
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
}
