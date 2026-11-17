import Foundation
import os

public actor OrganizationPlanner {
    private let policy: PathSafetyPolicy
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "OrganizationPlanner")

    public init(policy: PathSafetyPolicy = PathSafetyPolicy()) {
        self.policy = policy
    }

    private func isAllowed(_ file: FileRecord) -> Bool {
        if case .allow = policy.decide(target: file.url, isDirectory: false) {
            return true
        }
        return false
    }

    public func suggestOrganization(
        files: [FileRecord],
        sessionID: String,
        posture: CleanupPosture = .balanced
    ) throws -> ([Finding], [Recommendation]) {
        try Task.checkCancellation()
        let candidates = files.filter { file in
            file.kind == .regularFile
                && isAllowed(file)
                && file.url.pathComponents.contains(where: { component in
                    let lowered = component.lowercased()
                    return lowered == "downloads" || lowered == "desktop" || component == AppIdentity.inboxFolderName
                })
        }

        // Only suggest organization strictly below the posture's old-download
        // threshold so OrganizationPlanner never competes with CleanerRuleEngine.
        let oldDownloadDays: Int = switch posture {
        case .conservative: 60
        case .balanced: 30
        case .aggressive: 14
        }
        let organizationMinDays = 7
        let organizationMaxDays = min(29, oldDownloadDays - 1)

        var findings: [Finding] = []
        var recommendations: [Recommendation] = []
        for file in candidates {
            guard let modifiedAt = file.modifiedAt else { continue }
            let ageDays = Calendar.current.dateComponents([.day], from: modifiedAt, to: Date()).day ?? 0
            guard ageDays >= organizationMinDays, ageDays <= organizationMaxDays else { continue }
            let pair = makeSuggestion(for: file, modifiedAt: modifiedAt, ageDays: ageDays, sessionID: sessionID)
            findings.append(pair.finding)
            recommendations.append(pair.recommendation)
        }
        return (findings, recommendations)
    }

    private func makeSuggestion(
        for file: FileRecord,
        modifiedAt: Date,
        ageDays: Int,
        sessionID: String
    ) -> (finding: Finding, recommendation: Recommendation) {
        let findingID = UUID().uuidString
        let action: ActionType
        let reason: String
        if file.url.pathComponents.contains(AppIdentity.inboxFolderName) {
            action = .createAlias
            reason = String(
                localized: "Create a safe organized alias from the Inbox before moving the original.",
                comment: "Recommendation reason for inbox alias"
            )
        } else {
            action = .tag
            reason = String(
                localized: "Tag this loose file for review instead of moving it automatically.",
                comment: "Recommendation reason for tagging loose file"
            )
        }
        let finding = Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: .organization,
            severity: .medium,
            confidence: 0.7,
            bytesReclaimable: 0,
            summary: String(localized: "Loose file organization candidate.", comment: "Finding summary for organization candidate"),
            evidence: [
                "path": file.displayPath,
                "age_days": String(ageDays),
                "suggested_folder": suggestedFolderName(for: file, modifiedAt: modifiedAt),
                "tag_name": Self.taxonomyTagName(for: file)
            ],
            targetFileIDs: [file.id]
        )
        let recommendation = Recommendation(
            id: UUID().uuidString,
            findingID: findingID,
            actionType: action,
            targetFileIDs: [file.id],
            confidence: 0.7,
            risk: .medium,
            reason: reason,
            expectedBytesReclaimed: 0,
            requiresConfirmation: true,
            llmTraceID: nil,
            policyTraceID: "organization_planner"
        )
        return (finding, recommendation)
    }

    private func suggestedFolderName(for file: FileRecord, modifiedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        let month = formatter.string(from: modifiedAt)
        switch file.fileExtension {
        case "png", "jpg", "jpeg", "heic", "gif", "webp":
            return String(localized: "Image Exports \(month)", comment: "Suggested folder name for image exports")
        case "pdf", "doc", "docx", "ppt", "pptx":
            return String(localized: "Documents \(month)", comment: "Suggested folder name for documents")
        case "mov", "mp4", "m4v":
            return String(localized: "Screen Recordings \(month)", comment: "Suggested folder name for screen recordings")
        default:
            return String(localized: "Tidybyte Archive \(month)", comment: "Suggested folder name for the monthly archive")
        }
    }

    public static func taxonomyTagName(for file: FileRecord, risk: RiskLevel? = nil) -> String {
        let ext = file.fileExtension?.lowercased() ?? ""
        let rawPhotoExtensions: Set<String> = ["raw", "cr2", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw"]
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"]
        let docExtensions: Set<String> = ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx"]
        let exportExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv"]

        if rawPhotoExtensions.contains(ext) {
            return "Raw Photo"
        }
        if imageExtensions.contains(ext) {
            return "Screenshot or Export"
        }
        if docExtensions.contains(ext) {
            return "Keep"
        }
        if exportExtensions.contains(ext) {
            return "Generated Export"
        }
        return risk == .low ? "Archive Candidate" : "Review Later"
    }
}
