import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import Vision

struct ImageMeasurement: @unchecked Sendable {
    var facts: MediaFacts
    var feature: VNFeaturePrintObservation?
    var perceptualHash: UInt64
    var isUtility = false
}

private struct FileHashResult: Sendable {
    let item: ReviewItem
    let cacheKey: String?
    let digest: String?
}

private struct AnalysisOutcome: @unchecked Sendable {
    let index: Int
    let item: ReviewItem
    let measurement: ImageMeasurement?
}

private struct NearMatchEntry {
    let item: ReviewItem
    let feature: VNFeaturePrintObservation
    let hash: UInt64
}

public actor MediaAnalysisService {
    private let photos: PhotoLibraryService
    private let store: SQLiteStore
    private static let workerLimit = 4

    public init(photos: PhotoLibraryService, store: SQLiteStore) {
        self.photos = photos
        self.store = store
    }

    public func analyze(
        _ input: [ReviewItem], scopeID: String, settings: CleanupSettings,
        progress: @Sendable (CleanupProgress) async -> Void
    ) async throws -> AnalysisResult {
        let hashCandidates = try await stagedCandidates(input)
        var items = try await resolvePhotoHashes(input, candidates: hashCandidates)
        let digests = try await resolveFileHashes(items, candidates: hashCandidates)
        var images: [String: ImageMeasurement] = [:]
        var hashes: [String: [ReviewItem]] = [:]

        items = try await analyzeItems(items, settings: settings, images: &images, progress: progress)
        for index in items.indices {
            ImageQualityAnalysis.applySourceFacts(&items[index], isDownload: Self.isDownload(items[index]))
            let item = items[index]
            if let digest = digests[item.id] ?? (item.photoID != nil ? Self.resourceSignature(item) : nil) {
                hashes[digest, default: []].append(item)
            }
        }

        let exactGroups = hashes.values.filter { $0.count > 1 }.map {
            Self.group(.duplicates, items: $0, explanation: String(localized: "Exact content match"))
        }
        let exactSets = exactGroups.map { Set($0.memberIDs) }
        let nearGroups = try await nearMatches(items, images: images, excludingExactGroups: exactSets)
        let timeSimilar = Self.timeGroups(items, seconds: settings.similarSeconds, images: images)
            .filter { candidate in !exactSets.contains { $0.isSuperset(of: Set(candidate.memberIDs)) } }
        var seenSimilar = Set<String>()
        let similarGroups = (nearGroups + timeSimilar).filter { seenSimilar.insert($0.id).inserted }
        let groups = exactGroups + similarGroups + Self.burstGroups(items) + Self.formatGroups(items, images: images)
        Self.annotateReasons(&items, groups: groups, images: images, largeMegabytes: settings.largeMegabytes)
        return AnalysisResult(generation: UUID(), scopeID: scopeID, settings: settings, items: items, groups: groups)
    }

    private func resolvePhotoHashes(_ items: [ReviewItem], candidates: Set<String>) async throws -> [ReviewItem] {
        let targetPhotos = items.filter { $0.photoID != nil && candidates.contains($0.id) }
        guard !targetPhotos.isEmpty else { return items }
        let hashed = try await photos.hashResourcesIfNeeded(for: targetPhotos)
        let byID = Dictionary(uniqueKeysWithValues: hashed.map { ($0.id, $0) })
        return items.map { byID[$0.id] ?? $0 }
    }

    private func resolveFileHashes(_ items: [ReviewItem], candidates: Set<String>) async throws -> [String: String] {
        let targets = items.filter { $0.canAnalyze && $0.url != nil && candidates.contains($0.id) }
        guard !targets.isEmpty else { return [:] }
        var digests: [String: String] = [:]
        var toCompute: [(item: ReviewItem, cacheKey: String?)] = []
        for item in targets {
            try Task.checkCancellation()
            guard let url = item.url else { continue }
            if let stamp = DuplicateDetector.changeStamp(of: url) {
                let key = "hash:" + item.reviewKey + "|\(stamp.inode)|\(stamp.changedAtNanoseconds)"
                if let cached = try await store.loadCleanupState(String.self, key: key) {
                    digests[item.id] = cached
                } else {
                    toCompute.append((item, key))
                }
            } else {
                toCompute.append((item, nil))
            }
        }
        guard !toCompute.isEmpty else { return digests }
        for result in try await Self.computeFileHashes(toCompute) {
            if let digest = result.digest {
                digests[result.item.id] = digest
                if let key = result.cacheKey { try await store.saveCleanupState(digest, key: key) }
            }
        }
        return digests
    }

    private static func computeFileHashes(
        _ targets: [(item: ReviewItem, cacheKey: String?)]
    ) async throws -> [FileHashResult] {
        var results: [FileHashResult] = []
        var iterator = targets.makeIterator()
        try await withThrowingTaskGroup(of: FileHashResult.self) { group in
            func submit(_ next: (item: ReviewItem, cacheKey: String?)) {
                group.addTask {
                    let digest = next.item.url.flatMap { try? FingerprintService.fullHash(for: $0) }
                    return FileHashResult(item: next.item, cacheKey: next.cacheKey, digest: digest)
                }
            }
            for _ in 0..<workerLimit {
                guard let next = iterator.next() else { break }
                submit(next)
            }
            while let entry = try await group.next() {
                results.append(entry)
                if let next = iterator.next() { try Task.checkCancellation(); submit(next) }
            }
        }
        return results
    }

    private func analyzeItems(
        _ input: [ReviewItem], settings: CleanupSettings,
        images: inout [String: ImageMeasurement],
        progress: @Sendable (CleanupProgress) async -> Void
    ) async throws -> [ReviewItem] {
        var items = input
        let eligibleIndices = input.indices.filter { input[$0].canAnalyze }
        var iterator = eligibleIndices.makeIterator()
        var completed = 0
        let photos = self.photos
        try await withThrowingTaskGroup(of: AnalysisOutcome.self) { group in
            func enqueueNext() {
                guard let idx = iterator.next() else { return }
                let item = input[idx]
                group.addTask { try await Self.analyzeSingle(index: idx, item: item, settings: settings, photos: photos) }
            }
            for _ in 0..<Self.workerLimit { enqueueNext() }
            while let outcome = try await group.next() {
                items[outcome.index] = outcome.item
                if let measurement = outcome.measurement { images[outcome.item.id] = measurement }
                completed += 1
                await progress(
                    CleanupProgress(
                        String(localized: "Analyzing media"), completed: completed, total: max(1, eligibleIndices.count)))
                try Task.checkCancellation()
                enqueueNext()
            }
        }
        return items
    }

    nonisolated private static func analyzeSingle(
        index: Int, item: ReviewItem, settings: CleanupSettings, photos: PhotoLibraryService
    ) async throws -> AnalysisOutcome {
        var updated = item
        var measurement: ImageMeasurement?
        do {
            if item.kind == .image {
                let measured = try await measure(item, settings: settings, photos: photos)
                updated.facts = measured.facts
                updated.createdAt = measured.facts.capturedAt ?? item.createdAt
                measurement = measured
            } else if let url = item.url {
                updated.facts = try await ImageQualityAnalysis.mediaFacts(url, item: item)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            updated.analysisError = error.localizedDescription
        }
        return AnalysisOutcome(index: index, item: updated, measurement: measurement)
    }

    private static func resourceSignature(_ item: ReviewItem) -> String? {
        let resources = item.resources
        if resources.count == 1, let digest = resources.first?.hash { return digest }
        guard !resources.isEmpty, resources.allSatisfy({ $0.hash != nil }) else { return nil }
        return resources.map { "\($0.type):\($0.hash ?? "")" }.sorted().joined(separator: "|")
    }

    private func stagedCandidates(_ input: [ReviewItem]) async throws -> Set<String> {
        let groups = Dictionary(grouping: input.filter { $0.canAnalyze && $0.bytes > 0 }, by: \.bytes)
        var candidates = Set<String>()
        for group in groups.values where group.count > 1 {
            try Task.checkCancellation()
            if group.contains(where: { $0.photoID != nil }) {
                candidates.formUnion(group.map(\.id))
                continue
            }
            var quick: [String: [String]] = [:]
            for item in group where item.url != nil {
                try Task.checkCancellation()
                if let url = item.url, let digest = try? FingerprintService.quickHash(for: url, sizeBytes: item.bytes) {
                    quick[digest, default: []].append(item.id)
                }
            }
            for matches in quick.values where matches.count > 1 { candidates.formUnion(matches) }
            await Task.yield()
        }
        return candidates
    }

    nonisolated private static func measure(
        _ item: ReviewItem, settings: CleanupSettings, photos: PhotoLibraryService
    ) async throws -> ImageMeasurement {
        let url = if let file = item.url { file } else { try await photos.analysisPreview(item, size: 512) }
        do {
            let measured = try await ImageQualityAnalysis.measureImageAsync(
                url, original: item.facts, sensitivity: settings.categorySensitivity)
            if item.photoID != nil { await photos.releaseAnalysisPreview(url) }
            return measured
        } catch {
            if item.photoID != nil { await photos.releaseAnalysisPreview(url) }
            throw error
        }
    }

    private func nearMatches(
        _ items: [ReviewItem], images: [String: ImageMeasurement], excludingExactGroups: [Set<String>]
    ) async throws -> [AnalysisGroup] {
        let entries = items.compactMap { item -> NearMatchEntry? in
            guard let measurement = images[item.id], let feature = measurement.feature else { return nil }
            return NearMatchEntry(item: item, feature: feature, hash: measurement.perceptualHash)
        }
        guard entries.count > 1 else { return [] }
        let hashes = entries.reduce(into: [String: UInt64]()) { if $0[$1.item.id] == nil { $0[$1.item.id] = $1.hash } }
        let neighbors = VisualPreFilter.buildNeighborAdjacency(
            ids: entries.map(\.item.id), pairs: VisualPreFilter.candidatePairs(hashes))
        var visited = Set<String>()
        var groups: [AnalysisGroup] = []
        for idx in entries.indices {
            try Task.checkCancellation()
            guard !visited.contains(entries[idx].item.id) else { continue }
            var cluster = [entries[idx].item]
            visited.insert(entries[idx].item.id)
            for otherIdx in neighbors[idx] where !visited.contains(entries[otherIdx].item.id) {
                if VisualPreFilter.isVisualMatch(entries[idx].feature, entries[otherIdx].feature) {
                    cluster.append(entries[otherIdx].item)
                    visited.insert(entries[otherIdx].item.id)
                }
            }
            guard cluster.count > 1 else { continue }
            let memberIDs = Set(cluster.map(\.id))
            if excludingExactGroups.contains(where: { $0.isSuperset(of: memberIDs) }) { continue }
            groups.append(
                Self.group(
                    .similar, items: cluster,
                    explanation: String(localized: "Visual near-match. Check before removing"),
                    isVisualMatch: true))
        }
        return groups
    }
}

private struct ToolMatchContext {
    let grouped: Set<String>
    let livePairIDs: Set<String>
    let settings: CleanupSettings
}

extension MediaAnalysisService {
    public static func candidates(_ tool: CleanupTool, in result: AnalysisResult) -> [ReviewItem] {
        let grouped = Set(result.groups.filter { $0.tool == tool }.flatMap(\.memberIDs))
        let livePairIDs = Set(
            result.groups
                .filter { $0.tool == .formatPairs && isLivePhotoPairGroup($0, items: result.items) }
                .flatMap(\.memberIDs))
        let context = ToolMatchContext(grouped: grouped, livePairIDs: livePairIDs, settings: result.settings)
        return result.items.filter { matchesTool($0, tool: tool, context: context) }
    }

    private static func matchesTool(
        _ item: ReviewItem, tool: CleanupTool, context: ToolMatchContext
    ) -> Bool {
        switch tool {
        case .duplicates, .similar, .bursts: return context.grouped.contains(item.id)
        case .formatPairs: return context.grouped.contains(item.id) || isCompoundPhoto(item)
        case .livePhotos: return isLivePhoto(item) || context.livePairIDs.contains(item.id)
        case .blurry: return !qualityIssues(item, sensitivity: context.settings.blurSensitivity).isEmpty
        case .large: return Double(item.bytes) >= context.settings.largeMegabytes * 1_000_000
        default: return matchesFilterTool(item, tool: tool)
        }
    }

    private static func matchesFilterTool(_ item: ReviewItem, tool: CleanupTool) -> Bool {
        switch tool {
        case .screenshots: return item.facts.isScreenshot
        case .screenRecordings: return item.facts.isScreenRecording
        case .categories: return item.kind == .image
        case .imageCompression: return item.kind == .image && !isLivePhoto(item)
        case .videoCompression: return item.kind == .video
        case .downloads: return isDownload(item)
        case .swipe: return true
        default: return false
        }
    }

    public static func imageCompressionCandidates(in result: AnalysisResult, showAll: Bool = false) -> [ReviewItem] {
        candidates(.imageCompression, in: result).filter { item in
            showAll || (item.bytes >= 2_000_000 && !item.isHEIC)
        }
    }

    public static func qualityIssue(_ item: ReviewItem, sensitivity: Int) -> String? {
        qualityIssues(item, sensitivity: sensitivity).first
    }

    public static func qualityIssues(_ item: ReviewItem, sensitivity: Int) -> [String] {
        guard item.kind == .image, item.canAnalyze else { return [] }
        var issues: [String] = []
        if let light = item.facts.luminance, light < 0.12 { issues.append(String(localized: "Too dark")) }
        if (item.facts.clippedHighlights ?? 0) > 0.35 || (item.facts.luminance ?? 0) > 0.88 {
            issues.append(String(localized: "Overexposed"))
        }
        let thresholds: [Double] = [40, 70, 120]
        if let sharp = item.facts.sharpness, sharp < thresholds[min(2, max(0, sensitivity))] {
            issues.append(String(localized: "Out of focus"))
        }
        if item.facts.hasLensSmudge {
            issues.append(String(localized: "Lens smudge"))
        }
        return issues
    }

    public static func isCompoundPhoto(_ item: ReviewItem) -> Bool {
        let types = Set(item.resources.map(\.type))
        return item.photoID != nil && !types.isDisjoint(with: [4, 5, 9, 10])
    }

    public static func isLivePhoto(_ item: ReviewItem) -> Bool {
        let types = Set(item.resources.map(\.type))
        return item.photoID != nil && !types.isDisjoint(with: [9, 10])
    }

    public static func isDownload(_ item: ReviewItem) -> Bool {
        if item.facts.isExportedChatMedia == true || item.facts.savedFromApp != nil { return true }
        if SavedFromAppMarkers.matches(filename: item.name) { return true }
        let path = item.sourceName.lowercased()
        return ["downloads", "whatsapp", "telegram", "messages export", "chat export"].contains { path.contains($0) }
    }

    public static func reviewReason(
        for item: ReviewItem, isUtility: Bool = false, largeMegabytes: Double = 10
    ) -> String? {
        ImageQualityAnalysis.reviewReason(for: item, isUtility: isUtility, largeMegabytes: largeMegabytes)
    }

    public static func safeSelection(
        _ proposed: Set<String>, groups: [AnalysisGroup],
        items: [ReviewItem] = [], explicitlyChosen: Set<String> = []
    ) -> Set<String> {
        var selected = proposed
        let protected = Set(items.filter { $0.isFavorite || $0.isBurstPick }.map(\.id))
            .union(groups.flatMap(\.protectedIDs))
        let autoProtected = protected.subtracting(explicitlyChosen)
        selected.subtract(autoProtected)
        for group in groups where group.memberIDs.allSatisfy({
            selected.contains($0) || autoProtected.contains($0)
        }) {
            selected.remove(group.bestID)
        }
        return selected
    }

    public static func autoCleanSelection(for groups: [AnalysisGroup], items: [ReviewItem] = []) -> Set<String> {
        let nonBest = Set(groups.flatMap { group in group.memberIDs.filter { $0 != group.bestID } })
        return safeSelection(nonBest, groups: groups, items: items)
    }

    public static func timeGroups(_ items: [ReviewItem], seconds: Double) -> [AnalysisGroup] {
        timeGroups(items, seconds: seconds, images: nil)
    }

    static func timeGroups(
        _ items: [ReviewItem], seconds: Double, images: [String: ImageMeasurement]?
    ) -> [AnalysisGroup] {
        var seen = Set<String>()
        return [false, true].flatMap { modified in
            timeGroups(items, seconds: seconds, modified: modified, images: images)
        }.filter { seen.insert($0.id).inserted }
    }

    static func livePhotoGroups(_ items: [ReviewItem]) -> [AnalysisGroup] {
        let eligible = items.filter { $0.canAnalyze && $0.url != nil && $0.facts.contentIdentifier != nil }
        return Dictionary(grouping: eligible) { $0.sourceName + "|" + ($0.facts.contentIdentifier ?? "") }
            .values.compactMap { pool in
                guard pool.count == 2, Set(pool.map(\.kind)) == [.image, .video] else { return nil }
                return group(
                    .formatPairs, items: pool,
                    explanation: String(localized: "Live Photo pair. Removing a component loses motion or still data"))
            }
    }
}

extension MediaAnalysisService {
    private static func timeGroups(
        _ items: [ReviewItem], seconds: Double, modified: Bool, images: [String: ImageMeasurement]?
    ) -> [AnalysisGroup] {
        func date(_ item: ReviewItem) -> Date? { modified ? item.modifiedAt : item.createdAt }
        let pools = Dictionary(grouping: items.filter(\.canAnalyze)) { $0.sourceName + $0.kind.rawValue }
        return pools.values.flatMap { pool -> [AnalysisGroup] in
            let ordered = pool.sorted { (date($0) ?? .distantPast) < (date($1) ?? .distantPast) }
            var batches: [[ReviewItem]] = []
            var batch: [ReviewItem] = []
            for item in ordered {
                if let first = batch.first, let start = date(first), let current = date(item),
                    current.timeIntervalSince(start) > max(1, min(60, seconds)) {
                    if batch.count > 1 { batches.append(batch) }
                    batch = []
                }
                if date(item) != nil { batch.append(item) }
            }
            if batch.count > 1 { batches.append(batch) }
            let explanation = modified
                ? String(localized: "Modified close together")
                : String(localized: "Captured close together")
            return batches.flatMap { window -> [AnalysisGroup] in
                guard let images else { return [group(.similar, items: window, explanation: explanation)] }
                return splitByVisualSimilarity(window, images: images).map {
                    group(.similar, items: $0, explanation: explanation, isVisualMatch: true)
                }
            }
        }
    }

    private static func splitByVisualSimilarity(
        _ batch: [ReviewItem], images: [String: ImageMeasurement]
    ) -> [[ReviewItem]] {
        let nonImages = batch.filter { $0.kind != .image }
        let imageItems = batch.filter { $0.kind == .image }
        var clusters: [[ReviewItem]] = nonImages.count > 1 ? [nonImages] : []
        var visited = Set<Int>()
        for idx in imageItems.indices where !visited.contains(idx) {
            guard let feature = images[imageItems[idx].id]?.feature else { continue }
            visited.insert(idx)
            var cluster = [imageItems[idx]]
            for otherIdx in (idx + 1)..<imageItems.endIndex where !visited.contains(otherIdx) {
                guard let otherFeature = images[imageItems[otherIdx].id]?.feature,
                    VisualPreFilter.isVisualMatch(feature, otherFeature)
                else { continue }
                visited.insert(otherIdx)
                cluster.append(imageItems[otherIdx])
            }
            if cluster.count > 1 { clusters.append(cluster) }
        }
        return clusters
    }

    private static func group(
        _ tool: CleanupTool, items: [ReviewItem], explanation: String, isVisualMatch: Bool = false
    ) -> AnalysisGroup {
        let ranked = items.sorted { ImageQualityAnalysis.ranksHigher($0, than: $1) }
        let reason = ImageQualityAnalysis.bestReason(ranked: ranked)
        let protected = ranked.filter { $0.isFavorite || $0.isBurstPick }.map(\.id)
        return AnalysisGroup(
            tool: tool, memberIDs: ranked.map(\.id), bestID: ranked.first?.id ?? "",
            explanation: explanation, isVisualMatch: isVisualMatch,
            bestReason: reason, protectedIDs: protected)
    }

    private static func annotateReasons(
        _ items: inout [ReviewItem], groups: [AnalysisGroup],
        images: [String: ImageMeasurement], largeMegabytes: Double
    ) {
        let indexByID = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for group in groups {
            if let idx = indexByID[group.bestID], items[idx].facts.bestReason == nil {
                items[idx].facts.bestReason = group.bestReason
            }
        }
        for idx in items.indices {
            let isUtility = images[items[idx].id]?.isUtility ?? false
            items[idx].facts.reviewReason = reviewReason(
                for: items[idx], isUtility: isUtility, largeMegabytes: largeMegabytes)
        }
    }

    private static func burstGroups(_ items: [ReviewItem]) -> [AnalysisGroup] {
        let members = items.filter { $0.facts.burstIdentifier != nil }
        return Dictionary(grouping: members) { $0.sourceName + ($0.facts.burstIdentifier ?? "") }.values
            .filter { $0.count > 1 }.map { group(.bursts, items: $0, explanation: String(localized: "Burst sequence")) }
    }

    private static func formatGroups(_ items: [ReviewItem], images: [String: ImageMeasurement]) -> [AnalysisGroup] {
        let pools = Dictionary(grouping: items.filter { $0.canAnalyze && $0.url != nil && $0.kind == .image }) {
            $0.sourceName + ($0.url?.deletingPathExtension().lastPathComponent.lowercased() ?? "")
        }
        let stills = pools.values.compactMap { pool -> AnalysisGroup? in
            let extensions = Set(pool.compactMap { $0.url?.pathExtension.lowercased() })
            let raw = !extensions.isDisjoint(with: ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"])
            let jpeg = !extensions.isDisjoint(with: ["jpg", "jpeg"])
            let stillPair = jpeg && (raw || extensions.contains("heic"))
            guard stillPair, pool.count > 1, let first = pool.first, let feature = images[first.id]?.feature
            else { return nil }
            for item in pool.dropFirst() {
                guard let other = images[item.id]?.feature, VisualPreFilter.isVisualMatch(feature, other) else { return nil }
                if let lhs = first.createdAt, let rhs = item.createdAt, abs(lhs.timeIntervalSince(rhs)) > 5 {
                    return nil
                }
            }
            return group(
                .formatPairs, items: pool,
                explanation: String(localized: "Paired formats. Removing a component loses its editing or motion data"))
        }
        return stills + livePhotoGroups(items)
    }

    private static func isLivePhotoPairGroup(_ group: AnalysisGroup, items: [ReviewItem]) -> Bool {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let members = group.memberIDs.compactMap { byID[$0] }
        return members.count == 2 && Set(members.map(\.kind)) == [.image, .video]
            && members.allSatisfy { $0.facts.contentIdentifier != nil }
    }
}
