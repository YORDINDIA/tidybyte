import Darwin
import Foundation
import os

/// S-01: the cleanup posture has to change what the rule engine proposes.
/// Conservative asks for older, larger candidates; aggressive proposes
/// younger, smaller ones; balanced keeps the thresholds this engine has
/// always used.
private struct PostureThresholds {
    let oldDownloadDays: Int
    let organizationDays: Int
    let largeFileBytes: Int64

    init(_ posture: CleanupPosture) {
        switch posture {
        case .conservative:
            oldDownloadDays = 60
            organizationDays = 90
            largeFileBytes = 2 * FileCrawler.largeFileBytes
        case .balanced:
            oldDownloadDays = 30
            organizationDays = 45
            largeFileBytes = FileCrawler.largeFileBytes
        case .aggressive:
            oldDownloadDays = 14
            organizationDays = 30
            largeFileBytes = FileCrawler.largeFileBytes / 2
        }
    }
}

public actor CleanerRuleEngine {
    private let policy: PathSafetyPolicy
    private let homeDirectoryOverride: URL?
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "CleanerRuleEngine")

    private var homeDirectory: URL {
        homeDirectoryOverride ?? PathSafetyPolicy.realHomeDirectory
    }

    private var desktopAndDocumentsPrefixes: [String] {
        ["Desktop", "Documents"].map {
            homeDirectory.appendingPathComponent($0).standardizedFileURL.path + "/"
        }
    }

    private static let lowRiskDeveloperArtifacts = ProjectArtifactFolders.lowRisk

    /// Build-output directories that only make sense inside a detected project
    /// root (a directory containing a manifest such as package.json, Package.swift
    /// or *.xcodeproj). Matching these outside a project would risk deleting
    /// unrelated folders named "build", "dist" or "target" in a user's home or
    /// Documents folder, so a project root is required.
    private static let projectBoundBuildOutputs = ProjectArtifactFolders.projectBound

    /// Xcode's global build cache (~/Library/Developer/Xcode/DerivedData). It
    /// lives outside project roots by definition, so the project-containment
    /// guard does not apply. CoreSimulator is not a cache: it holds devices.
    private static let globalBuildCacheDirectories: Set<String> = ["deriveddata"]

    private static let mediumRiskDeveloperArtifacts: Set<String> = projectBoundBuildOutputs.union(globalBuildCacheDirectories)

    public init(policy: PathSafetyPolicy = PathSafetyPolicy(), homeDirectoryOverride: URL? = nil) {
        self.policy = policy
        self.homeDirectoryOverride = homeDirectoryOverride
    }

    /// True when the policy permits `record` as a cleanup candidate. Uses the
    /// policy's analyze-time gate: the crawler already recorded each record's
    /// risk flags, so no filesystem round-trips happen here (`decide` resolves
    /// symlink ancestors with one syscall per record — seconds per million
    /// records, three times over in this engine). `SafetyAuditor` re-decides
    /// with full symlink resolution before anything is deleted.
    private func isAllowed(_ record: FileRecord) -> Bool {
        policy.allowsCleanupTarget(record)
    }

    public func analyze(
        files: [FileRecord],
        projects: [ProjectUnit],
        sessionID: String,
        posture: CleanupPosture = .balanced
    ) throws -> ([Finding], [Recommendation]) {
        var findings: [Finding] = []
        var recommendations: [Recommendation] = []
        let directorySizes = subtreeSizes(for: files)
        let thresholds = PostureThresholds(posture)

        // One policy pass for every rule below. The crawler already recorded
        // each record's risk flags, so filtering is string work; the allowed
        // set feeds the findings loop and the per-rule passes alike, instead
        // of being recomputed up to three times per record.
        let allowedFiles = files.filter { record in autoreleasepool { isAllowed(record) } }
        // One autorelease pool per record: the path checks autorelease URL
        // objects, and a pass over a million records otherwise keeps them all
        // alive. A million-record pass takes seconds; check cancellation
        // periodically so cancelScan() does not wait for the whole pass.
        for record in allowedFiles {
            if record.id.hashValue % 2048 == 0 {
                try Task.checkCancellation()
            }
            if let result = autoreleasepool(invoking: {
                firstFinding(
                    for: record, sessionID: sessionID, directorySizes: directorySizes, projects: projects,
                    thresholds: thresholds)
            }) {
                findings.append(result.finding)
                recommendations.append(result.recommendation)
            }
        }
        let screenshots = screenshotFindings(in: allowedFiles, sessionID: sessionID)
        findings.append(contentsOf: screenshots)
        for screenshot in screenshots {
            let recommendation = Recommendation(
                id: UUID().uuidString,
                findingID: screenshot.id,
                actionType: .moveToTrash,
                targetFileIDs: screenshot.targetFileIDs,
                confidence: screenshot.confidence,
                risk: screenshot.severity,
                reason: String(localized: "Review screenshots and screen recordings before moving them to Trash.", comment: "Recommendation reason for screenshot cleanup"),
                expectedBytesReclaimed: screenshot.bytesReclaimable,
                requiresConfirmation: true,
                llmTraceID: nil,
                policyTraceID: "screenshot_rule"
            )
            recommendations.append(recommendation)
        }

        let packageCacheResults = packageManagerCacheFindings(files: allowedFiles, sessionID: sessionID, directorySizes: directorySizes)
        findings.append(contentsOf: packageCacheResults.map(\.finding))
        recommendations.append(contentsOf: packageCacheResults.map(\.recommendation))

        let previewResults = xcodePreviewsFindings(in: files, sessionID: sessionID, directorySizes: directorySizes)
        findings.append(contentsOf: previewResults.map(\.finding))
        recommendations.append(contentsOf: previewResults.map(\.recommendation))

        let largeFiles = largeFileFindings(files: allowedFiles, sessionID: sessionID, thresholds: thresholds)
        findings.append(contentsOf: largeFiles.map(\.finding))
        recommendations.append(contentsOf: largeFiles.map(\.recommendation))
        let appLeftovers = appLeftoverFindings(files: allowedFiles, sessionID: sessionID, directorySizes: directorySizes)
        findings.append(contentsOf: appLeftovers.map(\.finding))
        recommendations.append(contentsOf: appLeftovers.map(\.recommendation))
        return (dedupeFindings(findings), dedupeRecommendations(recommendations))
    }

    private func developerArtifactFinding(
        _ record: FileRecord,
        sessionID: String,
        directorySizes: [String: Int64],
        projects: [ProjectUnit]
    ) -> (finding: Finding, recommendation: Recommendation)? {
        guard record.kind == .directory else {
            return nil
        }
        // Case-insensitive matching: macOS filesystems are case-insensitive by
        // default, so "Node_Modules" and "node_modules" refer to the same folder.
        let loweredName = record.fileName.lowercased()
        guard Self.lowRiskDeveloperArtifacts.contains(loweredName) || Self.mediumRiskDeveloperArtifacts.contains(loweredName) else {
            return nil
        }
        let project = projects.first { record.displayPath.hasPrefix($0.rootURL.path + "/") }
        // Build outputs (node_modules, dist, build, target, ...) are only proposed
        // when they sit inside a detected project root.
        if Self.projectBoundBuildOutputs.contains(loweredName) && project == nil {
            return nil
        }
        var size = directorySizes[record.displayPath] ?? record.sizeBytes
        // node_modules/.cache emits its own cache finding inside project roots, so
        // subtract its bytes here to avoid double-counting reclaimable space.
        if loweredName == "node_modules", project != nil {
            let cacheSubtreeBytes = directorySizes[record.displayPath + "/.cache"] ?? 0
            if cacheSubtreeBytes > 1024 * 1024 {
                size = max(0, size - cacheSubtreeBytes)
            }
        }
        guard size > 0 else {
            return nil
        }
        let isLowRisk = Self.lowRiskDeveloperArtifacts.contains(loweredName)
        let risk: RiskLevel = isLowRisk ? .low : .medium
        let confidence = project == nil && loweredName == "node_modules" ? 0.66 : (isLowRisk ? 0.94 : 0.84)
        let findingID = UUID().uuidString
        let evidence = [
            "folder_name": record.fileName,
            "project": project?.name ?? "unknown",
            "project_status": project?.status.rawValue ?? "unknown",
            "bytes": String(size)
        ]
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: .developerArtifact,
            severity: risk,
            confidence: confidence,
            bytesReclaimable: size,
            summary: String(localized: "\(record.fileName) appears to be a rebuildable developer artifact.", comment: "Finding summary for developer artifact"),
            evidence: evidence,
            targetFileIDs: [record.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: .moveToTrash,
            targetFileIDs: [record.id],
            confidence: confidence,
            risk: risk,
            reason: reasonForDeveloperArtifact(record: record, project: project, risk: risk),
            expectedBytesReclaimed: size,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: "developer_artifact_rule"
        )
        return (finding, recommendation)
    }

    private func xcarchiveFinding(
        _ record: FileRecord,
        sessionID: String,
        directorySizes: [String: Int64]
    ) -> (finding: Finding, recommendation: Recommendation)? {
        guard record.kind == .directory, record.fileExtension == "xcarchive" else { return nil }
        let size = directorySizes[record.displayPath] ?? record.sizeBytes
        guard size > 0 else { return nil }
        let findingID = UUID().uuidString
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: .developerArtifact,
            severity: .medium,
            confidence: 0.88,
            bytesReclaimable: size,
            summary: String(localized: "Xcode archive (.xcarchive) found.", comment: "Finding summary for xcarchive"),
            evidence: ["path": record.displayPath, "bytes": String(size)],
            targetFileIDs: [record.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: .inspectOnly,
            targetFileIDs: [record.id],
            confidence: 0.88,
            risk: .high,
            reason: String(localized: "Xcode archives keep the debug symbols for builds you shipped. They cannot be rebuilt from source. Delete them in Xcode Organizer only when you no longer need to read crash reports.", comment: "Recommendation reason for xcarchive review"),
            expectedBytesReclaimed: size,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: "xcarchive_rule"
        )
        return (finding, recommendation)
    }

    private func cacheOrLogFinding(
        _ record: FileRecord,
        sessionID: String,
        directorySizes: [String: Int64],
        projects: [ProjectUnit]
    ) -> (finding: Finding, recommendation: Recommendation)? {
        let components = record.url.pathComponents
        guard !isDedicatedLocalAIDevCacheDescendant(record.url.standardizedFileURL.path) else {
            return nil
        }
        // Case-insensitive cache detection to catch "cache", "Cache", "CACHE" variants
        let isCache = components.contains(where: { $0.lowercased() == "caches" || $0.lowercased() == ".cache" || $0.lowercased() == "cache" })
        // A "Logs" folder in Documents can hold user files: only the macOS log folders and .log files count.
        let isLog = record.fileExtension == "log"
            || Self.isMacOSLogPath(record.url.standardizedFileURL.path, home: homeDirectory.standardizedFileURL.path)
        guard isCache || isLog else {
            return nil
        }
        // "node_modules/.cache"-style matches are only proposed inside a detected
        // project root; a stray node_modules outside any project is ambiguous.
        if components.contains(where: { $0.lowercased() == "node_modules" })
            && !projects.contains(where: { record.displayPath.hasPrefix($0.rootURL.path + "/") }) {
            return nil
        }
        let size = record.kind == .directory ? (directorySizes[record.displayPath] ?? record.sizeBytes) : record.sizeBytes
        guard size > 1024 * 1024 else {
            return nil
        }
        let category: FindingCategory = isLog ? .log : .cache
        let findingID = UUID().uuidString
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: category,
            severity: .low,
            confidence: 0.9,
            bytesReclaimable: size,
            summary: isLog ? String(localized: "Old or large log file/folder.", comment: "Finding summary for log file") : String(localized: "Application or package cache.", comment: "Finding summary for cache"),
            evidence: ["path": record.displayPath, "bytes": String(size)],
            targetFileIDs: [record.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: .moveToTrash,
            targetFileIDs: [record.id],
            confidence: 0.9,
            risk: .low,
            reason: String(localized: "Caches and logs are usually rebuildable, but the action still requires review and uses Trash.", comment: "Recommendation reason for cache/log cleanup"),
            expectedBytesReclaimed: size,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: "cache_log_rule"
        )
        return (finding, recommendation)
    }

    /// Installer archive extensions. Internal so the natural-language planner
    /// can apply the same set to "old installers" commands.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    private func oldDownloadFinding(
        _ record: FileRecord, sessionID: String, thresholds: PostureThresholds
    ) -> (finding: Finding, recommendation: Recommendation)? {
        let folders = Set(record.url.pathComponents.map { $0.lowercased() })
        let isInstaller = record.fileExtension.map(Self.installerExtensions.contains) ?? false
        let inDownloads = folders.contains("downloads")
        // Archives count in Downloads only; installers also in ~/Desktop and ~/Documents.
        let path = record.url.standardizedFileURL.path
        guard record.kind == .regularFile || (record.kind == .package && isInstaller),
              inDownloads || (isInstaller && desktopAndDocumentsPrefixes.contains { path.hasPrefix($0) }),
              let modifiedAt = record.modifiedAt,
              let cutoff = Calendar.current.date(byAdding: .day, value: -thresholds.oldDownloadDays, to: Date()),
              modifiedAt < cutoff else {
            return nil
        }
        let oldDownloadExtensions = Self.installerExtensions.union(["zip", "tar", "gz", "xz", "rar", "7z", "img", "deb", "rpm", "msi"])
        guard let fileExtension = record.fileExtension, oldDownloadExtensions.contains(fileExtension) else {
            return nil
        }
        // People keep some installers on purpose: outside Downloads, bulk approval skips them.
        let risk: RiskLevel = isInstaller && inDownloads ? .low : .medium
        let findingID = UUID().uuidString
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: isInstaller ? .oldInstaller : .oldDownload,
            severity: risk,
            confidence: 0.86,
            bytesReclaimable: record.sizeBytes,
            summary: String(localized: "Old download archive or installer.", comment: "Finding summary for old download"),
            evidence: ["modified_at": modifiedAt.ISO8601Format(), "extension": fileExtension],
            targetFileIDs: [record.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: .moveToTrash,
            targetFileIDs: [record.id],
            confidence: 0.86,
            risk: risk,
            reason: String(localized: "The file is an old downloaded archive or installer. Review before moving it to Trash.", comment: "Recommendation reason for old download cleanup"),
            expectedBytesReclaimed: record.sizeBytes,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: "old_download_rule"
        )
        return (finding, recommendation)
    }

    private func codingAgentFinding(
        _ record: FileRecord,
        sessionID: String,
        directorySizes: [String: Int64]
    ) -> (finding: Finding, recommendation: Recommendation)? {
        let components = record.url.pathComponents.map { $0.lowercased() }
        let agentRoots = PathSafetyPolicy.codingAgentFolders
        guard components.contains(where: { agentRoots.contains($0) }) else {
            return nil
        }
        let safeNames: Set<String> = ["logs", "log", "cache", "caches", "tmp", "temp", "outputs"]
        guard components.contains(where: { safeNames.contains($0.lowercased()) }) else {
            return nil
        }
        let size = record.kind == .directory ? (directorySizes[record.displayPath] ?? record.sizeBytes) : record.sizeBytes
        guard size > 0 else {
            return nil
        }
        let findingID = UUID().uuidString
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: .codingAgentArtifact,
            severity: .medium,
            confidence: 0.74,
            bytesReclaimable: size,
            summary: String(localized: "Coding-agent log/cache artifact. Config and memory paths remain protected.", comment: "Finding summary for coding agent artifact"),
            evidence: ["path": record.displayPath, "bytes": String(size)],
            targetFileIDs: [record.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: .archive,
            targetFileIDs: [record.id],
            confidence: 0.74,
            risk: .medium,
            reason: String(localized: "This looks like a coding-agent log/cache path. Archive is suggested before deletion because agent sessions can contain useful private context.", comment: "Recommendation reason for coding agent artifact"),
            expectedBytesReclaimed: size,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: "coding_agent_safe_candidate_rule"
        )
        return (finding, recommendation)
    }

    private func organizationFinding(
        _ record: FileRecord, sessionID: String, thresholds: PostureThresholds
    ) -> (finding: Finding, recommendation: Recommendation)? {
        guard record.kind == .regularFile,
              record.url.pathComponents.contains(where: { $0.lowercased() == "downloads" }),
              let modifiedAt = record.modifiedAt,
              let cutoff = Calendar.current.date(byAdding: .day, value: -thresholds.organizationDays, to: Date()),
              modifiedAt < cutoff else {
            return nil
        }
        let organizeExtensions: Set<String> = ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "png", "jpg", "jpeg", "mov", "mp4"]
        guard let fileExtension = record.fileExtension, organizeExtensions.contains(fileExtension) else {
            return nil
        }
        let findingID = UUID().uuidString
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: .organization,
            severity: .medium,
            confidence: 0.68,
            bytesReclaimable: 0,
            summary: String(localized: "Downloaded file may belong in an archive or tagged collection.", comment: "Finding summary for organization candidate"),
            evidence: ["extension": fileExtension, "modified_at": modifiedAt.ISO8601Format()],
            targetFileIDs: [record.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: .tag,
            targetFileIDs: [record.id],
            confidence: 0.68,
            risk: .medium,
            reason: String(localized: "Tag this older download for review instead of moving it automatically.", comment: "Recommendation reason for organization tagging"),
            expectedBytesReclaimed: 0,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: "downloads_organization_rule"
        )
        return (finding, recommendation)
    }

    private func largeFileFindings(
        files: [FileRecord], sessionID: String, thresholds: PostureThresholds
    ) -> [(finding: Finding, recommendation: Recommendation)] {
        let thresholdLabel = thresholds.largeFileBytes.formattedByteCount
        return files
            .filter { $0.kind == .regularFile && $0.sizeBytes >= thresholds.largeFileBytes }
            .map { record in
                let findingID = UUID().uuidString
                let finding = Finding(
                    id: findingID,
                    scanSessionID: sessionID,
                    category: .largeFile,
                    severity: .high,
                    confidence: 0.7,
                    bytesReclaimable: record.sizeBytes,
                    summary: String(localized: "Large file worth reviewing.", comment: "Finding summary for large file"),
                    evidence: ["path": record.displayPath, "bytes": String(record.sizeBytes)],
                    targetFileIDs: [record.id]
                )
                let recommendation = Recommendation(
                    id: UUID().uuidString,
                    findingID: findingID,
                    actionType: .inspectOnly,
                    targetFileIDs: [record.id],
                    confidence: 0.7,
                    risk: .high,
                    reason: String(
                        localized: "This file is over \(thresholdLabel). Review whether it can be moved or deleted.",
                        comment: "Recommendation reason for large file"
                    ),
                    expectedBytesReclaimed: record.sizeBytes,
                    requiresConfirmation: true,
                    llmTraceID: nil,
                    policyTraceID: "large_file_rule"
                )
                return (finding, recommendation)
            }
    }

    private static let appleProtectedSupportFolders: Set<String> = [
        "dock", "addressbook", "clouddocs", "syncservices", "crashreporter",
        "mobilesync", "callhistorydb", "callhistorytransactions", "icloud",
        "icloudmailagent", "differentialprivacy", "facedatastore", "knowledge",
        "animoji", "coredata", "spotlight", "fileprovider", "apple"
    ]

    private static let appFolderVendorAliases: [String: (appNames: Set<String>, bundlePrefixes: [String])] = [
        "code": (["visualstudiocode", "vscode"], ["com.microsoft.vscode"]),
        "vscode": (["visualstudiocode"], ["com.microsoft.vscode"]),
        "mozilla": (["firefox", "thunderbird"], ["org.mozilla."]),
        "google": (["googlechrome", "googleearth", "googledrive"], ["com.google."]),
        "adobe": (["adobe"], ["com.adobe."]),
        "jetbrains": (
            ["intellijidea", "pycharm", "webstorm", "goland", "clion", "datagrip", "rider", "rubymine", "phpstorm", "fleet"],
            ["com.jetbrains."]
        ),
        "slack": (["slack"], ["com.tinyspeck.slackmacgap"]),
        "steam": (["steam"], ["com.valvesoftware.steam"]),
        "discord": (["discord"], ["com.hnc.discord"]),
        "spotify": (["spotify"], ["com.spotify.client"]),
        "notion": (["notion"], ["notion.id"])
    ]

    private func appLeftoverFindings(
        files: [FileRecord],
        sessionID: String,
        directorySizes: [String: Int64]
    ) -> [(finding: Finding, recommendation: Recommendation)] {
        let inventory = installedApplicationInventory()
        let supportDirectories = files.filter { record in
            record.kind == .directory
                && record.url.deletingLastPathComponent().lastPathComponent == "Application Support"
        }
        return supportDirectories.compactMap { record in
            let lowered = record.fileName.lowercased()
            guard !Self.appleProtectedSupportFolders.contains(lowered),
                  !lowered.hasPrefix("com.apple.") else {
                return nil
            }
            guard !isInstalledApplicationFolder(record.fileName, inventory: inventory) else {
                return nil
            }
            let size = directorySizes[record.displayPath] ?? record.sizeBytes
            guard size > 50_000_000 else {
                return nil
            }
            let findingID = UUID().uuidString
            let finding = Finding(
                id: findingID,
                scanSessionID: sessionID,
                category: .appLeftover,
                severity: .medium,
                confidence: 0.62,
                bytesReclaimable: size,
                summary: String(localized: "Possible app support leftover for an app that is not currently installed.", comment: "Finding summary for app leftover"),
                evidence: ["folder": record.displayPath, "bytes": String(size)],
                targetFileIDs: [record.id]
            )
            let recommendation = Recommendation(
                id: UUID().uuidString,
                findingID: findingID,
                actionType: .moveToTrash,
                targetFileIDs: [record.id],
                confidence: 0.62,
                risk: .medium,
                reason: String(localized: "This Application Support folder does not clearly match an installed app. Review carefully before moving it to Trash.", comment: "Recommendation reason for app leftover"),
                expectedBytesReclaimed: size,
                requiresConfirmation: true,
                llmTraceID: nil,
                policyTraceID: "app_leftover_rule"
            )
            return (finding, recommendation)
        }
    }

    private func reasonForDeveloperArtifact(record: FileRecord, project: ProjectUnit?, risk: RiskLevel) -> String {
        if let project {
            return String(localized: "The folder is a rebuildable artifact inside the \(project.name) project. The project is \(project.status.rawValue), and source/config files remain protected.", comment: "Recommendation reason for developer artifact with project")
        }
        if risk == .low {
            return String(localized: "The folder is a low-risk rebuildable cache or test artifact. It will still go through review and Trash.", comment: "Recommendation reason for low-risk developer artifact")
        }
        return String(localized: "The folder is a rebuildable developer artifact, but the surrounding project is unclear, so it requires grouped review.", comment: "Recommendation reason for developer artifact without project")
    }

    /// The first rule that matches the record, in priority order.
    private func firstFinding(
        for record: FileRecord, sessionID: String, directorySizes: [String: Int64], projects: [ProjectUnit],
        thresholds: PostureThresholds
    ) -> (finding: Finding, recommendation: Recommendation)? {
        // The caller loops over the engine's one policy pass, so `record` is
        // already policy-allowed.
        return danglingSymlinkFinding(record, sessionID: sessionID)
            ?? developerArtifactFinding(record, sessionID: sessionID, directorySizes: directorySizes, projects: projects)
            ?? xcarchiveFinding(record, sessionID: sessionID, directorySizes: directorySizes)
            ?? localAIDevCacheFinding(record, sessionID: sessionID, directorySizes: directorySizes)
            ?? cacheOrLogFinding(record, sessionID: sessionID, directorySizes: directorySizes, projects: projects)
            ?? oldDownloadFinding(record, sessionID: sessionID, thresholds: thresholds)
            ?? codingAgentFinding(record, sessionID: sessionID, directorySizes: directorySizes)
            ?? organizationFinding(record, sessionID: sessionID, thresholds: thresholds)
    }

    private func danglingSymlinkFinding(
        _ record: FileRecord,
        sessionID: String
    ) -> (finding: Finding, recommendation: Recommendation)? {
        guard record.kind == .symlink else { return nil }
        guard let rawTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: record.url.path) else {
            return nil
        }
        let targetURL = rawTarget.hasPrefix("/")
            ? URL(fileURLWithPath: rawTarget)
            : record.url.deletingLastPathComponent().appendingPathComponent(rawTarget)
        let resolvedTarget = targetURL.standardizedFileURL
        guard !resolvedTarget.path.hasPrefix("/Volumes/") else { return nil }
        guard Darwin.access(resolvedTarget.path, F_OK) != 0,
              errno == ENOENT || errno == ENOTDIR || errno == ELOOP else {
            return nil
        }
        let findingID = UUID().uuidString
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: .organization,
            severity: .low,
            confidence: 0.9,
            bytesReclaimable: 0,
            summary: String(localized: "Broken symbolic link.", comment: "Finding summary for dangling symlink"),
            evidence: ["path": record.displayPath, "target": resolvedTarget.path],
            targetFileIDs: [record.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: .inspectOnly,
            targetFileIDs: [record.id],
            confidence: 0.9,
            risk: .low,
            reason: String(
                localized: "This symbolic link points to \(resolvedTarget.path), which does not exist. Inspect before removing manually.",
                comment: "Recommendation reason for dangling symlink"
            ),
            expectedBytesReclaimed: 0,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: "dangling_symlink_rule"
        )
        return (finding, recommendation)
    }

    private struct DedicatedCacheDescriptor {
        let path: String
        let isInspectOnly: Bool
        let category: FindingCategory
        let title: String
        let reason: String
    }

    private struct CachePairSpec {
        let category: FindingCategory
        let actionType: ActionType
        let risk: RiskLevel
        let policyTraceID: String
        let summary: String
        let reason: String
    }

    private var dedicatedCacheDescriptors: [DedicatedCacheDescriptor] {
        let home = homeDirectory.standardizedFileURL.path
        return [
            DedicatedCacheDescriptor(
                path: home + "/.cache/huggingface", isInspectOnly: true, category: .cache,
                title: String(localized: "Hugging Face model cache.", comment: "Finding summary for Hugging Face cache"),
                reason: String(
                    localized: "Downloaded AI model weights can be large and slow to re-download. Inspect before deleting.",
                    comment: "Inspect reason for Hugging Face cache"
                )
            ),
            DedicatedCacheDescriptor(
                path: home + "/.ollama/models", isInspectOnly: true, category: .cache,
                title: String(localized: "Ollama local AI models.", comment: "Finding summary for Ollama models"),
                reason: String(
                    localized: "Local LLM weights are large and slow to re-download. Inspect with `ollama rm` before removing.",
                    comment: "Inspect reason for Ollama models"
                )
            ),
            DedicatedCacheDescriptor(
                path: home + "/.cargo/registry/cache", isInspectOnly: false, category: .cache,
                title: String(localized: "Cargo package archive cache.", comment: "Finding summary for Cargo cache"),
                reason: String(
                    localized: "Downloaded Rust crate archives are rebuildable on next build. Review before moving to Trash.",
                    comment: "Reason for Cargo cache"
                )
            ),
            DedicatedCacheDescriptor(
                path: home + "/.cache/uv", isInspectOnly: false, category: .cache,
                title: String(localized: "uv Python package cache.", comment: "Finding summary for uv cache"),
                reason: String(
                    localized: "uv package cache files can be re-downloaded when needed. Review before moving to Trash.",
                    comment: "Reason for uv cache"
                )
            ),
            DedicatedCacheDescriptor(
                path: home + "/.bun/install/cache", isInspectOnly: false, category: .cache,
                title: String(localized: "Bun package cache.", comment: "Finding summary for Bun cache"),
                reason: String(
                    localized: "Bun install cache files are rebuildable. Review before moving to Trash.",
                    comment: "Reason for Bun cache"
                )
            )
        ]
    }

    private func isDedicatedLocalAIDevCacheDescendant(_ standardizedPath: String) -> Bool {
        if dedicatedCacheDescriptors.contains(where: {
            standardizedPath == $0.path || standardizedPath.hasPrefix($0.path + "/")
        }) {
            return true
        }
        let components = standardizedPath.split(separator: "/")
        return components.contains { $0.lowercased() == "modulecache.noindex" }
    }

    private func localAIDevCacheFinding(
        _ record: FileRecord,
        sessionID: String,
        directorySizes: [String: Int64]
    ) -> (finding: Finding, recommendation: Recommendation)? {
        guard record.kind == .directory else { return nil }
        let standardized = record.url.standardizedFileURL.path
        let size = directorySizes[record.displayPath] ?? record.sizeBytes
        guard size > 1_048_576 else { return nil }

        if record.fileName.lowercased() == "modulecache.noindex" {
            return makeCachePair(
                record: record, sessionID: sessionID, size: size,
                spec: CachePairSpec(
                    category: .developerArtifact, actionType: .moveToTrash, risk: .low,
                    policyTraceID: "dev_cache_rule",
                    summary: String(localized: "Xcode Clang module cache (ModuleCache.noindex).", comment: "Finding summary for ModuleCache"),
                    reason: String(
                        localized: "Xcode rebuilds ModuleCache.noindex automatically on the next build.",
                        comment: "Reason for ModuleCache cleanup"
                    )
                )
            )
        }
        guard let descriptor = dedicatedCacheDescriptors.first(where: { standardized == $0.path }) else {
            return nil
        }
        return makeCachePair(
            record: record, sessionID: sessionID, size: size,
            spec: CachePairSpec(
                category: descriptor.category,
                actionType: descriptor.isInspectOnly ? .inspectOnly : .moveToTrash,
                risk: descriptor.isInspectOnly ? .medium : .low,
                policyTraceID: descriptor.isInspectOnly ? "local_ai_dev_cache_rule" : "dev_cache_rule",
                summary: descriptor.title,
                reason: descriptor.reason
            )
        )
    }

    private func xcodePreviewsFindings(
        in files: [FileRecord],
        sessionID: String,
        directorySizes: [String: Int64]
    ) -> [(finding: Finding, recommendation: Recommendation)] {
        let previewsPath = homeDirectory.standardizedFileURL.path + "/Library/Developer/Xcode/UserData/Previews"
        return files.compactMap { record in
            guard record.kind == .directory,
                  record.url.standardizedFileURL.path == previewsPath else { return nil }
            let size = directorySizes[record.displayPath] ?? record.sizeBytes
            guard size > 1_048_576 else { return nil }
            return makeCachePair(
                record: record, sessionID: sessionID, size: size,
                spec: CachePairSpec(
                    category: .developerArtifact, actionType: .inspectOnly, risk: .medium,
                    policyTraceID: "local_ai_dev_cache_rule",
                    summary: String(localized: "Xcode SwiftUI Previews cache.", comment: "Finding summary for Xcode Previews cache"),
                    reason: String(
                        localized: """
                            Xcode Previews caches simulator state and takes significant space. Prune safely with \
                            `xcrun simctl --set previews`.
                            """,
                        comment: "Inspect reason for Xcode Previews cache"
                    )
                )
            )
        }
    }

    private func makeCachePair(
        record: FileRecord,
        sessionID: String,
        size: Int64,
        spec: CachePairSpec
    ) -> (finding: Finding, recommendation: Recommendation) {
        let findingID = UUID().uuidString
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: spec.category,
            severity: spec.risk,
            confidence: 0.9,
            bytesReclaimable: size,
            summary: spec.summary,
            evidence: ["path": record.displayPath, "bytes": String(size)],
            targetFileIDs: [record.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: spec.actionType,
            targetFileIDs: [record.id],
            confidence: 0.9,
            risk: spec.risk,
            reason: spec.reason,
            expectedBytesReclaimed: size,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: spec.policyTraceID
        )
        return (finding, recommendation)
    }

    private func subtreeSizes(for files: [FileRecord]) -> [String: Int64] {
        let directories = files.filter { $0.kind == .directory || $0.kind == .package }
        // Include all file kinds with sizeBytes (not just regularFile) to avoid undercounting
        // directories that contain symlinks, packages, or other non-regular files. A
        // summarized folder is a leaf: its size is already the total of its contents.
        let sortedFiles = files.filter { ($0.rolledUpItemCount != nil || ![.directory, .package].contains($0.kind)) && $0.sizeBytes > 0 }
            .sorted { $0.displayPath < $1.displayPath }
        let sortedPaths = sortedFiles.map(\.displayPath)
        var sizes: [String: Int64] = [:]
        for directory in directories {
            let prefix = directory.displayPath + "/"
            let start = SortedPathSearch.lowerBound(sortedPaths, prefix)
            let end = SortedPathSearch.upperBound(sortedPaths, prefix)
            var total: Int64 = directory.rolledUpItemCount != nil ? directory.sizeBytes : 0
            for i in start..<end {
                total += sortedFiles[i].sizeBytes
            }
            sizes[directory.displayPath] = total
        }
        return sizes
    }



    private struct InstalledAppInventory {
        let names: Set<String>
        let index: InstalledAppIndex
    }

    private func installedApplicationInventory() -> InstalledAppInventory {
        let home = homeDirectory
        var bundleURLs = InstalledAppIndex.standardBundles(home: home)
        let nestedSearchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            home.appendingPathComponent("Applications/Caskroom", isDirectory: true)
        ]
        for root in nestedSearchRoots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                if child.pathExtension == "app" {
                    bundleURLs.append(child)
                } else if let grandChildren = try? FileManager.default.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) {
                    bundleURLs.append(contentsOf: grandChildren.filter { $0.pathExtension == "app" })
                }
            }
        }
        var names: Set<String> = []
        var bundleIDs: Set<String> = []
        for url in bundleURLs {
            names.insert(normalizeAppName(url.deletingPathExtension().lastPathComponent))
            if let bundle = Bundle(url: url) {
                if let bundleID = bundle.bundleIdentifier {
                    bundleIDs.insert(bundleID)
                }
                if let info = bundle.infoDictionary {
                    if let name = info["CFBundleName"] as? String { names.insert(normalizeAppName(name)) }
                    if let display = info["CFBundleDisplayName"] as? String { names.insert(normalizeAppName(display)) }
                }
            }
        }
        return InstalledAppInventory(names: names, index: InstalledAppIndex(bundleIDs: bundleIDs))
    }

    private func isInstalledApplicationFolder(_ folderName: String, inventory: InstalledAppInventory) -> Bool {
        let normalized = normalizeAppName(folderName)
        if inventory.names.contains(normalized) {
            return true
        }
        if InstalledAppIndex.isThirdPartyBundleID(folderName), inventory.index.isInstalled(folderName) {
            return true
        }
        if let alias = Self.appFolderVendorAliases[normalized] {
            if !alias.appNames.isDisjoint(with: inventory.names) {
                return true
            }
            if alias.bundlePrefixes.contains(where: { prefix in
                inventory.index.bundleIDs.contains { $0.hasPrefix(prefix) }
            }) {
                return true
            }
        }
        if normalized.count >= 4 {
            let vendorMatch = inventory.index.bundleIDs.contains { bundleID in
                let parts = bundleID.split(separator: ".")
                return parts.count >= 2 && normalizeAppName(String(parts[1])) == normalized
            }
            if vendorMatch {
                return true
            }
        }
        return false
    }

    private func normalizeAppName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    private static let localizedScreenshotPrefixes: [String] = [
        "screen shot ", "screenshot ", "screenshot_", "screenshot-", "screen recording ",
        "bildschirmfoto ", "bildschirmaufnahme ",
        "capture d’écran ", "capture d'écran ", "enregistrement de l’écran ", "enregistrement de l'écran ",
        "captura de pantalla ", "grabación de pantalla ",
        "istantanea ", "schermata ", "captura de tela ", "schermafbeelding ",
        "スクリーンショット", "截屏", "屏幕截图", "스크린샷", "снимок экрана "
    ]

    nonisolated private static func hasScreenCaptureXattr(at url: URL) -> Bool {
        let key = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = Darwin.getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= 1024 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        let bytesRead = Darwin.getxattr(url.path, key, &buffer, size, 0, XATTR_NOFOLLOW)
        guard bytesRead > 0 else { return false }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: Data(buffer.prefix(bytesRead)), format: nil
        ) else {
            return false
        }
        if let flag = plist as? Bool { return flag }
        if let num = plist as? NSNumber { return num.boolValue }
        return false
    }

    func screenshotFindings(in files: [FileRecord], sessionID: String) -> [Finding] {
        let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic", "mov", "mp4"]
        let screenshotFiles = files.filter { file in
            guard let ext = file.fileExtension?.lowercased(), screenshotExtensions.contains(ext) else { return false }
            if let meta = file.spotlightMetadata["kMDItemIsScreenCapture"]?.lowercased(),
               meta == "1" || meta == "true" || meta == "yes" {
                return true
            }
            if Self.hasScreenCaptureXattr(at: file.url) {
                return true
            }
            let name = file.fileName.lowercased()
            return Self.localizedScreenshotPrefixes.contains { name.hasPrefix($0) }
        }
        guard !screenshotFiles.isEmpty else { return [] }
        let grouped = Dictionary(grouping: screenshotFiles) { $0.url.deletingLastPathComponent().lastPathComponent }
        return grouped.compactMap { (folderName, groupFiles) in
            let totalBytes = groupFiles.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
            guard !groupFiles.isEmpty else { return nil }
            return Finding(
                id: UUID().uuidString,
                scanSessionID: sessionID,
                category: .screenshot,
                severity: .low,
                confidence: 0.85,
                bytesReclaimable: totalBytes,
                summary: groupFiles.count == 1
                    ? String(localized: "1 screenshot in \(folderName) (\(totalBytes.formattedByteCount))", comment: "Screenshot finding summary per folder, singular")
                    : String(localized: "\(groupFiles.count) screenshots in \(folderName) (\(totalBytes.formattedByteCount))", comment: "Screenshot finding summary per folder"),
                evidence: ["type": "screenshot", "folder": folderName, "count": "\(groupFiles.count)"],
                targetFileIDs: groupFiles.map(\.id)
            )
        }
    }

    private func packageManagerCacheFindings(files: [FileRecord], sessionID: String, directorySizes: [String: Int64]) -> [(finding: Finding, recommendation: Recommendation)] {
        let home = homeDirectory
        let cachePaths: [(path: String, name: String)] = [
            (home.appendingPathComponent(".npm").path, ".npm"),
            (home.appendingPathComponent(".cache/pip").path, "pip cache"),
        ]
        return files.compactMap { record in
            guard record.kind == .directory else { return nil }
            guard let match = cachePaths.first(where: { record.displayPath == $0.0 }) else {
                return nil
            }
            // Directories report only their own allocation size from the crawler;
            // use the computed subtree total so the planner sizes the action correctly.
            let size = directorySizes[record.displayPath] ?? record.sizeBytes
            guard size > 0 else { return nil }
            let findingID = UUID().uuidString
            let finding = Finding(
                id: findingID,
                scanSessionID: sessionID,
                category: .packageManagerCleanup,
                severity: .low,
                confidence: 0.91,
                bytesReclaimable: size,
                summary: String(localized: "\(match.name) cache directory.", comment: "Finding summary for package manager cache"),
                evidence: ["path": record.displayPath, "bytes": String(size)],
                targetFileIDs: [record.id]
            )
            let recommendation = Recommendation(
                id: UUID().uuidString,
                findingID: findingID,
                actionType: .moveToTrash,
                targetFileIDs: [record.id],
                confidence: 0.91,
                risk: .low,
                reason: String(localized: "Package manager caches are rebuildable. Review before moving to Trash.", comment: "Recommendation reason for package manager cache"),
                expectedBytesReclaimed: size,
                requiresConfirmation: true,
                llmTraceID: nil,
                policyTraceID: "package_manager_cache_rule"
            )
            return (finding, recommendation)
        }
    }

    private func dedupeFindings(_ findings: [Finding]) -> [Finding] {
        var bestByKey: [String: Finding] = [:]
        for finding in findings {
            let key = "\(finding.category.rawValue)-\(finding.targetFileIDs.joined(separator: ","))"
            if let existing = bestByKey[key] {
                if finding.confidence > existing.confidence {
                    bestByKey[key] = finding
                }
            } else {
                bestByKey[key] = finding
            }
        }
        return Array(bestByKey.values)
    }

    private func dedupeRecommendations(_ recommendations: [Recommendation]) -> [Recommendation] {
        var bestByKey: [String: Recommendation] = [:]
        for recommendation in recommendations {
            let key = "\(recommendation.actionType.rawValue)-\(recommendation.targetFileIDs.joined(separator: ","))"
            if let existing = bestByKey[key] {
                if recommendation.confidence > existing.confidence {
                    bestByKey[key] = recommendation
                }
            } else {
                bestByKey[key] = recommendation
            }
        }
        return Array(bestByKey.values)
    }
}

extension CleanerRuleEngine {
    /// True for `/Library/Logs`, `<home>/Library/Logs` and everything inside them,
    /// including the folder record itself. A `Library/Logs` folder elsewhere does not match.
    static func isMacOSLogPath(_ path: String, home: String) -> Bool {
        ["/Library/Logs", home + "/Library/Logs"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func isMacOSLog(_ url: URL) -> Bool {
        let home = PathSafetyPolicy.realHomeDirectory.standardizedFileURL.path
        return isMacOSLogPath(url.standardizedFileURL.path, home: home)
    }
}
