import AppKit
import Foundation
import MacOSCleanerCore

// Store-selection ladder, folder bookmarks, onboarding state, API key storage,
// and settings persistence.

@MainActor
extension AppViewModel {
    struct ResolvedStore {
        let store: SQLiteStore
        let usedTempDatabase: Bool
    }

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

    static func bootstrap() -> AppViewModel {
        let resolved = resolveStore(primary: { try SQLiteStore() })
        let store = resolved.store
        let keychain = KeychainStore()
        let memory = MemoryEngine(store: store)
        let planner = PlannerAgent()
        let model = AppViewModel(
            store: store,
            keychain: keychain,
            memory: memory,
            orchestrator: ScanOrchestrator(store: store, planner: planner, memory: memory),
            executor: ActionExecutor(store: store),
            undoService: UndoManagerService(store: store, memory: memory),
            reportGenerator: ReportGenerator(store: store),
            notifications: NotificationScheduler(),
            planner: planner
        )
        if resolved.usedTempDatabase {
            model.isUsingTempDatabase = true
            model.errorMessage = L10n.string(
                "Primary database failed. Using a temporary database. Data will not persist after quit.",
                language: model.languageStore.activeOverride
            )
        }
        return model
    }

    // MARK: - Onboarding single source of truth

    func completeOnboardingExplicitly() {
        defaults.set(true, forKey: OnboardingView.explicitCompletionKey)
        defaults.set(OnboardingView.doneStep, forKey: OnboardingView.stepKey)
    }

    func markOnboardingImplicitlyDismissed() {
        if defaults.integer(forKey: OnboardingView.stepKey) < OnboardingView.doneStep {
            defaults.set(OnboardingView.doneStep, forKey: OnboardingView.stepKey)
        }
    }

    private func resetOnboardingIfImplicit() {
        guard !defaults.bool(forKey: OnboardingView.explicitCompletionKey),
              selectedMode == .selectedFolders,
              selectedFolders.isEmpty else { return }
        defaults.set(0, forKey: OnboardingView.stepKey)
    }

    // MARK: - Folders & Inbox

    func addDownloadFolderToSelection() {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            errorMessage = L10n.string("Could not resolve Downloads folder.", language: languageStore.activeOverride)
            return
        }
        addScanFolder(downloads)
    }

    func addScanFolder(_ folder: URL) {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Wait until scan or execution completes to change scan folders.", language: override)
            return
        }
        let normalized = folder.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalized.path) else {
            errorMessage = L10n.string("The selected folder no longer exists.", language: override)
            return
        }
        selectedFolders = mergeSelectedFolders(with: [normalized])
        selectedMode = .selectedFolders
        markOnboardingImplicitlyDismissed()
        saveSettings()
        let count = selectedFolders.count
        statusMessage = count == 1
            ? L10n.string("1 folder selected. Ready to scan.", language: override)
            : L10n.format("%lld folders selected. Ready to scan.", language: override, count)
    }

    func removeSelectedFolder(_ folder: URL) {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Wait until scan or execution completes to change scan folders.", language: override)
            return
        }
        let normalized = folder.standardizedFileURL
        let existingCount = selectedFolders.count
        selectedFolders.removeAll { $0.standardizedFileURL == normalized }
        guard selectedFolders.count != existingCount else { return }
        saveSettings()

        if selectedFolders.isEmpty {
            statusMessage = L10n.string("No folders selected.", language: override)
            resetOnboardingIfImplicit()
        } else if selectedFolders.count == 1 {
            statusMessage = L10n.string("1 folder remains selected.", language: override)
        } else {
            statusMessage = L10n.format("%lld folders remain selected.", language: override, selectedFolders.count)
        }
    }

    func clearSelectedFolders() {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Wait until scan or execution completes to change scan folders.", language: override)
            return
        }
        guard !selectedFolders.isEmpty else {
            statusMessage = L10n.string("No folders selected.", language: override)
            return
        }
        selectedFolders.removeAll()
        saveSettings()
        statusMessage = L10n.string("All scan folders removed.", language: override)
        resetOnboardingIfImplicit()
    }

    func createInbox() async {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Wait until the current scan or cleanup finishes.", language: override)
            return
        }
        let root: URL?
        if let inboxRoot {
            root = inboxRoot
        } else if !DistributionChannel.supportsAdvanced {
            guard let picked = await pickInboxParentFolder() else {
                statusMessage = L10n.string("Inbox creation canceled.", language: override)
                return
            }
            root = picked
        } else {
            root = nil
        }
        do {
            let inbox = try await inboxManager.ensureInboxExists(at: root)
            if !selectedFolders.contains(inbox) {
                selectedFolders.append(inbox)
            }
            selectedMode = .selectedFolders
            markOnboardingImplicitlyDismissed()
            saveSettings()
            statusMessage = L10n.string("Tidybyte Inbox is ready.", language: override)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pickInboxParentFolder() async -> URL? {
        if let resolved = resolveInboxBookmark() {
            return resolved
        }
        if let stored = defaults.string(forKey: SettingsKey.inboxRootPath.rawValue) {
            let url = URL(fileURLWithPath: stored, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let override = languageStore.activeOverride
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = L10n.string("Choose where Tidybyte should create the inbox folder.", language: override)
        panel.prompt = L10n.string("Create Here", language: override)

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let parent = panel.url else { return nil }
        persistInboxBookmark(for: parent)
        defaults.set(parent.path, forKey: SettingsKey.inboxRootPath.rawValue)
        trackSecurityScopedURL(parent)
        return parent
    }

    private func resolveInboxBookmark() -> URL? {
        guard let data = defaults.data(forKey: SettingsKey.inboxBookmarkData.rawValue) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        trackSecurityScopedURL(url)
        if isStale { persistInboxBookmark(for: url) }
        return url
    }

    private func persistInboxBookmark(for url: URL) {
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(data, forKey: SettingsKey.inboxBookmarkData.rawValue)
        }
    }

    private func persistSelectedFolderBookmarks() {
        let datas: [Data] = selectedFolders.compactMap { url in
            try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        if datas.isEmpty {
            defaults.removeObject(forKey: SettingsKey.selectedFolderBookmarks.rawValue)
        } else {
            defaults.set(datas, forKey: SettingsKey.selectedFolderBookmarks.rawValue)
        }
    }

    func resolveSavedBookmarksAsync() {
        let inboxData = defaults.data(forKey: SettingsKey.inboxBookmarkData.rawValue)
        let folderDatas = defaults.array(forKey: SettingsKey.selectedFolderBookmarks.rawValue) as? [Data] ?? []
        guard inboxData != nil || !folderDatas.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = resolveInboxBookmark()
            for data in folderDatas {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    trackSecurityScopedURL(url)
                }
            }
        }
    }

    private func trackSecurityScopedURL(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !activeSecurityScopedURLs.contains(standardized) else { return }
        if standardized.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.append(standardized)
        }
    }

    func stopAllSecurityScopedAccess() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    private func mergeSelectedFolders(with newFolders: [URL]) -> [URL] {
        var merged = selectedFolders
        for folder in newFolders {
            let normalized = folder.standardizedFileURL
            guard !merged.contains(where: { $0.standardizedFileURL == normalized }) else { continue }
            merged.append(normalized)
        }
        return merged
    }

    // MARK: - API key, clear data & settings persistence

    func saveAPIKey() async {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting else {
            errorMessage = L10n.string("Wait until the current scan or cleanup finishes.", language: override)
            return
        }
        do {
            try await keychain.saveAPIKey(apiKeyInput, account: providerSettings.providerName)
            apiKeyInput = ""
            errorMessage = nil
            if !includeAI { includeAI = true }
            if providerSettings.privacyMode == .localOnly {
                statusMessage = L10n.string(
                    "API key saved. AI is on, but privacy mode is still Local Only; choose a mode with AI to use scanned content.",
                    language: override
                )
            } else {
                statusMessage = L10n.string("API key saved in Keychain.", language: override)
            }
            saveSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() { errorMessage = nil }

    func clearAllData() async {
        let override = languageStore.activeOverride
        guard !isScanning, !isExecuting, !cleanup.isBusy, !cleanup.isSaving else {
            errorMessage = L10n.string(
                "Cannot clear data while a scan, media cleanup, or execution is in progress.",
                language: override
            )
            return
        }
        do {
            planSaveTask?.cancel()
            deferredMaintenanceTask?.cancel()
            await cleanup.cancelPendingSettingsSave()
            try await keychain.deleteAllAPIKeys()
            try await store.deleteAllData()
            await cleanup.resetAfterClear()
            await screenshots.resetAfterClear()
            stopAllSecurityScopedAccess()
            resetAllDataState()
            for key in SettingsKey.allCases.map(\.rawValue) + AutoScanSettingsKey.allCases.map(\.rawValue) {
                defaults.removeObject(forKey: key)
            }
            defaults.removeObject(forKey: AutoScanRunner.lastRunKey)
            defaults.removeObject(forKey: OnboardingView.explicitCompletionKey)
            defaults.set(0, forKey: OnboardingView.stepKey)
            statusMessage = L10n.string("All data cleared.", language: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetAllDataState() {
        outcome = nil
        plan = nil
        undoRecords = []
        historyActions = []
        historyShowsMedia = false
        generatedReportURL = nil
        spaceForecast = nil
        naturalLanguageCommand = ""
        selectedFolders = []
        selectedMode = .selectedFolders
        cleanupPosture = .balanced
        includeAI = false
        providerSettings = ProviderSettings()
        autoscanEnabled = false
        resetExecutionState()
        resetWorkspaceState()
        languageStore.reset()
    }

    private func resetWorkspaceState() {
        selectedActionID = nil
        selectedActionIDs = []
        reviewRiskFilter = nil
        destination = .overview
        searchText = ""
        selectedExploreRecordID = nil
        focusedExploreRecordID = nil
        selectedApplicationID = nil
        selectedHistoryID = nil
        selectedSnapshotID = nil
        showsInspector = false
        showsPlanner = false
        showsScanSetup = false
        exploreViewKindRaw = "list"
        exploreGroupingRaw = "byFolder"
        exploreDepth = 7
        exploreCache.invalidate()
        storageSnapshots = []
        olderSnapshotID = nil
        newerSnapshotID = nil
        snapshotDiff = nil
        snapshotDiffError = nil
        footprintItemsByAppID = [:]
        stagedUninstallAppIDs = []
        removedApplications = [:]
        fullDiskAccessHint = nil
        dismissedScanNoticeIDs = []
    }

    func saveIncludeAI() {
        defaults.set(includeAI, forKey: SettingsKey.includeAI.rawValue)
    }

    func saveSettings() {
        let normalizedPaths = selectedFolders.map { $0.standardizedFileURL.path }
        defaults.set(selectedMode.rawValue, forKey: SettingsKey.selectedMode.rawValue)
        defaults.set(normalizedPaths, forKey: AutoScanSettingsKey.selectedFolderPaths.rawValue)
        if selectedMode == .selectedFolders {
            persistSelectedFolderBookmarks()
        }
        defaults.set(cleanupPosture.rawValue, forKey: SettingsKey.cleanupPosture.rawValue)
        defaults.set(duplicateStrategy.rawValue, forKey: SettingsKey.duplicateStrategy.rawValue)
        defaults.set(autoscanEnabled, forKey: AutoScanSettingsKey.enabled.rawValue)
        defaults.set(includeAI, forKey: SettingsKey.includeAI.rawValue)
        defaults.set(providerSettings.providerName, forKey: SettingsKey.providerName.rawValue)
        defaults.set(providerSettings.apiBaseURL.absoluteString, forKey: SettingsKey.apiBaseURL.rawValue)
        defaults.set(providerSettings.textModel, forKey: SettingsKey.textModel.rawValue)
        defaults.set(providerSettings.maxTokens, forKey: SettingsKey.maxTokens.rawValue)
        defaults.set(providerSettings.temperature, forKey: SettingsKey.temperature.rawValue)
        defaults.set(providerSettings.privacyMode.rawValue, forKey: SettingsKey.privacyMode.rawValue)
        defaults.set(exploreViewKindRaw, forKey: SettingsKey.exploreViewKind.rawValue)
        defaults.set(exploreGroupingRaw, forKey: SettingsKey.exploreGrouping.rawValue)
        defaults.set(exploreDepth, forKey: SettingsKey.exploreDepth.rawValue)
        if !selectedFolders.isEmpty { markOnboardingImplicitlyDismissed() }
    }

    private func restoreLastDestination() {
        guard let destinationRaw = defaults.string(forKey: SettingsKey.lastDestination.rawValue),
              let restored = AppDestination(rawValue: destinationRaw),
              AppDestination.available.contains(restored) else { return }
        destination = restored
    }

    func loadSettings() {
        if let modeRaw = defaults.string(forKey: SettingsKey.selectedMode.rawValue),
           let mode = ScanMode(rawValue: modeRaw) {
            selectedMode = mode
        }
        if let paths = defaults.stringArray(forKey: AutoScanSettingsKey.selectedFolderPaths.rawValue) {
            selectedFolders = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        if let postureRaw = defaults.string(forKey: SettingsKey.cleanupPosture.rawValue),
           let posture = CleanupPosture(rawValue: postureRaw) {
            cleanupPosture = posture
        }
        if let strategyRaw = defaults.string(forKey: SettingsKey.duplicateStrategy.rawValue),
           let strategy = DuplicateStrategy(rawValue: strategyRaw) {
            duplicateStrategy = strategy
        }
        suppressAutoscanObserver = true
        autoscanEnabled = defaults.bool(forKey: AutoScanSettingsKey.enabled.rawValue)
        suppressAutoscanObserver = false
        includeAI = defaults.bool(forKey: SettingsKey.includeAI.rawValue)
        loadProviderAndExploreSettings()
        restoreLastDestination()
        if !selectedFolders.isEmpty { markOnboardingImplicitlyDismissed() }
    }

    private func loadProviderAndExploreSettings() {
        if let name = defaults.string(forKey: SettingsKey.providerName.rawValue) {
            providerSettings.providerName = name
        }
        if let urlString = defaults.string(forKey: SettingsKey.apiBaseURL.rawValue), let url = URL(string: urlString) {
            providerSettings.apiBaseURL = url
        }
        if let model = defaults.string(forKey: SettingsKey.textModel.rawValue) {
            providerSettings.textModel = model
        }
        if defaults.object(forKey: SettingsKey.maxTokens.rawValue) != nil {
            providerSettings.maxTokens = defaults.integer(forKey: SettingsKey.maxTokens.rawValue)
        }
        if defaults.object(forKey: SettingsKey.temperature.rawValue) != nil {
            providerSettings.temperature = defaults.double(forKey: SettingsKey.temperature.rawValue)
        }
        if let privacyRaw = defaults.string(forKey: SettingsKey.privacyMode.rawValue),
           let privacy = PrivacyMode(rawValue: privacyRaw) {
            providerSettings.privacyMode = privacy
        }
        if let viewKind = defaults.string(forKey: SettingsKey.exploreViewKind.rawValue), !viewKind.isEmpty {
            exploreViewKindRaw = viewKind
        }
        if let grouping = defaults.string(forKey: SettingsKey.exploreGrouping.rawValue), !grouping.isEmpty {
            exploreGroupingRaw = grouping
        }
        if defaults.object(forKey: SettingsKey.exploreDepth.rawValue) != nil {
            exploreDepth = max(1, min(10, defaults.integer(forKey: SettingsKey.exploreDepth.rawValue)))
        }
    }
}
