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
        maxChildren: Int
    ) -> [ExploreGroup] {
        guard !files.isEmpty else {
            return []
        }
        let componentLists = files.map { $0.url.pathComponents }
        let commonLength = commonPrefixLength(of: componentLists)
        let commonPath = joinComponents(componentLists.first?.prefix(commonLength) ?? [])
        let rootName: String = {
            let last = URL(fileURLWithPath: commonPath).lastPathComponent
            return last.isEmpty ? commonPath : last
        }()
        let root = FolderTrieNode(name: rootName, path: commonPath)
        for file in files {
            let components = file.url.pathComponents
            let relative = Array(components.dropFirst(commonLength))
            // The last component is the file itself; intermediate components
            // are folders. A summarized folder is a folder all the way down, and
            // stands for every item inside. Anything deeper than maxDepth rolls up.
            let items = file.rolledUpItemCount
            let folders = Array((items == nil ? relative.dropLast() : relative[...]).prefix(maxDepth))
            let count = itemCount(of: file)
            root.bytes += max(0, file.sizeBytes)
            root.fileCount += count
            var node = root
            var pathSoFar = commonPath
            for folder in folders {
                pathSoFar += "/" + folder
                if node.children[folder] == nil {
                    node.children[folder] = FolderTrieNode(name: folder, path: pathSoFar)
                }
                guard let next = node.children[folder] else {
                    break
                }
                next.bytes += max(0, file.sizeBytes)
                next.fileCount += count
                node = next
            }
        }
        // Depth-1 children of the common root are the top-level groups.
        let top = root.children.values.sorted { $0.bytes > $1.bytes }
        guard !top.isEmpty else {
            // Every item sits directly in the common folder, so that folder is the one group.
            return [convertNode(root, paletteIndex: 0)]
        }
        // Loose files directly in the common folder have no child node. Roll them into "Other".
        let loose = (
            bytes: root.bytes - top.reduce(Int64(0)) { $0 + $1.bytes },
            count: root.fileCount - top.reduce(0) { $0 + $1.fileCount }
        )
        return cappedGroups(from: top, loose: loose, maxChildren: maxChildren, paletteBase: 0)
    }

    private static func cappedGroups(
        from nodes: [FolderTrieNode],
        loose: (bytes: Int64, count: Int),
        maxChildren: Int,
        paletteBase: Int
    ) -> [ExploreGroup] {
        let kept = Array(nodes.prefix(max(1, maxChildren)))
        var groups = kept.enumerated().map { index, node in
            convertNode(node, paletteIndex: paletteBase + index)
        }
        let remainder = nodes.dropFirst(kept.count)
        if !remainder.isEmpty || loose.bytes > 0 {
            let bytes = remainder.reduce(loose.bytes) { $0 + $1.bytes }
            let count = remainder.reduce(loose.count) { $0 + $1.fileCount }
            groups.append(ExploreGroup(
                id: "__other__",
                name: String(localized: "Other", comment: "Explore rollup group for small entries"),
                bytes: bytes,
                fileCount: count,
                detail: nil,
                paletteIndex: paletteBase + kept.count,
                children: []
            ))
        }
        return groups
    }

    private static func convertNode(_ node: FolderTrieNode, paletteIndex: Int) -> ExploreGroup {
        let kids = node.children.values.sorted { $0.bytes > $1.bytes }
        return ExploreGroup(
            id: node.path.isEmpty ? node.name : node.path,
            name: node.name,
            bytes: node.bytes,
            fileCount: node.fileCount,
            detail: node.path,
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

    /// Rebuilds a path from `pathComponents`. The leading "/" component is
    /// dropped first, so the result never starts with "//".
    private static func joinComponents(_ components: ArraySlice<String>) -> String {
        let parts = components.filter { $0 != "/" }
        guard !parts.isEmpty else {
            return "/"
        }
        return "/" + parts.joined(separator: "/")
    }
}
