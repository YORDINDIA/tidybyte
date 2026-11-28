import Darwin
import Foundation
import os

/// Watches configured screenshot/capture folders for newly created vague images
/// (~1s settle debounce) and detects manual Finder renames by inode to teach the
/// user's naming style.
public actor ScreenshotWatcherService {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ScreenshotWatcherService")

    private struct FolderWatch {
        let url: URL
        let source: DispatchSourceFileSystemObject
    }

    private let store: SQLiteStore
    private let renameService: ScreenshotRenameService
    private let policy: PathSafetyPolicy
    private let fileManager: FileManager
    private let settleDelayNanoseconds: UInt64

    private var watches: [FolderWatch] = []
    private var knownEntriesByFolder: [String: Set<String>] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var namingStyle: ScreenshotNamingStyle = .titleCase
    private var useAppleIntelligence = true
    private var isRunning = false
    private var eventHandler: (@Sendable (ScreenshotWatchEvent) async -> Void)?

    public init(
        store: SQLiteStore,
        renameService: ScreenshotRenameService,
        policy: PathSafetyPolicy = PathSafetyPolicy(),
        fileManager: FileManager = .default,
        settleDelayNanoseconds: UInt64 = 900_000_000
    ) {
        self.store = store
        self.renameService = renameService
        self.policy = policy
        self.fileManager = fileManager
        self.settleDelayNanoseconds = settleDelayNanoseconds
    }

    /// Resolves the macOS screenshot location from `com.apple.screencapture`,
    /// falling back to `~/Desktop`, plus optional default capture directories.
    nonisolated public static func defaultSystemFolders(
        home: URL = PathSafetyPolicy.realHomeDirectory,
        fileManager: FileManager = .default
    ) -> [ScreenshotWatchFolder] {
        var folders: [ScreenshotWatchFolder] = []
        let captureLocation: URL
        if let customPath = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !customPath.isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            captureLocation = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        } else {
            captureLocation = home.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL
        }
        folders.append(ScreenshotWatchFolder(url: captureLocation, isEnabled: true, isSystemDetected: true))

        let downloads = home.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL
        if downloads != captureLocation, fileManager.fileExists(atPath: downloads.path) {
            folders.append(ScreenshotWatchFolder(url: downloads, isEnabled: false, isSystemDetected: true))
        }

        let cleanShot = home
            .appendingPathComponent("Library/Application Support/CleanShot/media", isDirectory: true)
            .standardizedFileURL
        if fileManager.fileExists(atPath: cleanShot.path) {
            folders.append(ScreenshotWatchFolder(url: cleanShot, isEnabled: true, isSystemDetected: true))
        }
        return folders
    }

    public func updateConfiguration(
        folders: [URL],
        style: ScreenshotNamingStyle,
        useAppleIntelligence: Bool = true
    ) {
        self.namingStyle = style
        self.useAppleIntelligence = useAppleIntelligence
        if isRunning {
            let newSet = Set(folders.map(\.standardizedFileURL))
            let currentSet = Set(watches.map(\.url))
            if newSet != currentSet {
                restartWatches(folders: folders)
            }
        }
    }

    public func isCurrentlyWatching() -> Bool {
        isRunning
    }

    public func start(
        folders: [URL],
        style: ScreenshotNamingStyle,
        useAppleIntelligence: Bool = true,
        onEvent: @escaping @Sendable (ScreenshotWatchEvent) async -> Void
    ) {
        stop()
        self.namingStyle = style
        self.useAppleIntelligence = useAppleIntelligence
        self.eventHandler = onEvent
        self.isRunning = true
        restartWatches(folders: folders)
    }

    public func stop() {
        isRunning = false
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
        for watch in watches {
            watch.source.cancel()
        }
        watches.removeAll()
        knownEntriesByFolder.removeAll()
    }

    /// Exposed for deterministic testing and immediate folder scans without waiting on kqueue.
    public func processFolderChange(at folderURL: URL) async {
        let standardizedFolder = folderURL.standardizedFileURL
        let folderKey = standardizedFolder.path
        let currentNames = snapshotEntries(in: standardizedFolder)
        let previousNames = knownEntriesByFolder[folderKey] ?? []
        knownEntriesByFolder[folderKey] = currentNames

        await detectFinderManualOverrides(in: standardizedFolder, currentEntries: currentNames)

        let addedNames = currentNames.subtracting(previousNames).sorted()
        for fileName in addedNames {
            let candidateURL = standardizedFolder.appendingPathComponent(fileName, isDirectory: false)
            await handleNewCandidate(at: candidateURL)
        }
        let updatedNames = snapshotEntries(in: standardizedFolder)
        knownEntriesByFolder[folderKey] = updatedNames
    }

    private func restartWatches(folders: [URL]) {
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        for watch in watches { watch.source.cancel() }
        watches.removeAll()
        knownEntriesByFolder.removeAll()

        let uniqueFolders = Array(Set(folders.map(\.standardizedFileURL)))
        for folder in uniqueFolders {
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            knownEntriesByFolder[folder.path] = snapshotEntries(in: folder)
            let descriptor = Darwin.open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else {
                Self.logger.debug("Unable to watch folder \(folder.path, privacy: .public)")
                continue
            }
            let queue = DispatchQueue(label: "com.sakshammittal.tidybyte.screenshotwatch.\(folder.lastPathComponent)")
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                Task { await self?.scheduleFolderCheck(folder) }
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            source.resume()
            watches.append(FolderWatch(url: folder, source: source))
        }
    }

    private func scheduleFolderCheck(_ folder: URL) {
        let key = folder.standardizedFileURL.path
        debounceTasks[key]?.cancel()
        let delay = settleDelayNanoseconds
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            await self.processFolderChange(at: folder)
        }
    }

    private func handleNewCandidate(at url: URL) async {
        guard !(await renameService.isPathRecentlyMutatedByUs(url)) else { return }
        guard VagueFilenameDetector.isEligibleVagueImage(at: url, policy: policy, fileManager: fileManager) else {
            return
        }
        guard await waitForStableFileSize(at: url) else { return }
        guard !(await renameService.isPathRecentlyMutatedByUs(url)) else { return }

        do {
            let record = try await renameService.renameAutomatically(
                at: url,
                style: namingStyle,
                source: .autoWatch,
                useAppleIntelligence: useAppleIntelligence
            )
            await eventHandler?(.renamed(record))
        } catch {
            Self.logger.debug(
                "Auto-rename failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await eventHandler?(.failed(url: url, error: error.localizedDescription))
        }
    }

    private func detectFinderManualOverrides(in folder: URL, currentEntries: Set<String>) async {
        guard let recent = try? await store.loadScreenshotRenames(limit: 120) else { return }
        let folderPath = folder.standardizedFileURL.path
        let candidates = recent.filter {
            $0.status == .applied
                && $0.currentURL.deletingLastPathComponent().standardizedFileURL.path == folderPath
                && !currentEntries.contains($0.currentURL.lastPathComponent)
        }
        guard !candidates.isEmpty else { return }

        var entriesByIdentity: [FileArtifactIdentity: URL] = [:]
        for name in currentEntries {
            let entryURL = folder.appendingPathComponent(name, isDirectory: false)
            if let identity = FileArtifactIdentity.capture(at: entryURL) {
                entriesByIdentity[identity] = entryURL
            }
        }

        for record in candidates {
            guard !(await renameService.isPathRecentlyRevertedOrEditedByUs(record.currentURL)),
                  let dev = record.deviceID,
                  let inode = record.inodeID else { continue }
            let targetIdentity = FileArtifactIdentity(deviceID: dev, inodeID: inode)
            guard let relocatedURL = entriesByIdentity[targetIdentity],
                  !(await renameService.isPathRecentlyRevertedOrEditedByUs(relocatedURL)),
                  relocatedURL.lastPathComponent != record.newFileName,
                  relocatedURL.lastPathComponent != record.originalFileName else {
                continue
            }
            if let (_, example) = try? await renameService.learnFromManualRename(record: record, newURL: relocatedURL) {
                await eventHandler?(.learnedStyle(example))
            }
        }
    }

    private func waitForStableFileSize(at url: URL) async -> Bool {
        let firstSize = fileSize(at: url)
        guard let firstSize, firstSize > 0 else { return false }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled, fileManager.fileExists(atPath: url.path) else { return false }
        guard let secondSize = fileSize(at: url), secondSize == firstSize else { return false }
        return true
    }

    private func fileSize(at url: URL) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func snapshotEntries(in folder: URL) -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }
}
