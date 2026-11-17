import Darwin
import Foundation
import os
@preconcurrency import Vision

/// Sendable wrapper for a Vision feature print. VNFeaturePrintObservation is
/// not marked Sendable, but it is an immutable value object once produced —
/// safe to pass between concurrency domains.
public struct ImageFeaturePrint: @unchecked Sendable {
    let observation: VNFeaturePrintObservation
}

/// How exact duplicate groups should be resolved by default.
public enum DuplicateStrategy: String, Codable, Sendable, CaseIterable {
    /// Fold duplicates onto the newest copy as APFS clones: nothing is
    /// deleted, every path and its metadata stay, and the space is reclaimed
    /// immediately. Undo re-splits a folded copy into a real file.
    case apfsClone
    /// Move duplicate copies to Trash (the classic resolution).
    case moveToTrash
}

public struct DuplicateAnalysis: Sendable {
    public var fingerprints: [FileFingerprint]
    public var findings: [Finding]
    public var recommendations: [Recommendation]
    public var edges: [RelationshipEdge]
}

public actor DuplicateDetector {
    private let policy: PathSafetyPolicy
    /// Persistent full-hash cache. A cached hash is reused only when size and
    /// mtime both match, so rescans stop re-reading unchanged files.
    private let hashCache: SQLiteStore?
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "DuplicateDetector")

    /// Pairwise feature-print distance at or below which two images count as
    /// visually similar. The current feature print (revision 2) scores 0 for
    /// identical images and about 1 for unrelated ones; a retake scores about 0.3.
    /// 0.5 is the cutoff the iOS app ships with. The old cutoff of 8 came from
    /// revision 1's scale and matched every pair of images.
    static let nearDuplicateDistanceThreshold: Float = 0.5
    /// Images fingerprinted per scan, largest first. A feature print costs tens of
    /// milliseconds, so this bounds the stage to minutes on any library.
    static let maxNearDuplicateImages = 20_000
    /// Each image is compared with this many neighbours in time order. Similar
    /// shots (bursts, retakes, edits) sit next to each other in time. Comparing
    /// every pair grew as n squared and ran for hours on a large home folder.
    static let nearDuplicateWindow = 32
    /// Hash workers per size group. Bounded so a huge group cannot saturate
    /// every cooperative thread; disk throughput is usually the limit anyway.
    static let hashWorkerCount = 4

    public init(policy: PathSafetyPolicy = PathSafetyPolicy(), hashCache: SQLiteStore? = nil) {
        self.policy = policy
        self.hashCache = hashCache
    }

    /// App and system state under ~/Library (containers, simulators, device
    /// support) is never a duplicate target: other software owns those bytes.
    static func isInsideUserLibrary(_ url: URL, homeDirectory: URL = PathSafetyPolicy.realHomeDirectory) -> Bool {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path.lowercased()
        let path = url.standardizedFileURL.path.lowercased()
        return path == library || path.hasPrefix(library + "/")
    }

    private func isDuplicateCandidate(_ file: FileRecord, maxSize: Int64) -> Bool {
        guard file.kind == .regularFile, file.sizeBytes > 0, file.sizeBytes <= maxSize,
              !Self.isCloudPlaceholder(file), !Self.isInsideUserLibrary(file.url, homeDirectory: policy.homeDirectory) else {
            return false
        }
        if case .allow = policy.decide(target: file.url, isDirectory: false) {
            return true
        }
        return false
    }

    /// True when the file is a dataless cloud placeholder (iCloud/cloud-synced).
    /// Placeholders have no local content, hashing them would trigger a download,
    /// and they must never be proposed for trashing as duplicates. Trusts the
    /// crawler-populated flag — re-statting every candidate doubled syscalls.
    public static func isCloudPlaceholder(_ file: FileRecord) -> Bool {
        file.isCloudPlaceholder
    }

    /// - Parameters:
    ///   - strategy: how exact duplicate groups should be resolved. `apfsClone`
    ///     emits non-destructive fold recommendations; `moveToTrash` preserves
    ///     the classic behavior.
    /// - Throws: `CancellationError` when the scan is cancelled mid-analysis.
    public func analyze(
        files: [FileRecord],
        sessionID: String,
        strategy: DuplicateStrategy = .apfsClone
    ) async throws -> DuplicateAnalysis {
        // Skip files over 2GB for full hashing — extremely expensive and rarely intentional duplicates
        let maxFullHashSize: Int64 = 2_000_000_000
        // One autorelease pool per file: the path and policy checks autorelease URL
        // objects, and one pass over a million records kept about 3 GB of them alive.
        let candidates = files.filter { file in autoreleasepool { isDuplicateCandidate(file, maxSize: maxFullHashSize) } }

        // Paths sharing a device+inode ARE the same storage (hard links).
        // Hashing both and recommending a trash would free zero bytes, so
        // deduplicate by storage identity before grouping. Records without
        // identity fields are kept (conservative — they hash like any other).
        var seenInodes = Set<String>()
        var uniqueStorage: [FileRecord] = []
        uniqueStorage.reserveCapacity(candidates.count)
        for file in candidates {
            // One representative per inode joins the grouping. Its other names add
            // nothing new, so they are dropped. The representative itself is never
            // a trash target (see `selectKeeper`).
            if let device = file.identity.deviceIdentifier,
               let inode = file.identity.inodeIdentifier {
                guard seenInodes.insert("\(device)-\(inode)").inserted else { continue }
            }
            uniqueStorage.append(file)
        }

        // Group by LOGICAL size: two identical sparse files can report
        // different allocated sizes and would never meet in an
        // allocated-size bucket. Reclaimable bytes stay allocated-size based.
        let sizeGroups = Dictionary(grouping: uniqueStorage, by: { $0.identity.sizeBytes ?? $0.sizeBytes })
            .values.filter { $0.count > 1 }
        var findings: [Finding] = []
        var recommendations: [Recommendation] = []
        var edges: [RelationshipEdge] = []

        // All fingerprints, collected from parallel workers.
        var fingerprints: [FileFingerprint] = []
        // Files that share a full SHA-256 with at least one other candidate,
        // keyed by hash → group members.
        var fullGroups: [String: [(file: FileRecord, quick: String?)]] = [:]

        for sizeGroup in sizeGroups {
            // Cooperative cancellation between groups.
            try Task.checkCancellation()
            // Quick-hash the group with bounded workers. This used to run
            // sequentially on the actor: one core reading three 64 KB samples
            // per file while the rest idled — minutes on a large first scan.
            var quickGroups: [String: [FileRecord]] = [:]
            var quickHashFailures: [FileRecord] = []
            var quickIterator = sizeGroup.makeIterator()
            await withTaskGroup(of: (FileRecord, String?).self) { group in
                for _ in 0..<Self.hashWorkerCount {
                    guard let file = quickIterator.next() else { break }
                    group.addTask { Self.quickHashTask(for: file) }
                }
                while let (file, quick) = await group.next() {
                    if let quick {
                        quickGroups[quick, default: []].append(file)
                    } else {
                        quickHashFailures.append(file)
                    }
                    if let next = quickIterator.next() {
                        group.addTask { Self.quickHashTask(for: next) }
                    }
                }
            }
            // A cancelled worker surfaces as a nil hash; stop before any
            // survivor is sent to full hashing.
            try Task.checkCancellation()
            if !quickHashFailures.isEmpty {
                logger.warning("Quick hash failed for \(quickHashFailures.count) files; marking failed instead of full hashing.")
                for failed in quickHashFailures {
                    fingerprints.append(FileFingerprint(
                        fileID: failed.id,
                        sizeBytes: failed.sizeBytes,
                        quickHash: nil,
                        fullHash: nil,
                        imagePerceptualHash: nil,
                        videoKeyframeHashes: [],
                        hashStatus: .failed
                    ))
                }
            }
            // Quick hashing is cheap (≤3 chunks); only files sharing a quick
            // hash proceed to expensive full hashing.
            let fullHashCandidates = quickGroups.values.filter { $0.count > 1 }.flatMap { $0 }

            // Cache pass: batch query avoids N+1 SQLite reads; a cached full hash
            // is reused only when size, mtime, inode, and ctime all match.
            var resolvedHashes: [String: String] = [:]
            var pendingHash: [String: FileRecord] = [:]
            var stamps: [String: (inode: UInt64, changedAtNanoseconds: Int64)] = [:]
            for file in fullHashCandidates {
                if let stamp = Self.changeStamp(of: file.url) {
                    stamps[file.id] = stamp
                }
            }
            let cachedByPath: [String: FileHashCacheEntry]
            if let hashCache, !stamps.isEmpty {
                let paths = Array(Set(fullHashCandidates.compactMap { stamps[$0.id] != nil ? $0.url.path : nil }))
                cachedByPath = (try? await hashCache.cachedFullHashes(forPaths: paths)) ?? [:]
            } else {
                cachedByPath = [:]
            }
            for file in fullHashCandidates {
                if let stamp = stamps[file.id],
                   let cached = cachedByPath[file.url.path],
                   cached.matches(
                        sizeBytes: file.sizeBytes,
                        modifiedAt: file.modifiedAt,
                        inode: stamp.inode,
                        changedAtNanoseconds: stamp.changedAtNanoseconds
                   ) {
                    resolvedHashes[file.id] = cached.fullHash
                } else {
                    pendingHash[file.id] = file
                }
            }

            // Full-hash the remaining survivors with a bounded worker pool. Previously every
            // hash funneled through one actor hop per file, serializing at
            // single-stream disk speed regardless of cores.
            var freshHashes: [String: String?] = [:]
            var iterator = pendingHash.values.makeIterator()
            await withTaskGroup(of: (FileRecord, String?).self) { group in
                for _ in 0..<Self.hashWorkerCount {
                    guard let file = iterator.next() else { break }
                    group.addTask { Self.fullHashTask(for: file) }
                }
                while let (file, full) = await group.next() {
                    freshHashes[file.id] = .some(full)
                    if let next = iterator.next() {
                        group.addTask { Self.fullHashTask(for: next) }
                    }
                }
            }
            // Persist fresh hashes so the next scan skips re-reading these files.
            if let hashCache, !freshHashes.isEmpty {
                let entries = freshHashes.compactMap { entry -> FileHashCacheEntry? in
                    guard let hash = entry.value, let file = pendingHash[entry.key],
                          let stamp = stamps[file.id] else { return nil }
                    return FileHashCacheEntry(
                        path: file.url.path,
                        sizeBytes: file.sizeBytes,
                        modifiedAt: file.modifiedAt,
                        fullHash: hash,
                        inode: stamp.inode,
                        changedAtNanoseconds: stamp.changedAtNanoseconds
                    )
                }
                try? await hashCache.saveFileHashes(entries)
            }
            for (fileID, result) in freshHashes {
                if let hash = result {
                    resolvedHashes[fileID] = hash
                } else {
                    // Hashing failed (or was cancelled mid-read) — surface as a
                    // failure fingerprint instead of silently dropping the file.
                    if let file = pendingHash[fileID] {
                        fingerprints.append(FileFingerprint(
                            fileID: file.id,
                            sizeBytes: file.sizeBytes,
                            quickHash: nil,
                            fullHash: nil,
                            imagePerceptualHash: nil,
                            videoKeyframeHashes: [],
                            hashStatus: .failed
                        ))
                    }
                }
            }
            // Collect into hash groups; files that were neither resolved nor
            // hashed (quick-hash failures) simply do not group.
            for file in fullHashCandidates {
                if let full = resolvedHashes[file.id] {
                    fullGroups[full, default: []].append((file, nil))
                }
            }
            try Task.checkCancellation()
        }

        // Emit one finding per exact-duplicate group (full SHA-256 match).
        var exactNonKeeperIDs = Set<String>()
        for (hash, members) in fullGroups where members.count > 1 {
            let files = members.map(\.file).sorted { lhs, rhs in
                (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }
            guard let keep = files.first else { continue }
            let duplicates = Array(files.dropFirst())
            if let (_, resolvedDuplicates) = Self.selectKeeper(sortedNewestFirst: [keep] + duplicates) {
                exactNonKeeperIDs.formUnion(resolvedDuplicates.map(\.id))
            }
            emitExactDuplicateGroup(
                keep: keep,
                duplicates: duplicates,
                hash: hash,
                sessionID: sessionID,
                strategy: strategy,
                into: &findings,
                recommendationsOut: &recommendations,
                edgesOut: &edges
            )
            // Every member of an exact-match group carries a confirmed fingerprint.
            for file in files {
                fingerprints.append(FileFingerprint(
                    fileID: file.id,
                    sizeBytes: file.sizeBytes,
                    quickHash: nil,
                    fullHash: hash,
                    imagePerceptualHash: nil,
                    videoKeyframeHashes: [],
                    hashStatus: .fullHashConfirmed
                ))
            }
        }

        // Near-duplicate phase: group IMAGES by pairwise Vision feature-print
        // distance. Exact-duplicate non-keepers are excluded so a file queued
        // for APFS clone folding is never also proposed for Trash.
        try await detectNearDuplicates(
            files: uniqueStorage,
            existingFindings: findings,
            exactNonKeeperIDs: exactNonKeeperIDs,
            sessionID: sessionID,
            into: &findings,
            recommendationsOut: &recommendations,
            edgesOut: &edges
        )

        return DuplicateAnalysis(
            fingerprints: fingerprints,
            findings: findings,
            recommendations: recommendations,
            edges: edges
        )
    }

    /// Full-hashes one file off the actor; `nil` result means hashing failed
    /// (or was cancelled mid-read, which surfaces as a failure fingerprint).
    private static func fullHashTask(for file: FileRecord) -> (FileRecord, String?) {
        do {
            let full = try FingerprintService.fullHash(for: file.url)
            return (file, full)
        } catch {
            return (file, nil)
        }
    }

    /// Quick-hashes one file off the actor; `nil` means the file could not be
    /// read. Hashing itself does not observe cancellation — the caller checks
    /// it after the worker group drains, so a stopped scan never reaches full
    /// hashing.
    private static func quickHashTask(for file: FileRecord) -> (FileRecord, String?) {
        guard let quick = try? FingerprintService.quickHash(for: file.url, sizeBytes: file.sizeBytes) else {
            return (file, nil)
        }
        return (file, quick)
    }

    /// Keeper selection rule shared by scan emission and plan-time rebuilds:
    /// the newest copy wins, except a cloud-synced copy is never the keeper
    /// while a local copy exists — folding a local file onto a cloud-synced
    /// twin would make the sync engine see an inode swap.
    static func selectKeeper(sortedNewestFirst members: [FileRecord]) -> (keeper: FileRecord, duplicates: [FileRecord])? {
        guard members.count > 1 else { return nil }
        // A file with other hard links keeps its storage when the other names go.
        // It stays the keeper, and no file with other hard links is ever a trash target.
        let keeper = members.first { ($0.linkCount ?? 1) > 1 }
            ?? members.first { $0.cloudProvider == nil }
            ?? members[0]
        let duplicates = members.filter { $0.id != keeper.id && ($0.linkCount ?? 1) <= 1 }
        return duplicates.isEmpty ? nil : (keeper, duplicates)
    }

    /// Newest copy of an exact-match group wins the keeper slot — the same
    /// ordering and local-preference rule the detector uses when it emits findings.
    public static func keeperAndDuplicates(of targetFileIDs: [String], filesByID: [String: FileRecord]) -> (keeper: FileRecord, duplicates: [FileRecord])? {
        let records = targetFileIDs.compactMap { filesByID[$0] }
        let sorted = records.sorted { lhs, rhs in
            (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
        }
        return selectKeeper(sortedNewestFirst: sorted)
    }

    /// Duplicates that could be folded onto `keep`: keeper and duplicate both
    /// local (not cloud-synced — sync engines must not see inode swaps), same
    /// volume, on a clone-capable volume. Final eligibility is re-verified at
    /// execution time. Static and nonisolated so the planner and the
    /// per-group strategy switch share one eligibility rule.
    public static func foldEligibleDuplicates(duplicates: [FileRecord], keep: FileRecord) -> [FileRecord] {
        guard keep.cloudProvider == nil,
              APFSCloneService.volumeSupportsClones(at: keep.url),
              let keepDevice = keep.identity.deviceIdentifier else {
            return []
        }
        return duplicates.filter { duplicate in
            guard let duplicateDevice = duplicate.identity.deviceIdentifier,
                  keepDevice == duplicateDevice else {
                return false
            }
            guard duplicate.cloudProvider == nil,
                  APFSCloneService.volumeSupportsClones(at: duplicate.url) else {
                return false
            }
            // Skip files whose blocks are already shared with an APFS clone so
            // re-scans never report full sizeBytes as newly reclaimable.
            if let privateBytes = ReclaimableBytes.privateSize(of: duplicate.url), privateBytes == 0 {
                return false
            }
            return true
        }
    }

    private func emitExactDuplicateGroup(
        keep: FileRecord,
        duplicates: [FileRecord],
        hash: String,
        sessionID: String,
        strategy: DuplicateStrategy,
        into findings: inout [Finding],
        recommendationsOut: inout [Recommendation],
        edgesOut: inout [RelationshipEdge]
    ) {
        // Re-resolve the keeper with the shared rule: a cloud-synced copy
        // never keeps while a local copy exists.
        guard let (resolvedKeeper, resolvedDuplicates) = Self.selectKeeper(sortedNewestFirst: [keep] + duplicates) else {
            return
        }
        let foldEligible = strategy == .apfsClone
            ? Self.foldEligibleDuplicates(duplicates: resolvedDuplicates, keep: resolvedKeeper) : []
        let eligibleIDs = Set(foldEligible.map(\.id))
        let alreadyClonedIDs: Set<String> = strategy == .apfsClone
            ? Set(resolvedDuplicates.compactMap { dup in
                guard !eligibleIDs.contains(dup.id),
                      dup.cloudProvider == nil,
                      dup.identity.deviceIdentifier == resolvedKeeper.identity.deviceIdentifier,
                      APFSCloneService.volumeSupportsClones(at: dup.url),
                      let priv = ReclaimableBytes.privateSize(of: dup.url), priv == 0 else { return nil }
                return dup.id
            })
            : []
        // Members that cannot be folded (cloud-synced, other volume, or a
        // trash-strategy scan) keep the classic trash recommendation; already-
        // folded APFS clones stay untouched.
        let trashTargets = strategy == .moveToTrash
            ? resolvedDuplicates
            : resolvedDuplicates.filter { !eligibleIDs.contains($0.id) && !alreadyClonedIDs.contains($0.id) }
        if strategy == .apfsClone && foldEligible.isEmpty && trashTargets.isEmpty {
            return
        }
        let unsharedBytes: (FileRecord) -> Int64 = { record in
            if let priv = ReclaimableBytes.privateSize(of: record.url) {
                return min(record.sizeBytes, max(0, priv))
            }
            return record.sizeBytes
        }
        let foldBytes = foldEligible.reduce(Int64(0)) { $0 + unsharedBytes($1) }
        let trashBytes = strategy == .apfsClone
            ? trashTargets.reduce(Int64(0)) { $0 + unsharedBytes($1) }
            : trashTargets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let bytes = foldBytes + trashBytes
        let risk = (strategy == .moveToTrash ? resolvedDuplicates : trashTargets).contains(where: { $0.cloudProvider != nil })
            ? RiskLevel.high : RiskLevel.low
        let findingID = UUID().uuidString
        let groupCount = groupSize(keep: resolvedKeeper, duplicates: resolvedDuplicates)
        let summary: String
        switch strategy {
        case .apfsClone:
            summary = String(
                localized: """
                    \(groupCount) exact duplicate files, confirmed by full SHA-256. \
                    Their space can be reclaimed without deleting anything.
                    """,
                comment: "Exact duplicate finding summary"
            )
        case .moveToTrash:
            summary = String(
                localized: "\(groupCount) exact duplicate files, confirmed by full SHA-256.",
                comment: "Exact duplicate finding summary"
            )
        }
        findings.append(Finding(
            id: findingID,
            scanSessionID: sessionID,
            category: .duplicate,
            severity: risk,
            confidence: 0.99,
            bytesReclaimable: bytes,
            summary: summary,
            evidence: ["kept_file": resolvedKeeper.displayPath, "hash": hash, "bytes": String(bytes)],
            targetFileIDs: ([resolvedKeeper] + resolvedDuplicates).map(\.id)
        ))

        if !foldEligible.isEmpty {
            recommendationsOut.append(Recommendation(
                id: UUID().uuidString,
                findingID: findingID,
                actionType: .cloneDeduplicate,
                targetFileIDs: foldEligible.map(\.id),
                confidence: 0.99,
                risk: .low,
                reason: String(
                    localized: """
                        Fold each copy onto the newest file as an APFS clone. Every file keeps its name, \
                        contents and metadata. Nothing is deleted, the space is reclaimed immediately, \
                        and this can be undone.
                        """,
                    comment: "Exact duplicate clone-fold recommendation reason"
                ),
                expectedBytesReclaimed: foldBytes,
                requiresConfirmation: true,
                llmTraceID: nil,
                policyTraceID: "duplicate_apfs_clone",
                destination: resolvedKeeper.url
            ))
        }
        if !trashTargets.isEmpty {
            recommendationsOut.append(Recommendation(
                id: UUID().uuidString,
                findingID: findingID,
                actionType: .moveToTrash,
                targetFileIDs: trashTargets.map(\.id),
                confidence: 0.99,
                risk: risk,
                reason: String(
                    localized: """
                        These files have the same size and full content hash. Keep the newest copy \
                        and move duplicate copies to Trash.
                        """,
                    comment: "Exact duplicate recommendation reason"
                ),
                expectedBytesReclaimed: trashBytes,
                requiresConfirmation: true,
                llmTraceID: nil,
                policyTraceID: "duplicate_full_sha256"
            ))
        }
        for duplicate in resolvedDuplicates {
            edgesOut.append(RelationshipEdge(
                id: "\(resolvedKeeper.id)-\(duplicate.id)-duplicate",
                fromFileID: resolvedKeeper.id,
                toFileID: duplicate.id,
                edgeType: .duplicate,
                confidence: 0.99,
                evidence: "Full SHA-256 hash matched."
            ))
        }
    }

    private func groupSize(keep: FileRecord, duplicates: [FileRecord]) -> Int {
        duplicates.count + 1
    }

    /// Groups images whose Vision feature-print distance to a group's first image
    /// is under the threshold. At most `nearDuplicateWindow` distance calls per
    /// image, over at most `maxNearDuplicateImages` images.
    private func detectNearDuplicates(
        files: [FileRecord],
        existingFindings: [Finding],
        exactNonKeeperIDs: Set<String>,
        sessionID: String,
        into findings: inout [Finding],
        recommendationsOut: inout [Recommendation],
        edgesOut: inout [RelationshipEdge]
    ) async throws {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic", "webp"]
        // One Set per exact-match finding, built once for the whole pass.
        let existingTargetSets = existingFindings.map { Set($0.targetFileIDs) }
        let images = files.filter { file in
            guard !exactNonKeeperIDs.contains(file.id),
                  let ext = file.fileExtension?.lowercased(),
                  imageExtensions.contains(ext) else {
                return false
            }
            return true
        }
        guard images.count > 1 else { return }

        var prints: [(file: FileRecord, print: ImageFeaturePrint)] = []
        var iterator = images.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(Self.maxNearDuplicateImages).makeIterator()
        await withTaskGroup(of: (FileRecord, ImageFeaturePrint?).self) { group in
            for _ in 0..<Self.hashWorkerCount {
                guard let file = iterator.next() else { break }
                group.addTask { (file, await FingerprintService.featurePrint(for: file.url)) }
            }
            while let (file, print) = await group.next() {
                if Task.isCancelled { break }
                if let print {
                    prints.append((file, print))
                }
                if let next = iterator.next() {
                    group.addTask { (next, await FingerprintService.featurePrint(for: next.url)) }
                }
            }
        }
        try Task.checkCancellation()
        guard prints.count > 1 else { return }
        prints.sort { ($0.file.modifiedAt ?? .distantPast) < ($1.file.modifiedAt ?? .distantPast) }

        // Each group is one anchor plus the later images (by modified time) within
        // the threshold of that anchor. Grouping is not transitive, so a run of
        // slowly changing shots never chains into one group of unrelated images.
        var visited = Set<Int>()
        var components: [[Int]] = []
        for i in prints.indices where !visited.contains(i) {
            try Task.checkCancellation()
            visited.insert(i)
            var group = [i]
            for other in (i + 1)..<min(i + 1 + Self.nearDuplicateWindow, prints.endIndex) where !visited.contains(other) {
                var distance: Float = 0
                guard (try? prints[i].print.observation.computeDistance(&distance, to: prints[other].print.observation)) != nil,
                    distance < Self.nearDuplicateDistanceThreshold
                else { continue }
                visited.insert(other)
                group.append(other)
            }
            if group.count > 1 { components.append(group) }
        }

        for component in components {
            let members = component.map { prints[$0].file }.sorted { lhs, rhs in
                (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }
            guard let keep = members.first else { continue }
            let nearDuplicates = Array(members.dropFirst())
            // Skip groups already fully covered by an exact-match finding.
            // Target sets are precomputed once: rebuilding a Set per finding
            // per component was quadratic on duplicate-heavy libraries.
            let memberIDs = Set(members.map(\.id))
            if existingTargetSets.contains(where: { $0.isSuperset(of: memberIDs) }) {
                continue
            }
            let bytes = nearDuplicates.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let findingID = UUID().uuidString
            findings.append(Finding(
                id: findingID,
                scanSessionID: sessionID,
                category: .duplicate,
                severity: .low,
                confidence: 0.85,
                bytesReclaimable: bytes,
                summary: String(localized: "\(members.count) visually similar images detected.", comment: "Near-duplicate finding summary"),
                evidence: ["kept_file": keep.displayPath, "bytes": String(bytes)],
                targetFileIDs: members.map(\.id)
            ))
            recommendationsOut.append(Recommendation(
                id: UUID().uuidString,
                findingID: findingID,
                actionType: .moveToTrash,
                targetFileIDs: nearDuplicates.map(\.id),
                confidence: 0.85,
                risk: .low,
                reason: String(localized: "These images look very similar but are not byte-identical. Verify before trashing; keep the newest.", comment: "Near-duplicate recommendation reason"),
                expectedBytesReclaimed: bytes,
                requiresConfirmation: true,
                llmTraceID: nil,
                policyTraceID: "duplicate_feature_print_distance"
            ))
            for dup in nearDuplicates {
                edgesOut.append(RelationshipEdge(
                    id: "\(keep.id)-\(dup.id)-nearDuplicate",
                    fromFileID: keep.id,
                    toFileID: dup.id,
                    edgeType: .nearDuplicateOf,
                    confidence: 0.85,
                    evidence: "Feature-print distance < \(String(format: "%.1f", Self.nearDuplicateDistanceThreshold))."
                ))
            }
        }
    }

    /// Inode and status-change time from one lstat, with the time kept as integer
    /// nanoseconds. Nil when the file cannot be read.
    static func changeStamp(of url: URL) -> (inode: UInt64, changedAtNanoseconds: Int64)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let nanoseconds = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
        return (UInt64(info.st_ino), nanoseconds)
    }
}
