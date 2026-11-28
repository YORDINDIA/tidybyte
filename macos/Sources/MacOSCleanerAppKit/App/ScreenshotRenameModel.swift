import AppKit
import Foundation
import MacOSCleanerCore
import Observation
import os

@MainActor
@Observable
final class ScreenshotRenameModel {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ScreenshotRenameModel")

    private enum Key {
        static let autoRenameEnabled = "screenshotAutoRenameEnabled"
        static let namingStyle = "screenshotNamingStyle"
        static let watchedFolders = "screenshotWatchedFolders"
        static let renameImmediatelyOnDrop = "screenshotRenameImmediatelyOnDrop"
        static let useAppleIntelligence = "screenshotUseAppleIntelligence"
    }

    var isAutoRenameEnabled = false
    var namingStyle: ScreenshotNamingStyle = .titleCase
    var renameImmediatelyOnDrop = false
    var useAppleIntelligence = true
    var watchedFolders: [ScreenshotWatchFolder] = []
    var history: [ScreenshotRenameRecord] = []
    var learnedExamples: [StyleLearningExample] = []
    var pendingTidyUp: TidyUpScanSummary?
    var selectedHistoryID: String?
    var isScanningFolder = false
    var isApplying = false
    var lastStatusText: String?
    var errorMessage: String?

    private let store: SQLiteStore
    private let defaults: UserDefaults
    private let renameService: ScreenshotRenameService
    private let watcherService: ScreenshotWatcherService
    private var activeSecurityScopedURLs: [URL] = []
    private var loaded = false

    var appleIntelligenceAvailable: Bool {
        ScreenshotTitleGenerator.isAppleIntelligenceAvailable()
    }

    var totalNamedCount: Int {
        history.filter { $0.status != .reverted }.count
    }

    var undoableHistory: [ScreenshotRenameRecord] {
        history.filter { $0.status != .reverted }
    }

    var selectedRecord: ScreenshotRenameRecord? {
        guard let selectedHistoryID else { return nil }
        return history.first { $0.id == selectedHistoryID }
    }

    var canUndoLast: Bool {
        !undoableHistory.isEmpty && !isApplying && !isScanningFolder
    }

    init(
        store: SQLiteStore,
        defaults: UserDefaults = .standard,
        renameService: ScreenshotRenameService? = nil,
        watcherService: ScreenshotWatcherService? = nil
    ) {
        self.store = store
        self.defaults = defaults
        let service = renameService ?? ScreenshotRenameService(store: store)
        self.renameService = service
        self.watcherService = watcherService ?? ScreenshotWatcherService(store: store, renameService: service)
        loadPreferences()
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        await reloadFromStore()
        if isAutoRenameEnabled {
            await syncWatcherState()
        }
    }

    func stop() {
        Task { await watcherService.stop() }
        stopSecurityScopedAccess()
    }

    func reloadFromStore() async {
        do {
            history = try await store.loadScreenshotRenames(limit: 500)
            learnedExamples = try await store.loadStyleExamples(limit: 50)
        } catch {
            Self.logger.warning("Failed to load screenshot history: \(error.localizedDescription)")
        }
    }

    func setAutoRenameEnabled(_ enabled: Bool) async {
        isAutoRenameEnabled = enabled
        defaults.set(enabled, forKey: Key.autoRenameEnabled)
        if enabled && !DistributionChannel.supportsAdvanced && watchedFolders.filter(\.isEnabled).isEmpty {
            if let picked = await pickFolderToWatch() {
                addOrEnableWatchedFolder(picked)
            } else {
                isAutoRenameEnabled = false
                defaults.set(false, forKey: Key.autoRenameEnabled)
                return
            }
        }
        await syncWatcherState()
    }

    func setNamingStyle(_ style: ScreenshotNamingStyle) async {
        namingStyle = style
        defaults.set(style.rawValue, forKey: Key.namingStyle)
        await syncWatcherState()
    }

    func setRenameImmediatelyOnDrop(_ value: Bool) {
        renameImmediatelyOnDrop = value
        defaults.set(value, forKey: Key.renameImmediatelyOnDrop)
    }

    func setUseAppleIntelligence(_ value: Bool) async {
        useAppleIntelligence = value
        defaults.set(value, forKey: Key.useAppleIntelligence)
        await syncWatcherState()
    }

    func toggleWatchedFolder(_ folder: ScreenshotWatchFolder) async {
        guard let index = watchedFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        watchedFolders[index].isEnabled.toggle()
        persistWatchedFolders()
        await syncWatcherState()
    }

    func addWatchedFolderViaPanel() async {
        guard let url = await pickFolderToWatch() else { return }
        addOrEnableWatchedFolder(url)
        await syncWatcherState()
    }

    func removeWatchedFolder(_ folder: ScreenshotWatchFolder) async {
        watchedFolders.removeAll { $0.id == folder.id }
        persistWatchedFolders()
        await syncWatcherState()
    }

    func tidyUpDesktop() async {
        let desktop = PathSafetyPolicy.realHomeDirectory.appendingPathComponent("Desktop", isDirectory: true)
        await scanFolderForTidyUp(desktop)
    }

    func tidyUpDownloads() async {
        let downloads = PathSafetyPolicy.realHomeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        await scanFolderForTidyUp(downloads)
    }

    func chooseFolderAndTidyUp() async {
        guard let url = await pickFolderToWatch() else { return }
        await scanFolderForTidyUp(url)
    }

    func scanFolderForTidyUp(_ folderURL: URL) async {
        guard !isScanningFolder, !isApplying else { return }
        isScanningFolder = true
        errorMessage = nil
        defer { isScanningFolder = false }
        let summary = await renameService.scanFolderForTidyUp(
            at: folderURL,
            style: namingStyle,
            useAppleIntelligence: useAppleIntelligence
        )
        if summary.candidates.isEmpty {
            let override = LanguagePreferenceStore.stored()
            lastStatusText = summary.skippedWellNamedCount > 0
                ? L10n.format(
                    "%@ already looks tidy (%lld well-named files left alone).",
                    language: override,
                    folderURL.lastPathComponent,
                    summary.skippedWellNamedCount
                )
                : L10n.format("No vague screenshots or images found in %@.", language: override, folderURL.lastPathComponent)
        } else {
            pendingTidyUp = summary
        }
    }

    func handleDroppedURLs(_ urls: [URL]) async {
        guard !urls.isEmpty, !isScanningFolder, !isApplying else { return }
        isScanningFolder = true
        errorMessage = nil
        defer { isScanningFolder = false }

        let summary = await renameService.scanURLsForTidyUp(
            urls,
            style: namingStyle,
            useAppleIntelligence: useAppleIntelligence
        )
        guard !summary.candidates.isEmpty else {
            lastStatusText = L10n.string(
                "All dropped files already have readable names.",
                language: LanguagePreferenceStore.stored()
            )
            return
        }
        if renameImmediatelyOnDrop {
            await applyTidyUpCandidates(summary.candidates, folderName: summary.folderURL.lastPathComponent)
        } else {
            pendingTidyUp = summary
        }
    }

    func applyPendingTidyUp() async {
        guard let summary = pendingTidyUp else { return }
        pendingTidyUp = nil
        await applyTidyUpCandidates(summary.candidates, folderName: summary.folderURL.lastPathComponent)
    }

    func undoLast() async {
        let override = LanguagePreferenceStore.stored()
        guard let latest = undoableHistory.first else {
            lastStatusText = L10n.string("Nothing to undo.", language: override)
            return
        }
        if let batchID = latest.batchID {
            await undoBatch(batchID)
        } else {
            await undoRecord(latest)
        }
    }

    func undoRecord(_ record: ScreenshotRenameRecord) async {
        let override = LanguagePreferenceStore.stored()
        guard !isApplying else { return }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }
        do {
            let reverted = try await renameService.undo(record: record)
            await reloadFromStore()
            lastStatusText = L10n.format("Restored original name: %@", language: override, reverted.originalFileName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoBatch(_ batchID: String) async {
        let override = LanguagePreferenceStore.stored()
        guard !isApplying else { return }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }
        do {
            let reverted = try await renameService.undoBatch(batchID: batchID)
            await reloadFromStore()
            lastStatusText = reverted.count == 1
                ? L10n.format("Restored %@", language: override, reverted[0].originalFileName)
                : L10n.format("Restored %lld original filenames.", language: override, reverted.count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameHistoryRecord(_ record: ScreenshotRenameRecord, to customTitle: String) async {
        let override = LanguagePreferenceStore.stored()
        let cleaned = ScreenshotNameFormatter.sanitizeRawTitle(customTitle)
        guard !cleaned.isEmpty, !isApplying else { return }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }
        do {
            let (updated, _) = try await renameService.learnAndRenameInApp(record: record, newUserTitle: cleaned)
            await reloadFromStore()
            selectedHistoryID = updated.id
            lastStatusText = L10n.format("Renamed to %@ and learned your style.", language: override, updated.newFileName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteStyleExample(_ example: StyleLearningExample) async {
        do {
            try await store.deleteStyleExample(id: example.id)
            learnedExamples.removeAll { $0.id == example.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetAfterClear() async {
        await watcherService.stop()
        stopSecurityScopedAccess()
        isAutoRenameEnabled = false
        namingStyle = .titleCase
        renameImmediatelyOnDrop = false
        useAppleIntelligence = true
        history = []
        learnedExamples = []
        pendingTidyUp = nil
        selectedHistoryID = nil
        lastStatusText = nil
        errorMessage = nil
        for key in [Key.autoRenameEnabled, Key.namingStyle, Key.watchedFolders, Key.renameImmediatelyOnDrop, Key.useAppleIntelligence] {
            defaults.removeObject(forKey: key)
        }
        watchedFolders = DistributionChannel.supportsAdvanced ? ScreenshotWatcherService.defaultSystemFolders() : []
    }
}

extension ScreenshotRenameModel {
    private func applyTidyUpCandidates(_ candidates: [TidyUpCandidate], folderName: String) async {
        let override = LanguagePreferenceStore.stored()
        guard !isApplying else { return }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }
        do {
            let applied = try await renameService.applyTidyUpCandidates(candidates, style: namingStyle)
            await reloadFromStore()
            if applied.count == 1, let first = applied.first {
                lastStatusText = L10n.format("Renamed to %@", language: override, first.newFileName)
            } else if applied.count > 1 {
                lastStatusText = L10n.format("Tidied %lld files in %@.", language: override, applied.count, folderName)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncWatcherState() async {
        guard isAutoRenameEnabled else {
            await watcherService.stop()
            return
        }
        let activeURLs = watchedFolders.filter(\.isEnabled).map(\.url)
        guard !activeURLs.isEmpty else {
            await watcherService.stop()
            return
        }
        let style = namingStyle
        let useAI = useAppleIntelligence
        if await watcherService.isCurrentlyWatching() {
            await watcherService.updateConfiguration(folders: activeURLs, style: style, useAppleIntelligence: useAI)
        } else {
            await watcherService.start(folders: activeURLs, style: style, useAppleIntelligence: useAI) { [weak self] event in
                await MainActor.run {
                    self?.handleWatchEvent(event)
                }
            }
        }
    }

    private func handleWatchEvent(_ event: ScreenshotWatchEvent) {
        let override = LanguagePreferenceStore.stored()
        Task { await reloadFromStore() }
        switch event {
        case .renamed(let record):
            lastStatusText = L10n.format("Renamed to %@", language: override, record.newFileName)
        case .learnedStyle(let example):
            lastStatusText = L10n.format("Learned naming style: %@", language: override, example.userChosenTitle)
        case .skipped:
            break
        case .failed(_, let message):
            Self.logger.debug("Screenshot auto-rename skipped/failed: \(message, privacy: .public)")
        }
    }

    private func loadPreferences() {
        isAutoRenameEnabled = defaults.bool(forKey: Key.autoRenameEnabled)
        renameImmediatelyOnDrop = defaults.bool(forKey: Key.renameImmediatelyOnDrop)
        if defaults.object(forKey: Key.useAppleIntelligence) != nil {
            useAppleIntelligence = defaults.bool(forKey: Key.useAppleIntelligence)
        }
        if let rawStyle = defaults.string(forKey: Key.namingStyle),
           let style = ScreenshotNamingStyle(rawValue: rawStyle) {
            namingStyle = style
        }
        if let data = defaults.data(forKey: Key.watchedFolders),
           let decoded = try? JSONDecoder().decode([ScreenshotWatchFolder].self, from: data) {
            watchedFolders = decoded.map { resolveBookmarkFolder($0) }
        } else if DistributionChannel.supportsAdvanced {
            watchedFolders = ScreenshotWatcherService.defaultSystemFolders()
        }
    }

    private func resolveBookmarkFolder(_ folder: ScreenshotWatchFolder) -> ScreenshotWatchFolder {
        var resolved = folder
        if let bookmark = folder.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                trackSecurityScopedURL(url)
                resolved.url = url.standardizedFileURL
            }
        }
        return resolved
    }

    private func addOrEnableWatchedFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        trackSecurityScopedURL(standardized)
        let bookmark = try? standardized.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if let index = watchedFolders.firstIndex(where: { $0.url == standardized }) {
            watchedFolders[index].isEnabled = true
            watchedFolders[index].bookmarkData = bookmark ?? watchedFolders[index].bookmarkData
        } else {
            watchedFolders.append(
                ScreenshotWatchFolder(url: standardized, bookmarkData: bookmark, isEnabled: true, isSystemDetected: false)
            )
        }
        persistWatchedFolders()
    }

    private func persistWatchedFolders() {
        if let data = try? JSONEncoder().encode(watchedFolders) {
            defaults.set(data, forKey: Key.watchedFolders)
        }
    }

    private func pickFolderToWatch() async -> URL? {
        let override = LanguagePreferenceStore.stored()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Choose Folder", language: override)
        panel.message = L10n.string("Choose a folder containing screenshots or images.", language: override)
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        return response == .OK ? panel.url : nil
    }

    private func trackSecurityScopedURL(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !activeSecurityScopedURLs.contains(standardized) else { return }
        if standardized.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.append(standardized)
        }
    }

    private func stopSecurityScopedAccess() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }
}
