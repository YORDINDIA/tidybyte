enum PhotoCompressionPolicy {
    static let minimumMegabytes: Int64 = 2
    static let minimumBytes: Int64 = minimumMegabytes * 1_000_000

    static func candidates(from assets: [AssetSummary], excluding compressedCopies: Set<String>, showAll: Bool) -> [AssetSummary] {
        assets.filter { isCandidate($0, excluding: compressedCopies, showAll: showAll) }
    }

    static func isCandidate(_ asset: AssetSummary, excluding compressedCopies: Set<String>, showAll: Bool) -> Bool {
        // Re-encoding a Live Photo's still would discard its motion.
        guard !asset.isLivePhoto, !compressedCopies.contains(asset.id) else { return false }
        return showAll || (asset.fileSize >= minimumBytes && !asset.isHEIC)
    }
}
