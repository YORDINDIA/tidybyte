import AVFoundation
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public actor MediaCompressionService {
    private static let fullResolutionMaxPixelSize = 6144
    private static let targetDimensionSteps: [Int?] = [nil, 4032, 3024, 2048, 1536, 1024]
    private static let targetQualityRange: ClosedRange<Double> = 0.3...0.9

    private let photos: PhotoLibraryService?

    public init(photos: PhotoLibraryService? = nil) {
        self.photos = photos
    }

    public static func estimate(_ item: ReviewItem, settings: CleanupSettings) -> Int64 {
        if item.kind == .image {
            if let maxMB = settings.photoMaxSizeMB, maxMB > 0 {
                return min(item.bytes, Int64(maxMB * 1_000_000))
            }
            var factor = settings.imageQuality.quality * 0.8
            if let maxDim = settings.photoMaxDimension, let width = item.facts.width, let height = item.facts.height {
                let longest = Double(max(width, height))
                if longest > Double(maxDim) {
                    let scale = Double(maxDim) / longest
                    factor *= scale * scale
                }
            }
            return Int64(Double(item.bytes) * min(factor, 1.0))
        }
        let longest = max(1, max(item.facts.width ?? settings.videoHeight, item.facts.height ?? settings.videoHeight))
        let targetLongest = Double(targetLongestEdge(forHeight: settings.videoHeight))
        let scale = min(1.0, targetLongest / Double(longest))
        let codecFactor = settings.videoUseHEVC ? 0.50 : 0.65
        return Int64(Double(item.bytes) * scale * scale * codecFactor)
    }

    public static func isAlreadyUnderTarget(_ item: ReviewItem, settings: CleanupSettings) -> Bool {
        guard item.kind == .image, let maxMB = settings.photoMaxSizeMB, maxMB > 0 else { return false }
        let targetBytes = Int64(maxMB * 1_000_000)
        return item.bytes > 0 && item.bytes <= targetBytes
    }

    public func measureCompressedSize(
        _ item: ReviewItem, source: URL? = nil, settings: CleanupSettings
    ) async throws -> Int64 {
        try Task.checkCancellation()
        guard item.kind == .image else {
            throw CleanupError.message(String(localized: "Size measurement is supported for images only."))
        }
        let resolvedSource: URL
        var ownedPhotos: PhotoLibraryService?
        if let source {
            resolvedSource = source
        } else if let url = item.url {
            resolvedSource = url
        } else if item.photoID != nil {
            let service = photos ?? PhotoLibraryService()
            if photos == nil { ownedPhotos = service }
            resolvedSource = try await service.previewURL(for: item)
        } else {
            throw CleanupError.message(String(localized: "Image source is unavailable."))
        }
        defer {
            if let ownedPhotos {
                Task { await ownedPhotos.purgePreviewCache() }
            }
        }
        let ext = settings.photoConvertToHEIC ? "heic" : resolvedSource.pathExtension.lowercased()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("measure-" + UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "heic" : ext)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await Task.detached(priority: .utility) {
            try Self.compressImage(resolvedSource, output: tempURL, settings: settings, preserveMetadata: false)
            return try ReviewSafety.identity(at: tempURL).sizeBytes ?? 0
        }.value
    }

    public func compress(
        _ item: ReviewItem, source: URL, destination: URL, settings: CleanupSettings,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        guard ReviewSafety.hasFreeDiskSpace(bytes: item.bytes, at: destination) else {
            throw CleanupError.message(String(localized: "Not enough free disk space to compress safely."))
        }
        let ext = Self.outputExtension(for: item, source: source, settings: settings)
        let name = source.deletingPathExtension().lastPathComponent + "-compressed." + ext
        let staging = destination.appendingPathComponent(".cleaner-compression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = staging.appendingPathComponent(name)
        do {
            try await runCompression(
                item: item, source: source, output: output, settings: settings, progress: progress)
            try Task.checkCancellation()
            let before = try ReviewSafety.identity(at: source).sizeBytes ?? 0
            let after = try ReviewSafety.identity(at: output).sizeBytes ?? 0
            guard after > 0, after < before else {
                throw CleanupError.message(
                    String(localized: "The compressed copy is not smaller. The original was kept."))
            }
            await progress(1)
            return try publish(output: output, destination: destination, name: name)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private func runCompression(
        item: ReviewItem, source: URL, output: URL, settings: CleanupSettings,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        if item.kind == .image {
            let preserveMetadata = item.url != nil
            try await Task.detached(priority: .utility) {
                try Self.compressImage(source, output: output, settings: settings, preserveMetadata: preserveMetadata)
            }.value
        } else if item.kind == .video {
            try await Self.compressVideo(source, output: output, settings: settings, progress: progress)
        } else {
            throw CleanupError.message(String(localized: "This file does not support compression."))
        }
    }

    private func publish(output: URL, destination: URL, name: String) throws -> URL {
        for _ in 0..<100 {
            let published = ReviewSafety.uniqueOutput(in: destination, name: name)
            if renamex_np(output.path, published.path, UInt32(RENAME_EXCL)) == 0 { return published }
            if errno != EEXIST { break }
        }
        throw CleanupError.message(String(localized: "Cannot save the verified output. The original was kept."))
    }
}

extension MediaCompressionService {
    private static func outputExtension(for item: ReviewItem, source: URL, settings: CleanupSettings) -> String {
        if item.kind == .video { return "mp4" }
        if settings.photoConvertToHEIC { return "heic" }
        let ext = source.pathExtension.lowercased()
        return ext.isEmpty ? "jpg" : ext
    }

    private static func compressImage(
        _ sourceURL: URL, output: URL, settings: CleanupSettings, preserveMetadata: Bool
    ) throws {
        let supportedTypes = [
            UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier, UTType.png.identifier
        ]
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
            CGImageSourceGetCount(source) == 1,
            let sourceType = CGImageSourceGetType(source),
            supportedTypes.contains(sourceType as String)
        else {
            throw CleanupError.message(
                String(localized: "Compression does not support this image's format or animation data."))
        }
        let targetType: CFString = settings.photoConvertToHEIC ? UTType.heic.identifier as CFString : sourceType
        let baseMetadata = preserveMetadata ? cleanedMetadata(from: source) : [:]
        let encodedImage: CGImage
        if let maxMB = settings.photoMaxSizeMB, maxMB > 0 {
            let maxBytes = Int64(maxMB * 1_000_000)
            encodedImage = try encodeToMaxBytes(
                source, output: output, targetType: targetType,
                maxBytes: maxBytes, metadata: (settings.photoMaxDimension, baseMetadata))
        } else {
            let image = try makeUprightImage(from: source, maxDimension: settings.photoMaxDimension)
            _ = try writeImage(
                image, to: output, type: targetType, quality: settings.imageQuality.quality, metadata: baseMetadata)
            encodedImage = image
        }
        try verifyImage(at: output, expected: encodedImage)
    }

    private static func encodeToMaxBytes(
        _ source: CGImageSource, output: URL, targetType: CFString,
        maxBytes: Int64, metadata: (cap: Int?, properties: [CFString: Any])
    ) throws -> CGImage {
        let steps = targetDimensionSteps.filter { step in
            guard let cap = metadata.cap else { return true }
            return step.map { $0 <= cap } ?? false
        }
        let candidates = steps.isEmpty ? [metadata.cap] : steps
        for dimension in candidates {
            let image = try makeUprightImage(from: source, maxDimension: dimension)
            let bestSize = try writeImage(
                image, to: output, type: targetType,
                quality: targetQualityRange.upperBound, metadata: metadata.properties)
            if bestSize <= maxBytes { return image }
            let minSize = try writeImage(
                image, to: output, type: targetType,
                quality: targetQualityRange.lowerBound, metadata: metadata.properties)
            guard minSize <= maxBytes else { continue }
            var low = targetQualityRange.lowerBound
            var high = targetQualityRange.upperBound
            for _ in 0..<4 {
                let mid = (low + high) / 2
                if try writeImage(
                    image, to: output, type: targetType, quality: mid, metadata: metadata.properties) <= maxBytes {
                    low = mid
                } else {
                    high = mid
                }
            }
            _ = try writeImage(image, to: output, type: targetType, quality: low, metadata: metadata.properties)
            return image
        }
        throw CleanupError.message(String(localized: "Cannot reach the target file size. The original was kept."))
    }

    private static func makeUprightImage(from source: CGImageSource, maxDimension: Int?) throws -> CGImage {
        let pixelCap = maxDimension ?? fullResolutionMaxPixelSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelCap
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CleanupError.message(String(localized: "Cannot decode the image for compression."))
        }
        return cgImage
    }

    private static func writeImage(
        _ image: CGImage, to url: URL, type: CFString, quality: Double, metadata: [CFString: Any]
    ) throws -> Int64 {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw CleanupError.message(String(localized: "Cannot create the compressed image."))
        }
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CleanupError.message(String(localized: "Cannot write the compressed image."))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > 0 else {
            throw CleanupError.message(String(localized: "Cannot read the compressed image size."))
        }
        return size
    }

    private static func verifyImage(at output: URL, expected image: CGImage) throws {
        guard let verification = CGImageSourceCreateWithURL(output as CFURL, nil),
            CGImageSourceGetCount(verification) == 1,
            let decoded = CGImageSourceCreateImageAtIndex(verification, 0, nil),
            decoded.width == image.width, decoded.height == image.height,
            !hasAlpha(image) || hasAlpha(decoded)
        else {
            throw CleanupError.message(String(localized: "The compressed image did not pass verification."))
        }
    }

    private static func cleanedMetadata(from source: CGImageSource) -> [CFString: Any] {
        guard var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        properties.removeValue(forKey: kCGImagePropertyOrientation)
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
    }

    private static func targetLongestEdge(forHeight height: Int) -> Int {
        if height >= 2160 { return 3840 }
        if height >= 1080 { return 1920 }
        if height >= 720 { return 1280 }
        return 640
    }

    private static func compressVideo(
        _ source: URL, output: URL, settings: CleanupSettings,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let allTracks = try await asset.load(.tracks)
        let allowedTypes: Set<AVMediaType> = [
            .video, .audio, .metadata, .timecode, .subtitle, .closedCaption, .text
        ]
        guard videoTracks.count == 1, audioTracks.count <= 1,
            !allTracks.contains(where: { !allowedTypes.contains($0.mediaType) }),
            let track = videoTracks.first
        else {
            throw CleanupError.message(String(localized: "This video's track layout is not supported for compression."))
        }
        for description in try await track.load(.formatDescriptions) {
            try validateVideoFormat(description)
        }
        let preset = try await selectVideoPreset(asset: asset, track: track, settings: settings)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CleanupError.message(String(localized: "This video format cannot be exported."))
        }
        let compatibleTypes = await exporter.compatibleFileTypes
        guard compatibleTypes.contains(.mp4) else {
            throw CleanupError.message(String(localized: "This video format cannot be exported."))
        }
        exporter.metadata = try await asset.load(.metadata)
        exporter.shouldOptimizeForNetworkUse = true
        let states = exporter.states(updateInterval: 0.2)
        let observation = Task {
            for await state in states {
                if case .exporting(let status) = state { await progress(status.fractionCompleted) }
            }
        }
        defer { observation.cancel() }
        try await exporter.export(to: output, as: .mp4)
        try Task.checkCancellation()
        try await verifyVideo(asset, output: output, videoCount: videoTracks.count, audioCount: audioTracks.count)
    }

    private static func selectVideoPreset(
        asset: AVURLAsset, track: AVAssetTrack, settings: CleanupSettings
    ) async throws -> String {
        let rawSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = rawSize.applying(transform)
        let longestEdge = Int(max(abs(oriented.width), abs(oriented.height)).rounded())
        guard longestEdge >= 640, settings.videoHeight >= 480 else {
            throw CleanupError.message(String(localized: "This video is below 480p and will not be upscaled."))
        }
        let effectiveLongest = min(targetLongestEdge(forHeight: settings.videoHeight), longestEdge)
        if settings.videoUseHEVC, effectiveLongest >= 1920 {
            if longestEdge <= 1920,
                await AVAssetExportSession.compatibility(
                    ofExportPreset: AVAssetExportPresetHEVCHighestQuality, with: asset, outputFileType: .mp4) {
                return AVAssetExportPresetHEVCHighestQuality
            }
            if await AVAssetExportSession.compatibility(
                ofExportPreset: AVAssetExportPresetHEVC1920x1080, with: asset, outputFileType: .mp4) {
                return AVAssetExportPresetHEVC1920x1080
            }
        }
        if effectiveLongest >= 1920 { return AVAssetExportPreset1920x1080 }
        if effectiveLongest >= 1280 { return AVAssetExportPreset1280x720 }
        return AVAssetExportPreset640x480
    }

    static func validateVideoFormat(_ description: CMFormatDescription) throws {
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? ""
        let hasAlpha = extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool == true
        let depth = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int ?? 8
        let unsupportedKeys = [
            kCMFormatDescriptionExtension_AlphaChannelMode, kCMFormatDescriptionExtension_LogTransferFunction,
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
            kCMFormatDescriptionExtension_ContentLightLevelInfo,
            kCMFormatDescriptionExtension_AlternativeTransferCharacteristics,
            kCMFormatDescriptionExtension_ProjectionKind,
            kCMFormatDescriptionExtension_StereoCameraBaseline
        ]
        let hasStereo = [
            kCMFormatDescriptionExtension_HasLeftStereoEyeView, kCMFormatDescriptionExtension_HasRightStereoEyeView
        ].contains { extensions[$0 as String] as? Bool == true }
        guard !hasAlpha, !hasStereo, depth <= 8,
            !unsupportedKeys.contains(where: { extensions[$0 as String] != nil }),
            !["2084", "HLG", "2100"].contains(where: transfer.contains)
        else {
            throw CleanupError.message(
                String(localized: "This video has HDR, transparency, or spatial data that must be retained."))
        }
    }

    private static func verifyVideo(_ asset: AVURLAsset, output: URL, videoCount: Int, audioCount: Int)
        async throws {
        let result = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let actual = try await result.load(.duration).seconds
        let newVideo = try await result.loadTracks(withMediaType: .video)
        let newAudio = try await result.loadTracks(withMediaType: .audio)
        guard actual.isFinite, abs(duration - actual) < max(0.1, duration * 0.001),
            newVideo.count == videoCount, newAudio.count == audioCount, let verifiedTrack = newVideo.first
        else {
            throw CleanupError.message(String(localized: "The exported video did not pass verification."))
        }
        if let originalTrack = try await asset.loadTracks(withMediaType: .video).first {
            let before = try await orientedSize(for: originalTrack)
            let after = try await orientedSize(for: verifiedTrack)
            guard before.width > 0, before.height > 0, after.width > 0, after.height > 0,
                after.width <= before.width + 1, after.height <= before.height + 1,
                abs(after.width / after.height - before.width / before.height) < 0.02
            else {
                throw CleanupError.message(
                    String(localized: "The export changed aspect ratio or increased dimensions."))
            }
        }
        try decodeFirstSample(asset: result, videoTrack: verifiedTrack, audioTrack: newAudio.first)
    }

    private static func orientedSize(for track: AVAssetTrack) async throws -> CGSize {
        let raw = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = raw.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private static func decodeFirstSample(
        asset: AVURLAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(readerOutput)
        guard reader.startReading(), readerOutput.copyNextSampleBuffer() != nil else {
            throw CleanupError.message(String(localized: "The exported video could not be decoded."))
        }
        reader.cancelReading()
        if let audioTrack {
            let audioReader = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(
                track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            audioReader.add(audioOutput)
            guard audioReader.startReading(), audioOutput.copyNextSampleBuffer() != nil else {
                throw CleanupError.message(String(localized: "The exported audio could not be decoded."))
            }
            audioReader.cancelReading()
        }
    }
}
