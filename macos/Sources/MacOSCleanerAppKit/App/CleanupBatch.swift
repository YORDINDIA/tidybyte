import Foundation
import MacOSCleanerCore

/// The confirmation and executor share this fixed list, including its scan and settings.
struct CleanupBatch: Identifiable {
    let id = UUID()
    let generation: UUID
    let scopeID: String
    let tool: CleanupTool
    let items: [ReviewItem]
    let retained: [ReviewItem]
    let settings: CleanupSettings
}

struct DiskHeadroomCheck {
    let isSufficient: Bool
    let requiredBytes: Int64
    let availableBytes: Int64?
}

extension CleanupModel {
    func makeBatch(items: [ReviewItem], tool: CleanupTool) -> CleanupBatch? {
        guard let result, result.isFresh, result.scopeID == scope.id else { return nil }
        let proposed = Set(items.map(\.reviewKey))
        let candidates = self.items(for: tool).filter {
            proposed.contains($0.reviewKey) && Self.isEligible($0, for: tool)
        }
        let ids = Set(candidates.map(\.id))
        let safe: Set<String>
        if tool.isCompression || tool == .livePhotos {
            safe = ids
        } else {
            safe = MediaAnalysisService.safeSelection(
                ids, groups: result.groups, items: result.items, explicitlyChosen: explicitlySelectedIDs)
        }
        let selected = candidates.filter { safe.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        let affected = result.groups.filter {
            $0.tool == .formatPairs && !$0.memberIDs.allSatisfy { !safe.contains($0) }
        }
        let retainedIDs = Set(affected.flatMap(\.memberIDs)).subtracting(safe)
        return CleanupBatch(
            generation: result.generation, scopeID: scope.id, tool: tool, items: selected,
            retained: tool == .formatPairs ? result.items.filter { retainedIDs.contains($0.id) } : [],
            settings: settings)
    }

    func validate(_ batch: CleanupBatch) -> Bool {
        guard let result, result.isFresh, result.scopeID == scope.id, batch.scopeID == scope.id,
            result.generation == batch.generation, !batch.items.isEmpty,
            result.settingsVersion == batch.settings.analysisVersion
        else {
            error = String(localized: "Scan results changed. Review the selected items again before continuing.")
            return false
        }
        let available = Dictionary(result.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(batch.items.map(\.id))
        let itemsMatch = batch.items.allSatisfy {
            available[$0.id]?.reviewKey == $0.reviewKey
                && available[$0.id]?.source == $0.source
                && Self.isEligible($0, for: batch.tool)
        }
        let selectionSafe =
            batch.tool.isCompression || batch.tool == .livePhotos
            || MediaAnalysisService.safeSelection(
                ids, groups: result.groups, items: result.items, explicitlyChosen: explicitlySelectedIDs) == ids
        guard itemsMatch, selectionSafe else {
            error = String(localized: "The selection changed. Review it again before continuing.")
            return false
        }
        return true
    }

    static func isEligible(_ item: ReviewItem, for tool: CleanupTool) -> Bool {
        if tool.isCompression {
            return item.canEditLocally && item.canAnalyze
        }
        if tool == .livePhotos || tool == .formatPairs {
            return item.canEditLocally
        }
        return item.canDelete
    }

    /// Verifies at least 2× batch size in free disk space before starting compression.
    static func checkCompressionDiskHeadroom(for items: [ReviewItem]) -> DiskHeadroomCheck {
        let totalBytes = items.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        guard totalBytes > 0 else {
            return DiskHeadroomCheck(isSufficient: true, requiredBytes: 0, availableBytes: nil)
        }
        let requiredBytes = totalBytes > Int64.max / 2 ? Int64.max : totalBytes * 2
        let probe = items.compactMap(\.url).first?.deletingLastPathComponent() ?? ReviewSafety.userHome
        let resolvedProbe = FileManager.default.fileExists(atPath: probe.path) ? probe : ReviewSafety.userHome
        let values = try? resolvedProbe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)
        let sufficient = available.map { $0 >= requiredBytes } ?? true
        return DiskHeadroomCheck(isSufficient: sufficient, requiredBytes: requiredBytes, availableBytes: available)
    }

    func downloadFromICloud(_ item: ReviewItem) async {
        guard item.photoID != nil, !item.isDownloaded, downloadingItemIDs[item.id] == nil else { return }
        downloadingItemIDs[item.id] = 0
        defer { downloadingItemIDs.removeValue(forKey: item.id) }
        do {
            let updated = try await photos.downloadFromICloud(item) { [weak self] fraction in
                await MainActor.run { self?.downloadingItemIDs[item.id] = fraction }
            }
            if var current = result, let idx = current.items.firstIndex(where: { $0.id == item.id }) {
                var merged = updated
                merged.facts = current.items[idx].facts
                merged.isFavorite = current.items[idx].isFavorite
                merged.isBurstPick = current.items[idx].isBurstPick
                merged.isHEIC = current.items[idx].isHEIC
                current.items[idx] = merged
                result = current
                try? await store.saveCleanupState(current, key: "inventory")
                if selectedItem?.id == item.id { selectedItem = merged }
                if var draft = session, let sIdx = draft.items.firstIndex(where: { $0.id == item.id }) {
                    draft.items[sIdx] = merged
                    session = draft
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func measureCompressionSizes(for items: [ReviewItem]) async {
        guard !isMeasuringSizes else { return }
        let targets = items.filter { $0.kind == .image && $0.canAnalyze }
        guard !targets.isEmpty else { return }
        isMeasuringSizes = true
        defer { isMeasuringSizes = false }
        let currentSettings = settings
        let suffix = Self.compressionSettingsSignature(for: currentSettings)
        let service = MediaCompressionService(photos: photos)
        await withTaskGroup(of: (String, Int64?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let item = targets[index]
                let key = "\(item.reviewKey)|\(suffix)"
                group.addTask {
                    let measured = try? await service.measureCompressedSize(item, settings: currentSettings)
                    return (key, measured)
                }
            }
            while next < min(2, targets.count) {
                enqueue(next)
                next += 1
            }
            while let (key, bytes) = await group.next() {
                if let bytes { measuredCompressionSizes[key] = bytes }
                if next < targets.count, !Task.isCancelled {
                    enqueue(next)
                    next += 1
                }
            }
        }
    }

    func measuredBytes(for item: ReviewItem) -> Int64? {
        let key = "\(item.reviewKey)|\(Self.compressionSettingsSignature(for: settings))"
        return measuredCompressionSizes[key]
    }

    static func compressionSettingsSignature(for settings: CleanupSettings) -> String {
        let maxDim = settings.photoMaxDimension.map(String.init) ?? "orig"
        let maxSize = settings.photoMaxSizeMB.map { String(format: "%.1f", $0) } ?? "preset"
        return "\(settings.imageQuality.rawValue)|\(settings.photoConvertToHEIC)|\(maxDim)|\(maxSize)"
    }

    func livePhotoRecoverableBytes(for item: ReviewItem) -> Int64 {
        let videoBytes = item.resources
            .filter { [9, 10].contains($0.type) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        if videoBytes > 0 { return videoBytes }
        if item.kind == .video && item.facts.contentIdentifier != nil { return item.bytes }
        return max(0, item.bytes / 2)
    }

    func compressSelection(_ batch: CleanupBatch) {
        guard !isBusy, batch.tool.isCompression, validate(batch) else { return }
        let selected = batch.items
        let currentSettings = batch.settings
        progress = CleanupProgress(String(localized: "Compressing media"), completed: 0, total: selected.count)
        jobs = selected.map {
            CompressionJob(item: $0, estimatedBytes: MediaCompressionService.estimate($0, settings: currentSettings))
        }
        isBusy = true
        beginSelfMutation()
        notice = nil
        error = nil
        task = Task {
            defer {
                isBusy = false
                task = nil
                endSelfMutation()
            }
            let events = await runCompressionJobs(selected: selected, settings: currentSettings)
            let successful = jobs.filter { $0.event?.state == .complete }.count
            let unprocessed = jobs.filter { $0.event == nil }.count
            let failed = jobs.count - successful - unprocessed
            if failed > 0 || unprocessed > 0 {
                error = String(
                    localized:
                        "\(successful) successful · \(failed) failed · \(unprocessed) unprocessed. Check Activity.")
            } else if successful > 0 {
                let savedBytes = events.filter { $0.state == .complete }.reduce(Int64(0)) { $0 + $1.savings }
                notice = currentSettings.deleteOriginalsAfterCompression
                    ? String(localized: "Compressed and replaced originals; saved \(savedBytes.formattedByteCount).")
                    : String(localized: "Saved smaller compressed copies while keeping originals.")
            }
            await applyMutationOutcomes(
                events, tool: batch.tool,
                deleteOriginals: currentSettings.deleteOriginalsAfterCompression, settings: currentSettings)
        }
    }

    private func runCompressionJobs(
        selected: [ReviewItem], settings: CleanupSettings
    ) async -> [ActivityEvent] {
        await withTaskGroup(of: (Int, ActivityEvent).self) { group in
            var next = 0
            func add(_ index: Int) {
                let item = selected[index]
                group.addTask { [executor] in
                    let event = await executor.compress(
                        item, settings: settings, deleteOriginals: settings.deleteOriginalsAfterCompression
                    ) { [self] fraction in
                        await MainActor.run { self.jobs[index].progress = fraction }
                    }
                    return (index, event)
                }
            }
            while next < min(2, selected.count) {
                add(next)
                next += 1
            }
            while let (index, event) = await group.next() {
                jobs[index].event = event
                progress.completed += 1
                if next < selected.count, !Task.isCancelled {
                    add(next)
                    next += 1
                }
            }
            return jobs.compactMap(\.event)
        }
    }

    func convertLivePhotosToStills(_ items: [ReviewItem], deleteOriginals: Bool = true) {
        guard !isBusy, result?.isFresh == true, result?.scopeID == scope.id else { return }
        let targets = items.filter { $0.canEditLocally && $0.photoID != nil }
        guard !targets.isEmpty else { return }
        isBusy = true
        beginSelfMutation()
        notice = nil
        error = nil
        progress = CleanupProgress(
            String(localized: "Converting Live Photos to stills"), completed: 0, total: targets.count)
        task = Task {
            defer {
                isBusy = false
                task = nil
                endSelfMutation()
            }
            let events = await executor.convertLivePhotosToStills(
                targets, deleteOriginals: deleteOriginals
            ) { done, total in
                await MainActor.run {
                    self.progress = CleanupProgress(
                        String(localized: "Converting Live Photos to stills"), completed: done, total: total)
                }
            }
            let successful = events.filter { $0.state == .complete }.count
            let failed = events.count - successful
            if failed > 0 {
                error = String(localized: "Converted \(successful) of \(events.count); \(failed) failed. Check Activity.")
            } else if successful > 0 {
                let reclaimed = events.reduce(Int64(0)) { $0 + $1.savings }.formattedByteCount
                notice = successful == 1
                    ? String(localized: "Converted 1 Live Photo to a still (\(reclaimed) reclaimed).")
                    : String(localized: "Converted \(successful) Live Photos to stills (\(reclaimed) reclaimed).")
            }
            await applyMutationOutcomes(events, tool: .livePhotos, deleteOriginals: deleteOriginals, settings: nil)
        }
    }
}
