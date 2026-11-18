import Foundation
import MacOSCleanerCore

// The freshness-monitor wiring and incremental pruning, split out of CleanupModel
// to keep that file's lint budget (file/function lengths) intact.

extension CleanupModel {
    /// Rebuilds the freshness monitor for the current scope. PSA-01:
    /// FSEventStreamCreate can block indefinitely, so the monitor is built
    /// off the main actor and handed back; a build superseded by a newer call
    /// loses the race and is dropped.
    func startMonitoring() {
        freshnessEpoch += 1
        let epoch = freshnessEpoch
        let roots = scope.roots
        let includesPhotos = scope.includesPhotos
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.freshnessDidChange()
            }
        }
        Task.detached(priority: .utility) {
            let monitor = CleanupFreshnessMonitor(roots: roots, includesPhotos: includesPhotos, changed: changed)
            await MainActor.run {
                guard epoch == self.freshnessEpoch else {
                    monitor.stop()
                    return
                }
                self.freshness?.stop()
                self.freshness = monitor
            }
        }
    }

    func beginSelfMutation() {
        selfMutationDepth += 1
    }

    func endSelfMutation(cooldown: TimeInterval = 3.0) {
        selfMutationDepth = max(0, selfMutationDepth - 1)
        suppressFreshnessEvents(for: cooldown)
    }

    /// Ignores monitor callbacks triggered by Tidybyte's own deletions/compressions.
    func suppressFreshnessEvents(for duration: TimeInterval = 3.0) {
        let deadline = Date().addingTimeInterval(duration)
        if deadline > suppressFreshnessUntil {
            suppressFreshnessUntil = deadline
        }
    }

    /// Freshness callback from the monitor: mark staleness immediately and
    /// auto-rescan only when idle. Rescans are debounced so a burst of file
    /// changes (S-04) coalesces into one pass. Internal so tests can drive it.
    func freshnessDidChange() {
        guard selfMutationDepth == 0, Date() >= suppressFreshnessUntil else { return }
        changeGeneration += 1
        result?.isFresh = false
        guard !isBusy, session == nil else { return }
        rescanEpoch += 1
        let epoch = rescanEpoch
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard epoch == self.rescanEpoch, !self.isBusy, self.session == nil else { return }
            self.scan()
        }
    }

    /// Incrementally prunes removed items from `result` and `groups` so counts,
    /// tool badges, and scroll position stay live without wiping freshness.
    func pruneRemovedItems(ids removedIDs: Set<String>) async {
        guard !removedIDs.isEmpty, var current = result else { return }
        current.items.removeAll { removedIDs.contains($0.id) }
        current.groups = Self.pruneGroups(current.groups, removing: removedIDs, replacements: [:])
        current.generation = UUID()
        selection.subtract(removedIDs)
        explicitlySelectedIDs.subtract(removedIDs)
        if let selectedItem, removedIDs.contains(selectedItem.id) {
            self.selectedItem = nil
        }
        result = current
        try? await store.saveCleanupState(current, key: "inventory")
    }

    /// Incrementally updates `result` after compression, conversion, or component replacement.
    func applyMutationOutcomes(
        _ events: [ActivityEvent], tool: CleanupTool, deleteOriginals: Bool, settings: CleanupSettings?
    ) async {
        guard var current = result else {
            await finishMutationHousekeeping()
            return
        }
        let delta = Self.collectMutationDelta(
            events, tool: tool, deleteOriginals: deleteOriginals, settings: settings)
        if !delta.removedIDs.isEmpty || !delta.replacements.isEmpty {
            current.items = current.items.compactMap { item in
                if delta.removedIDs.contains(item.id) { return nil }
                return delta.replacements[item.id] ?? item
            }
            current.groups = Self.pruneGroups(
                current.groups, removing: delta.removedIDs, replacements: delta.idMap)
            current.generation = UUID()
            result = current
            try? await store.saveCleanupState(current, key: "inventory")
        }
        if let selectedItem, delta.removedIDs.contains(selectedItem.id) {
            self.selectedItem = nil
        } else if let selectedItem, let updated = delta.replacements[selectedItem.id] {
            self.selectedItem = updated
        }
        selection.subtract(delta.processedIDs)
        explicitlySelectedIDs.subtract(delta.processedIDs)
        if events.contains(where: { $0.state == .interrupted }) {
            result?.isFresh = false
        }
        await finishMutationHousekeeping()
    }

    private struct MutationDelta {
        var removedIDs = Set<String>()
        var replacements: [String: ReviewItem] = [:]
        var idMap: [String: String] = [:]
        var processedIDs = Set<String>()
    }

    private static func collectMutationDelta(
        _ events: [ActivityEvent], tool: CleanupTool, deleteOriginals: Bool, settings: CleanupSettings?
    ) -> MutationDelta {
        var delta = MutationDelta()
        for event in events where event.state == .complete {
            let oldItem = event.item
            delta.processedIDs.insert(oldItem.id)
            if event.action == "trash" || event.action == "move" {
                delta.removedIDs.insert(oldItem.id)
            } else if event.action == "keepComponent",
                (tool == .livePhotos && deleteOriginals) || tool == .formatPairs {
                delta.removedIDs.insert(oldItem.id)
            } else if event.action == "compress", deleteOriginals {
                if let replacement = buildReplacementItem(for: oldItem, event: event, settings: settings) {
                    delta.replacements[oldItem.id] = replacement
                    delta.idMap[oldItem.id] = replacement.id
                } else {
                    delta.removedIDs.insert(oldItem.id)
                }
            }
        }
        return delta
    }

    func finishMutationHousekeeping() async {
        await photos.purgePreviewCache()
        do { try await reloadHistory() } catch { self.error = error.localizedDescription }
    }

    private static func pruneGroups(
        _ groups: [AnalysisGroup], removing removedIDs: Set<String>, replacements: [String: String]
    ) -> [AnalysisGroup] {
        groups.compactMap { group in
            var updated = group
            updated.memberIDs = group.memberIDs.compactMap { memberID in
                if removedIDs.contains(memberID) { return nil }
                return replacements[memberID] ?? memberID
            }
            updated.protectedIDs = group.protectedIDs.compactMap { protectedID in
                if removedIDs.contains(protectedID) { return nil }
                return replacements[protectedID] ?? protectedID
            }
            if removedIDs.contains(group.bestID) {
                updated.bestID = updated.memberIDs.first ?? ""
            } else if let mappedBest = replacements[group.bestID] {
                updated.bestID = mappedBest
            }
            return updated.memberIDs.count > 1 ? updated : nil
        }
    }

    private static func buildReplacementItem(
        for oldItem: ReviewItem, event: ActivityEvent, settings: CleanupSettings?
    ) -> ReviewItem? {
        if let url = event.replacementURL, let root = oldItem.root,
            var recorded = try? ReviewInventory.record(url, root: root) {
            recorded.facts = oldItem.facts
            recorded.isFavorite = oldItem.isFavorite
            recorded.isBurstPick = oldItem.isBurstPick
            if oldItem.kind == .image, let settings {
                recorded.isHEIC = settings.photoConvertToHEIC || url.pathExtension.lowercased() == "heic"
            }
            return recorded
        }
        if let newPhotoID = event.replacementPhotoID {
            var updated = oldItem
            updated.id = "photos:" + newPhotoID
            updated.source = .photos(newPhotoID)
            updated.bytes = event.outputBytes > 0 ? event.outputBytes : oldItem.bytes
            updated.modifiedAt = Date()
            updated.isDownloaded = true
            if oldItem.kind == .image, let settings {
                updated.isHEIC = settings.photoConvertToHEIC || oldItem.isHEIC
            }
            return updated
        }
        return nil
    }
}
