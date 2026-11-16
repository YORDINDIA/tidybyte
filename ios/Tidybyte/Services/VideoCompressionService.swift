import AVFoundation
import Photos
import UIKit

struct CompressionPreset: Identifiable, Sendable {
    let id: String
    /// The resolution ("1080p", "720p") is a technical name, not a word, so it
    /// stays as-is in every language. Only `description` is prose.
    let label: String
    let preset: String
    let description: String
    let targetLongestEdge: Int
    let estimatedBitrate: Int64

    /// A computed property, not a `static let`.
    ///
    /// This matters for localization: a `static let` array is built once on
    /// first access and cached for the life of the process, so it would keep
    /// serving the launch-time language forever after a switch. Rebuilding
    /// three small structs per access is free.
    static var presets: [CompressionPreset] {
        [
            CompressionPreset(id: "1080p", label: "1080p HD", preset: AVAssetExportPreset1920x1080,
                              description: L10n.string("Good quality, moderate savings"),
                              targetLongestEdge: 1920, estimatedBitrate: 8_000_000),
            CompressionPreset(id: "720p", label: "720p", preset: AVAssetExportPreset1280x720,
                              description: L10n.string("Decent quality, major savings"),
                              targetLongestEdge: 1280, estimatedBitrate: 4_000_000),
            CompressionPreset(id: "480p", label: "480p", preset: AVAssetExportPreset640x480,
                              description: L10n.string("Lower quality, maximum savings"),
                              targetLongestEdge: 640, estimatedBitrate: 2_000_000)
        ]
    }


}

struct CompressionResult: Sendable {
    let originalSize: Int64
    let compressedSize: Int64
    let replacementAssetIdentifier: String?
    /// True when compression would not have saved space, so the original was
    /// left untouched and no replacement was created.
    let skipped: Bool
}

/// Outcome counts for one compression batch, surfaced after the loop so the UI
/// can present a single summary (rather than an alert popping per failed item
/// mid-batch — COMP-11).
struct CompressionBatchSummary: Sendable, Equatable {
    let completed: Int
    let failed: Int
    let skipped: Int
    let cancelled: Bool
}

enum CompressionState: Sendable {
    case waiting
    case exporting(Float)
    /// Step 1 done: the new copy is saved. The original is deleted in step 2,
    /// with the rest of the batch.
    case copySaved
    case completed(savedBytes: Int64)
    /// The item was intentionally left untouched (no savings, unknown size,
    /// or already compressed previously) and stays in the list so the user
    /// can see why (COMP-04, COMP-07, COMP-16).
    case keptOriginal(reason: String)
    case failed(String)
}

/// Deterministic batch order: descending file size (matching the on-screen
/// sorted list), ties broken by local identifier. `Set` iteration alone is
/// nondeterministic, which made per-item progress flicker between runs
/// (COMP-12).
func sortedBatchIds(selected: Set<String>, fileSizes: [String: Int64]) -> [String] {
    selected.sorted { lhs, rhs in
        let lhsSize = fileSizes[lhs] ?? 0
        let rhsSize = fileSizes[rhs] ?? 0
        if lhsSize != rhsSize { return lhsSize > rhsSize }
        return lhs < rhs
    }
}

actor VideoCompressionService {
    private let photoService: PhotoLibraryService

    init(photoService: PhotoLibraryService) {
        self.photoService = photoService
    }

    // MARK: - Preset Selection

    /// Picks the export preset for an asset without ever upscaling (COMP-10):
    /// when the source's longest edge is smaller than the selected preset's
    /// target, falls back to the largest preset that still fits — down to the
    /// smallest (480p) for sub-640p sources. Exporting with a preset larger
    /// than the source both wastes space and can fail outright on sub-1080p
    /// sources, which was the default first-run experience.
    static func effectivePreset(for asset: AssetSummary, selected: CompressionPreset) -> CompressionPreset {
        let longestEdge = max(asset.pixelWidth, asset.pixelHeight)
        guard let selectedRank = CompressionPreset.presets.firstIndex(where: { $0.id == selected.id }) else {
            // Unknown/custom preset — the caller chose it explicitly.
            return selected
        }
        // `presets` is ordered largest → smallest; walk from the selected one
        // downward in size until a target fits the source.
        for rank in selectedRank..<CompressionPreset.presets.count {
            let candidate = CompressionPreset.presets[rank]
            if longestEdge >= candidate.targetLongestEdge {
                return candidate
            }
        }
        // Source smaller than every preset (or dimensions unknown): fall back
        // to the smallest preset rather than failing the export.
        return CompressionPreset.presets[CompressionPreset.presets.count - 1]
    }

    // MARK: - Compress Video

    func compressVideo(
        assetId: String,
        preset: CompressionPreset,
        onSaveWillCommit: (@MainActor @Sendable () -> Void)? = nil,
        onReplacementSaved: (@MainActor @Sendable (String, Int64) -> Void)? = nil,
        onProgress: @escaping @MainActor @Sendable (Float) -> Void
    ) async throws -> CompressionResult {
        guard let phAsset = photoService.getPHAsset(for: assetId) else {
            throw CompressionError.assetNotFound
        }

        let originalSize = getFileSize(for: phAsset)
        guard originalSize > 0 else {
            // A size of 0 means PhotoKit reported no size. Compressing would
            // make the "does this save space?" check meaningless and could
            // delete a large original in exchange for a 0-byte history record,
            // so skip instead (COMP-07).
            throw CompressionError.sizeUnknown
        }

        let load = await loadAVAsset(from: phAsset)
        if let error = Self.loadError(for: load) { throw error }
        guard case .loaded(let avAssetBox) = load else { throw CompressionError.videoLoadTimedOut }
        let avAsset = avAssetBox.value

        // Export to a temp file; guarantee it is removed on every exit path.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: preset.preset) else {
            throw CompressionError.exportSessionCreationFailed
        }

        // Setting an unsupported outputFileType raises an Objective-C exception, which is a crash.
        guard exportSession.supportedFileTypes.contains(.mp4) else {
            throw CompressionError.exportSessionCreationFailed
        }
        exportSession.outputURL = tempURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        // Poll progress on a background-priority task that is always cancelled on scope exit.
        // AVAssetExportSession isn't Sendable, but reading `.progress` while the export
        // runs is the documented, thread-safe polling pattern (pre-iOS 18). Box it so the
        // capture across the isolation boundary is explicit rather than an unchecked leak.
        let sessionBox = UncheckedSendableBox(exportSession)
        let progressTask = Task(priority: .utility) {
            var lastSent: Float = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let p = sessionBox.value.progress
                // Guard: only hop to the main actor when progress moved
                // meaningfully (or finished) — every tick used to do a
                // firstIndex + @Observable publish, churning the main thread
                // for minutes during long encodes.
                if abs(p - lastSent) >= 0.02 || p >= 1.0 {
                    lastSent = p
                    await onProgress(p)
                }
            }
        }
        defer { progressTask.cancel() }

        // D4: task cancellation now actually stops the in-flight encode —
        // previously `cancelExport()` was never called, so "Cancel" let the
        // export run to completion (minutes for long videos) before the batch
        // loop noticed. `cancelExport` is documented thread-safe and is the
        // intended cross-thread stop.
        try await withTaskCancellationHandler {
            await exportSession.export()
        } onCancel: {
            exportSession.cancelExport()
        }

        guard exportSession.status == .completed else {
            // A cancelled export surfaces as a failed status with no error —
            // map it to the typed cancelled case so the batch summary counts
            // it correctly instead of reporting an export failure (D4).
            if Task.isCancelled || exportSession.status == .cancelled {
                throw CompressionError.cancelled
            }
            guard let error = exportSession.error as NSError? else {
                throw CompressionError.exportFailed(L10n.string("Unknown error"))
            }
            AppLog.compression.error("Export failed: \(String(describing: error), privacy: .public)")
            throw Self.exportFailure(for: error)
        }

        // Verify the exported file exists and is non-empty before trusting it.
        let compressedSize: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            compressedSize = (attrs[.size] as? Int64) ?? 0
        } catch {
            throw CompressionError.fileSizeReadFailed
        }
        guard compressedSize > 0 else {
            throw CompressionError.exportFailed(L10n.string("Exported file was empty."))
        }

        // Respect batch cancellation: once the user cancels, stop before
        // replacing anything so no half-finished swap happens (COMP-08).
        guard !Task.isCancelled else {
            throw CompressionError.cancelled
        }

        // If compression wouldn't actually save space, keep the original untouched.
        guard compressedSize < originalSize else {
            AppLog.compression.info("No savings compressing \(assetId, privacy: .public); keeping original")
            return CompressionResult(
                originalSize: originalSize,
                compressedSize: originalSize,
                replacementAssetIdentifier: nil,
                skipped: true
            )
        }

        // Capture album membership so the replacement joins the same albums.
        let albumIdentifiers = await photoService.userAlbumIdentifiers(containing: assetId)

        // Save the compressed video, preserving the original's
        // date/location/favorite/hidden state. Burst membership cannot be
        // carried over — there is no creation-request API for it (COMP-17).
        //
        // D1: tell the journal a library write is about to begin. This is the
        // last moment the row can be written before a copy could exist without
        // its id being recorded — reconcile needs it to tell a crash here apart
        // from a crash during the export (which strands nothing).
        await onSaveWillCommit?()
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempURL)
            request?.creationDate = phAsset.creationDate
            request?.location = phAsset.location
            request?.isFavorite = phAsset.isFavorite
            request?.isHidden = phAsset.isHidden
            placeholder = request?.placeholderForCreatedAsset
        }

        guard let replacementId = placeholder?.localIdentifier else {
            throw CompressionError.exportFailed(L10n.string("Failed to save compressed video to library."))
        }
        // D1: report the durable new copy to the journal immediately, with the
        // real exported size so the journal never has to guess at 0.
        await onReplacementSaved?(replacementId, compressedSize)

        // A cancel that lands after this point keeps the saved copy: the
        // batch still offers it in the single delete-originals commit.

        // Restore album membership on the replacement (best effort).
        for albumId in albumIdentifiers {
            do {
                try await photoService.addToAlbum(assetIdentifiers: [replacementId], albumIdentifier: albumId)
            } catch {
                AppLog.photo.error("Failed to restore album \(albumId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // The original is NOT deleted here. The batch deletes every original
        // in one `OriginalsCommit.commit` call after all copies are saved, so
        // the user sees one iOS prompt per batch instead of one per video.
        return CompressionResult(
            originalSize: originalSize,
            compressedSize: compressedSize,
            replacementAssetIdentifier: replacementId,
            skipped: false
        )
    }

    // MARK: - Helpers

    /// What `loadAVAsset` reports. The cases are kept apart so the user sees
    /// why a load failed: a timeout, a PhotoKit error and a cancel need
    /// different text.
    enum AssetLoad: Sendable {
        case loaded(UncheckedSendableBox<AVAsset>)
        case timedOut
        case failed(String)
        case cancelled
    }

    /// The error a failed load reports, or nil when the asset loaded.
    static func loadError(for load: AssetLoad) -> CompressionError? {
        switch load {
        case .loaded: nil
        case .timedOut: .videoLoadTimedOut
        case .failed(let detail): .assetLoadFailed(detail)
        case .cancelled: .cancelled
        }
    }

    /// Maps a failed export to its error. An interrupted export means the app
    /// left the foreground mid-encode (AVError -11847), so the message says
    /// what to do instead of quoting AVFoundation.
    static func exportFailure(for error: NSError) -> CompressionError {
        if error.domain == AVFoundationErrorDomain,
           error.code == AVError.Code.operationInterrupted.rawValue {
            return .exportInterrupted
        }
        // Domain and code in the text: AVFoundation's sentence is often
        // generic, and the row text is the only thing a reporter can send.
        return .exportFailed("\(error.localizedDescription) (\(error.domain) \(error.code))")
    }

    /// Loads the asset's `AVAsset`. The load fails after `LoadStall.limit`
    /// seconds with no progress, not after a fixed time, so a slow iCloud
    /// download that keeps moving completes and a stalled one still fails
    /// (COMP-03). Reports the PhotoKit error detail when the request fails,
    /// instead of folding it into the timeout.
    private func loadAVAsset(from phAsset: PHAsset) async -> AssetLoad {
        await withCheckedContinuation { (continuation: CheckedContinuation<AssetLoad, Never>) in
            let resumer = ContinuationResumer<AssetLoad>(continuation)
            let stall = StallWatch()

            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            // Each progress tick moves the stall deadline. Runs on an arbitrary queue.
            options.progressHandler = { _, _, _, _ in
                let at = LoadStall.now()
                Task { await stall.recordProgress(at: at) }
            }

            // Wire the timeout + cleanup hook BEFORE issuing the request so a
            // synchronously-delivered callback still cancels the timeout Task
            // (otherwise it lingers, orphaned, for the full timeout).
            let manager = PHImageManager.default()
            var requestID: PHImageRequestID = PHInvalidImageRequestID
            let timeoutTask = watchForStall(stall) { resumer.resume(.timedOut) }
            resumer.onResume = {
                manager.cancelImageRequest(requestID)
                timeoutTask.cancel()
            }

            requestID = manager.requestAVAsset(
                forVideo: phAsset,
                options: options
            ) { avAsset, _, info in
                // Our own timeout cancels the request, which calls back here.
                // The resumer ignores that second resume.
                if let avAsset {
                    resumer.resume(.loaded(UncheckedSendableBox(avAsset)))
                } else if let error = info?[PHImageErrorKey] as? NSError {
                    AppLog.compression.error("Video load request failed: \(String(describing: error), privacy: .public)")
                    resumer.resume(.failed("\(error.localizedDescription) (\(error.domain) \(error.code))"))
                } else if info?[PHImageCancelledKey] as? Bool == true {
                    resumer.resume(.cancelled)
                } else {
                    resumer.resume(.failed(L10n.string("Unknown error")))
                }
            }
        }
    }

    private func getFileSize(for asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        for resource in resources {
            if resource.responds(to: NSSelectorFromString("fileSize")),
               let size = resource.value(forKey: "fileSize") as? Int64 {
                total += size
            }
        }
        return total
    }
}

enum CompressionError: LocalizedError {
    case assetNotFound
    case videoLoadTimedOut
    case sizeUnknown
    case cancelled
    case exportSessionCreationFailed
    case exportFailed(String)
    case fileSizeReadFailed
    case assetLoadFailed(String)
    /// AVFoundation stopped the export because the app left the foreground (-11847).
    case exportInterrupted

    var errorDescription: String? {
        // User-facing: the compression tool shows these in its error banner.
        switch self {
        case .assetNotFound: L10n.string("Video not found.")
        case .videoLoadTimedOut: L10n.string("Couldn't load the video (it may still be in iCloud). Please try again.")
        case .sizeUnknown: L10n.string("Video size unknown (iCloud-only) — skipped.")
        case .cancelled: L10n.string("Cancelled.")
        case .exportSessionCreationFailed: L10n.string("Failed to create export session.")
        case .exportFailed(let msg): L10n.format("Export failed: %@", msg)
        case .fileSizeReadFailed: L10n.string("Failed to read file size.")
        case .assetLoadFailed(let msg): L10n.format("Couldn't load the video: %@", msg)
        case .exportInterrupted: L10n.string("TidyByte stopped compression because it left the foreground. Keep TidyByte open while it compresses, then try again.")
        }
    }
}
