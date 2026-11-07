import Foundation

struct BurstGroup: Identifiable {
    let id: String
    let assets: [AssetSummary]
    var bestAssetId: String
}

enum BurstSelectionPolicy {
    /// Sorts each burst bin by capture time and computes the best frame
    /// (via the shared `BestAssetSelector` ladder — D14: the previous local
    /// duplicate used a different, non-deterministic-on-ties order), skipping
    /// empty bins (LF-13).
    static func rebuildGroups(from burstGroups: [String: [AssetSummary]]) -> [BurstGroup] {
        var result: [BurstGroup] = []
        for (burstId, assets) in burstGroups {
            let sorted = assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            guard let best = BestAssetSelector.bestByMetadata(from: sorted) else { continue }
            result.append(BurstGroup(id: burstId, assets: sorted, bestAssetId: best.id))
        }
        return result.sorted {
            if $0.assets.count != $1.assets.count { return $0.assets.count > $1.assets.count }
            return $0.id < $1.id
        }
    }

    /// What the tool arms by itself: every frame but the keeper, except
    /// favorites. A favorite is only deleted when the user marks it.
    static func suggestedIds(in group: BurstGroup) -> Set<String> {
        var selection = SelectionState()
        selection.selectNonBest(assets: group.assets, bestAssetId: group.bestAssetId)
        return selection.ids
    }

}
