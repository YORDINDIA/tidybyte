import Foundation
import ImageIO
import UIKit

/// What a scan of picked Google Photos items found. Every list holds item
/// ids; `items` resolves them.
struct CloudScanResult: Sendable {
    struct Group: Identifiable, Sendable {
        let id: String
        /// Best first (largest, then newest). The rest are the extra copies.
        let itemIds: [String]
        let isExactDuplicate: Bool
    }

    var items: [String: CloudMediaItem] = [:]
    var duplicateGroups: [Group] = []
    var similarGroups: [Group] = []
    var blurry: [String] = []
    var screenshots: [String] = []
    var largeVideos: [String] = []
    var thumbnails: [String: UIImage] = [:]

    /// Bytes freed by removing everything flagged except the first item of
    /// each group. An item flagged twice counts once.
    var recoverableBytes: Int64 {
        var ids = Set(blurry + screenshots + largeVideos)
        for group in duplicateGroups + similarGroups { ids.formUnion(group.itemIds.dropFirst()) }
        return ids.reduce(0) { $0 + (items[$1]?.fileSize ?? 0) }
    }
}

/// Runs the same on-device checks as the iPhone tools on picked cloud items.
/// The maths is shared: `VisualPreFilter` hashes and `VisionAnalysisService`
/// feature prints and blur scores. Only 512 px previews are downloaded.
@MainActor
struct GooglePhotosScanner {
    var api = GooglePhotosAPI()
    var vision = VisionAnalysisService()

    /// Matches `SimilarPhotosViewModel.visualSimilarityThreshold`.
    static let similarThreshold: Float = 0.7
    /// Distance under which two same-size images count as the same photo.
    static let duplicateThreshold: Float = 0.05

    func scan(
        _ picked: [CloudMediaItem],
        largeVideoBytes: Int64 = AppPreferences.largeFileThresholdBytes(),
        blurSensitivity: BlurSensitivity = AppPreferences.blurSensitivity(),
        progress: @escaping (Double) -> Void
    ) async -> CloudScanResult {
        var result = CloudScanResult()
        var items = picked
        let total = Double(max(1, picked.count * 2))
        var done = 0.0

        // 1. Sizes, 6 at a time.
        // ponytail: one HEAD per item; drop to video-only HEADs if Google rate-limits large picks.
        await withTaskGroup(of: (Int, Int64?).self) { group in
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let index = next, item = items[index]
                next += 1
                group.addTask { @MainActor in (index, await api.fileSize(of: item)) }
            }
            for _ in 0..<6 { addNext() }
            for await (index, size) in group {
                items[index].fileSize = size
                done += 1
                progress(done / total)
                addNext()
            }
        }
        result.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 2. Classify by metadata.
        for item in items {
            if Self.isScreenshotOrRecording(item) { result.screenshots.append(item.id) }
            if Self.isLargeVideo(item, threshold: largeVideoBytes) { result.largeVideos.append(item.id) }
        }

        // 3. Pixels: previews for photos only, 4 at a time.
        // ponytail: JPEG decode and the luminance hash run on the main actor; move them off if large picks stutter the UI.
        var hashes: [String: UInt64] = [:]
        var prints: [String: FeaturePrint] = [:]
        var previews: [String: UIImage] = [:]
        let photos = items.filter { $0.kind == .photo }
        await withTaskGroup(of: (String, CGImage?).self) { group in
            var next = 0
            func addNext() {
                guard next < photos.count else { return }
                let item = photos[next]
                next += 1
                group.addTask { @MainActor in
                    let data = try? await api.thumbnailData(of: item, size: 512)
                    return (item.id, data.flatMap(Self.decode))
                }
            }
            for _ in 0..<4 { addNext() }
            for await (id, image) in group {
                if let image {
                    if let grid = VisualPreFilter.luminanceGrid(from: image) { hashes[id] = VisualPreFilter.hash64(from: grid) }
                    if let print = await vision.generateFeaturePrint(image: image) { prints[id] = print }
                    if await vision.analyzeBlurriness(image: image, assetId: id, sensitivity: blurSensitivity).isBlurry {
                        result.blurry.append(id)
                    }
                    previews[id] = Self.smallThumbnail(image)
                }
                done += 1
                progress(done / total)
                addNext()
            }
        }
        done += Double(items.count - photos.count)
        progress(done / total)

        // Video tiles get a preview too, but only the flagged ones.
        for id in Set(result.screenshots + result.largeVideos) where previews[id] == nil {
            guard let item = result.items[id],
                  let data = try? await api.thumbnailData(of: item, size: 320),
                  let image = Self.decode(data) else { continue }
            previews[id] = Self.smallThumbnail(image)
        }

        // 4. Group near-identical photos.
        var distances: [PairKey: Float] = [:]
        for pair in VisualPreFilter.candidatePairs(hashes) {
            guard let a = prints[pair.a], let b = prints[pair.b] else { continue }
            let distance = await vision.computeDistance(between: a, and: b)
            if distance < Self.similarThreshold { distances[pair] = distance }
        }
        let groups = Self.groups(from: Array(distances.keys))
        for (index, ids) in groups.enumerated() {
            let ordered = ids.sorted {
                let a = result.items[$0], b = result.items[$1]
                if (a?.fileSize ?? 0) != (b?.fileSize ?? 0) { return (a?.fileSize ?? 0) > (b?.fileSize ?? 0) }
                return (a?.createTime ?? .distantPast) > (b?.createTime ?? .distantPast)
            }
            let exact = Self.isExactGroup(ordered, items: result.items, distances: distances)
            let group = CloudScanResult.Group(id: "g\(index)", itemIds: ordered, isExactDuplicate: exact)
            if exact { result.duplicateGroups.append(group) } else { result.similarGroups.append(group) }
        }

        // Keep previews only for flagged items, to bound memory.
        let flagged = Set(result.blurry + result.screenshots + result.largeVideos
            + (result.duplicateGroups + result.similarGroups).flatMap(\.itemIds))
        result.thumbnails = previews.filter { flagged.contains($0.key) }
        return result
    }

    // MARK: - Pure rules (tested)

    /// Screenshots and screen recordings, from what the picker reports:
    /// iOS/Android file names, or a PNG with a phone-screen aspect ratio.
    nonisolated static func isScreenshotOrRecording(_ item: CloudMediaItem) -> Bool {
        let name = item.filename.lowercased()
        if PhotoLibraryService.isScreenRecordingFilename(item.filename) { return true }
        if name.contains("screenshot") || name.contains("screen shot") || name.contains("screen_recording")
            || name.contains("screenrecord") || name.contains("screen recording") { return true }
        guard item.kind == .photo, item.mimeType == "image/png", item.width > 0, item.height > 0 else { return false }
        let ratio = Double(max(item.width, item.height)) / Double(min(item.width, item.height))
        return ratio >= 1.7 && ratio <= 2.4
    }

    nonisolated static func isLargeVideo(_ item: CloudMediaItem, threshold: Int64) -> Bool {
        item.kind == .video && (item.fileSize ?? 0) >= threshold
    }

    /// Connected components of the matched pairs.
    nonisolated static func groups(from pairs: [PairKey]) -> [[String]] {
        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var id = id
            while let p = parent[id], p != id { id = p }
            return id
        }
        for pair in pairs {
            parent[pair.a] = parent[pair.a] ?? pair.a
            parent[pair.b] = parent[pair.b] ?? pair.b
            let a = root(pair.a), b = root(pair.b)
            if a != b { parent[b] = a }
        }
        return Dictionary(grouping: parent.keys, by: root).values
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    nonisolated static func isExactGroup(_ ids: [String], items: [String: CloudMediaItem], distances: [PairKey: Float]) -> Bool {
        let sizes = Set(ids.compactMap { items[$0].map { "\($0.width)x\($0.height)" } })
        guard sizes.count == 1 else { return false }
        for (i, a) in ids.enumerated() {
            for b in ids.dropFirst(i + 1) {
                guard let distance = distances[PairKey(a, b)], distance < duplicateThreshold else { return false }
            }
        }
        return true
    }

    // MARK: - Images

    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated static func smallThumbnail(_ image: CGImage) -> UIImage {
        let side: CGFloat = 160
        let scale = side / CGFloat(max(image.width, image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
