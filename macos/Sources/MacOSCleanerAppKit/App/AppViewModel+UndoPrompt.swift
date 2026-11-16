import MacOSCleanerCore

// MB-10: restores initiated outside the History view — the menu bar's
// "Undo Last Cleanup" — are routed through the same regret-reason prompt as
// an in-app History restore instead of silently restoring.

extension AppViewModel {
    /// Reasons offered when a person restores a change. The raw value is the
    /// English text stored with the regret event, so it never changes; `title`
    /// is what the person sees.
    enum RegretReason: String, CaseIterable {
        case neededLater = "Needed later"
        case misclassified = "Misclassified"
        case shouldHaveArchived = "Should have archived, not deleted"
        case wrongProject = "Wrong project"
        case tooAggressive = "Too aggressive"

        var title: String {
            switch self {
            case .neededLater: String(localized: "Needed later", comment: "Restore reason")
            case .misclassified: String(localized: "Misclassified", comment: "Restore reason")
            case .shouldHaveArchived: String(localized: "Should have archived, not deleted", comment: "Restore reason")
            case .wrongProject: String(localized: "Wrong project", comment: "Restore reason")
            case .tooAggressive: String(localized: "Too aggressive", comment: "Restore reason")
            }
        }
    }

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
