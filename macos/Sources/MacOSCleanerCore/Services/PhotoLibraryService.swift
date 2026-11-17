import AppKit
import Foundation
import ImageIO
@preconcurrency import os
@preconcurrency import Photos
import UniformTypeIdentifiers

public protocol PhotoMutationService: Sendable {
    func previewURL(for item: ReviewItem) async throws -> URL
    func localURLs(for item: ReviewItem) async throws -> [URL]
    func export(_ item: ReviewItem, to folder: URL) async throws -> [URL]
    func replace(_ item: ReviewItem, with url: URL, kind: MediaKind) async throws -> String
    func delete(_ item: ReviewItem) async throws
    func delete(_ items: [ReviewItem]) async throws
}

extension PhotoMutationService {
    public func delete(_ items: [ReviewItem]) async throws {
        for item in items {
            try Task.checkCancellation()
            try await delete(item)
        }
    }
}

public struct PhotosReplacementError: LocalizedError, Sendable {
    public let replacementID: String
    public let reason: String
    public var errorDescription: String? { reason }
}

public actor PhotoLibraryService: PhotoMutationService {
    private var exportCache: [String: [URL]] = [:]
    private var exportCacheOrder: [String] = []
    private let maxExportCacheEntries = 24
    private let cacheRoot: URL

    public init() {
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CleanerPreviews-" + UUID().uuidString)
    }

    deinit { try? FileManager.default.removeItem(at: cacheRoot) }

    nonisolated public static func currentAuthorizationState() -> PhotoAuthorizationState {
        mapAuthorizationStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func authorizationState() -> PhotoAuthorizationState { Self.currentAuthorizationState() }

    @discardableResult
    public func authorize() async throws -> PhotoAuthorizationState {
        let state = Self.mapAuthorizationStatus(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        guard state == .authorized || state == .limited else { throw CleanupError.photosAccessDenied }
        return state
    }

    public func scan(progress: @Sendable (CleanupProgress) async -> Void) async throws -> [ReviewItem] {
        try await authorize()
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        var result: [ReviewItem] = []
        result.reserveCapacity(assets.count)
        for index in 0..<assets.count {
            try Task.checkCancellation()
            if let item = await Self.buildItem(from: assets.object(at: index)) { result.append(item) }
            if (index + 1).isMultiple(of: 25) || index + 1 == assets.count {
                await progress(
                    CleanupProgress(String(localized: "Reading Photos resources"), completed: index + 1, total: assets.count))
                await Task.yield()
            }
        }
        return result
    }

    public func hashResourcesIfNeeded(for items: [ReviewItem]) async throws -> [ReviewItem] {
        let pending = items.filter { $0.photoID != nil && $0.isDownloaded && $0.resources.contains { $0.hash == nil } }
        guard !pending.isEmpty else { return items }
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        var assetsByID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: pending.compactMap(\.photoID), options: options).enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }
        var updatedByID: [String: ReviewItem] = [:]
        for item in pending {
            try Task.checkCancellation()
            guard let id = item.photoID, let phAsset = assetsByID[id], phAsset.modificationDate == item.modifiedAt
            else { continue }
            updatedByID[item.id] = try await Self.hashResources(of: phAsset, into: item)
        }
        return items.map { updatedByID[$0.id] ?? $0 }
    }

    public func asset(_ item: ReviewItem) throws -> PHAsset {
        guard let id = item.photoID,
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
            asset.modificationDate == item.modifiedAt
        else {
            throw CleanupError.message(String(localized: "The Photos asset changed. Scan again before making changes."))
        }
        return asset
    }

    public func localURLs(for item: ReviewItem) async throws -> [URL] {
        try Task.checkCancellation()
        _ = try asset(item)
        guard item.isDownloaded else {
            throw CleanupError.message(String(localized: "This asset is not downloaded. Download it in Photos first."))
        }
        if let urls = exportCache[item.reviewKey], urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            return urls
        }
        let directory = cacheRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let urls = try await export(item, to: directory)
            cacheExport(urls, for: item.reviewKey)
            return urls
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func previewURL(for item: ReviewItem) async throws -> URL {
        let urls = try await localURLs(for: item)
        let desired = item.kind == .video ? [PHAssetResourceType.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        for type in desired {
            if let index = item.resources.firstIndex(where: { $0.type == type.rawValue }), urls.indices.contains(index) {
                return urls[index]
            }
        }
        guard let first = urls.first else { throw CleanupError.message(String(localized: "No preview is available.")) }
        return first
    }

    public func analysisPreview(_ item: ReviewItem, size: Int = 512) async throws -> URL {
        let original = try asset(item)
        let pending = PendingPreviewRequest()
        let image: CGImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact
                pending.store(continuation)
                let requestID = PHImageManager.default().requestImage(
                    for: original, targetSize: CGSize(width: size, height: size),
                    contentMode: .aspectFit, options: options
                ) { image, information in
                    if information?[PHImageResultIsDegradedKey] as? Bool == true { return }
                    pending.deliver(image.flatMap(Self.orientedCGImage(from:)))
                }
                pending.setRequestID(requestID)
            }
        } onCancel: { pending.cancelIfPending() }
        try Task.checkCancellation()
        return try writePreviewJPEG(image)
    }

    public func releaseAnalysisPreview(_ url: URL) {
        guard url.deletingLastPathComponent() == cacheRoot else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func purgePreviewCache() {
        exportCache.removeAll()
        exportCacheOrder.removeAll()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    public func export(_ item: ReviewItem, to folder: URL) async throws -> [URL] {
        let current = try asset(item)
        let resources = PHAssetResource.assetResources(for: current)
        guard resources.count == item.resources.count, item.isDownloaded else {
            throw CleanupError.message(String(localized: "Original Photos resources are not available."))
        }
        var urls: [URL] = []
        for (index, resource) in resources.enumerated() {
            try Task.checkCancellation()
            let descriptor = item.resources[index]
            guard descriptor.name == resource.originalFilename, descriptor.type == resource.type.rawValue else {
                throw CleanupError.message(String(localized: "The Photos resource list changed. Scan again."))
            }
            let output = try ReviewSafety.reserveOutput(in: folder, name: resource.originalFilename)
            let digest = try await Self.read(resource, output: output)
            let sizeValid = descriptor.bytes == 0 ? digest.0 > 0 : digest.0 == descriptor.bytes
            let hashValid = descriptor.hash == nil || digest.1 == descriptor.hash
            guard sizeValid, hashValid, try FingerprintService.fullHash(for: output) == digest.1 else {
                throw CleanupError.message(String(localized: "Export verification failed. The Photos original was kept."))
            }
            urls.append(output)
        }
        return urls
    }

    public func delete(_ item: ReviewItem) async throws { try await delete([item]) }

    public func delete(_ items: [ReviewItem]) async throws {
        guard !items.isEmpty else { return }
        try Task.checkCancellation()
        let box = UncheckedBox(value: try items.map { try asset($0) } as NSArray)
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(box.value) }
    }

    public func replace(_ item: ReviewItem, with url: URL, kind: MediaKind) async throws -> String {
        try Task.checkCancellation()
        let original = try asset(item)
        let placeholder = PhotoReplacementID()
        var editableAlbums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil).enumerateObjects { collection, _, _ in
            if collection.canPerform(.addContent) { editableAlbums.append(collection) }
        }
        let assetBox = UncheckedBox(value: original)
        let albumsBox = UncheckedBox(value: editableAlbums)
        let filename = Self.replacementFilename(for: item, outputURL: url, kind: kind)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: kind == .video ? .video : .photo, fileURL: url, options: options)
            request.creationDate = assetBox.value.creationDate
            request.location = assetBox.value.location
            request.isFavorite = assetBox.value.isFavorite
            request.isHidden = assetBox.value.isHidden
            if let created = request.placeholderForCreatedAsset {
                placeholder.value = created.localIdentifier
                for album in albumsBox.value where album.canPerform(.addContent) {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([created] as NSArray)
                }
            }
        }
        return try await verifyReplacement(placeholderID: placeholder.value, sourceURL: url)
    }
}

extension PhotoLibraryService {
    public func fetchUserAlbums() -> [(id: String, title: String)] {
        var result: [(id: String, title: String)] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
            guard collection.canPerform(.addContent) else { return }
            result.append((id: collection.localIdentifier, title: collection.localizedTitle ?? String(localized: "Untitled Album")))
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func addToAlbum(item: ReviewItem, albumID: String) async throws {
        try Task.checkCancellation()
        let target = try asset(item)
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
            .firstObject else { throw CleanupError.message(String(localized: "The selected album could not be found.")) }
        guard album.canPerform(.addContent) else {
            throw CleanupError.message(String(localized: "Photos cannot add items to this album."))
        }
        let targetBox = UncheckedBox(value: target)
        let albumBox = UncheckedBox(value: album)
        let added = OSAllocatedUnfairLock(initialState: false)
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: albumBox.value) else { return }
            request.addAssets([targetBox.value] as NSArray)
            added.withLock { $0 = true }
        }
        guard added.withLock({ $0 }) else {
            throw CleanupError.message(String(localized: "Could not add this item to the album."))
        }
    }

    public func createAlbum(title: String) async throws -> String {
        try Task.checkCancellation()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CleanupError.message(String(localized: "Enter an album name.")) }
        let placeholder = PhotoReplacementID()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: trimmed)
            placeholder.value = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = placeholder.value else {
            throw CleanupError.message(String(localized: "Could not create the album."))
        }
        return id
    }

    @discardableResult
    public func downloadFromICloud(
        _ item: ReviewItem, progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> ReviewItem {
        try Task.checkCancellation()
        let resources = PHAssetResource.assetResources(for: try asset(item))
        guard !resources.isEmpty else {
            throw CleanupError.message(String(localized: "No Photos resources are available to download."))
        }
        var updatedResources: [PhotoResource] = []
        var totalBytes: Int64 = 0
        let resourceCount = Double(resources.count)
        for (index, resource) in resources.enumerated() {
            try Task.checkCancellation()
            let digest = try await Self.read(resource, output: nil, allowsNetwork: true) { fraction in
                await progress?((Double(index) + fraction) / resourceCount)
            }
            updatedResources.append(
                PhotoResource(
                    name: resource.originalFilename, type: resource.type.rawValue,
                    uniformType: resource.uniformTypeIdentifier, bytes: digest.0, hash: digest.1))
            totalBytes += digest.0
        }
        await progress?(1.0)
        var updated = item
        updated.resources = updatedResources
        updated.bytes = totalBytes
        updated.isDownloaded = true
        return updated
    }

    private func cacheExport(_ urls: [URL], for key: String) {
        exportCache[key] = urls
        exportCacheOrder.removeAll { $0 == key }
        exportCacheOrder.append(key)
        while exportCacheOrder.count > maxExportCacheEntries {
            let oldest = exportCacheOrder.removeFirst()
            if let evicted = exportCache.removeValue(forKey: oldest),
                let dir = evicted.first?.deletingLastPathComponent(), dir.deletingLastPathComponent() == cacheRoot {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    private func writePreviewJPEG(_ image: CGImage) throws -> URL {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let output = cacheRoot.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CleanupError.message(String(localized: "Cannot create a preview.")) }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            throw CleanupError.message(String(localized: "Cannot write preview."))
        }
        return output
    }

    private func verifyReplacement(placeholderID: String?, sourceURL: URL) async throws -> String {
        guard let id = placeholderID else {
            throw CleanupError.message(String(localized: "Cannot verify the new Photos asset. The original was kept."))
        }
        do {
            guard let replacement = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
                let resource = PHAssetResource.assetResources(for: replacement).first
            else {
                throw CleanupError.message(String(localized: "Cannot verify the new Photos asset. The original was kept."))
            }
            let digest = try await Self.read(resource, output: nil)
            guard try FingerprintService.fullHash(for: sourceURL) == digest.1 else {
                throw CleanupError.message(String(localized: "The Photos import did not verify. Both assets were kept."))
            }
        } catch { throw PhotosReplacementError(replacementID: id, reason: error.localizedDescription) }
        return id
    }
}

extension PhotoLibraryService {
    private static func mapAuthorizationStatus(_ status: PHAuthorizationStatus) -> PhotoAuthorizationState {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    private static func buildItem(from asset: PHAsset) async -> ReviewItem? {
        guard asset.mediaType == .image || asset.mediaType == .video else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let primaryName = resources.first?.originalFilename
        var item = ReviewItem(
            id: "photos:" + asset.localIdentifier, source: .photos(asset.localIdentifier),
            name: primaryName ?? String(localized: "Photos asset"),
            kind: asset.mediaType == .video ? .video : .image, bytes: 0)
        item.createdAt = asset.creationDate
        item.modifiedAt = asset.modificationDate
        item.isFavorite = asset.isFavorite
        item.isBurstPick = asset.burstSelectionTypes.contains(.userPick) || asset.burstSelectionTypes.contains(.autoPick)
        item.isHEIC = isHEICAsset(resources: resources, filename: primaryName)
        item.facts.width = asset.pixelWidth
        item.facts.height = asset.pixelHeight
        item.facts.duration = asset.mediaType == .video ? asset.duration : nil
        item.facts.capturedAt = asset.creationDate
        item.facts.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        item.facts.isScreenRecording = asset.mediaSubtypes.contains(.videoScreenRecording)
            || resources.contains { $0.originalFilename.uppercased().hasPrefix("RPREPLAY_FINAL") }
        item.facts.burstIdentifier = asset.burstIdentifier
        item.facts.savedFromApp = detectSavedFromApp(asset: asset, filename: primaryName)
        var allLocal = !resources.isEmpty
        for resource in resources {
            let byteSize = resourceByteSize(resource)
            if await !checkLocallyAvailable(resource, knownBytes: byteSize) { allLocal = false }
            item.bytes += byteSize
            item.resources.append(
                PhotoResource(
                    name: resource.originalFilename, type: resource.type.rawValue,
                    uniformType: resource.uniformTypeIdentifier, bytes: byteSize))
        }
        item.isDownloaded = allLocal
        return item
    }

    private static func hashResources(of asset: PHAsset, into item: ReviewItem) async throws -> ReviewItem {
        let phResources = PHAssetResource.assetResources(for: asset)
        var updated = item
        var allLocal = true
        for index in updated.resources.indices {
            try Task.checkCancellation()
            guard updated.resources[index].hash == nil,
                let resource = matchResource(updated.resources[index], at: index, in: phResources)
            else { continue }
            do {
                let digest = try await read(resource, output: nil)
                updated.resources[index].bytes = digest.0
                updated.resources[index].hash = digest.1
            } catch is CancellationError { throw CancellationError() } catch { allLocal = false }
        }
        if !allLocal { updated.isDownloaded = false }
        let total = updated.resources.reduce(Int64(0)) { $0 + $1.bytes }
        if total > 0 { updated.bytes = total }
        return updated
    }

    private static func matchResource(
        _ descriptor: PhotoResource, at index: Int, in resources: [PHAssetResource]
    ) -> PHAssetResource? {
        if resources.indices.contains(index), resources[index].type.rawValue == descriptor.type,
            resources[index].originalFilename == descriptor.name { return resources[index] }
        return resources.first { $0.type.rawValue == descriptor.type && $0.originalFilename == descriptor.name }
    }

    private static func resourceByteSize(_ resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")),
            let size = resource.value(forKey: "fileSize") as? Int64 else { return 0 }
        return max(0, size)
    }

    private static func checkLocallyAvailable(_ resource: PHAssetResource, knownBytes: Int64) async -> Bool {
        if resource.responds(to: NSSelectorFromString("locallyAvailable")),
            let local = resource.value(forKey: "locallyAvailable") as? Bool { return local }
        if knownBytes > 0 { return true }
        let flag = OSAllocatedUnfairLock(initialState: (done: false, requestID: PHAssetResourceDataRequestID(0)))
        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                guard !data.isEmpty else { return }
                let (resume, reqID) = flag.withLock { state -> (Bool, PHAssetResourceDataRequestID) in
                    guard !state.done else { return (false, 0) }
                    state.done = true
                    return (true, state.requestID)
                }
                if resume {
                    if reqID != 0 { PHAssetResourceManager.default().cancelDataRequest(reqID) }
                    continuation.resume(returning: true)
                }
            } completionHandler: { error in
                if flag.withLock({ let wasDone = $0.done; $0.done = true; return !wasDone }) {
                    continuation.resume(returning: error == nil)
                }
            }
            if flag.withLock({ $0.requestID = id; return $0.done }) {
                PHAssetResourceManager.default().cancelDataRequest(id)
            }
        }
    }

    private static func isHEICAsset(resources: [PHAssetResource], filename: String?) -> Bool {
        let primary = resources.first { $0.type == .fullSizePhoto } ?? resources.first { $0.type == .photo } ?? resources.first
        if let uti = primary?.uniformTypeIdentifier, [UTType.heic.identifier, UTType.heif.identifier].contains(uti) {
            return true
        }
        guard let name = (primary?.originalFilename ?? filename)?.lowercased() else { return false }
        return name.hasSuffix(".heic") || name.hasSuffix(".heif")
    }

    private static func detectSavedFromApp(asset: PHAsset, filename: String?) -> String? {
        guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return nil }
        let upper = (filename ?? "").uppercased()
        let isCameraName = ["IMG_", "DSC", "DSCF", "DJI_", "GOPR", "PXL_", "MVIMG"].contains { upper.hasPrefix($0) }
            || upper.hasSuffix(".DNG")
        let hasCameraMarkers = asset.mediaSubtypes.contains(.photoHDR)
            || asset.mediaSubtypes.contains(.photoDepthEffect)
            || asset.mediaSubtypes.contains(.photoLive) || asset.location != nil
        guard !isCameraName, !hasCameraMarkers else { return nil }
        return SavedFromAppMarkers.appName(for: filename)
    }

    private static func replacementFilename(for item: ReviewItem, outputURL: URL, kind: MediaKind) -> String {
        let stem = ((item.resources.first?.name ?? item.name) as NSString).deletingPathExtension
        let ext = outputURL.pathExtension.isEmpty ? (kind == .video ? "mp4" : "heic") : outputURL.pathExtension
        return "\(stem.isEmpty ? "compressed" : stem).\(ext)"
    }

    private static func orientedCGImage(from image: NSImage) -> CGImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let targetSize = image.size
        guard targetSize.width > 0, targetSize.height > 0,
            (targetSize.width > targetSize.height) != (cgImage.width > cgImage.height) else { return cgImage }
        let (width, height) = (cgImage.height, cgImage.width)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return cgImage }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage() ?? cgImage
    }

    private static func read(
        _ resource: PHAssetResource, output: URL?, allowsNetwork: Bool = false,
        progressHandler: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> (Int64, String) {
        let transfer = try PhotoTransfer(output: output)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = allowsNetwork
                if let progressHandler { options.progressHandler = { fraction in Task { await progressHandler(fraction) } } }
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) {
                    transfer.receive($0)
                } completionHandler: { error in
                    do {
                        let result = try transfer.finish()
                        if let error { throw error }
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
                transfer.setRequest(id)
            }
        } onCancel: { transfer.cancel() }
    }
}

private final class PhotoReplacementID: @unchecked Sendable { var value: String? }
