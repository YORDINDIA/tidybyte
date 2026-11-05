import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

struct PhotoCompressionPreset: Identifiable, Sendable {
    let id: String
    let label: String
    /// Longest-edge cap in pixels; `nil` re-encodes at full resolution.
    let maxDimension: CGFloat?
    /// HEIC lossy quality, 0...1.
    let quality: CGFloat
    let description: String
    /// Set for "Max size" mode: the encoder searches quality / resolution
    /// until the output is at or under this many bytes.
    var targetBytes: Int64? = nil

    /// Computed, not a `static let` — see `CompressionPreset.presets` for why
    /// caching a localized array breaks live language switching.
    static var presets: [PhotoCompressionPreset] {
        [
            PhotoCompressionPreset(id: "high", label: L10n.string("High Quality"), maxDimension: nil, quality: 0.8,
                                   description: L10n.string("Re-encode to HEIC, full resolution")),
            PhotoCompressionPreset(id: "balanced", label: L10n.string("Balanced"), maxDimension: 3024, quality: 0.6,
                                   description: L10n.string("Resize to 3K, good savings")),
            PhotoCompressionPreset(id: "space", label: L10n.string("Space Saver"), maxDimension: 2048, quality: 0.5,
                                   description: L10n.string("Resize to 2K, maximum savings"))
        ]
    }

    /// Size caps offered in the "Max size" menu, in MB.
    static let maxSizeChoicesMB: [Double] = [1, 2, 3, 4.5, 5, 10]

    /// "Max size" mode: compress each photo to at most `megabytes` MB.
    /// Photos already under the cap are skipped, with no copy made.
    static func maxSize(megabytes: Double) -> PhotoCompressionPreset {
        let bytes = Int64(megabytes * 1_000_000)
        return PhotoCompressionPreset(
            id: "max-\(bytes)",
            label: L10n.format("Max %@", bytes.formattedFileSize),
            maxDimension: nil,
            quality: 0.9,
            description: L10n.string("Smallest change that fits the size limit"),
            targetBytes: bytes
        )
    }
}

/// Re-encodes photos to HEIC (optionally downscaling) to reclaim space, then
/// replaces the original in the library. Mirrors `VideoCompressionService`:
/// reuses its media-agnostic `CompressionResult`/`CompressionState`, writes to a
/// temp file with guaranteed cleanup, skips when no space is saved, preserves
/// date/location/favorite/hidden + album membership. It never deletes the
/// original: the batch does that for all items at once (`OriginalsCommit`).
actor PhotoCompressionService {
    private let photoService: PhotoLibraryService

    init(photoService: PhotoLibraryService) {
        self.photoService = photoService
    }

    func compressPhoto(
        assetId: String,
        preset: PhotoCompressionPreset,
        onSaveWillCommit: (@MainActor @Sendable () -> Void)? = nil,
        onReplacementSaved: (@MainActor @Sendable (String, Int64) -> Void)? = nil,
        onProgress: @escaping @MainActor @Sendable (Float) -> Void
    ) async throws -> CompressionResult {
        guard let phAsset = photoService.getPHAsset(for: assetId) else {
            throw PhotoCompressionError.assetNotFound
        }
        guard phAsset.mediaType == .image, !phAsset.mediaSubtypes.contains(.photoLive) else {
            throw PhotoCompressionError.notAnImage
        }

        await onProgress(0.05)
        let resources = PHAssetResource.assetResources(for: phAsset)
        let originalSize = fileSize(of: resources)
        guard originalSize > 0 else {
            // iCloud-only (or KVC-unreadable) assets report 0 bytes. Compressing
            // them would make the "does this save space?" check meaningless and
            // could delete a large original in exchange for a 0-byte history
            // record — skip instead (COMP-07).
            throw PhotoCompressionError.sizeUnknown
        }

        guard let imageData = await photoService.loadFullImageData(for: phAsset) else {
            throw PhotoCompressionError.imageDataLoadFailed
        }
        await onProgress(0.4)

        // Encode to a temp HEIC; guarantee removal on every exit path.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try encode(imageData, preset: preset, to: tempURL)
        await onProgress(0.8)

        // Respect batch cancellation: stop before replacing anything so no
        // half-finished swap happens (COMP-08).
        guard !Task.isCancelled else {
            throw PhotoCompressionError.cancelled
        }

        let compressedSize: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            compressedSize = (attrs[.size] as? Int64) ?? 0
        } catch {
            throw PhotoCompressionError.fileSizeReadFailed
        }
        guard compressedSize > 0 else {
            throw PhotoCompressionError.encodeFailed
        }

        // If re-encoding wouldn't save space (e.g. an already-efficient HEIC),
        // keep the original untouched.
        guard compressedSize < originalSize else {
            AppLog.compression.info("No savings compressing photo \(assetId, privacy: .public); keeping original")
            return CompressionResult(
                originalSize: originalSize,
                compressedSize: originalSize,
                replacementAssetIdentifier: nil,
                skipped: true
            )
        }

        let albumIdentifiers = await photoService.userAlbumIdentifiers(containing: assetId)
        let replacementFilename = heicFilename(from: resources.first?.originalFilename)

        // D1: tell the journal a library write is about to begin (see
        // VideoCompressionService.compressVideo) — reconcile uses it to tell a
        // crash here apart from a crash during the encode, which strands nothing.
        await onSaveWillCommit?()
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.originalFilename = replacementFilename
            request.addResource(with: .photo, fileURL: tempURL, options: resourceOptions)
            request.creationDate = phAsset.creationDate
            request.location = phAsset.location
            request.isFavorite = phAsset.isFavorite
            request.isHidden = phAsset.isHidden
            placeholder = request.placeholderForCreatedAsset
        }

        guard let replacementId = placeholder?.localIdentifier else {
            throw PhotoCompressionError.saveFailed(L10n.string("Failed to save compressed photo to library."))
        }
        // D1: report the durable new copy to the journal immediately, with the
        // real encoded size so the journal never has to guess at 0.
        await onReplacementSaved?(replacementId, compressedSize)
        await onProgress(1.0)

        for albumId in albumIdentifiers {
            do {
                try await photoService.addToAlbum(assetIdentifiers: [replacementId], albumIdentifier: albumId)
            } catch {
                AppLog.photo.error("Failed to restore album \(albumId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // The original is NOT deleted here: see VideoCompressionService — the
        // batch deletes all originals in one commit (one iOS prompt).
        return CompressionResult(
            originalSize: originalSize,
            compressedSize: compressedSize,
            replacementAssetIdentifier: replacementId,
            skipped: false
        )
    }

    /// Encodes the photo exactly as `compressPhoto` would, but saves nothing.
    /// Returns the real output size, so the user can review it first.
    func measureCompressedSize(assetId: String, preset: PhotoCompressionPreset) async throws -> Int64 {
        guard let phAsset = photoService.getPHAsset(for: assetId) else {
            throw PhotoCompressionError.assetNotFound
        }
        guard let imageData = await photoService.loadFullImageData(for: phAsset) else {
            throw PhotoCompressionError.imageDataLoadFailed
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try encode(imageData, preset: preset, to: tempURL)
    }

    // MARK: - Encoding

    /// Writes the HEIC for `preset` to `url` and returns its size in bytes.
    @discardableResult
    private func encode(_ data: Data, preset: PhotoCompressionPreset, to url: URL) throws -> Int64 {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoCompressionError.encodeFailed
        }
        guard let target = preset.targetBytes else {
            let image = try makeImage(from: source, maxDimension: preset.maxDimension)
            return try writeHEIC(image, to: url, quality: preset.quality)
        }
        return try encode(source, toMaxBytes: target, at: url)
    }

    /// Steps down through these longest-edge caps (nil = full resolution)
    /// when even the lowest quality is too big.
    private static let targetDimensionSteps: [CGFloat?] = [nil, 4032, 3024, 2048, 1536, 1024]
    private static let targetQualityRange: ClosedRange<CGFloat> = 0.3...0.9

    /// Finds the highest quality (at the highest resolution) whose output is
    /// at or under `maxBytes`, and leaves that file at `url`.
    // ponytail: up to ~6 encodes per resolution step; make the search adaptive if large images feel slow.
    private func encode(_ source: CGImageSource, toMaxBytes maxBytes: Int64, at url: URL) throws -> Int64 {
        let range = Self.targetQualityRange
        for dimension in Self.targetDimensionSteps {
            let image = try makeImage(from: source, maxDimension: dimension)
            let best = try writeHEIC(image, to: url, quality: range.upperBound)
            if best <= maxBytes { return best }
            guard try writeHEIC(image, to: url, quality: range.lowerBound) <= maxBytes else { continue }
            var low = range.lowerBound, high = range.upperBound
            for _ in 0..<4 {
                let mid = (low + high) / 2
                if try writeHEIC(image, to: url, quality: mid) <= maxBytes { low = mid } else { high = mid }
            }
            return try writeHEIC(image, to: url, quality: low)
        }
        throw PhotoCompressionError.cannotReachTarget
    }

    /// Longest-edge cap for the "High Quality" (full-resolution) path. Without
    /// a cap, a 48MP capture (8064×6048) decodes into a ~195 MB RGBA bitmap
    /// before re-encoding — a jetsam risk. Capping at 6144 halves that peak
    /// (6144×4608×4 ≈ 113 MB) while keeping more resolution than the downscale
    /// presets; typical captures (12MP, longest edge 4032) are untouched. The
    /// tradeoff: genuinely huge sources are no longer re-encoded at their true
    /// pixel-for-pixel size (COMP-06).
    private let fullResolutionMaxPixelSize: CGFloat = 6144

    /// Decodes `data`, optionally downscales to `maxDimension` (longest edge),
    /// and writes a HEIC file at `quality`. The thumbnail transform bakes
    /// orientation into the pixels, so the output is always upright. We
    /// deliberately do NOT copy the source's EXIF/TIFF dictionaries: their
    /// embedded Orientation tag would conflict with the already-upright pixels
    /// (causing a double-rotation in viewers that honor it), and their pixel
    /// dimensions would be stale after a downscale. The user-visible metadata
    /// (creation date, location, favorite, hidden) is restored on the new
    /// asset by the caller via `PHAssetCreationRequest`, so nothing important
    /// is lost.
    private func makeImage(from source: CGImageSource, maxDimension: CGFloat?) throws -> CGImage {
        var thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let maxDimension {
            thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = Int(maxDimension)
        } else {
            // Full-resolution preset: still bound the decode (see
            // `fullResolutionMaxPixelSize`). A cap derived from
            // PHAsset.pixelWidth/Height would silently downscale assets (e.g.
            // RAW/DNG) whose reported dimensions are smaller than the actual
            // decoded image — and the original is deleted afterward, so that
            // loss would be unrecoverable. The fixed cap only affects sources
            // whose true decoded size exceeds it.
            thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = Int(fullResolutionMaxPixelSize)
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw PhotoCompressionError.encodeFailed
        }
        return cgImage
    }

    /// Writes `image` as HEIC at `quality` (replacing `url`) and returns the file size.
    private func writeHEIC(_ image: CGImage, to url: URL, quality: CGFloat) throws -> Int64 {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoCompressionError.encodeFailed
        }

        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoCompressionError.encodeFailed
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        guard let size, size > 0 else { throw PhotoCompressionError.fileSizeReadFailed }
        return size
    }

    // MARK: - Helpers

    private func fileSize(of resources: [PHAssetResource]) -> Int64 {
        var total: Int64 = 0
        for resource in resources {
            if resource.responds(to: NSSelectorFromString("fileSize")),
               let size = resource.value(forKey: "fileSize") as? Int64 {
                total += size
            }
        }
        return total
    }

    private func heicFilename(from original: String?) -> String {
        guard let original, !original.isEmpty else { return "compressed.heic" }
        return ((original as NSString).deletingPathExtension as NSString)
            .appendingPathExtension("heic") ?? "compressed.heic"
    }
}

enum PhotoCompressionError: LocalizedError {
    case assetNotFound
    case notAnImage
    case imageDataLoadFailed
    case sizeUnknown
    case cancelled
    case encodeFailed
    case fileSizeReadFailed
    case saveFailed(String)
    case cannotReachTarget

    var errorDescription: String? {
        // Surfaced to the user in the compression tool's error banner, so these
        // resolve through `L10n` rather than staying English literals.
        switch self {
        case .assetNotFound: L10n.string("Photo not found.")
        case .notAnImage: L10n.string("This item can't be compressed as a photo.")
        case .imageDataLoadFailed: L10n.string("Failed to load the photo.")
        case .sizeUnknown: L10n.string("Photo size unknown (iCloud-only) — skipped.")
        case .cancelled: L10n.string("Cancelled.")
        case .encodeFailed: L10n.string("Failed to re-encode the photo.")
        case .fileSizeReadFailed: L10n.string("Failed to read file size.")
        case .saveFailed(let msg): L10n.format("Save failed: %@", msg)
        case .cannotReachTarget: L10n.string("Can't reach the size limit — kept original")
        }
    }
}
