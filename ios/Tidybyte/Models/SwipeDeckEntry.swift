import Foundation
import SwiftData

/// What the user chose for one photo in one swipe deck.
enum SwipeDeckDecision: String, Sendable {
    case keep
    case skip
    case album
    /// Marked for deletion. Nothing is deleted until the user confirms.
    case marked
    /// Live Photo deck: convert to a still.
    case convert
    /// Live Photo deck: keep as a Live Photo.
    case keepLive
}

/// One decision in one saved swipe deck. A deck (All Media, Blurry, the Live
/// Photo review, ...) remembers its decisions across app quits until the user
/// resets swipe sessions in Settings or starts a finished deck over.
///
/// `SwipeRecord` stays the app-wide swipe history ("Not Swiped Yet"). This
/// table is per deck, and it also holds the photos marked for deletion, which
/// `SwipeRecord` leaves out on purpose.
@Model
final class SwipeDeckEntry {
    /// `SwipeFilter.deckKey`, or the key a Cleanup tool passes for its deck.
    var deckKey: String
    var assetLocalIdentifier: String
    /// `SwipeDeckDecision` raw value.
    var decision: String
    var decidedAt: Date

    init(deckKey: String, assetLocalIdentifier: String, decision: SwipeDeckDecision, decidedAt: Date = .now) {
        self.deckKey = deckKey
        self.assetLocalIdentifier = assetLocalIdentifier
        self.decision = decision.rawValue
        self.decidedAt = decidedAt
    }

    var deckDecision: SwipeDeckDecision? { SwipeDeckDecision(rawValue: decision) }
}

/// Reads and writes `SwipeDeckEntry` rows. Saves at once, so a quit or a crash
/// keeps every decision made so far.
@MainActor
enum SwipeDeckStore {
    /// The deck key of the Live Photo convert review.
    static let livePhotosKey = "livePhotos"

    /// Every decision in the deck, oldest first.
    static func decisions(deckKey: String, context: ModelContext) -> [SwipeDeckEntry] {
        let descriptor = FetchDescriptor<SwipeDeckEntry>(predicate: #Predicate { $0.deckKey == deckKey })
        return ((try? context.fetch(descriptor)) ?? []).sorted { $0.decidedAt < $1.decidedAt }
    }

    /// Saves one decision, replacing an earlier one for the same photo in this
    /// deck. Anything but a delete mark also clears that photo's delete marks in
    /// other decks: a keep, file or skip always wins over an earlier mark, so a
    /// photo kept here is never deleted from a deck the user left for later.
    static func record(_ decision: SwipeDeckDecision, assetId: String, deckKey: String, context: ModelContext) {
        let marked = SwipeDeckDecision.marked.rawValue
        let existing = (try? context.fetch(FetchDescriptor<SwipeDeckEntry>(
            predicate: #Predicate { $0.assetLocalIdentifier == assetId }
        ))) ?? []
        for entry in existing where entry.deckKey == deckKey || (decision != .marked && entry.decision == marked) {
            context.delete(entry)
        }
        context.insert(SwipeDeckEntry(deckKey: deckKey, assetLocalIdentifier: assetId, decision: decision))
        save(context)
    }

    /// Removes this deck's decisions for the given photos (an undo, an unmark,
    /// a committed delete).
    static func remove(assetIds: Set<String>, deckKey: String, context: ModelContext) {
        guard !assetIds.isEmpty else { return }
        for entry in decisions(deckKey: deckKey, context: context) where assetIds.contains(entry.assetLocalIdentifier) {
            context.delete(entry)
        }
        save(context)
    }

    /// Removes every decision of one kind from the deck ("Keep All Items" drops
    /// the delete marks; "Start Over" drops the rest).
    static func remove(_ kinds: Set<SwipeDeckDecision>, deckKey: String, context: ModelContext) {
        for entry in decisions(deckKey: deckKey, context: context) {
            if let kind = entry.deckDecision, kinds.contains(kind) { context.delete(entry) }
        }
        save(context)
    }

    /// Photos marked for deletion, per deck. Drives the "N marked" line on the
    /// Swipe home cards.
    static func markedCounts(context: ModelContext) -> [String: Int] {
        let marked = SwipeDeckDecision.marked.rawValue
        let entries = (try? context.fetch(FetchDescriptor<SwipeDeckEntry>(
            predicate: #Predicate { $0.decision == marked }
        ))) ?? []
        return entries.reduce(into: [:]) { $0[$1.deckKey, default: 0] += 1 }
    }

    private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            AppLog.app.error("Saving a swipe deck decision failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
