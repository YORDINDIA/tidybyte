import Foundation
import os

public enum ScreenshotRenameError: Error, LocalizedError, Sendable {
    case unsafeTarget(URL)
    case missingFile(URL)
    case identityMismatch(URL)
    case alreadyReverted
    case nothingToUndo

    public var errorDescription: String? {
        switch self {
        case .unsafeTarget(let url):
            String(
                localized: "Cannot rename protected or unsafe file: \(url.lastPathComponent)",
                comment: "Error when screenshot rename target is protected"
            )
        case .missingFile(let url):
            String(
                localized: "The file no longer exists: \(url.lastPathComponent)",
                comment: "Error when screenshot file is missing"
            )
        case .identityMismatch(let url):
            String(
                localized: "Skipped undo because \(url.lastPathComponent) was replaced on disk.",
                comment: "Error when file identity changed before undo"
            )
        case .alreadyReverted:
            String(localized: "This rename was already undone.", comment: "Error when rename record already reverted")
        case .nothingToUndo:
            String(localized: "No screenshot renames are available to undo.", comment: "Error when no screenshot renames exist to undo")
        }
    }
}

/// Executes safe, timestamp-preserving screenshot renames, batch Tidy Up runs,
/// persistent undo, and manual-override style learning.
public actor ScreenshotRenameService {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ScreenshotRenameService")

    private let store: SQLiteStore
    private let generator: ScreenshotTitleGenerator
    private let policy: PathSafetyPolicy
    private let fileManager: FileManager
    private var suppressedPaths: [String: Date] = [:]
    private var suppressedOverridePaths: [String: Date] = [:]

    public init(
        store: SQLiteStore,
        generator: ScreenshotTitleGenerator = ScreenshotTitleGenerator(),
        policy: PathSafetyPolicy = PathSafetyPolicy(),
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.generator = generator
        self.policy = policy
        self.fileManager = fileManager
    }

    public func isPathRecentlyMutatedByUs(_ url: URL) -> Bool {
        pruneSuppressedPaths()
        let key = url.standardizedFileURL.path.lowercased()
        guard let expiry = suppressedPaths[key] else { return false }
        return expiry > Date()
    }

    public func isPathRecentlyRevertedOrEditedByUs(_ url: URL) -> Bool {
        pruneSuppressedPaths()
        let key = url.standardizedFileURL.path.lowercased()
        guard let expiry = suppressedOverridePaths[key] else { return false }
        return expiry > Date()
    }

    public func scanFolderForTidyUp(
        at folderURL: URL,
        style: ScreenshotNamingStyle,
        useAppleIntelligence: Bool = true
    ) async -> TidyUpScanSummary {
        let urls = collectTopLevelFiles(in: [folderURL])
        return await buildTidyUpSummary(
            urls: urls,
            rootFolder: folderURL,
            style: style,
            useAppleIntelligence: useAppleIntelligence
        )
    }

    public func scanURLsForTidyUp(
        _ urls: [URL],
        style: ScreenshotNamingStyle,
        useAppleIntelligence: Bool = true
    ) async -> TidyUpScanSummary {
        var collected: [URL] = []
        var rootFolder = urls.first?.deletingLastPathComponent() ?? policy.homeDirectory
        for url in urls {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                rootFolder = url
                collected.append(contentsOf: collectTopLevelFiles(in: [url]))
            } else {
                collected.append(url)
            }
        }
        return await buildTidyUpSummary(
            urls: collected,
            rootFolder: rootFolder,
            style: style,
            useAppleIntelligence: useAppleIntelligence
        )
    }

    public func renameAutomatically(
        at sourceURL: URL,
        style: ScreenshotNamingStyle,
        source: ScreenshotRenameSource = .autoWatch,
        batchID: String? = nil,
        useAppleIntelligence: Bool = true
    ) async throws -> ScreenshotRenameRecord {
        guard VagueFilenameDetector.isEligibleVagueImage(at: sourceURL, policy: policy, fileManager: fileManager) else {
            throw ScreenshotRenameError.unsafeTarget(sourceURL)
        }
        let examples = (try? await store.loadStyleExamples(limit: 20)) ?? []
        let generated = await generator.generateTitle(
            for: sourceURL,
            style: style,
            learnedExamples: examples,
            useAppleIntelligence: useAppleIntelligence
        )
        return try await renameFile(
            at: sourceURL,
            toFileName: generated.formattedFileName,
            style: style,
            source: source,
            batchID: batchID,
            ocrSnippet: generated.ocrSnippet,
            visionLabels: generated.visionLabels,
            usedAppleIntelligence: generated.usedAppleIntelligence
        )
    }

    public func applyTidyUpCandidates(
        _ candidates: [TidyUpCandidate],
        style: ScreenshotNamingStyle,
        source: ScreenshotRenameSource = .tidyUp
    ) async throws -> [ScreenshotRenameRecord] {
        let selected = candidates.filter(\.isSelected)
        guard !selected.isEmpty else { return [] }
        let batchID = UUID().uuidString
        var applied: [ScreenshotRenameRecord] = []
        for candidate in selected {
            guard fileManager.fileExists(atPath: candidate.url.path) else { continue }
            let targetFileName = ScreenshotNameFormatter.fileName(
                fromFormattedTitle: candidate.proposedTitle,
                originalExtension: candidate.url.pathExtension
            )
            let record = try await renameFile(
                at: candidate.url,
                toFileName: targetFileName,
                style: style,
                source: source,
                batchID: batchID,
                ocrSnippet: candidate.ocrSnippet,
                visionLabels: candidate.visionLabels,
                usedAppleIntelligence: candidate.usedAppleIntelligence
            )
            applied.append(record)
        }
        return applied
    }

    public func renameFile(
        at sourceURL: URL,
        toFileName targetFileName: String,
        style: ScreenshotNamingStyle,
        source: ScreenshotRenameSource,
        batchID: String? = nil,
        ocrSnippet: String? = nil,
        visionLabels: [String] = [],
        usedAppleIntelligence: Bool = false
    ) async throws -> ScreenshotRenameRecord {
        let standardizedSource = sourceURL.standardizedFileURL
        guard fileManager.fileExists(atPath: standardizedSource.path) else {
            throw ScreenshotRenameError.missingFile(standardizedSource)
        }
        guard VagueFilenameDetector.isSafeRenameTarget(url: standardizedSource, policy: policy, fileManager: fileManager) else {
            throw ScreenshotRenameError.unsafeTarget(standardizedSource)
        }

        let timestamps = Self.captureTimestamps(at: standardizedSource, fileManager: fileManager)
        let identity = FileArtifactIdentity.capture(at: standardizedSource)
        let destinationURL = ScreenshotNameFormatter.collisionFreeURL(
            forFileName: targetFileName,
            in: standardizedSource.deletingLastPathComponent(),
            excluding: standardizedSource,
            style: style,
            fileManager: fileManager
        )

        suppressMutation(at: standardizedSource)
        suppressMutation(at: destinationURL)
        if standardizedSource.path != destinationURL.path {
            try fileManager.moveItem(at: standardizedSource, to: destinationURL)
        }
        Self.restoreTimestamps(timestamps, at: destinationURL, fileManager: fileManager)

        let postIdentity = FileArtifactIdentity.capture(at: destinationURL) ?? identity
        let record = ScreenshotRenameRecord(
            batchID: batchID,
            originalURL: standardizedSource,
            currentURL: destinationURL,
            originalFileName: standardizedSource.lastPathComponent,
            newFileName: destinationURL.lastPathComponent,
            deviceID: postIdentity?.deviceID,
            inodeID: postIdentity?.inodeID,
            namingStyle: style,
            source: source,
            status: .applied,
            ocrSnippet: ocrSnippet,
            visionLabels: visionLabels,
            usedAppleIntelligence: usedAppleIntelligence,
            originalCreationDate: timestamps.creationDate,
            originalModificationDate: timestamps.modificationDate
        )
        try await store.saveScreenshotRename(record)
        return record
    }

    @discardableResult
    public func undo(record: ScreenshotRenameRecord) async throws -> ScreenshotRenameRecord {
        guard record.status != .reverted else {
            throw ScreenshotRenameError.alreadyReverted
        }
        let currentURL = record.currentURL.standardizedFileURL
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw ScreenshotRenameError.missingFile(currentURL)
        }
        if let expectedDevice = record.deviceID, let expectedInode = record.inodeID {
            guard let actual = FileArtifactIdentity.capture(at: currentURL),
                  actual.deviceID == expectedDevice,
                  actual.inodeID == expectedInode else {
                throw ScreenshotRenameError.identityMismatch(currentURL)
            }
        }

        let targetURL = ScreenshotNameFormatter.collisionFreeURL(
            forFileName: record.originalFileName,
            in: currentURL.deletingLastPathComponent(),
            excluding: currentURL,
            fileManager: fileManager
        )
        let currentTimestamps = Self.captureTimestamps(at: currentURL, fileManager: fileManager)
        suppressMutation(at: currentURL, includeOverride: true)
        suppressMutation(at: targetURL, includeOverride: true)
        if currentURL.path != targetURL.path {
            try fileManager.moveItem(at: currentURL, to: targetURL)
        }
        let timestampsToRestore = (
            creationDate: record.originalCreationDate ?? currentTimestamps.creationDate,
            modificationDate: record.originalModificationDate ?? currentTimestamps.modificationDate
        )
        Self.restoreTimestamps(timestampsToRestore, at: targetURL, fileManager: fileManager)

        var updated = record
        updated.status = .reverted
        updated.currentURL = targetURL
        try await store.saveScreenshotRename(updated)
        return updated
    }

    @discardableResult
    public func undoBatch(batchID: String) async throws -> [ScreenshotRenameRecord] {
        let batch = try await store.loadScreenshotRenameBatch(batchID: batchID)
            .filter { $0.status != .reverted }
        guard !batch.isEmpty else {
            throw ScreenshotRenameError.nothingToUndo
        }
        var reverted: [ScreenshotRenameRecord] = []
        for record in batch {
            if let done = try? await undo(record: record) {
                reverted.append(done)
            }
        }
        if reverted.isEmpty {
            throw ScreenshotRenameError.nothingToUndo
        }
        return reverted
    }

    /// Renames a previously renamed file to a user-provided filename AND records
    /// a `StyleLearningExample` so future screenshots follow the user's lead.
    public func learnAndRenameInApp(
        record: ScreenshotRenameRecord,
        newUserTitle: String
    ) async throws -> (record: ScreenshotRenameRecord, example: StyleLearningExample) {
        let currentURL = record.currentURL.standardizedFileURL
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw ScreenshotRenameError.missingFile(currentURL)
        }
        let targetFileName = ScreenshotNameFormatter.fileName(
            fromFormattedTitle: newUserTitle,
            originalExtension: currentURL.pathExtension
        )
        let targetURL = ScreenshotNameFormatter.collisionFreeURL(
            forFileName: targetFileName,
            in: currentURL.deletingLastPathComponent(),
            excluding: currentURL,
            fileManager: fileManager
        )
        let timestamps = Self.captureTimestamps(at: currentURL, fileManager: fileManager)
        suppressMutation(at: currentURL, includeOverride: true)
        suppressMutation(at: targetURL, includeOverride: true)
        if currentURL.path != targetURL.path {
            try fileManager.moveItem(at: currentURL, to: targetURL)
        }
        Self.restoreTimestamps(timestamps, at: targetURL, fileManager: fileManager)
        return try await learnFromManualRename(record: record, newURL: targetURL)
    }

    /// Records a style-learning example when the user manually renamed `record`
    /// (either in Finder or in-app) to `newURL`.
    @discardableResult
    public func learnFromManualRename(
        record: ScreenshotRenameRecord,
        newURL: URL
    ) async throws -> (record: ScreenshotRenameRecord, example: StyleLearningExample) {
        let suggestedStem = URL(fileURLWithPath: record.newFileName).deletingPathExtension().lastPathComponent
        let userStem = newURL.deletingPathExtension().lastPathComponent
        let keywords = (record.ocrSnippet ?? "")
            .split(whereSeparator: \.isWhitespace)
            .prefix(8)
            .map(String.init)

        let example = StyleLearningAnalyzer.analyzeOverride(
            suggestedTitle: suggestedStem,
            userChosenTitle: userStem,
            ocrKeywords: keywords
        )
        try await store.saveStyleExample(example)

        var updated = record
        updated.status = .userOverridden
        updated.currentURL = newURL.standardizedFileURL
        updated.newFileName = newURL.lastPathComponent
        if let identity = FileArtifactIdentity.capture(at: newURL) {
            updated.deviceID = identity.deviceID
            updated.inodeID = identity.inodeID
        }
        try await store.saveScreenshotRename(updated)
        return (updated, example)
    }
}

extension ScreenshotRenameService {
    private func buildTidyUpSummary(
        urls: [URL],
        rootFolder: URL,
        style: ScreenshotNamingStyle,
        useAppleIntelligence: Bool
    ) async -> TidyUpScanSummary {
        let learned = (try? await store.loadStyleExamples(limit: 20)) ?? []
        let partitioned = partitionVagueURLs(urls)
        let candidates = await generateCandidatesConcurrently(
            urls: partitioned.vague,
            style: style,
            learnedExamples: learned,
            useAppleIntelligence: useAppleIntelligence
        )
        return TidyUpScanSummary(
            folderURL: rootFolder,
            candidates: candidates,
            skippedWellNamedCount: partitioned.skippedCount
        )
    }

    private func partitionVagueURLs(_ urls: [URL]) -> (vague: [URL], skippedCount: Int) {
        var vague: [URL] = []
        var skippedCount = 0
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard VagueFilenameDetector.supportedImageExtensions.contains(ext),
                  VagueFilenameDetector.isSafeRenameTarget(url: url, policy: policy, fileManager: fileManager) else {
                continue
            }
            let stem = url.deletingPathExtension().lastPathComponent
            if VagueFilenameDetector.isVagueStem(stem, fullFileName: url.lastPathComponent) {
                vague.append(url)
            } else {
                skippedCount += 1
            }
        }
        return (vague, skippedCount)
    }

    private func generateCandidatesConcurrently(
        urls: [URL],
        style: ScreenshotNamingStyle,
        learnedExamples: [StyleLearningExample],
        useAppleIntelligence: Bool
    ) async -> [TidyUpCandidate] {
        let maxConcurrent = 3
        return await withTaskGroup(of: (Int, TidyUpCandidate).self) { group in
            var byIndex: [Int: TidyUpCandidate] = [:]
            var iterator = urls.enumerated().makeIterator()

            func enqueueNext() -> Bool {
                guard let (idx, url) = iterator.next() else { return false }
                group.addTask {
                    let generated = await self.generator.generateTitle(
                        for: url,
                        style: style,
                        learnedExamples: learnedExamples,
                        useAppleIntelligence: useAppleIntelligence
                    )
                    let timestamps = Self.captureTimestamps(at: url)
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    let candidate = TidyUpCandidate(
                        url: url,
                        currentFileName: url.lastPathComponent,
                        proposedTitle: generated.formattedTitle,
                        proposedFileName: generated.formattedFileName,
                        isSelected: true,
                        creationDate: timestamps.creationDate,
                        modificationDate: timestamps.modificationDate,
                        sizeBytes: size,
                        ocrSnippet: generated.ocrSnippet,
                        visionLabels: generated.visionLabels,
                        usedAppleIntelligence: generated.usedAppleIntelligence
                    )
                    return (idx, candidate)
                }
                return true
            }

            for _ in 0..<maxConcurrent where enqueueNext() {}
            while let (idx, candidate) = await group.next() {
                byIndex[idx] = candidate
                _ = enqueueNext()
            }
            return urls.indices.compactMap { byIndex[$0] }
        }
    }

    private func collectTopLevelFiles(in folders: [URL]) -> [URL] {
        var files: [URL] = []
        for folder in folders {
            let entries = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            files.append(contentsOf: entries.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return files
    }

    nonisolated private static func captureTimestamps(
        at url: URL,
        fileManager: FileManager = .default
    ) -> (creationDate: Date?, modificationDate: Date?) {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else {
            return (nil, nil)
        }
        return (attrs[.creationDate] as? Date, attrs[.modificationDate] as? Date)
    }

    nonisolated private static func restoreTimestamps(
        _ timestamps: (creationDate: Date?, modificationDate: Date?),
        at url: URL,
        fileManager: FileManager = .default
    ) {
        var attrs: [FileAttributeKey: Any] = [:]
        if let creationDate = timestamps.creationDate {
            attrs[.creationDate] = creationDate
        }
        if let modificationDate = timestamps.modificationDate {
            attrs[.modificationDate] = modificationDate
        }
        guard !attrs.isEmpty else { return }
        do {
            try fileManager.setAttributes(attrs, ofItemAtPath: url.path)
        } catch {
            let msg = error.localizedDescription
            Self.logger.debug("Could not restore timestamps for \(url.lastPathComponent, privacy: .public): \(msg, privacy: .public)")
        }
    }

    private func suppressMutation(at url: URL, includeOverride: Bool = false) {
        pruneSuppressedPaths()
        let key = url.standardizedFileURL.path.lowercased()
        let expiry = Date().addingTimeInterval(6)
        suppressedPaths[key] = expiry
        if includeOverride {
            suppressedOverridePaths[key] = expiry
        }
    }

    private func pruneSuppressedPaths() {
        let now = Date()
        suppressedPaths = suppressedPaths.filter { $0.value > now }
        suppressedOverridePaths = suppressedOverridePaths.filter { $0.value > now }
    }
}
