import Foundation

public actor ReviewExecutor {
    private let store: SQLiteStore
    private let access: FolderAccess
    private let photos: any PhotoMutationService
    private let trash: any TrashService
    private var activeOperations = Set<String>()

    public init(
        store: SQLiteStore, access: FolderAccess, photos: any PhotoMutationService,
        trash: any TrashService = FileSystemTrashProvider()
    ) {
        self.store = store
        self.access = access
        self.photos = photos
        self.trash = trash
    }

    public func apply(_ decision: ReviewDecision, tool: CleanupTool, operationID: String) async -> ActivityEvent {
        var event = ActivityEvent(id: operationID, tool: tool, item: decision.item, action: decision.choice.rawValue)
        guard activeOperations.insert(operationID).inserted else {
            event.state = .failed
            event.error = String(localized: "This operation is already running. Check Activity for its result.")
            return event
        }
        defer { activeOperations.remove(operationID) }
        do {
            if let previous = try await store.cleanupActivity(id: operationID), previous.state != .failed {
                return previous
            }
            try Task.checkCancellation()
            let allowed = decision.choice == .trash ? decision.item.canDelete : decision.item.canEditLocally
            guard allowed else {
                throw CleanupError.message(String(localized: "This item is not available for changes."))
            }
            try await store.saveActivity(event)
            if decision.item.photoID != nil {
                try await applyPhoto(decision, event: &event)
            } else {
                try await applyFile(decision, event: &event)
            }
            event.state = .complete
            try await store.saveActivity(event)
        } catch {
            recordFailure(error, on: &event)
            try? await store.saveActivity(event)
        }
        return event
    }

    public func compress(
        _ item: ReviewItem, settings: CleanupSettings,
        deleteOriginals: Bool? = nil,
        progress: @escaping @Sendable (Double) async -> Void
    ) async -> ActivityEvent {
        let shouldDelete = deleteOriginals ?? settings.deleteOriginalsAfterCompression
        var event = ActivityEvent(
            tool: item.kind == .video ? .videoCompression : .imageCompression,
            item: item, action: shouldDelete ? "compress" : "keepBoth")
        let opID = "compress:" + item.id
        guard activeOperations.insert(opID).inserted else {
            event.state = .failed
            event.error = String(localized: "This operation is already running. Check Activity for its result.")
            return event
        }
        defer { activeOperations.remove(opID) }
        return await executeCompress(item, settings: settings, deleteOriginal: shouldDelete, event: &event, progress: progress)
    }

    public func keepPhotoResource(_ item: ReviewItem, index: Int) async -> ActivityEvent {
        var event = ActivityEvent(tool: .formatPairs, item: item, action: "keepComponent")
        let opID = "keepResource:" + item.id
        guard activeOperations.insert(opID).inserted else {
            event.state = .failed
            event.error = String(localized: "This operation is already running. Check Activity for its result.")
            return event
        }
        defer { activeOperations.remove(opID) }
        do {
            try Task.checkCancellation()
            guard item.canEditLocally, item.photoID != nil else {
                throw CleanupError.message(String(localized: "This Photos item is not available for changes."))
            }
            try await store.saveActivity(event)
            let urls = try await photos.localURLs(for: item)
            guard urls.indices.contains(index), item.resources.indices.contains(index) else {
                throw CleanupError.message(String(localized: "The selected resource is unavailable."))
            }
            let url = urls[index]
            let kind = ReviewInventory.mediaKind(url) ?? .image
            event.outputBytes = (try? ReviewSafety.identity(at: url).sizeBytes) ?? item.resources[index].bytes
            try Task.checkCancellation()
            event.replacementPhotoID = try await photos.replace(item, with: url, kind: kind)
            event.state = .outputReady
            try await store.saveActivity(event)
            try Task.checkCancellation()
            try await photos.delete(item)
            event.state = .complete
            try await store.saveActivity(event)
        } catch {
            recordFailure(error, on: &event, defaultInterrupted: true)
            try? await store.saveActivity(event)
        }
        return event
    }

    public func convertLivePhotoToStill(
        _ item: ReviewItem, deleteOriginal: Bool = true
    ) async -> ActivityEvent {
        var event = ActivityEvent(
            tool: .livePhotos, item: item, action: deleteOriginal ? "keepComponent" : "keepBoth")
        let opID = "livePhoto:" + item.id
        guard activeOperations.insert(opID).inserted else {
            event.state = .failed
            event.error = String(localized: "This operation is already running. Check Activity for its result.")
            return event
        }
        defer { activeOperations.remove(opID) }
        do {
            try await prepareLivePhotoReplacement(item, event: &event)
            if deleteOriginal {
                try Task.checkCancellation()
                try await photos.delete(item)
            }
            event.state = .complete
            try await store.saveActivity(event)
        } catch {
            recordFailure(error, on: &event)
            try? await store.saveActivity(event)
        }
        return event
    }

    public func restore(_ event: ActivityEvent) async throws {
        let operationID = "restore:" + event.id
        guard activeOperations.insert(operationID).inserted else {
            throw CleanupError.message(String(localized: "This restore is already running."))
        }
        defer { activeOperations.remove(operationID) }
        guard let event = try await store.cleanupActivity(id: event.id),
            event.restoreStartedAt == nil, event.state == .complete, !event.restored, let original = event.item.url,
            let root = event.item.root, let output = event.outputURL, let identity = event.outputIdentity,
            ReviewSafety.isAllowed(original), ReviewSafety.contains(original, in: root),
            ReviewSafety.contains(
                original.deletingLastPathComponent().resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath()),
            !FileManager.default.fileExists(atPath: original.path)
        else {
            throw CleanupError.message(
                String(localized: "This item cannot be restored here. Check Trash or Recently Deleted."))
        }
        let granted = try await access.acquire(root)
        defer { granted.stopAccessingSecurityScopedResource() }
        let recovery = try recoveryURL(output, bookmark: event.recoveryBookmark)
        defer { recovery.stopAccessingSecurityScopedResource() }
        try await performRestore(event: event, original: original, root: root, recovery: recovery, identity: identity)
    }

    @discardableResult
    public func dismissInterruptedOperations() async throws -> Int {
        try await store.dismissInterruptedOperations()
    }
}

extension ReviewExecutor {
    private func applyFile(_ decision: ReviewDecision, event: inout ActivityEvent) async throws {
        guard let root = decision.item.root, let source = decision.item.url else {
            throw CleanupError.message(String(localized: "The file has no approved folder."))
        }
        let granted = try await access.acquire(root)
        defer { granted.stopAccessingSecurityScopedResource() }
        try Task.checkCancellation()
        try ReviewSafety.verify(decision.item)
        if decision.choice == .trash {
            event.outputURL = try trash.trashItem(at: source)
        } else if decision.choice == .move, let requested = decision.destination {
            try await moveFile(decision.item, source: source, to: requested, event: &event)
        } else {
            throw CleanupError.message(String(localized: "The action is missing a move destination."))
        }
        if let output = event.outputURL {
            do {
                event.outputIdentity = try ReviewSafety.identity(at: output)
            } catch {
                throw CleanupError.message(String(localized: """
                    The item was moved, but its recovery record could not be saved. \
                    Check Trash or the destination in Finder.
                    """))
            }
            event.recoveryBookmark = try? output.bookmarkData(options: .withSecurityScope)
        }
    }

    private func moveFile(
        _ item: ReviewItem, source: URL, to requested: URL, event: inout ActivityEvent
    ) async throws {
        let destination = try await access.acquire(requested)
        defer { destination.stopAccessingSecurityScopedResource() }
        try ReviewSafety.validateDestination(destination)
        let output = ReviewSafety.uniqueOutput(in: destination, name: source.lastPathComponent)
        event.outputURL = output
        try await store.saveActivity(event)
        try Task.checkCancellation()
        try ReviewSafety.verify(item)
        try ReviewSafety.validateDestination(destination)
        try FileManager.default.moveItem(at: source, to: output)
    }

    private func applyPhoto(_ decision: ReviewDecision, event: inout ActivityEvent) async throws {
        if decision.choice == .move, let requested = decision.destination {
            let folder = try await access.acquire(requested)
            defer { folder.stopAccessingSecurityScopedResource() }
            try ReviewSafety.validateDestination(folder)
            let directory = ReviewSafety.uniqueOutput(in: folder, name: decision.item.name + "-resources")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            event.outputURL = directory
            try await store.saveActivity(event)
            let exported = try await photos.export(decision.item, to: directory)
            guard !exported.isEmpty, exported.count == decision.item.resources.count else {
                throw CleanupError.message(String(localized: "Export verification failed. The Photos original was kept."))
            }
            event.outputBytes = exported.reduce(Int64(0)) {
                $0 + ((try? ReviewSafety.identity(at: $1).sizeBytes) ?? 0)
            }
            event.state = .outputReady
            try await store.saveActivity(event)
            try Task.checkCancellation()
        } else if decision.choice != .trash {
            throw CleanupError.message(String(localized: "Choose an export destination."))
        }
        try Task.checkCancellation()
        try await photos.delete(decision.item)
    }

    private func executeCompress(
        _ item: ReviewItem, settings: CleanupSettings, deleteOriginal: Bool,
        event: inout ActivityEvent, progress: @escaping @Sendable (Double) async -> Void
    ) async -> ActivityEvent {
        var grant: URL?
        var tempPhotoOutput: URL?
        defer {
            grant?.stopAccessingSecurityScopedResource()
            if let tempPhotoOutput { try? FileManager.default.removeItem(at: tempPhotoOutput) }
        }
        do {
            try Task.checkCancellation()
            guard item.canEditLocally, item.canAnalyze else {
                throw CleanupError.message(String(localized: "This item cannot be compressed."))
            }
            if let root = item.root {
                grant = try await access.acquire(root)
                try ReviewSafety.verify(item)
            }
            try await store.saveActivity(event)
            let source = try await compressionSource(for: item)
            let destination = source.deletingLastPathComponent()
            guard ReviewSafety.hasFreeDiskSpace(bytes: item.bytes, at: destination) else {
                throw CleanupError.message(String(localized: "Not enough free disk space to compress safely."))
            }
            let service = MediaCompressionService(photos: photos as? PhotoLibraryService)
            let output = try await service.compress(
                item, source: source, destination: destination, settings: settings, progress: progress)
            if item.photoID != nil { tempPhotoOutput = output }
            try await commitCompressionOutput(
                item, output: output, deleteOriginal: deleteOriginal, event: &event)
        } catch {
            recordFailure(error, on: &event)
            try? await store.saveActivity(event)
        }
        return event
    }

    private func compressionSource(for item: ReviewItem) async throws -> URL {
        if let url = item.url { return url }
        return try await photos.previewURL(for: item)
    }

    private func commitCompressionOutput(
        _ item: ReviewItem, output: URL, deleteOriginal: Bool, event: inout ActivityEvent
    ) async throws {
        let identity = try ReviewSafety.identity(at: output)
        event.outputURL = output
        event.outputBytes = identity.sizeBytes ?? 0
        event.replacementURL = output
        event.outputIdentity = identity
        event.state = .outputReady
        try await store.saveActivity(event)
        try Task.checkCancellation()
        guard try ReviewSafety.identity(at: output) == event.outputIdentity else {
            throw CleanupError.message(String(localized: "The compressed output changed. The original was kept."))
        }
        if item.photoID != nil {
            event.replacementPhotoID = try await photos.replace(item, with: output, kind: item.kind)
            event.outputURL = nil
            event.replacementURL = nil
            try await store.saveActivity(event)
            if deleteOriginal {
                try Task.checkCancellation()
                try await photos.delete(item)
            }
        } else if deleteOriginal {
            try await trashLocalOriginal(item, event: &event)
        } else {
            event.outputURL = nil
        }
        event.state = .complete
        try await store.saveActivity(event)
    }

    private func trashLocalOriginal(_ item: ReviewItem, event: inout ActivityEvent) async throws {
        try ReviewSafety.verify(item)
        guard let url = item.url else {
            throw CleanupError.message(String(localized: "Original file missing."))
        }
        let originalTrashURL = try trash.trashItem(at: url)
        event.outputURL = originalTrashURL
        if let originalTrashURL {
            event.outputIdentity = try ReviewSafety.identity(at: originalTrashURL)
            event.recoveryBookmark = try? originalTrashURL.bookmarkData(options: .withSecurityScope)
        }
    }

    private func prepareLivePhotoReplacement(_ item: ReviewItem, event: inout ActivityEvent) async throws {
        try Task.checkCancellation()
        guard item.canEditLocally, item.photoID != nil else {
            throw CleanupError.message(String(localized: "This Photos item is not available for changes."))
        }
        guard let stillIndex = Self.preferredStillResourceIndex(for: item) else {
            throw CleanupError.message(String(localized: "Could not find still image in Live Photo."))
        }
        try await store.saveActivity(event)
        let urls = try await photos.localURLs(for: item)
        guard urls.indices.contains(stillIndex) else {
            throw CleanupError.message(String(localized: "The still image component is unavailable."))
        }
        let stillURL = urls[stillIndex]
        event.outputBytes = (try? ReviewSafety.identity(at: stillURL).sizeBytes) ?? item.resources[stillIndex].bytes
        try Task.checkCancellation()
        event.replacementPhotoID = try await photos.replace(item, with: stillURL, kind: .image)
        event.state = .outputReady
        try await store.saveActivity(event)
    }

    private static func preferredStillResourceIndex(for item: ReviewItem) -> Int? {
        if let full = item.resources.firstIndex(where: { $0.type == 5 }) { return full }
        return item.resources.firstIndex(where: { $0.type == 1 })
    }

    public func convertLivePhotosToStills(
        _ items: [ReviewItem], deleteOriginals: Bool = true,
        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        var pendingOriginals: [(index: Int, item: ReviewItem)] = []
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            var event = ActivityEvent(
                tool: .livePhotos, item: item, action: deleteOriginals ? "keepComponent" : "keepBoth")
            do {
                try await prepareLivePhotoReplacement(item, event: &event)
                if deleteOriginals {
                    pendingOriginals.append((events.count, item))
                } else {
                    event.state = .complete
                    try await store.saveActivity(event)
                }
            } catch {
                recordFailure(error, on: &event)
                try? await store.saveActivity(event)
            }
            events.append(event)
            await progress(index + 1, items.count)
        }
        if deleteOriginals, !pendingOriginals.isEmpty {
            await commitBatchPhotoDeletes(pendingOriginals, events: &events)
        }
        if let service = photos as? PhotoLibraryService { await service.purgePreviewCache() }
        return events
    }

    private func commitBatchPhotoDeletes(
        _ pending: [(index: Int, item: ReviewItem)], events: inout [ActivityEvent]
    ) async {
        do {
            try await photos.delete(pending.map(\.item))
            for entry in pending {
                events[entry.index].state = .complete
                try? await store.saveActivity(events[entry.index])
            }
        } catch {
            for entry in pending {
                events[entry.index].state = .interrupted
                events[entry.index].error = error.localizedDescription
                try? await store.saveActivity(events[entry.index])
            }
        }
    }

    private func performRestore(
        event: ActivityEvent, original: URL, root: URL, recovery: URL, identity: FileIdentity
    ) async throws {
        var updated = event
        updated.restoreStartedAt = Date()
        try await store.saveActivity(updated)
        do {
            try Task.checkCancellation()
            try ReviewSafety.validateDestination(root)
            guard ReviewSafety.isAllowed(original),
                ReviewSafety.contains(
                    original.deletingLastPathComponent().resolvingSymlinksInPath(),
                    in: root.resolvingSymlinksInPath()),
                (try? ReviewSafety.identity(at: original)) == nil,
                try ReviewSafety.identity(at: recovery) == identity
            else {
                throw CleanupError.message(String(localized: "The recovery path changed. Check Trash in Finder."))
            }
            try FileManager.default.moveItem(at: recovery, to: original)
            updated.restored = true
            updated.restoredAt = Date()
            try await store.saveActivity(updated)
        } catch {
            updated.error = error.localizedDescription
            if !updated.restored { updated.restoreStartedAt = nil }
            try? await store.saveActivity(updated)
            throw error
        }
    }

    private func recoveryURL(_ output: URL, bookmark: Data?) throws -> URL {
        guard let bookmark else { return output }
        var stale = false
        let recovery = try URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        _ = recovery.startAccessingSecurityScopedResource()
        return recovery
    }

    private func recordFailure(_ error: Error, on event: inout ActivityEvent, defaultInterrupted: Bool = false) {
        event.error = error.localizedDescription
        if let failure = error as? PhotosReplacementError { event.replacementPhotoID = failure.replacementID }
        if event.state != .complete {
            let hasOutput = defaultInterrupted || event.outputURL != nil || event.replacementPhotoID != nil
            event.state = hasOutput ? .interrupted : .failed
        }
    }
}

extension SQLiteStore {
    @discardableResult
    public func dismissInterruptedOperations() throws -> Int {
        let events = try cleanupActivity()
        var dismissed = 0
        for var event in events {
            let needsStateReset = event.state == .prepared || event.state == .outputReady || event.state == .interrupted
            let needsRestoreClear = event.restoreStartedAt != nil && !event.restored
            guard needsStateReset || needsRestoreClear else { continue }
            if needsStateReset {
                event.state = .failed
                event.error = event.error ?? String(localized: "Interrupted operation dismissed.")
            }
            if needsRestoreClear {
                event.restoreStartedAt = nil
                event.error = event.error ?? String(localized: "Interrupted restore dismissed.")
            }
            try saveActivity(event)
            dismissed += 1
        }
        return dismissed
    }
}

public struct FileSystemTrashProvider: TrashService {
    public init() {}
    public func trashItem(at url: URL) throws -> URL? {
        guard NSClassFromString("XCTestCase") == nil else {
            throw CocoaError(.featureUnsupported, userInfo: [NSFilePathErrorKey: url.path])
        }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}
