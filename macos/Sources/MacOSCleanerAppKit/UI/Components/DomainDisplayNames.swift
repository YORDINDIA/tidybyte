import Foundation
import MacOSCleanerCore

extension ActionType {
    var displayName: String {
        switch self {
        case .moveToTrash: L10n.string("Move to Trash")
        case .restore: L10n.string("Restore")
        case .move: L10n.string("Move")
        case .rename: L10n.string("Rename")
        case .tag: L10n.string("Tag")
        case .offloadLocalCopy: L10n.string("Offload Local Copy")
        case .createAlias: L10n.string("Create Alias")
        case .createSymlink: L10n.string("Create Symlink")
        case .archive: L10n.string("Archive")
        case .runProviderCleanup: L10n.string("Run Provider Cleanup")
        case .runPackageManagerCleanup: L10n.string("Run Package Cleanup")
        case .inspectOnly: L10n.string("Inspect Only")
        case .cloneDeduplicate: L10n.string("Fold into APFS Clone")
        case .unfoldClone: L10n.string("Unfold Clone")
        }
    }
}

// NOTE: `FindingCategory.displayName` lives in MacOSCleanerCore (public) so
// the report generator can use it; the UI resolves to that implementation.

extension PlannedActionStatus {
    var displayName: String {
        switch self {
        case .proposed: L10n.string("Proposed")
        case .approved: L10n.string("Approved")
        case .rejected: L10n.string("Rejected")
        case .executing: L10n.string("Executing")
        case .completed: L10n.string("Completed")
        case .failed: L10n.string("Failed")
        case .skipped: L10n.string("Skipped")
        }
    }
}

extension RiskLevel {
    var displayName: String {
        switch self {
        case .low: L10n.string("Low")
        case .medium: L10n.string("Medium")
        case .high: L10n.string("High")
        case .forbidden: L10n.string("Forbidden")
        }
    }
}

extension UndoStatus {
    var displayName: String {
        switch self {
        case .pending: L10n.string("In Progress")
        case .available: L10n.string("Available")
        case .restored: L10n.string("Restored")
        case .expired: L10n.string("Expired")
        case .notUndoable: L10n.string("Not Undoable")
        case .partiallyUndoable: L10n.string("Partially Undoable")
        case .reinstallable: L10n.string("Reinstallable")
        case .failed: L10n.string("Failed")
        }
    }
}

extension ScanMode {
    var displayName: String {
        switch self {
        case .selectedFolders: L10n.string("Selected Folders")
        case .homeFolder: L10n.string("Home Folder")
        case .developerCleanup: L10n.string("Developer Cleanup")
        case .deepSystem: L10n.string("Deep System")
        case .userEssentials: L10n.string("User Essentials")
        case .finderMetadata: L10n.string("Finder Metadata")
        case .macOSSystemCaches: L10n.string("macOS System Caches")
        case .sandboxedAppCaches: L10n.string("Sandboxed App Caches")
        case .browsers: L10n.string("Browsers")
        case .cloudStorage: L10n.string("Cloud Storage")
        case .officeApps: L10n.string("Office Applications")
        case .developerTools: L10n.string("Developer Tools")
        case .devApplications: L10n.string("Development Applications")
        case .vmTools: L10n.string("Virtual Machine Tools")
        case .applicationSupport: L10n.string("Application Support")
        case .uninstalledAppData: L10n.string("Uninstalled App Data")
        case .appleSiliconUpdates: L10n.string("Apple Silicon Updates")
        case .iosBackups: L10n.string("iOS Device Backups")
        case .timeMachineBackups: L10n.string("Time Machine Backups")
        case .largeFiles: L10n.string("Large Files")
        }
    }
}

extension RiskFlag {
    var displayName: String {
        switch self {
        case .sipProtectedSystemPath: L10n.string("SIP-protected system path")
        case .protectedDirectory: L10n.string("Protected directory")
        case .protectedFile: L10n.string("Protected file")
        case .secretOrCertificate: L10n.string("Secret or certificate")
        case .projectManifest: L10n.string("Project manifest")
        case .sourceOrConfig: L10n.string("Source or config")
        case .cloudSyncedLocalPath: L10n.string("Cloud-synced path")
        case .codingAgentMemoryOrConfig: L10n.string("Coding agent memory or config")
        case .insideTrash: L10n.string("Already in Trash")
        case .reviewOnly: L10n.string("Review only")
        }
    }
}

extension FileKind {
    var displayName: String {
        switch self {
        case .regularFile: L10n.string("File")
        case .directory: L10n.string("Folder")
        case .symlink: L10n.string("Symbolic Link")
        case .package: L10n.string("Package")
        case .other: L10n.string("Other")
        }
    }
}
