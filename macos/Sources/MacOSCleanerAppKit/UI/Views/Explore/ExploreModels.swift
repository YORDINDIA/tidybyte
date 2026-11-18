import Foundation
import MacOSCleanerCore

// MARK: - Subtree index

/// Pure helpers that derive directory rollups from an immutable file list.
/// Mirrors the prefix-based approach in CleanerRuleEngine without duplicating
/// its actor state; all members are static so views can call them directly.
enum ExploreSubtreeIndex {
    /// Lexical path normalization without resolving disk symlinks.
    static func normalizedPath(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else { return rawPath }
        let expanded = rawPath.hasPrefix("~")
            ? (rawPath as NSString).expandingTildeInPath
            : rawPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Total reclaimable bytes under every ancestor path. Only non-container
    /// records contribute, so directory records never double-count their own
    /// allocation size on top of their children. A summarized folder has no
    /// children, so it adds its total to itself and to its ancestors.
    static func totals(files: [FileRecord]) -> [String: Int64] {
        var totals: [String: Int64] = [:]
        for file in files {
            let bytes = max(0, file.sizeBytes)
            let summarized = file.rolledUpItemCount != nil
            guard bytes > 0, summarized || (file.kind != .directory && file.kind != .package) else {
                continue
            }
            var current = summarized
                ? file.url.standardizedFileURL.path
                : file.url.deletingLastPathComponent().standardizedFileURL.path
            var depth = 0
            while depth < 64 {
                totals[current, default: 0] += bytes
                if current == "/" || current.isEmpty {
                    break
                }
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
                if parent == current {
                    break
                }
                current = parent
                depth += 1
            }
        }
        return totals
    }

    /// Effective on-disk size for a record: the indexed subtree total for
    /// containers, the scanned size for files.
    static func subtreeBytes(for record: FileRecord, totals: [String: Int64]) -> Int64 {
        if record.kind == .directory || record.kind == .package {
            let urlPath = record.url.standardizedFileURL.path
            if let hit = totals[urlPath] {
                return hit
            }
            let normalizedDisplay = normalizedPath(record.displayPath)
            if let hit = totals[normalizedDisplay] ?? totals[record.displayPath] {
                return hit
            }
            return max(0, record.sizeBytes)
        }
        return max(0, record.sizeBytes)
    }

    static func parentPath(of displayPath: String) -> String {
        let normalized = normalizedPath(displayPath)
        guard !normalized.isEmpty, normalized != "/" else { return normalized }
        return URL(fileURLWithPath: normalized).deletingLastPathComponent().standardizedFileURL.path
    }

    /// Every scanned record strictly below the given directory path.
    static func descendants(ofParentPath parentPath: String, in files: [FileRecord]) -> [FileRecord] {
        let normalizedParent = normalizedPath(parentPath)
        let prefix = normalizedParent == "/" ? "/" : normalizedParent + "/"
        return files.filter { file in
            let filePath = normalizedPath(file.displayPath)
            return filePath != normalizedParent && filePath.hasPrefix(prefix)
        }
    }

    /// Scanned records whose direct parent is the given directory path.
    static func directChildren(ofParentPath parentPath: String, in files: [FileRecord]) -> [FileRecord] {
        let normalizedParent = normalizedPath(parentPath)
        return files.filter { file in
            let filePath = normalizedPath(file.displayPath)
            guard filePath != normalizedParent else { return false }
            return self.parentPath(of: filePath) == normalizedParent
        }
    }
}

// MARK: - Change token

/// O(1) change token for "the scan's files changed": `[FileRecord]` is not
/// cheaply Equatable, and mapping every id per render (the old `.onChange`
/// payload) allocated an all-files array on every body evaluation. The scan
/// session id catches a rescan whose first and last ids happen to match.
struct ExploreFilesToken: Equatable {
    let count: Int
    let firstID: String?
    let lastID: String?
    let sessionID: String?

    init(_ files: [FileRecord]) {
        count = files.count
        firstID = files.first?.id
        lastID = files.last?.id
        sessionID = files.first?.scanSessionID
    }
}

// MARK: - Live size probe

/// Reads both size keys for a URL in one stat call. FileRecord only carries a
/// single size, so APFS compression savings are probed live at selection time
/// and hidden when the filesystem cannot provide them.
enum FileSizeProbe {
    struct Sizes: Equatable, Sendable {
        var logical: Int64?
        var allocated: Int64?
    }

    static func sizes(for url: URL) -> Sizes {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Sizes(
            logical: values?.fileSize.map(Int64.init),
            allocated: values?.totalFileAllocatedSize.map(Int64.init)
        )
    }
}

// MARK: - Disk gauge data

/// Live home-volume capacity snapshot. The persisted Volume rows have no
/// loader (SQLiteStore only saves them during scans), so the gauge reads the
/// filesystem directly.
enum DiskGaugeData {
    struct Snapshot: Equatable, Sendable {
        var totalBytes: Int64?
        var freeBytes: Int64?
    }

    /// Free space counts purgeable space, as System Settings › Storage does.
    static func currentHomeVolume() -> Snapshot {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys)
        return Snapshot(
            totalBytes: values?.volumeTotalCapacity.map(Int64.init),
            freeBytes: values?.volumeAvailableCapacityForImportantUsage
        )
    }
}

/// Memo for the group tree one Explore canvas renders. Every render used to
/// rebuild the tree three to six times. The key covers every input, so a
/// cached tree is never stale.
@MainActor
final class ExploreTreeMemo {
    private struct Key: Equatable {
        let token: ExploreFilesToken
        let grouping: ExploreGrouping
        let maxDepth: Int
        let nameFilter: String
    }

    private var key: Key?
    private var value: [ExploreGroup] = []

    func groups(files: [FileRecord], grouping: ExploreGrouping, maxDepth: Int, nameFilter: String) -> [ExploreGroup] {
        let build = {
            ExploreTreeBuilder.build(
                files: ExploreTreeBuilder.filteredFiles(files, nameFilter: nameFilter),
                grouping: grouping,
                maxDepth: maxDepth
            )
        }
        // By Age buckets files against the current time, which the key does not cover.
        // Rebuild it every time so the buckets do not freeze while the canvas is open.
        guard grouping != .byAge else { return build() }
        let next = Key(token: ExploreFilesToken(files), grouping: grouping, maxDepth: maxDepth, nameFilter: nameFilter)
        if next == key { return value }
        key = next
        value = build()
        return value
    }
}

/// File-count copy for Explore labels: "1 file" or "N files".
enum ExploreCopy {
    static func fileCount(_ count: Int, language: AppLanguage? = nil) -> String {
        count == 1
            ? L10n.string("1 file", language: language)
            : L10n.format("%lld files", language: language, count)
    }
}
