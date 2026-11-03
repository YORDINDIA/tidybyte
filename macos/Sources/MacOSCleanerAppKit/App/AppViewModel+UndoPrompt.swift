import MacOSCleanerCore

// MB-10: restores initiated outside the History view — the menu bar's
// "Undo Last Cleanup" — are routed through the same regret-reason prompt as
// an in-app History restore instead of silently restoring.

extension AppViewModel {
    /// A restore waiting for the user's regret reason (or a skip).
    enum PendingUndoRestore: Identifiable {
        case systemRecord(UndoRecord)
        case mediaEvent(ActivityEvent)

        var id: String {
            switch self {
            case .systemRecord(let record):
                return "system-\(record.id)"
            case .mediaEvent(let event):
                let path = event.item.url?.absoluteString ?? event.id
                return "media-\(path)"
            }
        }

        /// The subject line the prompt shows.
        var subject: String {
            switch self {
            case .systemRecord(let record):
                return record.restoreURL?.path ?? record.trashURL?.path ?? record.inverseAction.displayName
            case .mediaEvent(let event):
                return event.item.url?.path ?? event.item.name
            }
        }
    }
}
