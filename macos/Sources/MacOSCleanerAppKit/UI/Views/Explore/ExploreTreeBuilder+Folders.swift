import Foundation
import MacOSCleanerCore

// The By Folder grouping, split out of ExploreTree.swift to keep ExploreTreeBuilder within its lint budget.

extension ExploreTreeBuilder {
    // MARK: - By Folder

    private final class FolderTrieNode {
        let name: String
        let path: String
        var bytes: Int64 = 0
        var fileCount: Int = 0
        var children: [String: FolderTrieNode] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    static func buildFolderTree(
        files: [FileRecord],
        maxDepth: Int,
        maxChildren: Int,
        language: AppLanguage? = nil
    ) -> [ExploreGroup] {
        guard !files.isEmpty else {
            return []
        }
        let componentLists = files.map { $0.url.standardizedFileURL.pathComponents }
        let commonLength = commonPrefixLength(of: componentLists)
        let commonPath = joinComponents(componentLists.first?.prefix(commonLength) ?? [])
        let rootName = URL(fileURLWithPath: commonPath).lastPathComponent
        let root = FolderTrieNode(name: rootName.isEmpty ? commonPath : rootName, path: commonPath)

        for file in files {
            insertFile(file, into: root, commonPath: commonPath, commonLength: commonLength, maxDepth: maxDepth)
        }

        let top = root.children.values.sorted { $0.bytes > $1.bytes }
        guard !top.isEmpty else {
            return [convertNode(root, paletteIndex: 0)]
        }
        let loose = (
            bytes: root.bytes - top.reduce(Int64(0)) { $0 + $1.bytes },
            count: root.fileCount - top.reduce(0) { $0 + $1.fileCount }
        )
        return cappedGroups(from: top, loose: loose, maxChildren: maxChildren, language: language)
    }

    private static func insertFile(
        _ file: FileRecord,
        into root: FolderTrieNode,
        commonPath: String,
        commonLength: Int,
        maxDepth: Int
    ) {
        let components = file.url.standardizedFileURL.pathComponents
        let relative = Array(components.dropFirst(commonLength))
        let folders = Array((file.rolledUpItemCount == nil ? relative.dropLast() : relative[...]).prefix(maxDepth))
        let count = itemCount(of: file)
        let size = max(0, file.sizeBytes)
        root.bytes += size
        root.fileCount += count
        var node = root
        var pathSoFar = commonPath
        for folder in folders {
            let nextRaw = pathSoFar == "/" ? "/" + folder : pathSoFar + "/" + folder
            pathSoFar = ExploreSubtreeIndex.normalizedPath(nextRaw)
            if node.children[folder] == nil {
                node.children[folder] = FolderTrieNode(name: folder, path: pathSoFar)
            }
            guard let next = node.children[folder] else { break }
            next.bytes += size
            next.fileCount += count
            node = next
        }
    }

    private static func cappedGroups(
        from nodes: [FolderTrieNode],
        loose: (bytes: Int64, count: Int),
        maxChildren: Int,
        language: AppLanguage?
    ) -> [ExploreGroup] {
        let kept = Array(nodes.prefix(max(1, maxChildren)))
        var groups = kept.enumerated().map { index, node in
            convertNode(node, paletteIndex: index)
        }
        let remainder = nodes.dropFirst(kept.count)
        // `loose.count` is an Int field of a tuple, not a collection.
        // swiftlint:disable:next empty_count
        if !remainder.isEmpty || loose.bytes > 0 || loose.count > 0 {
            let bytes = remainder.reduce(loose.bytes) { $0 + $1.bytes }
            let count = remainder.reduce(loose.count) { $0 + $1.fileCount }
            groups.append(ExploreGroup(
                id: "__other__",
                name: L10n.string("Other", language: language),
                bytes: bytes,
                fileCount: count,
                detail: nil,
                paletteIndex: kept.count,
                children: []
            ))
        }
        return groups
    }

    private static func convertNode(_ node: FolderTrieNode, paletteIndex: Int) -> ExploreGroup {
        let kids = node.children.values.sorted { $0.bytes > $1.bytes }
        let normalizedID = node.path.isEmpty ? node.name : ExploreSubtreeIndex.normalizedPath(node.path)
        return ExploreGroup(
            id: normalizedID,
            name: node.name,
            bytes: node.bytes,
            fileCount: node.fileCount,
            detail: normalizedID,
            paletteIndex: paletteIndex,
            usesFolderPastel: true,
            children: kids.map { convertNode($0, paletteIndex: paletteIndex) }
        )
    }

    private static func commonPrefixLength(of lists: [[String]]) -> Int {
        guard let first = lists.first else {
            return 0
        }
        var length = 0
        for component in first {
            let matchesAll = lists.allSatisfy { $0.count > length && $0[length] == component }
            guard matchesAll else {
                break
            }
            length += 1
        }
        return length
    }

    private static func joinComponents(_ components: ArraySlice<String>) -> String {
        let parts = components.filter { $0 != "/" }
        guard !parts.isEmpty else {
            return "/"
        }
        return "/" + parts.joined(separator: "/")
    }
}
