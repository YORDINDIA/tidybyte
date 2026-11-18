import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import os
import PDFKit
@preconcurrency import Vision

enum SavedFromAppMarkers {
    private static let prefixMarkers: [(prefix: String, app: String)] = [
        ("LINE_", "LINE"),
        ("LINE-", "LINE"),
        ("QQ_", "QQ"),
        ("IMO_", "imo"),
        ("IMO-", "imo"),
        ("RECEIVED_", "Downloaded"),
        ("DOWNLOAD", "Downloaded"),
        ("IMG-", "WhatsApp")
    ]

    private static let substringMarkers: [(token: String, app: String)] = [
        ("WHATSAPP", "WhatsApp"),
        ("FB_IMG", "Facebook"),
        ("MESSENGER", "Messenger"),
        ("INSTA_", "Instagram"),
        ("INSTAGRAM", "Instagram"),
        ("TELEGRAM", "Telegram"),
        ("SNAPCHAT", "Snapchat"),
        ("SIGNAL-", "Signal"),
        ("DISCORD", "Discord"),
        ("TIKTOK", "TikTok"),
        ("MMEXPORT", "WeChat"),
        ("WX_CAMERA", "WeChat"),
        ("WEIXIN", "WeChat"),
        ("WEIBO", "Weibo"),
        ("DOUYIN", "Douyin"),
        ("KAKAO", "KakaoTalk"),
        ("NAVER", "Naver"),
        ("SHAREIT", "ShareIt"),
        ("VIBER", "Viber"),
        ("ZALO", "Zalo")
    ]

    static func matches(filename: String?) -> Bool {
        appName(for: filename) != nil
    }

    static func appName(for filename: String?) -> String? {
        guard let filename, !filename.isEmpty else { return nil }
        let upper = filename.uppercased()
        if hasWhatsAppMarker(upper) { return "WhatsApp" }
        if let match = substringMarkers.first(where: { upper.contains($0.token) }) {
            return match.app
        }
        if let match = prefixMarkers.first(where: { upper.hasPrefix($0.prefix) }) {
            return match.app
        }
        return nil
    }

    static func hasWhatsAppMarker(_ uppercasedName: String) -> Bool {
        var rest = Substring(uppercasedName)
        while let found = rest.range(of: "-WA") {
            if let next = rest[found.upperBound...].first, next.isASCII, next.isNumber { return true }
            rest = rest[found.upperBound...]
        }
        return false
    }
}

struct PairKey: Hashable, Sendable {
    let first: String
    let second: String

    init(_ lhs: String, _ rhs: String) {
        if lhs < rhs {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }
}

enum VisualPreFilter {
    static let maxHammingDistance = 12
    static let distanceThreshold: Float = 0.48

    static func shouldCompare(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        if lhs == 0 || rhs == 0 { return true }
        return (lhs ^ rhs).nonzeroBitCount <= maxHammingDistance
    }

    static func isVisualMatch(
        _ lhs: VNFeaturePrintObservation, _ rhs: VNFeaturePrintObservation
    ) -> Bool {
        var distance: Float = 0
        do {
            try lhs.computeDistance(&distance, to: rhs)
            return distance.isFinite && distance <= distanceThreshold
        } catch {
            return false
        }
    }

    static func buildNeighborAdjacency(
        ids: [String], pairs: Set<PairKey>
    ) -> [[Int]] {
        let indexByID = ids.enumerated().reduce(into: [String: Int]()) { result, entry in
            if result[entry.element] == nil { result[entry.element] = entry.offset }
        }
        var neighbors = Array(repeating: [Int](), count: ids.count)
        for pair in pairs {
            guard let lhs = indexByID[pair.first], let rhs = indexByID[pair.second], lhs != rhs else { continue }
            neighbors[min(lhs, rhs)].append(max(lhs, rhs))
        }
        for idx in neighbors.indices { neighbors[idx].sort() }
        return neighbors
    }

    static func candidatePairs(_ hashes: [String: UInt64]) -> Set<PairKey> {
        guard hashes.count > 1 else { return [] }
        let chunkCount = 8
        let chunkWidth = 8
        var buckets: [Int: [String]] = [:]
        var pairs = Set<PairKey>()
        var nearCache: [Int: [Int]] = [:]

        for (id, hash) in hashes where hash != 0 {
            for chunk in 0..<chunkCount {
                let value = Int((hash >> UInt64(chunkWidth * chunk)) & 0xFF)
                let baseKey = chunk * (1 << chunkWidth)
                let near = nearCache[value] ?? {
                    let values = nearValues(to: value, width: chunkWidth)
                    nearCache[value] = values
                    return values
                }()
                for candidate in near {
                    for other in buckets[baseKey + candidate] ?? [] where other != id {
                        if let otherHash = hashes[other], shouldCompare(hash, otherHash) {
                            pairs.insert(PairKey(id, other))
                        }
                    }
                }
                buckets[baseKey + value, default: []].append(id)
            }
        }

        let sentinelIDs = hashes.compactMap { $0.value == 0 ? $0.key : nil }
        for sentinel in sentinelIDs {
            for id in hashes.keys where id != sentinel {
                pairs.insert(PairKey(sentinel, id))
            }
        }
        return pairs
    }

    private static func nearValues(to value: Int, width: Int) -> [Int] {
        var result = [value]
        for bit in 0..<width {
            result.append(value ^ (1 << bit))
        }
        return result
    }
}

private struct ClassificationSignals {
    let labels: [VNClassificationObservation]
    let textArea: Float
    let textCount: Int
    let faceCoverage: Float
    let isScreenshot: Bool
    let textThreshold: Float
}

enum ImageQualityAnalysis {
    private static let blurWorkingEdge = 512
    private static let smudgeUnsupported = OSAllocatedUnfairLock(initialState: false)
    private static let taxonomyToBucket: [String: SmartCategory] = [
        "food": .food, "fruit": .food, "vegetable": .food, "meal": .food,
        "drink": .food, "beverage": .food, "dessert": .food, "baked_goods": .food,
        "dish": .food, "snack": .food, "produce": .food, "cuisine": .food,
        "dog": .pets, "cat": .pets, "pet": .pets, "animal": .pets,
        "puppy": .pets, "kitten": .pets, "bird": .pets, "rabbit": .pets,
        "plant": .nature, "flower": .nature, "tree": .nature, "foliage": .nature,
        "mountain": .nature, "hill": .nature, "beach": .nature, "coast": .nature,
        "sky": .nature, "cloud": .nature, "sunset": .nature, "sunrise": .nature,
        "landscape": .nature, "field": .nature, "forest": .nature, "lake": .nature,
        "river": .nature, "ocean": .nature, "sea": .nature, "waterfall": .nature,
        "snow": .nature, "garden": .nature, "park": .nature,
        "selfie": .selfies, "portrait": .selfies,
        "document": .documents, "receipt": .documents, "paper": .documents,
        "letter": .documents, "menu": .documents, "whiteboard": .documents,
        "book": .documents, "newspaper": .documents
    ]

    static func measureImage(_ url: URL, original: MediaFacts, sensitivity: Int) throws -> ImageMeasurement {
        try autoreleasepool {
            try measureDecoded(url, original: original, sensitivity: sensitivity).measurement
        }
    }

    static func measureImageAsync(
        _ url: URL, original: MediaFacts, sensitivity: Int
    ) async throws -> ImageMeasurement {
        let (measurement, image) = try autoreleasepool {
            try measureDecoded(url, original: original, sensitivity: sensitivity)
        }
        var updated = measurement
        if let aesthetics = await analyzeAesthetics(image: image) {
            updated.facts.aestheticsScore = Double(aesthetics.score)
            updated.isUtility = aesthetics.isUtility
        }
        if await analyzeLensSmudge(image: image) {
            updated.facts.hasLensSmudge = true
        }
        return updated
    }

    private static func measureDecoded(
        _ url: URL, original: MediaFacts, sensitivity: Int
    ) throws -> (measurement: ImageMeasurement, image: CGImage) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: blurWorkingEdge,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw CleanupError.message(String(localized: "This image cannot be decoded."))
        }
        var facts = original
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        facts.width = original.width ?? properties?[kCGImagePropertyPixelWidth] as? Int
        facts.height = original.height ?? properties?[kCGImagePropertyPixelHeight] as? Int
        facts.capturedAt = captureDate(properties) ?? original.capturedAt
        let apple = properties?[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        facts.contentIdentifier = original.contentIdentifier ?? (apple?["17"] as? String)
        facts.savedFromApp = original.savedFromApp ?? SavedFromAppMarkers.appName(for: url.lastPathComponent)
        let sample = try luminanceSamples(image, side: 64)
        let mean = sample.reduce(0, +) / Double(max(1, sample.count))
        facts.luminance = mean
        facts.clippedHighlights = Double(sample.filter { $0 > 0.98 }.count) / Double(max(1, sample.count))
        facts.sharpness = Double(laplacianVariance(of: image))
        let hash = perceptualHash64(of: image)
        let classification = try classify(image, isScreenshot: facts.isScreenshot, sensitivity: sensitivity)
        facts.category = classification.category
        let measurement = ImageMeasurement(facts: facts, feature: classification.feature, perceptualHash: hash)
        return (measurement, image)
    }

    private static func perceptualHash64(of image: CGImage) -> UInt64 {
        guard let small = try? grayscaleBytes(image, width: 8, height: 8), !small.isEmpty else { return 0 }
        let mean = UInt64(small.reduce(0) { $0 + UInt64($1) }) / UInt64(small.count)
        var hash: UInt64 = 0
        for (index, value) in small.prefix(64).enumerated() where UInt64(value) >= mean {
            hash |= UInt64(1) << UInt64(index)
        }
        return hash
    }

    private static func laplacianVariance(of image: CGImage) -> Float {
        let srcW = image.width
        let srcH = image.height
        guard srcW >= 3, srcH >= 3 else { return 300 }
        let longest = max(srcW, srcH)
        let scale = longest > blurWorkingEdge ? Double(blurWorkingEdge) / Double(longest) : 1.0
        let width = max(3, Int((Double(srcW) * scale).rounded()))
        let height = max(3, Int((Double(srcH) * scale).rounded()))
        guard let pixels = try? grayscaleBytes(image, width: width, height: height) else { return 300 }
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        pixels.withUnsafeBufferPointer { buffer in
            for rowIndex in 1..<(height - 1) {
                let row = rowIndex * width
                let above = (rowIndex - 1) * width
                let below = (rowIndex + 1) * width
                for col in 1..<(width - 1) {
                    let lap = Int(buffer[above + col]) + Int(buffer[below + col])
                        + Int(buffer[row + col - 1]) + Int(buffer[row + col + 1]) - 4 * Int(buffer[row + col])
                    let value = Double(lap)
                    sum += value
                    sumSquares += value * value
                    count += 1
                }
            }
        }
        guard count > 0 else { return 300 }
        let mean = sum / count
        return Float(max(0, sumSquares / count - mean * mean))
    }

    private static func captureDate(_ properties: [CFString: Any]?) -> Date? {
        guard let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXXXX"
        return formatter.date(from: raw + (offset ?? ""))
    }

    private static func classify(
        _ image: CGImage, isScreenshot: Bool, sensitivity: Int
    ) throws -> (feature: VNFeaturePrintObservation?, category: SmartCategory) {
        let clamped = min(2, max(0, sensitivity))
        let feature = VNGenerateImageFeaturePrintRequest()
        feature.revision = VNGenerateImageFeaturePrintRequestRevision2
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let faces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([feature, classify, text, faces])

        let floor: Float = [0.30, 0.20, 0.10][clamped]
        let textThreshold: Float = [0.18, 0.12, 0.08][clamped]
        let labels = classify.results?.filter { $0.confidence >= floor } ?? []
        let textArea = text.results?.reduce(Float(0)) {
            $0 + Float($1.boundingBox.width * $1.boundingBox.height)
        } ?? 0
        let faceCoverage = faces.results?.reduce(Float(0)) {
            max($0, Float($1.boundingBox.width * $1.boundingBox.height))
        } ?? 0

        let signals = ClassificationSignals(
            labels: labels, textArea: min(textArea, 1), textCount: text.results?.count ?? 0,
            faceCoverage: faceCoverage, isScreenshot: isScreenshot, textThreshold: textThreshold)
        return (feature.results?.first, resolveCategory(signals))
    }

    private static func resolveCategory(_ signals: ClassificationSignals) -> SmartCategory {
        for label in signals.labels {
            let normalized = label.identifier.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
            if let bucket = taxonomyToBucket[normalized] {
                return bucket
            }
        }
        if signals.faceCoverage >= 0.10 { return .selfies }
        if signals.textArea >= signals.textThreshold || signals.textCount >= 6 {
            return signals.isScreenshot ? .memes : .documents
        }
        if signals.isScreenshot && (signals.textArea >= 0.03 || signals.textCount >= 2) {
            return .memes
        }
        return .other
    }

    private static func analyzeAesthetics(image: CGImage) async -> (score: Float, isUtility: Bool)? {
        guard !Task.isCancelled else { return nil }
        do {
            let result = try await CalculateImageAestheticsScoresRequest().perform(on: image)
            guard !Task.isCancelled, result.overallScore.isFinite else { return nil }
            return (result.overallScore, result.isUtility)
        } catch {
            return nil
        }
    }

    private static func analyzeLensSmudge(image: CGImage) async -> Bool {
        guard !Task.isCancelled, !smudgeUnsupported.withLock({ $0 }),
            MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) == true
        else { return false }
        do {
            let result = try await DetectLensSmudgeRequest().perform(on: image)
            guard !Task.isCancelled, result.confidence.isFinite else { return false }
            return result.confidence >= 0.8
        } catch {
            let nsError = error as NSError
            if nsError.domain == VNErrorDomain,
                [VNErrorCode.unsupportedRequest.rawValue, VNErrorCode.unsupportedComputeDevice.rawValue]
                .contains(nsError.code) {
                smudgeUnsupported.withLock { $0 = true }
            }
            return false
        }
    }

    private static func luminanceSamples(_ image: CGImage, side: Int) throws -> [Double] {
        try grayscaleBytes(image, width: side, height: side).map { Double($0) / 255 }
    }

    private static func grayscaleBytes(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw CleanupError.message(String(localized: "This image cannot be analyzed."))
        }
        return pixels
    }
}

extension ImageQualityAnalysis {
    static func mediaFacts(_ url: URL, item: ReviewItem) async throws -> MediaFacts {
        var facts = item.facts
        if item.kind == .pdf { facts.pageCount = PDFDocument(url: url)?.pageCount }
        if item.kind == .video || item.kind == .audio {
            let asset = AVURLAsset(url: url)
            facts.duration = try await asset.load(.duration).seconds
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let rawSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let size = rawSize.applying(transform)
                let limit: CGFloat = 1_000_000
                if size.width.isFinite, size.height.isFinite, abs(size.width) < limit, abs(size.height) < limit {
                    facts.width = Int(abs(size.width))
                    facts.height = Int(abs(size.height))
                }
            }
            let metadata = try await asset.load(.metadata)
            for entry in metadata where entry.identifier == .quickTimeMetadataContentIdentifier {
                facts.contentIdentifier = try await entry.load(.stringValue)
            }
        }
        return facts
    }

    static func reviewReason(for item: ReviewItem, isUtility: Bool, largeMegabytes: Double) -> String? {
        guard !item.isFavorite, item.canAnalyze else { return nil }
        if item.kind == .image, !item.facts.isScreenshot {
            if item.facts.hasLensSmudge { return String(localized: "A lens smudge may have reduced image clarity.") }
            if let sharp = item.facts.sharpness, sharp < 70 { return String(localized: "This photo may be out of focus.") }
            if let light = item.facts.luminance, light < 0.12 { return String(localized: "This photo has very low brightness.") }
            if (item.facts.clippedHighlights ?? 0) > 0.35 || (item.facts.luminance ?? 0) > 0.88 {
                return String(localized: "This photo has very high brightness.")
            }
            if let score = item.facts.aestheticsScore, score < 0, !isUtility, item.facts.category != .documents {
                return String(localized: "This photo received a low visual-quality score.")
            }
        }
        if item.facts.isScreenshot { return String(localized: "Review whether you still need this screenshot.") }
        if item.facts.isScreenRecording { return String(localized: "Review whether you still need this screen recording.") }
        let threshold = largeMegabytes * 1_000_000
        if threshold.isFinite, Double(item.bytes) >= threshold {
            return String(localized: "This item uses \(item.bytes.formattedByteCount); review whether you need it.")
        }
        return nil
    }

    static func applySourceFacts(_ item: inout ReviewItem, isDownload: Bool) {
        let name = item.name.lowercased()
        item.facts.isScreenshot =
            item.facts.isScreenshot
            || (item.kind == .image && ["screenshot", "screen shot"].contains { name.hasPrefix($0) })
        item.facts.isScreenRecording =
            item.facts.isScreenRecording
            || (item.kind == .video && ["screen recording", "screenrecording"].contains { name.hasPrefix($0) })
        if item.facts.burstIdentifier == nil,
            name.range(of: #"(?:burst|sequence)[_-]?\d+"#, options: .regularExpression) != nil {
            let stem = name.replacingOccurrences(of: #"[_-]?\d+(?=\.[^.]+$)"#, with: "", options: .regularExpression)
            let day = Int((item.createdAt ?? item.modifiedAt ?? .distantPast).timeIntervalSince1970 / 60)
            item.facts.burstIdentifier = "\(stem):\(day)"
        }
        if item.facts.savedFromApp == nil, item.url != nil, !item.facts.isScreenshot {
            item.facts.savedFromApp = SavedFromAppMarkers.appName(for: item.name)
        }
        if item.facts.category == .other, isDownload { item.facts.category = .savedFromApps }
    }

    static func ranksHigher(_ lhs: ReviewItem, than rhs: ReviewItem) -> Bool {
        if lhs.isBurstPick != rhs.isBurstPick { return lhs.isBurstPick }
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        let leftSharp = lhs.facts.sharpness ?? 0
        let rightSharp = rhs.facts.sharpness ?? 0
        if leftSharp != rightSharp { return leftSharp > rightSharp }
        let leftPixels = (lhs.facts.width ?? 0) * (lhs.facts.height ?? 0)
        let rightPixels = (rhs.facts.width ?? 0) * (rhs.facts.height ?? 0)
        if leftPixels != rightPixels { return leftPixels > rightPixels }
        let leftDate = lhs.createdAt ?? lhs.modifiedAt ?? .distantPast
        let rightDate = rhs.createdAt ?? rhs.modifiedAt ?? .distantPast
        return leftDate != rightDate ? leftDate > rightDate : lhs.id < rhs.id
    }

    static func bestReason(ranked: [ReviewItem]) -> String? {
        guard let best = ranked.first, ranked.count >= 2 else { return nil }
        let runnerUp = ranked[1]
        if best.isBurstPick && !runnerUp.isBurstPick { return String(localized: "Picked in burst") }
        if best.isFavorite && !runnerUp.isFavorite { return String(localized: "Favorited") }
        if (best.facts.sharpness ?? 0) > (runnerUp.facts.sharpness ?? 0) {
            return String(localized: "Sharpest photo")
        }
        let bestPixels = (best.facts.width ?? 0) * (best.facts.height ?? 0)
        let otherPixels = (runnerUp.facts.width ?? 0) * (runnerUp.facts.height ?? 0)
        return bestPixels > otherPixels ? String(localized: "Highest resolution") : String(localized: "Most recent")
    }
}
