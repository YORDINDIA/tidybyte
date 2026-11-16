import Foundation

/// Why the inbox folder cannot be created at the requested location.
public enum InboxManagerError: Error, LocalizedError, Sendable {
    case unsafeDestination(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeDestination(let reason):
            String(localized: "The inbox cannot be created there. \(reason)", comment: "Inbox refused by the safety policy")
        }
    }
}

public actor InboxManager {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func defaultInboxURL() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.inboxFolderName, isDirectory: true)
    }

    public func ensureInboxExists(at url: URL? = nil) throws -> URL {
        let resolved = url ?? defaultInboxURL()
        // Creating a folder is a write, so the same destination rules apply as to every other write.
        if case .deny(let reason) = PathSafetyPolicy().decide(target: resolved, isDirectory: true) {
            throw InboxManagerError.unsafeDestination(reason)
        }
        try fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
        return resolved
    }
}
