import AVFoundation
import CryptoKit
import os
import Photos
import UIKit

enum SwipeFilter: Sendable, Hashable {
    case allMedia
    case allMediaBefore(date: Date)
    case notInAnyAlbum
    case specificAlbum(id: String)
    case notSwipedYet
    case screenshots
    case worstShots
    /// Unreviewed items, biggest file first. Needs every file size, so on a
    /// cold cache it waits for a full library read.
    case largestFirst
    /// An explicit list, in the order the deck shows it (a tool's sort).
    case customAssetIds([String])
}

actor PhotoLibraryService {

    /// Single app-wide instance (A11). Every view/view model used to construct
    /// its own service, each owning a private `PHCachingImageManager` — that
    /// fragmented the image cache across instances and multiplied actors.
    /// One instance means one shared prefetch cache.
    static let shared = PhotoLibraryService()
    nonisolated static let shareExportFolderPrefix = "ShareExport-"

    private let imageManager = PHCachingImageManager()
    private let summaryBuilder = SummaryBuilder()
    private var changeObserverHelper: PhotoLibraryChangeObserverHelper?

    /// Baseline for incremental change details (SHARED-08): the broadest
    /// recent fetch result, so `handleLibraryChange` can evict exactly the
    /// removed/changed asset ids instead of purging the whole image cache.
    /// `PHFetchResult` is a lazy snapshot — retaining it is cheap.
    private var changeBaselineFetch: PHFetchResult<PHAsset>?
    /// True when `changeBaselineFetch` is a whole-library fetch. Only then
    /// does nil change details mean that no asset changed.
    private var changeBaselineIsFullLibrary = false

    // Called when the photo library changes — consumers can listen via this callback
    private var onLibraryChange: (@Sendable () -> Void)?

    init() {
        imageManager.allowsCachingHighQualityImages = true
    }

    deinit {
        // Ensure we never leave a dangling change observer registered with the
        // shared photo library if the service is deallocated.
        if let helper = changeObserverHelper {
            PHPhotoLibrary.shared().unregisterChangeObserver(helper)
        }
    }

    // MARK: - Change Observation

    func startObservingChanges(onChange: @escaping @Sendable () -> Void) {
        guard changeObserverHelper == nil else { return }
        self.onLibraryChange = onChange
        let helper = PhotoLibraryChangeObserverHelper { [weak self] box in
            Task { [weak self] in
                await self?.handleLibraryChange(box.change)
            }
        }
        self.changeObserverHelper = helper
        PHPhotoLibrary.shared().register(helper)
    }

    /// Keeps `ImageCache` and the resource reads coherent with the library
    /// (SHARED-08): evicts exactly the assets PhotoKit reports as removed or
    /// changed, so an in-app delete of N photos no longer re-decodes the other
    /// ~200 cached thumbnails. Without incremental details (no baseline yet, a
    /// non-incremental change) the thumbnails go, because stale thumbnails are
    /// worse than re-decode churn; the resource reads stay (see
    /// `ResourceCache.apply`). A change that does not touch the library list
    /// (nil details, such as an album edit) evicts nothing.
    private func handleLibraryChange(_ change: PHChange) async {
        var answer: LibraryChangeEffect.Details?
        var detail = ""
        if let baseline = changeBaselineFetch, let details = change.changeDetails(for: baseline) {
            // Advance the baseline on every answered change, incremental or not, so
            // the NEXT change diffs against current state. Left stale after a
            // non-incremental change, every later change diffed against an old
            // snapshot and purged the whole image cache.
            changeBaselineFetch = details.fetchResultAfterChanges
            answer = LibraryChangeEffect.Details(
                isIncremental: details.hasIncrementalChanges,
                removedOrChanged: (details.removedObjects + details.changedObjects).map(\.localIdentifier)
            )
            if details.hasIncrementalChanges {
                detail = " removed=\(details.removedObjects.count) changed=\(details.changedObjects.count) inserted=\(details.insertedObjects.count)"
            }
        }
        let effect = LibraryChangeEffect(
            baselineIsFullLibrary: changeBaselineFetch == nil ? nil : changeBaselineIsFullLibrary,
            details: answer
        )
        AppLog.photo.info("Library change: \(effect.logName, privacy: .public)\(detail, privacy: .public)")
        summaryBuilder.resources.apply(effect)
        switch effect {
        case .unaffected:
            break
        case .assets(let ids):
            for id in ids { await ImageCache.shared.removeAllVariants(of: id) }
        case .unknown:
            // Thumbnails are cached by id alone, with no modification date to
            // tell an edited asset apart, so these do go.
            await ImageCache.shared.removeAll()
        }
        onLibraryChange?()
    }

    /// Drops every cached resource read, so the next library build reads
    /// every asset again. For permission changes.
    /// Isolated so it can't fall between a fetch and its stamp.
    func discardCachedResources() {
        summaryBuilder.resources.removeAll()
    }

    /// Pull-to-refresh: every cached read is due again, and builds refresh
    /// them a slice at a time. Dropping them instead made each pull read the
    /// whole library again, about a minute and a half for 27,000 items.
    func refreshCachedResources() async {
        summaryBuilder.resources.markAllStale()
        await summaryBuilder.requestRefresh()
    }

    /// Writes the cached reads now. For the move to the background, where iOS
    /// may end the app before the next build saves them.
    nonisolated func saveCachedResources() {
        summaryBuilder.resources.saveIfDirty()
    }

    /// Reading an original can download it from iCloud, which changes its
    /// resources without a library change. Called whether or not the read
    /// succeeded: a failed or timed-out request may still have downloaded.
    private func forgetResources(of assetId: String) {
        summaryBuilder.resources.remove([assetId])
    }

    /// Records a fetch result as the change-details baseline. Keeps the
    /// broadest recent fetch: narrow fetches (a preview sheet's handful of
    /// ids, the screenshots-only census) must not displace a full-library
    /// snapshot, or deletions outside their membership would go unreported
    /// and leave stale thumbnails behind. Called from the `extractSummaries`
    /// funnel so every census-style fetch participates.
    private func retainChangeBaseline(_ fetchResult: PHFetchResult<PHAsset>, isFullLibrary: Bool) {
        if changeBaselineIsFullLibrary, !isFullLibrary { return }
        if !isFullLibrary, let current = changeBaselineFetch, current.count > fetchResult.count { return }
        changeBaselineFetch = fetchResult
        changeBaselineIsFullLibrary = isFullLibrary
    }

    /// The ids from `ids` that still exist in the library. Lists use it to drop
    /// items deleted elsewhere (Swipe Review, the Photos app) without a rescan.
    /// Actor-isolated (not static): the PhotoKit fetch + enumeration runs on
    /// this service's executor, never synchronously on the caller's (main) actor.
    func existingIds(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var present = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: allAssetsFetchOptions())
            .enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        return present
    }

    // MARK: - Album Fetching

    /// - Parameter editableOnly: true for "Add to Album". System smart albums
    ///   (Favorites, Recents, Screenshots…) and shared or synced albums
    ///   cannot take new photos, so listing them only produced errors.
    func fetchUserAlbums(editableOnly: Bool = false) -> [AlbumInfo] {
        var albums: [AlbumInfo] = []

        // Smart albums (Favorites, Recents, etc.)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        for index in 0..<(editableOnly ? 0 : smartAlbums.count) {
            let collection = smartAlbums.object(at: index)
            // Single fetch per album: newest-first ordering gives both the
            // count and the thumbnail id (previously two fetches per album).
            let (count, thumbnailId) = Self.countAndNewestId(in: collection)
            // Smart albums with zero assets are system noise ("Recently
            // Added" before any import, etc.) — still skipped. User albums
            // below are kept even when empty: a newly created album must be
            // visible in the pickers or it can never receive anything (A6).
            guard count > 0 else { continue }
            albums.append(AlbumInfo(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? L10n.string("Untitled"),
                count: count,
                type: .smartAlbum,
                thumbnailAssetId: thumbnailId
            ))
        }

        // User-created albums — including empty ones.
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        for index in 0..<userAlbums.count {
            let collection = userAlbums.object(at: index)
            if editableOnly, !collection.canPerform(.addContent) { continue }
            let (count, thumbnailId) = Self.countAndNewestId(in: collection)
            albums.append(AlbumInfo(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? L10n.string("Untitled"),
                count: count,
                type: .userAlbum,
                thumbnailAssetId: thumbnailId
            ))
        }

        // Smart albums first, then user albums, both sorted alphabetically
        let smart = albums.filter { $0.type == .smartAlbum }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let user = albums.filter { $0.type == .userAlbum }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return smart + user
    }

    /// One PhotoKit fetch per album returning both the asset count and the
    /// newest asset's id (for thumbnails).
    nonisolated private static func countAndNewestId(in collection: PHAssetCollection) -> (Int, String?) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(in: collection, options: options)
        return (fetched.count, fetched.firstObject?.localIdentifier)
    }

    // MARK: - Asset Fetching

    /// How many assets this process can currently see, unfiltered — one
    /// `PHAsset` count with no summaries, resource reads, or image work, so it
    /// is cheap enough to ask whenever a deck comes out empty.
    ///
    /// It is the only way to tell "this filter ran out of photos" from "the
    /// library is invisible to us". Those look identical downstream, and the
    /// second one (limited access with nothing shared, or a device-side
    /// permission glitch under full access) used to be drawn as "All Caught
    /// Up!" — the app blaming the library for a permission problem (SWIPE-09).
    func totalAssetCount() -> Int {
        let count = PHAsset.fetchAssets(with: allAssetsFetchOptions()).count
        if count == 0 {
            // Worth a release-build log line: an empty census for an app that
            // believes it has access is exactly the report this exists for, and
            // the two PhotoKit statuses are not always the same value.
            let readWrite = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
            let addOnly = PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue
            AppLog.photo.notice(
                "Library census returned 0 assets (readWrite=\(readWrite, privacy: .public) addOnly=\(addOnly, privacy: .public))"
            )
        }
        return count
    }

    /// Fetch order only: `SwipeSessionViewModel` applies the Largest First
    /// size order and the custom-list order.
    func fetchAssets(filter: SwipeFilter) async -> [AssetSummary] {
        guard let query = query(for: filter) else { return [] }
        let isFullLibrary = filter == .allMedia || filter == .largestFirst
        return await extractSummaries(from: query.assets, excluding: query.excluding, isFullLibrary: isFullLibrary)
    }

    /// The PhotoKit fetch behind each filter, plus the ids the filter drops
    /// after fetching. Nil when the filter's album no longer exists.
    nonisolated private func query(for filter: SwipeFilter) -> (assets: PHFetchResult<PHAsset>, excluding: Set<String>)? {
        switch filter {
        case .allMedia, .largestFirst:
            return (PHAsset.fetchAssets(with: allAssetsFetchOptions()), [])

        case .allMediaBefore(let cutoffDate):
            // Same options (and therefore ordering) as All Media, narrowed to
            // media created on or before the user's chosen starting position.
            let options = allAssetsFetchOptions()
            options.predicate = NSPredicate(format: "creationDate <= %@", cutoffDate as NSDate)
            return (PHAsset.fetchAssets(with: options), [])

        case .notInAnyAlbum:
            let allAssets = PHAsset.fetchAssets(with: allAssetsFetchOptions())
            return (allAssets, collectAssetsInUserAlbums())

        case .specificAlbum(let albumId):
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumId], options: nil
            ).firstObject else {
                return nil
            }
            return (PHAsset.fetchAssets(in: collection, options: allAssetsFetchOptions()), [])

        case .notSwipedYet:
            // Swipe history lives in SwiftData, not PhotoKit — the session view
            // model filters it out after the fetch.
            return (PHAsset.fetchAssets(with: allAssetsFetchOptions()), [])

        case .worstShots:
            // Same fetch as `fetchAllPhotos()`.
            let options = allAssetsFetchOptions()
            options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
            return (PHAsset.fetchAssets(with: options), [])

        case .screenshots:
            let options = allAssetsFetchOptions()
            options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
            return (PHAsset.fetchAssets(with: options), [])

        case .customAssetIds(let ids):
            return (PHAsset.fetchAssets(withLocalIdentifiers: ids, options: allAssetsFetchOptions()), [])
        }
    }

    // MARK: - Swipe Deck

    /// One summary per asset for a swipe deck, without reading any asset's
    /// resources. Resources (file size, filename, iCloud state) cost a Photos
    /// database round trip per asset, so a deck that read them for the whole
    /// library kept its first card waiting for minutes on a large library.
    /// Those fields are left at their "unknown" values here (no file size, no
    /// filename, locally available, origin guessed without a filename);
    /// `fetchSummaries(for:)` fills them in for the cards about to be shown.
    ///
    /// Nonisolated so a deck never queues behind a library-wide scan on this
    /// actor. It does not retain a change baseline; the full scans keep one.
    nonisolated func fetchDeckListing(filter: SwipeFilter) async -> [AssetSummary] {
        guard let query = query(for: filter) else { return [] }
        return Self.buildSummaries(from: query.assets, excluding: query.excluding) { _ in .unread }
    }

    /// Complete summaries for `ids`, keyed by id. Ids that are no longer in
    /// the library are absent. Reads each asset's resources, so keep it off
    /// the main actor for anything more than the few cards on screen.
    nonisolated func fetchSummaries(for ids: [String]) -> [String: AssetSummary] {
        guard !ids.isEmpty else { return [:] }
        var summaries: [String: AssetSummary] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: allAssetsFetchOptions()).enumerateObjects { asset, _, _ in
            summaries[asset.localIdentifier] = Self.makeSummary(from: asset)
        }
        return summaries
    }

    func fetchAssetsByMediaType(_ mediaType: PHAssetMediaType) async -> [AssetSummary] {
        let options = allAssetsFetchOptions()
        options.predicate = NSPredicate(format: "mediaType = %d", mediaType.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        return await extractSummaries(from: result)
    }

    nonisolated static func isScreenRecordingFilename(_ filename: String) -> Bool {
        let name = filename.uppercased()
        return name.hasPrefix("RPREPLAY_FINAL") && name.hasSuffix(".MP4")
    }

    /// Album membership only: badge counts do not need resource sizes or filenames.
    func assetIDs(inAlbums albumIDs: Set<String>) -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        var ids = Set<String>()
        let options = allAssetsFetchOptions()
        let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(albumIDs), options: nil)
        albums.enumerateObjects { album, _, _ in
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                ids.insert(asset.localIdentifier)
            }
        }
        return ids
    }

    /// Prune a scan using only identifiers and modification dates, without reading resources.
    func unchangedAssetIDs(_ scanned: [AssetSummary]) -> Set<String> {
        guard !scanned.isEmpty else { return [] }
        let byID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = PHAsset.fetchAssets(withLocalIdentifiers: Array(byID.keys), options: allAssetsFetchOptions())
        var unchanged = Set<String>()
        current.enumerateObjects { asset, _, _ in
            if let previous = byID[asset.localIdentifier], previous.modificationDate == asset.modificationDate {
                unchanged.insert(asset.localIdentifier)
            }
        }
        return unchanged
    }

    func fetchScreenshots() async -> [AssetSummary] {
        let options = allAssetsFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        return await extractSummaries(from: result)
    }

    func fetchLivePhotos() async -> [AssetSummary] {
        let options = allAssetsFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        return await extractSummaries(from: result)
    }

    /// Groups burst frames by `burstIdentifier` alone and drops single-frame
    /// "bursts". Apple's docs are ambiguous about whether `representsBurst` is
    /// set on every frame (vs. only the representative), so requiring it made
    /// the tool silently empty on some devices (LF-03). Frames are sorted by
    /// creation date within each group.
    func fetchBurstPhotos() async -> [String: [AssetSummary]] {
        let allAssets = PHAsset.fetchAssets(with: allAssetsFetchOptions())

        // Only the burst frames' summaries are needed; they are built on
        // `summaryBuilder` like every other scan, so the frames' resource
        // reads don't hold up image requests.
        var frameIds: [String] = []
        for index in 0..<allAssets.count {
            if index % 20 == 0 { await Task.yield() }
            let asset = allAssets.object(at: index)
            if asset.burstIdentifier != nil {
                frameIds.append(asset.localIdentifier)
            }
        }
        let frames = PHAsset.fetchAssets(withLocalIdentifiers: frameIds, options: allAssetsFetchOptions())
        var groups: [String: [AssetSummary]] = [:]
        for summary in await extractSummaries(from: frames, sort: false) {
            if let burstId = summary.burstIdentifier {
                groups[burstId, default: []].append(summary)
            }
        }
        for key in groups.keys {
            groups[key]?.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
        return groups.filter { $0.value.count > 1 }
    }

    /// Photos taken on or before `cutoff` that are neither screenshots nor
    /// favorites: the Text Photos scan. PhotoKit applies the predicate, so
    /// resources are read only for these photos, not the whole library.
    func fetchTextPhotoCandidates(takenOnOrBefore cutoff: Date) async -> [AssetSummary] {
        let options = allAssetsFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType = %d AND creationDate <= %@ AND favorite == NO AND (mediaSubtypes & %d) == 0",
            PHAssetMediaType.image.rawValue,
            cutoff as NSDate,
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        return await extractSummaries(from: PHAsset.fetchAssets(with: options))
    }

    /// `sortByCreationDate: false` keeps PhotoKit's fetch order, which is the
    /// order photos were added to the library (oldest added first).
    func fetchAllPhotos(sortByCreationDate: Bool = true) async -> [AssetSummary] {
        let options = allAssetsFetchOptions()
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        return await extractSummaries(from: result, sort: sortByCreationDate)
    }

    // MARK: - Image Loading

    /// `resizeMode` `.none` can return the full original (a 12 MP photo is a
    /// ~48 MB decode); pass `.exact` to cap the decode at `targetSize`.
    func loadImage(
        for assetId: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        resizeMode: PHImageRequestOptionsResizeMode = .none
    ) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: allAssetsFetchOptions()).firstObject else {
            return nil
        }
        return await loadImage(for: asset, targetSize: targetSize, contentMode: contentMode, resizeMode: resizeMode)
    }

    func loadImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        resizeMode: PHImageRequestOptionsResizeMode = .none
    ) async -> UIImage? {
        await requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            deliveryMode: .highQualityFormat,
            resizeMode: resizeMode
        )
    }

    func loadThumbnail(
        for assetId: String,
        size: CGSize = CGSize(width: 200, height: 200),
        contentMode: PHImageContentMode = .aspectFill
    ) async -> UIImage? {
        await loadThumbnailWithQuality(for: assetId, size: size, contentMode: contentMode).image
    }

    /// `PHAsset` overload so scan loops can resolve a whole batch with one
    /// `phAssetsById` fetch instead of one identifier lookup per image.
    func loadThumbnail(
        for asset: PHAsset,
        size: CGSize = CGSize(width: 200, height: 200),
        contentMode: PHImageContentMode = .aspectFill
    ) async -> UIImage? {
        await loadThumbnailWithQuality(for: asset, size: size, contentMode: contentMode).image
    }

    /// E4 (residual SHARED-05): reports whether the returned thumbnail is the
    /// DEGRADED fast-format placeholder (asset not on this device). Callers
    /// caching results key degraded images separately so a sharp version
    /// fetched later (after iCloud download) replaces the soft one instead of
    /// being blocked by it for the whole session.
    func loadThumbnailWithQuality(
        for assetId: String,
        size: CGSize = CGSize(width: 200, height: 200),
        contentMode: PHImageContentMode = .aspectFill
    ) async -> (image: UIImage?, isDegraded: Bool) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: allAssetsFetchOptions()).firstObject else {
            return (nil, false)
        }
        return await loadThumbnailWithQuality(for: asset, size: size, contentMode: contentMode)
    }

    func loadThumbnailWithQuality(
        for asset: PHAsset,
        size: CGSize = CGSize(width: 200, height: 200),
        contentMode: PHImageContentMode = .aspectFill
    ) async -> (image: UIImage?, isDegraded: Bool) {
        await requestImageWithQuality(
            for: asset,
            targetSize: size,
            contentMode: contentMode,
            deliveryMode: .fastFormat,
            // Preserve the original loadThumbnail behavior (.none) except for
            // fit thumbnails, where exact avoids returning a square crop.
            resizeMode: contentMode == .aspectFit ? .fast : .none,
            allowsNetworkAccess: true
        )
    }

    /// Loads a sharp, deterministically-sized image for on-device analysis
    /// (blur/exposure). Uses high-quality delivery + exact resize so sharpness
    /// isn't corrupted by a soft fast-format thumbnail, and disables network
    /// access so a full-library scan never stalls downloading from iCloud —
    /// callers should fall back to `loadThumbnail` when this returns `nil` (the
    /// asset's full resolution lives only in iCloud).
    func loadAnalysisImage(for assetId: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: allAssetsFetchOptions()).firstObject else {
            return nil
        }
        return await loadAnalysisImage(for: asset, targetSize: targetSize)
    }

    /// `PHAsset` overload so scan loops can resolve a whole batch with one
    /// `phAssetsById` fetch instead of one identifier lookup per image.
    func loadAnalysisImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            deliveryMode: .highQualityFormat,
            resizeMode: .exact,
            allowsNetworkAccess: false
        )
    }

    /// Loads a `PHLivePhoto` representation of a Live Photo asset for in-app
    /// motion playback (e.g. `PHLivePhotoView`). Mirrors `requestImage`'s
    /// single-resume/timeout/degraded-result-guard behaviour: it always resumes
    /// on the terminal callback and falls back to `nil` after
    /// `LoadStall.limit` with no progress, so a stalled iCloud download cannot hang callers.
    func loadLivePhoto(for assetId: String, targetSize: CGSize) async -> PHLivePhoto? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: allAssetsFetchOptions()).firstObject,
              asset.mediaSubtypes.contains(.photoLive) else {
            return nil
        }
        return await requestLivePhoto(for: asset, targetSize: targetSize)
    }

    /// Loads a playable `AVPlayerItem` for a video asset (e.g. for `VideoPlayer`
    /// / `AVPlayer`). Mirrors `requestLivePhoto`'s single-resume/timeout
    /// behaviour. The non-`Sendable` `AVPlayerItem` is returned inside an
    /// `UncheckedSendableBox` so it can safely cross from this actor to the
    /// `@MainActor` caller that builds the player; the caller unwraps `.value`.
    func loadPlayerItem(for assetId: String) async -> UncheckedSendableBox<AVPlayerItem>? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: allAssetsFetchOptions()).firstObject,
              asset.mediaType == .video else {
            return nil
        }
        return await requestPlayerItem(for: asset)
    }

    private func requestPlayerItem(for asset: PHAsset) async -> UncheckedSendableBox<AVPlayerItem>? {
        guard !Task.isCancelled else { return nil }
        return await withCancellableContinuation { continuation, relay in
            let resumer = ContinuationResumer<UncheckedSendableBox<AVPlayerItem>?>(continuation)

            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true

            // The stall watch fires only after LoadStall.limit with no progress. Wired
            // before the request, so a synchronous callback still stops it.
            let manager = imageManager
            let request = PendingRequest { manager.cancelImageRequest($0) }
            let watch = StallWatch()
            let stall = watchForStall(watch) { resumer.resume(nil) }
            options.progressHandler = { _, _, _, _ in
                Task { await watch.recordProgress(at: LoadStall.now()) }
            }
            resumer.onResume = {
                request.cancel()
                stall.cancel()
            }
            relay.install { resumer.resume(nil) }

            request.started(manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                if let error = info?[PHImageErrorKey] {
                    AppLog.photo.error("Player item request failed: \(String(describing: error), privacy: .public)")
                }
                resumer.resume(item.map(UncheckedSendableBox.init))
            })
        }
    }

    private func requestLivePhoto(
        for asset: PHAsset,
        targetSize: CGSize
    ) async -> PHLivePhoto? {
        guard !Task.isCancelled else { return nil }
        return await withCancellableContinuation { continuation, relay in
            let resumer = ContinuationResumer<PHLivePhoto?>(continuation)

            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            // The stall watch fires only after LoadStall.limit with no progress. Wired
            // before the request, so a synchronous callback still stops it.
            let manager = imageManager
            let request = PendingRequest { manager.cancelImageRequest($0) }
            let watch = StallWatch()
            let stall = watchForStall(watch) { resumer.resume(nil) }
            options.progressHandler = { _, _, _, _ in
                Task { await watch.recordProgress(at: LoadStall.now()) }
            }
            resumer.onResume = {
                request.cancel()
                stall.cancel()
            }
            relay.install { resumer.resume(nil) }

            request.started(manager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { livePhoto, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if let error = info?[PHImageErrorKey] {
                    AppLog.photo.error("Live Photo request failed: \(String(describing: error), privacy: .public)")
                    resumer.resume(livePhoto)
                } else if isCancelled {
                    resumer.resume(livePhoto)
                } else if !isDegraded {
                    resumer.resume(livePhoto)
                }
                // A degraded result without an error means the full-quality Live
                // Photo is still coming — keep waiting. Unlike `requestImage`,
                // network access is always allowed here, so there is no
                // "no result will ever arrive" case to short-circuit; the
                // stall watch is the only backstop for a
                // stalled iCloud download. Do NOT copy `requestImage`'s
                // `isInCloud && !allowsNetworkAccess` give-up branch — it can
                // never fire on this path and would be dead code.
            })
        }
    }

    /// Loads an image via `PHImageManager`, resuming exactly once on the terminal
    /// callback (final image, error, or cancellation) and falling back to `nil`
    /// after a timeout. Without this, an asset that only ever delivers a degraded
    /// placeholder (e.g. an iCloud asset with no network) would hang the caller
    /// forever, since the previous implementation only resumed on a non-degraded
    /// result.
    private func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        resizeMode: PHImageRequestOptionsResizeMode = .none,
        allowsNetworkAccess: Bool = true
    ) async -> UIImage? {
        await requestImageWithQuality(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            deliveryMode: deliveryMode,
            resizeMode: resizeMode,
            allowsNetworkAccess: allowsNetworkAccess
        ).image
    }

    /// `requestImage` plus the degraded flag (E4). A `.fastFormat` request for
    /// an iCloud-optimized asset delivers exactly one callback, flagged
    /// degraded — that soft placeholder is the terminal result and is reported
    /// as such so callers can cache it under a degraded key.
    private func requestImageWithQuality(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        resizeMode: PHImageRequestOptionsResizeMode,
        allowsNetworkAccess: Bool
    ) async -> (image: UIImage?, isDegraded: Bool) {
        guard !Task.isCancelled else { return (nil, false) }
        let box = QualityResultBox()

        await withCancellableContinuation { continuation, relay in
            let resumer = ContinuationResumer<Bool>(continuation)

            let options = PHImageRequestOptions()
            options.deliveryMode = deliveryMode
            options.isNetworkAccessAllowed = allowsNetworkAccess
            options.isSynchronous = false
            options.resizeMode = resizeMode

            // The stall watch fires only after LoadStall.limit with no progress. Wired
            // before the request, so a synchronous callback still stops it.
            let manager = imageManager
            let request = PendingRequest { manager.cancelImageRequest($0) }
            let watch = StallWatch()
            let stall = watchForStall(watch) { resumer.resume(false) }
            options.progressHandler = { _, _, _, _ in
                Task { await watch.recordProgress(at: LoadStall.now()) }
            }
            resumer.onResume = {
                request.cancel()
                stall.cancel()
            }
            // A cancelled caller gets nothing, not a placeholder that arrived
            // before the cancel: a scan would score it as a sharp image.
            relay.install {
                box.dropImage()
                resumer.resume(false)
            }

            request.started(manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                box.record(image, degraded: isDegraded)

                if info?[PHImageErrorKey] != nil {
                    AppLog.photo.error("Image request failed: \(String(describing: info?[PHImageErrorKey]), privacy: .public)")
                    resumer.resume(isDegraded)
                } else if isCancelled {
                    resumer.resume(isDegraded)
                } else if !isDegraded {
                    resumer.resume(false)
                } else if deliveryMode == .fastFormat {
                    // .fastFormat delivers exactly one callback; for iCloud-optimized
                    // assets that single result is flagged degraded. No non-degraded
                    // result is coming, so the degraded image IS the terminal result.
                    resumer.resume(true)
                } else if isInCloud && !allowsNetworkAccess {
                    // The full asset lives only in iCloud and network access is
                    // off, so no non-degraded result will ever arrive. Give up
                    // promptly so a scan doesn't stall per iCloud-only photo.
                    // Discard the retained degraded placeholder so the caller
                    // gets nil and falls back to the thumbnail path.
                    box.dropImage()
                    resumer.resume(isDegraded)
                }
                // A degraded placeholder without an error (and reachable) means
                // the full-quality result is still coming — keep waiting for it.
            })
        }

        return box.result
    }

    /// Result state bridged from the PhotoKit completion closure (a PhotoKit
    /// queue) to the actor. A late callback can still arrive after the timeout
    /// has resumed the continuation, so every access goes through the lock.
    private final class QualityResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var image: UIImage?
        private var isDegraded = false
        private var isClosed = false

        func record(_ image: UIImage?, degraded: Bool) {
            lock.withLock {
                guard !isClosed else { return }
                if degraded { isDegraded = true }
                if let image { self.image = image }
            }
        }

        /// Drops the image and ignores any callback that arrives later.
        func dropImage() {
            lock.withLock {
                image = nil
                isClosed = true
            }
        }

        var result: (image: UIImage?, isDegraded: Bool) {
            lock.withLock { (image, isDegraded) }
        }
    }

    // MARK: - Album Membership

    /// Local identifiers of the user albums that currently contain the asset.
    /// Used to restore album membership when an asset is replaced (e.g. after
    /// video compression or Live Photo conversion).
    func userAlbumIdentifiers(containing assetId: String) -> [String] {
        userAlbumIdentifiers(for: [assetId])[assetId] ?? []
    }

    /// Album membership for a batch of assets in a single pass over user
    /// albums (one fetch per album instead of one predicate fetch per
    /// album per item). Batch loops should call this once before iterating.
    func userAlbumIdentifiers(for assetIds: Set<String>) -> [String: [String]] {
        guard !assetIds.isEmpty else { return [:] }
        var result: [String: [String]] = Dictionary(uniqueKeysWithValues: assetIds.map { ($0, [String]()) })
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        let options = allAssetsFetchOptions()
        userAlbums.enumerateObjects { collection, _, _ in
            let fetched = PHAsset.fetchAssets(in: collection, options: options)
            var memberIds = Set<String>()
            fetched.enumerateObjects { asset, _, _ in
                if assetIds.contains(asset.localIdentifier) {
                    memberIds.insert(asset.localIdentifier)
                }
            }
            for id in memberIds {
                result[id, default: []].append(collection.localIdentifier)
            }
        }
        return result
    }

    // MARK: - Pre-fetching

    func startCaching(assetIds: [String], targetSize: CGSize) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: allAssetsFetchOptions())
        var phAssets: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            phAssets.append(asset)
        }
        imageManager.startCachingImages(for: phAssets, targetSize: targetSize, contentMode: .aspectFit, options: nil)
    }

    func stopCaching(assetIds: [String], targetSize: CGSize) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: allAssetsFetchOptions())
        var phAssets: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            phAssets.append(asset)
        }
        imageManager.stopCachingImages(for: phAssets, targetSize: targetSize, contentMode: .aspectFit, options: nil)
    }

    func stopAllCaching() {
        imageManager.stopCachingImagesForAllAssets()
    }

    // MARK: - Mutations

    /// Only successful PhotoKit mutations count as deletions. Already-absent
    /// assets still leave the UI, but never contribute bytes to the ledger.
    @discardableResult
    func deleteAssets(identifiers: [String]) async throws -> PhotoDeletionOutcome {
        let requested = Set(identifiers)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(requested), options: allAssetsFetchOptions())
        var present = Set<String>()
        assets.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        var absent = requested.subtracting(present)
        guard !present.isEmpty else { return PhotoDeletionOutcome(deletedIds: [], alreadyAbsentIds: absent) }
        do {
            try Task.checkCancellation()
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return PhotoDeletionOutcome(deletedIds: present, alreadyAbsentIds: absent)
        } catch {
            if error is CancellationError { throw error }
            if PhotoServiceError.isUserDeclined(error) { throw PhotoServiceError.userDeclined(alreadyAbsentIds: absent) }
            var deleted = Set<String>()
            var failed = 0
            for (offset, id) in present.sorted().enumerated() {
                if offset % 10 == 0 { await Task.yield() }
                if Task.isCancelled {
                    guard !deleted.isEmpty else { throw CancellationError() }
                    throw PhotoServiceError.partialDeletion(
                        succeededIds: deleted, failedCount: requested.subtracting(deleted.union(absent)).count,
                        alreadyAbsentIds: absent
                    )
                }
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: allAssetsFetchOptions()).firstObject else {
                    absent.insert(id)
                    continue
                }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                    }
                    deleted.insert(id)
                } catch {
                    if PhotoServiceError.isUserDeclined(error) {
                        guard !deleted.isEmpty else { throw PhotoServiceError.userDeclined(alreadyAbsentIds: absent) }
                        throw PhotoServiceError.partialDeletion(
                            succeededIds: deleted, failedCount: requested.subtracting(deleted.union(absent)).count,
                            alreadyAbsentIds: absent
                        )
                    }
                    failed += 1
                }
            }
            if failed > 0 {
                throw PhotoServiceError.partialDeletion(succeededIds: deleted, failedCount: failed, alreadyAbsentIds: absent)
            }
            return PhotoDeletionOutcome(deletedIds: deleted, alreadyAbsentIds: absent)
        }
    }

    func addToAlbum(assetIdentifiers: [String], albumIdentifier: String) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: allAssetsFetchOptions())
        guard let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumIdentifier], options: nil
        ).firstObject else {
            throw PhotoServiceError.albumNotFound
        }

        var changeRequestCreated = false
        try await PHPhotoLibrary.shared().performChanges {
            guard let albumChangeRequest = PHAssetCollectionChangeRequest(for: album) else { return }
            albumChangeRequest.addAssets(assets)
            changeRequestCreated = true
        }
        // The album fetched fine but PhotoKit refused to build a change request
        // for it — a distinct failure from the album being missing (SHARED-02).
        guard changeRequestCreated else {
            throw PhotoServiceError.albumChangeFailed
        }
    }

    func removeFromAlbum(assetIdentifiers: [String], albumIdentifier: String) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: allAssetsFetchOptions())
        guard let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumIdentifier], options: nil
        ).firstObject else {
            throw PhotoServiceError.albumNotFound
        }

        var changeRequestCreated = false
        try await PHPhotoLibrary.shared().performChanges {
            guard let albumChangeRequest = PHAssetCollectionChangeRequest(for: album) else { return }
            albumChangeRequest.removeAssets(assets)
            changeRequestCreated = true
        }
        // Same distinction as addToAlbum: the album exists but PhotoKit refused
        // to build a change request for it (SHARED-02).
        guard changeRequestCreated else {
            throw PhotoServiceError.albumChangeFailed
        }
    }

    func createAlbum(name: String) async throws -> String {
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let id = placeholder?.localIdentifier else {
            throw PhotoServiceError.albumCreationFailed
        }
        return id
    }

    // MARK: - Asset Data

    /// Streams an asset's primary resource through a SHA-256 hasher in chunks and
    /// returns the lowercased hex digest. Unlike loading the full `Data` and then
    /// hashing it, this keeps only one chunk in memory at a time — essential for
    /// large videos, which could otherwise exhaust memory during duplicate scans.
    func sha256ForPrimaryResource(of assetId: String) async -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: allAssetsFetchOptions()).firstObject else {
            return nil
        }
        return await sha256ForPrimaryResource(of: asset)
    }

    /// `PHAsset` overload so duplicate scans can resolve a whole batch with
    /// one `phAssetsById` fetch instead of one identifier lookup per asset.
    func sha256ForPrimaryResource(of asset: PHAsset) async -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = Self.preferredPrimaryResource(from: resources), !Task.isCancelled else {
            return nil
        }
        let hash: String? = await withCancellableContinuation { continuation, relay in
            let resumer = ContinuationResumer<String?>(continuation)
            var hasher = SHA256()
            let options = PHAssetResourceRequestOptions()
            // Only on-device assets are hashed (DUP-03), and the flag that says
            // so can be an old cached read. With the network off, an asset iOS
            // has since offloaded fails at once instead of downloading.
            options.isNetworkAccessAllowed = false

            // Stall-bounded: the hash keeps going while bytes arrive and fails only
            // after LoadStall.limit with none. Wired before the request, so a stalled
            // iCloud resource cannot hang the duplicate scan.
            let resourceManager = PHAssetResourceManager.default()
            let request = PendingRequest { resourceManager.cancelDataRequest($0) }
            let watch = StallWatch()
            let stall = watchForStall(watch) { resumer.resume(nil) }
            resumer.onResume = {
                request.cancel()
                stall.cancel()
            }
            relay.install { resumer.resume(nil) }

            request.started(resourceManager.requestData(
                for: resource,
                options: options
            ) { chunk in
                hasher.update(data: chunk)
                Task { await watch.recordProgress(at: LoadStall.now()) }
            } completionHandler: { error in
                if let error {
                    AppLog.photo.error("Resource hash failed: \(error.localizedDescription, privacy: .public)")
                    resumer.resume(nil)
                } else {
                    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    resumer.resume(hex)
                }
            })
        }
        // No `forgetResources`: with the network off, hashing cannot download
        // the original, so the cached read is still right. Dropping it made
        // the next Storage or Cleanup load read every hashed asset again.
        return hash
    }

    /// Reads the asset's resources again and drops its cached read, so the next
    /// build sees its current iCloud state. True when every resource is on the
    /// device. For an exact-duplicate hash that failed with the network off.
    func isOnDevice(_ asset: PHAsset) -> Bool {
        forgetResources(of: asset.localIdentifier)
        return Self.readResources(of: asset).isLocallyAvailable
    }

    nonisolated func getPHAsset(for identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: allAssetsFetchOptions()).firstObject
    }

    /// Resolves a batch of identifiers with ONE PhotoKit fetch. Scan loops
    /// that load an image (or hash) per asset must use this + the `PHAsset`
    /// loader overloads instead of the per-id loaders — one identifier lookup
    /// per image turned full-library scans into tens of thousands of fetches.
    /// Missing ids (deleted externally mid-scan) are simply absent.
    nonisolated func phAssetsById(_ ids: [String]) -> [String: PHAsset] {
        guard !ids.isEmpty else { return [:] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: allAssetsFetchOptions())
        var byId: [String: PHAsset] = [:]
        byId.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            byId[asset.localIdentifier] = asset
        }
        return byId
    }

    /// Loads an image asset's full-resolution encoded data (with EXIF, including
    /// the orientation tag, intact). Used by photo compression to re-encode.
    /// Mirrors `requestImage`'s single-resume / timeout behaviour so a stalled
    /// iCloud download can't hang the caller.
    func loadFullImageData(for assetId: String) async -> Data? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: allAssetsFetchOptions()).firstObject else {
            return nil
        }
        return await loadFullImageData(for: asset)
    }

    /// `PHAsset` overload so compression batches can resolve a whole batch
    /// with one `phAssetsById` fetch instead of one identifier lookup per item.
    func loadFullImageData(for asset: PHAsset) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let data: Data? = await withCancellableContinuation { continuation, relay in
            let resumer = ContinuationResumer<Data?>(continuation)

            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            // The stall watch fires only after LoadStall.limit with no progress. Wired
            // before the request, so a synchronous callback still stops it.
            let manager = imageManager
            let request = PendingRequest { manager.cancelImageRequest($0) }
            let watch = StallWatch()
            let stall = watchForStall(watch) { resumer.resume(nil) }
            options.progressHandler = { _, _, _, _ in
                Task { await watch.recordProgress(at: LoadStall.now()) }
            }
            resumer.onResume = {
                request.cancel()
                stall.cancel()
            }
            relay.install { resumer.resume(nil) }

            request.started(manager.requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                if let error = info?[PHImageErrorKey] {
                    AppLog.photo.error("Image data request failed: \(String(describing: error), privacy: .public)")
                    resumer.resume(nil)
                } else {
                    resumer.resume(data)
                }
            })
        }
        forgetResources(of: asset.localIdentifier)
        return data
    }

    /// Writes full-resolution representations of the given assets to temporary
    /// files (under one share-export folder) so they can be handed to a share
    /// sheet. Streams the primary resource bytes directly — preserving the
    /// original quality and metadata, no re-encode — and reports
    /// `(completed, total)` after each file. iCloud assets respect the per-item
    /// timeout; failures are skipped.
    func exportAssetsForSharing(
        identifiers: [String],
        onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void
    ) async -> (folder: URL, urls: [URL]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.shareExportFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var urls: [URL] = []
        let total = identifiers.count
        var completed = 0

        // One batched resolve for the whole export, not one identifier lookup
        // per file (ids deleted externally mid-export are skipped).
        let assetsById = phAssetsById(identifiers)
        for id in identifiers {
            if Task.isCancelled { break }
            if let asset = assetsById[id],
               let url = await writeResourceToTemp(asset: asset, in: folder) {
                urls.append(url)
            }
            completed += 1
            await onProgress(completed, total)
        }

        return (folder, urls)
    }

    private func writeResourceToTemp(asset: PHAsset, in folder: URL) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = Self.preferredPrimaryResource(from: resources), !Task.isCancelled else { return nil }

        let fileURL = uniqueURL(for: resource.originalFilename, in: folder)
        guard let sink = ExportFileSink(url: fileURL) else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let assetId = asset.localIdentifier
        return await withCancellableContinuation { continuation, relay in
            let resumer = ContinuationResumer<URL?>(continuation)

            // Streams the bytes into the file, so the request can be cancelled and
            // its partial file removed (SHARED-07). Stall-bounded like the others.
            let resourceManager = PHAssetResourceManager.default()
            let request = PendingRequest { resourceManager.cancelDataRequest($0) }
            let watch = StallWatch()
            // No bytes for LoadStall.limit, or the export was cancelled. Only the
            // call that resumes the continuation may discard the file, so a late
            // success cannot race it.
            let stall = watchForStall(watch) {
                if resumer.resume(nil) { sink.discard() }
            }
            resumer.onResume = {
                request.cancel()
                stall.cancel()
            }
            relay.install {
                if resumer.resume(nil) { sink.discard() }
            }

            request.started(resourceManager.requestData(for: resource, options: options) { chunk in
                sink.append(chunk)
                Task { await watch.recordProgress(at: LoadStall.now()) }
            } completionHandler: { error in
                if let error {
                    AppLog.photo.error("Share export write failed: \(error.localizedDescription, privacy: .public)")
                    sink.discard()
                    resumer.resume(nil)
                    return
                }
                // A failed write (disk full) must not come back as a complete copy.
                guard sink.finish() else {
                    sink.discard()
                    resumer.resume(nil)
                    return
                }
                if resumer.resume(fileURL) {
                    // Here rather than after the await: the original is now local.
                    Task { await self.forgetResources(of: assetId) }
                } else {
                    // A stall or cancel already answered nil. Its file is gone; drop this copy too.
                    sink.discard()
                }
            })
        }
    }

    /// A non-colliding URL inside `folder` for `filename`, appending `-2`, `-3`…
    /// before the extension when needed (two assets can share an original name).
    nonisolated private func uniqueURL(for filename: String, in folder: URL) -> URL {
        let name = filename.isEmpty ? "media.dat" : filename
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    // MARK: - Helpers

    nonisolated private func allAssetsFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        return options
    }

    nonisolated private static func estimateFileSize(from resources: [PHAssetResource]) -> Int64 {
        completeResourceSize(resources.map(Self.safeFileSize))
    }

    /// A missing Live Photo component or adjustment resource makes the total unknown.
    nonisolated static func completeResourceSize(_ sizes: [Int64]) -> Int64 {
        guard !sizes.isEmpty, sizes.allSatisfy({ $0 > 0 }) else { return 0 }
        return sizes.reduce(0, +)
    }

    /// Reads the summary fields that come from the asset's resources: one
    /// Photos database round trip per asset, the slow part of a library build.
    nonisolated static func readResources(of asset: PHAsset) -> ResourceFacts {
        let resources = PHAssetResource.assetResources(for: asset)
        return ResourceFacts(
            fileSize: Self.estimateFileSize(from: resources),
            filename: resources.first?.originalFilename,
            isLocallyAvailable: resources.allSatisfy { resource in
                guard resource.responds(to: NSSelectorFromString("locallyAvailable")) else { return true }
                return (resource.value(forKey: "locallyAvailable") as? Bool) ?? true
            },
            hasScreenRecordingFilename: resources.contains { Self.isScreenRecordingFilename($0.originalFilename) },
            primaryFileSize: Self.preferredPrimaryResource(from: resources).map(Self.safeFileSize) ?? 0
        )
    }

    nonisolated private static func makeSummary(from asset: PHAsset, resources: ResourceFacts? = nil) -> AssetSummary {
        let resources = resources ?? readResources(of: asset)

        let mediaType: MediaType
        switch asset.mediaType {
        case .image:
            mediaType = .photo
        case .video:
            mediaType = .video
        case .audio:
            mediaType = .audio
        default:
            mediaType = .unknown
        }

        return AssetSummary(
            id: asset.localIdentifier,
            mediaType: mediaType,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            fileSize: resources.fileSize,
            filename: resources.filename,
            isFavorite: asset.isFavorite,
            isBurst: asset.representsBurst,
            burstIdentifier: asset.burstIdentifier,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isLocallyAvailable: resources.isLocallyAvailable,
            assetOrigin: Self.detectOrigin(for: asset, filename: resources.filename),
            burstPick: asset.burstSelectionTypes.contains(.userPick) ? .user
                : asset.burstSelectionTypes.contains(.autoPick) ? .iPhone : .none,
            isScreenRecording: asset.mediaType == .video && (
                asset.mediaSubtypes.contains(.videoScreenRecording)
                || resources.hasScreenRecordingFilename
            ),
            isCinematic: asset.mediaSubtypes.contains(.videoCinematic),
            isSpatial: asset.mediaSubtypes.contains(.spatialMedia),
            primaryResourceSize: resources.primaryFileSize
        )
    }

    /// Best-effort classification of where an asset came from, used by the Smart
    /// Categories tool. Pure metadata inspection — no image loading. Camera
    /// captures carry a recognizable filename prefix or capture markers (HDR,
    /// depth, Live, GPS); screenshots have the screenshot subtype; anything else
    /// that's an image is treated as likely saved from another app (the category
    /// is intentionally recall-leaning and surfaced to the user as "likely").
    nonisolated private static func detectOrigin(for asset: PHAsset, filename: String?) -> AssetOrigin {
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            return .screenshot
        }

        let name = (filename ?? "").uppercased()
        let cameraPrefixes = ["IMG_", "DSC", "DSCF", "DJI_", "GOPR", "PXL_", "MVIMG"]
        let isCameraName = cameraPrefixes.contains { name.hasPrefix($0) } || name.hasSuffix(".DNG")
        let hasCameraMarkers = asset.mediaSubtypes.contains(.photoHDR)
            || asset.mediaSubtypes.contains(.photoDepthEffect)
            || asset.mediaSubtypes.contains(.photoLive)
            || asset.location != nil
        if isCameraName || hasCameraMarkers {
            return .camera
        }

        // Camera wins over the marker list above, so an `IMG_` capture that also
        // contains a marker string is still a camera photo. The list itself
        // lives in `SavedFromAppMarkers` so it can be unit tested.
        if SavedFromAppMarkers.matches(filename: filename) {
            return .savedFromApp
        }

        // Images that match neither a camera nor screenshot signature are most
        // likely imported/downloaded; videos without markers stay unknown.
        return asset.mediaType == .image ? .savedFromApp : .unknown
    }

    /// Builds the summaries on `summaryBuilder`, not on this actor. Reading
    /// every asset's resources takes minutes on a large library, and while
    /// that ran here, every thumbnail and card image request queued behind it.
    private func extractSummaries(
        from fetchResult: PHFetchResult<PHAsset>,
        excluding: Set<String> = [],
        sort: Bool = true,
        isFullLibrary: Bool = false
    ) async -> [AssetSummary] {
        retainChangeBaseline(fetchResult, isFullLibrary: isFullLibrary)
        // Stamp in the same actor turn as the fetch: the fetch keeps its
        // assets as they were when it was made, however long it waits for
        // the builder.
        let stamp = summaryBuilder.resources.stamp()
        return await summaryBuilder.build(
            from: UncheckedSendableBox(fetchResult),
            excluding: excluding,
            sort: sort,
            stamp: stamp,
            isFullLibrary: isFullLibrary
        )
    }

    nonisolated fileprivate static func buildSummaries(
        from fetchResult: PHFetchResult<PHAsset>,
        excluding: Set<String> = [],
        sort: Bool = true,
        resources: @escaping (PHAsset) -> ResourceFacts
    ) -> [AssetSummary] {
        var summaries: [AssetSummary] = []
        summaries.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            if !excluding.contains(asset.localIdentifier) {
                summaries.append(Self.makeSummary(from: asset, resources: resources(asset)))
            }
        }
        if sort {
            summaries.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        }
        return summaries
    }

    nonisolated private func collectAssetsInUserAlbums() -> Set<String> {
        var inAlbum = Set<String>()
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        let options = allAssetsFetchOptions()
        userAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            assets.enumerateObjects { asset, _, _ in
                inAlbum.insert(asset.localIdentifier)
            }
        }
        return inAlbum
    }

    /// The resource the exact-duplicate hash reads. `readResources` records
    /// its size, so the scan can skip assets whose size no other asset shares.
    nonisolated private static func preferredPrimaryResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first { $0.type == .fullSizePhoto }
        ?? resources.first { $0.type == .photo }
        ?? resources.first { $0.type == .fullSizeVideo }
        ?? resources.first { $0.type == .video }
        ?? resources.first { $0.type == .audio }
        ?? resources.first
    }

    nonisolated private static func safeFileSize(for resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")),
              let size = resource.value(forKey: "fileSize") as? Int64 else {
            return 0
        }
        return size
    }
}

/// Writes one export file as PhotoKit delivers its bytes. A failed write (for
/// example a full disk) marks the sink, and `finish` reports it, so a truncated
/// copy is never returned as complete. `discard` removes the partial file and
/// drops later bytes.
final class ExportFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let writeChunk: (FileHandle, Data) throws -> Void
    private var handle: FileHandle?
    private var failed = false

    init?(url: URL, writeChunk: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.writeChunk = writeChunk
        self.handle = handle
    }

    func append(_ data: Data) {
        lock.withLock {
            guard let handle, !failed else { return }
            do { try writeChunk(handle, data) } catch { failed = true }
        }
    }

    /// Closes the file. True only when the file was open and every write succeeded.
    func finish() -> Bool {
        lock.withLock {
            guard let handle else { return false }
            self.handle = nil
            do { try handle.close() } catch { failed = true }
            return !failed
        }
    }

    func discard() {
        lock.withLock {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct PhotoDeletionOutcome: Sendable, Equatable {
    let deletedIds: Set<String>
    let alreadyAbsentIds: Set<String>
    var removedIds: Set<String> { deletedIds.union(alreadyAbsentIds) }
}

// MARK: - Errors

enum PhotoServiceError: LocalizedError {
    case albumNotFound
    case albumCreationFailed
    case albumChangeFailed
    case partialDeletion(succeededIds: Set<String>, failedCount: Int, alreadyAbsentIds: Set<String> = [])
    /// The user tapped "Don't Allow" on the iOS delete prompt.
    case userDeclined(alreadyAbsentIds: Set<String> = [])

    var errorDescription: String? {
        // Shown in the cleanup tools' error banners, so these resolve through
        // `L10n` rather than staying English literals.
        switch self {
        case .albumNotFound: return L10n.string("Album not found.")
        case .albumCreationFailed: return L10n.string("Failed to create album.")
        case .albumChangeFailed: return L10n.string("Couldn't modify the album. Please try again.")
        case .partialDeletion(let succeededIds, let failedCount, _):
            let total = succeededIds.count + failedCount
            return L10n.format(
                "Deleted %lld of %lld items. %lld couldn't be deleted. Try again.",
                succeededIds.count, total, failedCount
            )
        case .userDeclined: return L10n.string("Nothing was deleted.")
        }
    }

    /// True for the PhotoKit error thrown when the user declines the iOS
    /// delete prompt, and for this enum's own `userDeclined`.
    static func isUserDeclined(_ error: Error) -> Bool {
        if case .userDeclined? = error as? PhotoServiceError { return true }
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain
            && nsError.code == PHPhotosError.Code.userCancelled.rawValue
    }

    var deletionOutcome: PhotoDeletionOutcome? {
        switch self {
        case .partialDeletion(let deleted, _, let absent):
            return PhotoDeletionOutcome(deletedIds: deleted, alreadyAbsentIds: absent)
        case .userDeclined(let absent):
            return PhotoDeletionOutcome(deletedIds: [], alreadyAbsentIds: absent)
        default:
            return nil
        }
    }

}

// MARK: - Summary Builder

/// Runs the library-wide summary builds one at a time, as they ran when they
/// were on `PhotoLibraryService` itself, without holding that actor.
private actor SummaryBuilder {
    /// The launch scan, Storage and Cleanup each build the whole library.
    /// Reading every asset's resources is what takes minutes, so only the
    /// first build does it; later builds reuse what it read.
    nonisolated let resources = ResourceCache(fileURL: ResourceCache.defaultFileURL)

    /// Reads past `ResourceCache.maxAge` that one build may repeat. A build of
    /// cached entries takes well under a second; this keeps a build that finds
    /// every entry aged out (a launch the next day) near that, while the iCloud
    /// state still gets refreshed a slice per build.
    static let staleRefreshesPerBuild = 500

    /// Pull-to-refresh: the next build refreshes up to this many old entries,
    /// oldest first, but stops after `refreshTimeBox`. A small library is
    /// refreshed in full; a large one stays fast and continues on later builds.
    static let staleRefreshesOnRequest = 5_000
    static let refreshTimeBox: Duration = .seconds(3)
    private var isRefreshRequested = false

    func requestRefresh() {
        isRefreshRequested = true
    }

    /// A long first read is saved this often, so the next launch continues it
    /// if iOS ends the app before the read is done.
    static let saveInterval: Duration = .seconds(10)

    /// A build that read only a few assets (one library change) leaves them
    /// for a later save: the file holds every asset, and rewriting it after
    /// each change on a busy iCloud library costs more than reading a few
    /// assets again after a crash.
    static let quietSaveInterval: Duration = .seconds(30)
    static let readsWorthASave = 1_000
    /// Nil until the first save of this launch, so the first build always saves.
    private var lastSave: ContinuousClock.Instant?

    /// `isFullLibrary`: the fetch holds every asset, so entries for any other
    /// id belong to deleted assets and are dropped.
    func build(
        from fetchResult: UncheckedSendableBox<PHFetchResult<PHAsset>>,
        excluding: Set<String>,
        sort: Bool,
        stamp: Int,
        isFullLibrary: Bool
    ) -> [AssetSummary] {
        defer { resources.release(stamp) }
        resources.loadIfNeeded()
        let start = ContinuousClock.now
        var lastLoopSave = start
        var reads = 0
        let isRefresh = isRefreshRequested
        isRefreshRequested = false
        let limit = isRefresh ? Self.staleRefreshesOnRequest : Self.staleRefreshesPerBuild
        // A whole-library build takes the oldest entries first. A narrower build
        // (screenshots, one album) takes its own old entries in fetch order:
        // the oldest entries in the cache are usually not in its fetch.
        var staleRefreshes = isFullLibrary
            ? resources.staleRefreshBudget(limit)
            : ResourceCache.StaleRefreshBudget(remaining: limit, readAtOrBefore: .distantFuture)
        var seen = Set<String>()
        let summaries = PhotoLibraryService.buildSummaries(from: fetchResult.value, excluding: excluding, sort: sort) { [resources] asset in
            if isFullLibrary { seen.insert(asset.localIdentifier) }
            if isRefresh, staleRefreshes.remaining > 0, ContinuousClock.now - start > Self.refreshTimeBox {
                staleRefreshes.remaining = 0
            }
            return resources.resources(
                id: asset.localIdentifier,
                modifiedAt: asset.modificationDate,
                stamp: stamp,
                staleRefreshes: &staleRefreshes
            ) {
                reads += 1
                if ContinuousClock.now - lastLoopSave > Self.saveInterval {
                    resources.saveIfDirty()
                    lastLoopSave = ContinuousClock.now
                }
                return PhotoLibraryService.readResources(of: asset)
            }
        }
        if isFullLibrary, excluding.isEmpty { resources.retainOnly(seen) }
        if reads >= Self.readsWorthASave || lastSave.map({ ContinuousClock.now - $0 > Self.quietSaveInterval }) ?? true {
            resources.saveIfDirty()
            lastSave = ContinuousClock.now
        }
        // The resource reads are what makes a build slow on a large library.
        // A slow or read-heavy build is logged at notice, so a user's device
        // log still holds it (info lines are not kept).
        let elapsed = ContinuousClock.now - start
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let level: OSLogType = reads >= Self.readsWorthASave || elapsed > .seconds(2) ? .default : .info
        AppLog.photo.log(level: level, "Summary build: \(summaries.count, privacy: .public) assets, \(reads, privacy: .public) resource reads, \(milliseconds, privacy: .public) ms")
        return summaries
    }
}

/// The summary fields that come from an asset's resources.
struct ResourceFacts: Sendable, Equatable {
    var fileSize: Int64
    var filename: String?
    var isLocallyAvailable: Bool
    var hasScreenRecordingFilename: Bool
    /// Size of the resource `sha256ForPrimaryResource` hashes. 0 when unknown.
    var primaryFileSize: Int64 = 0

    /// For a deck listing, which skips the resource read: no file size, no
    /// filename, locally available.
    static let unread = ResourceFacts(fileSize: 0, filename: nil, isLocallyAvailable: true, hasScreenRecordingFilename: false)
}

/// What one photo library change means for the cached reads. Pure, so the
/// rule is pinned by tests: PR #8 stopped clearing the cache on changes
/// without per-asset detail, and PR #27 brought the clear back, because the
/// rule lived only in a comment.
enum LibraryChangeEffect: Equatable, Sendable {
    /// The full-library fetch did not change: an album, a collection or
    /// other metadata changed. No cached read or thumbnail is affected.
    case unaffected
    /// PhotoKit listed the assets that changed or left the library.
    case assets(removedOrChanged: [String])
    /// No per-asset detail: no baseline fetch yet, or a change that is not
    /// incremental.
    case unknown

    /// What PhotoKit answered for the baseline fetch.
    struct Details: Equatable, Sendable {
        var isIncremental: Bool
        var removedOrChanged: [String]
    }

    /// `baselineIsFullLibrary` is nil when there is no baseline fetch yet;
    /// `details` is nil when `changeDetails(for:)` returned nil. Only a
    /// whole-library baseline answers for every asset: a narrow baseline
    /// (screenshots, one album) says nothing about an edit elsewhere, so any
    /// answer from it drops every thumbnail.
    init(baselineIsFullLibrary: Bool?, details: Details?) {
        guard let baselineIsFullLibrary else { self = .unknown; return }
        guard let details else { self = baselineIsFullLibrary ? .unaffected : .unknown; return }
        // Incremental details of a narrow baseline list only its own assets,
        // not an edit elsewhere, so they are no complete diff either.
        self = details.isIncremental && baselineIsFullLibrary ? .assets(removedOrChanged: details.removedOrChanged) : .unknown
    }

    var logName: String {
        switch self {
        case .unaffected: "unaffected"
        case .assets: "assets"
        case .unknown: "unknown"
        }
    }
}

/// Resource reads from earlier builds, by asset id, reused while the asset's
/// modification date is unchanged. `handleLibraryChange` drops the assets a
/// change touched. A lock rather than an actor, so a change takes effect at
/// once instead of waiting for a running build to finish.
///
/// Kept on disk between launches: reading every asset's resources is one
/// Photos database round trip per asset, minutes on a large library, and the
/// in-memory cache made every cold launch pay it again.
final class ResourceCache: @unchecked Sendable {
    /// Downloading or offloading an iCloud original changes
    /// `isLocallyAvailable` without always producing a library change. A read
    /// older than this is still used, but a build reads it again when its
    /// refresh budget allows (see `StaleRefreshBudget`).
    static let maxAge: TimeInterval = 30 * 60

    /// Bump when `Stored` changes; a file with another version is ignored.
    static let fileVersion = 1

    private struct Entry {
        var facts: ResourceFacts
        var modifiedAt: Date?
        var readAt: Date
    }

    private let lock = NSLock()
    /// Serializes file writes and deletes. Never taken inside `lock`.
    private let fileLock = NSLock()
    private let now: @Sendable () -> Date
    private let fileURL: URL?
    private var entries: [String: Entry] = [:]
    /// Ticks on every removal; `removedAt` and `clearedAt` record the tick. A
    /// build keeps nothing it read for an asset removed after its fetch was
    /// made: the fetch may hold that asset as it was before the change.
    private var tick = 0
    private var removedAt: [String: Int] = [:]
    private var clearedAt = 0
    /// Stamps handed out and not yet released, by count. A removal only
    /// matters to fetches stamped before it, so `removedAt` keeps only what
    /// the oldest open stamp still needs.
    private var openStamps: [Int: Int] = [:]
    /// The file is read once, by the first build. Removals before that are
    /// kept here so the file cannot bring those entries back.
    private var isLoaded: Bool
    private var removedBeforeLoad = Set<String>()
    private var isDirty = false

    /// `fileURL` nil keeps the reads in memory only (tests).
    init(now: @escaping @Sendable () -> Date = { Date() }, fileURL: URL? = nil) {
        self.now = now
        self.fileURL = fileURL
        self.isLoaded = fileURL == nil
    }

    /// The app's cache file. In Caches: iOS may purge it, which only costs
    /// one full read.
    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ResourceCache.plist")
    }

    /// Take when making the fetch a build will enumerate, pass to
    /// `resources(id:modifiedAt:stamp:orRead:)`, and `release` when the build
    /// is done.
    func stamp() -> Int {
        lock.withLock {
            openStamps[tick, default: 0] += 1
            return tick
        }
    }

    func release(_ stamp: Int) {
        lock.withLock {
            if let count = openStamps[stamp], count > 1 {
                openStamps[stamp] = count - 1
            } else {
                openStamps[stamp] = nil
            }
            pruneRemovals()
        }
    }

    /// How many entries past `maxAge` one build may read again, and which:
    /// the oldest reads first, so every entry gets its turn instead of the
    /// first ones in fetch order taking the budget each time.
    struct StaleRefreshBudget {
        var remaining: Int
        /// Only entries read at or before this are refreshed.
        let readAtOrBefore: Date

        static let unlimited = StaleRefreshBudget(remaining: .max, readAtOrBefore: .distantFuture)
    }

    /// A budget for `limit` refreshes that picks the `limit` oldest stale entries.
    func staleRefreshBudget(_ limit: Int) -> StaleRefreshBudget {
        let staleBefore = now().addingTimeInterval(-Self.maxAge)
        let staleReads = lock.withLock { entries.values.compactMap { $0.readAt <= staleBefore ? $0.readAt : nil } }
        guard limit > 0, staleReads.count > limit else {
            return StaleRefreshBudget(remaining: limit, readAtOrBefore: .distantFuture)
        }
        return StaleRefreshBudget(remaining: limit, readAtOrBefore: staleReads.sorted()[limit - 1])
    }

    /// Reads every entry past `maxAge` again (the behaviour before the budget).
    func resources(id: String, modifiedAt modificationDate: Date?, stamp: Int, orRead read: () -> ResourceFacts) -> ResourceFacts {
        var unlimited = StaleRefreshBudget.unlimited
        return resources(id: id, modifiedAt: modificationDate, stamp: stamp, staleRefreshes: &unlimited, orRead: read)
    }

    /// An entry past `maxAge` is read again only while the budget lasts and
    /// only if it is among the oldest reads the budget picked; otherwise the
    /// old read is returned. A build passes a small budget, so a launch after
    /// the entries aged out refreshes them a slice at a time instead of
    /// reading the whole library.
    func resources(
        id: String,
        modifiedAt modificationDate: Date?,
        stamp: Int,
        staleRefreshes budget: inout StaleRefreshBudget,
        orRead read: () -> ResourceFacts
    ) -> ResourceFacts {
        let cached = lock.withLock { entries[id] }
        if let cached, cached.modifiedAt == modificationDate {
            let isFresh = now().timeIntervalSince(cached.readAt) < Self.maxAge
            guard !isFresh, budget.remaining > 0, cached.readAt <= budget.readAtOrBefore else { return cached.facts }
            budget.remaining -= 1
        }
        let readAt = now()
        let facts = read()
        lock.withLock {
            if clearedAt <= stamp, removedAt[id, default: 0] <= stamp {
                entries[id] = Entry(facts: facts, modifiedAt: modificationDate, readAt: readAt)
                isDirty = true
            }
        }
        return facts
    }

    func remove(_ ids: [String]) {
        lock.withLock {
            tick += 1
            for id in ids {
                entries[id] = nil
                removedAt[id] = tick
                if !isLoaded { removedBeforeLoad.insert(id) }
            }
            isDirty = true
            pruneRemovals()
        }
    }

    /// Drops every entry, and the file, so a later launch cannot load them.
    func removeAll() {
        lock.withLock {
            tick += 1
            entries.removeAll()
            removedAt.removeAll()
            clearedAt = tick
            isLoaded = true
            removedBeforeLoad.removeAll()
            isDirty = false
        }
        if let fileURL { fileLock.withLock { try? FileManager.default.removeItem(at: fileURL) } }
    }

    /// Applies one library change. Only a change that lists assets drops
    /// entries. A change without per-asset detail keeps them all: an asset's
    /// resources change only through an edit, which moves the modification
    /// date every entry is checked against, or through an iCloud download or
    /// offload, which the `maxAge` refresh covers. PR #27 dropped every entry
    /// here; on an iCloud library such changes arrive every few seconds, so
    /// every scan read the whole library again and, on a large one, never
    /// finished.
    func apply(_ effect: LibraryChangeEffect) {
        if case .assets(let ids) = effect, !ids.isEmpty { remove(ids) }
    }

    /// Makes every entry due for a refresh without dropping it.
    /// Capped at `now - maxAge` rather than set to one date, so the oldest
    /// reads still go first: repeated pulls refresh new entries each time.
    func markAllStale() {
        let staleAt = now().addingTimeInterval(-Self.maxAge)
        lock.withLock {
            for (id, entry) in entries where entry.readAt > staleAt { entries[id]?.readAt = staleAt }
            isDirty = true
        }
    }

    /// Drops entries for assets that are no longer in the library. A build of
    /// the whole library calls it with the ids it saw.
    func retainOnly(_ ids: Set<String>) {
        lock.withLock {
            // Usually nothing is gone: skip the 27,000-entry copy then.
            guard entries.keys.contains(where: { !ids.contains($0) }) else { return }
            entries = entries.filter { ids.contains($0.key) }
            isDirty = true
        }
    }

    var count: Int { lock.withLock { entries.count } }

    // MARK: File

    private struct Stored: Codable {
        struct Item: Codable {
            var id: String
            var modifiedAt: Date?
            var readAt: Date
            var fileSize: Int64
            var filename: String?
            var isLocallyAvailable: Bool
            var hasScreenRecordingFilename: Bool
            var primaryFileSize: Int64
        }
        var version: Int
        var items: [Item]
    }

    /// Reads the file once. An entry read in this launch wins over the file.
    func loadIfNeeded() {
        guard let fileURL, !lock.withLock({ isLoaded }) else { return }
        let items = (try? Data(contentsOf: fileURL))
            .flatMap { try? PropertyListDecoder().decode(Stored.self, from: $0) }
            .flatMap { $0.version == Self.fileVersion ? $0.items : nil } ?? []
        lock.withLock {
            guard !isLoaded else { return }
            isLoaded = true
            for item in items where entries[item.id] == nil && !removedBeforeLoad.contains(item.id) {
                entries[item.id] = Entry(
                    facts: ResourceFacts(
                        fileSize: item.fileSize,
                        filename: item.filename,
                        isLocallyAvailable: item.isLocallyAvailable,
                        hasScreenRecordingFilename: item.hasScreenRecordingFilename,
                        primaryFileSize: item.primaryFileSize
                    ),
                    modifiedAt: item.modifiedAt,
                    readAt: item.readAt
                )
            }
            removedBeforeLoad.removeAll()
        }
    }

    /// Writes the entries when anything changed since the last write.
    func saveIfDirty() {
        guard let fileURL else { return }
        fileLock.withLock { save(to: fileURL) }
    }

    /// Call with `fileLock` held. A removal or clear while the entries are
    /// encoded would be undone by writing them, so the save takes a new
    /// snapshot and tries again; after three tries it leaves the cache dirty
    /// for the next save.
    private func save(to fileURL: URL) {
        for _ in 0..<3 {
            switch saveOnce(to: fileURL) {
            case .done: return
            case .changedDuringEncode: continue
            }
        }
        lock.withLock { isDirty = true }
    }

    private enum SaveOutcome { case done, changedDuringEncode }

    private func saveOnce(to fileURL: URL) -> SaveOutcome {
        let taken: (entries: [String: Entry], tick: Int)? = lock.withLock {
            guard isDirty, isLoaded else { return nil }
            isDirty = false
            return (entries, tick)
        }
        guard let (snapshot, snapshotTick) = taken else { return .done }
        let items = snapshot.map { id, entry in
            Stored.Item(
                id: id,
                modifiedAt: entry.modifiedAt,
                readAt: entry.readAt,
                fileSize: entry.facts.fileSize,
                filename: entry.facts.filename,
                isLocallyAvailable: entry.facts.isLocallyAvailable,
                hasScreenRecordingFilename: entry.facts.hasScreenRecordingFilename,
                primaryFileSize: entry.facts.primaryFileSize
            )
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            let data = try encoder.encode(Stored(version: Self.fileVersion, items: items))
            // `tick` moves on every removal and clear. Entries added during the
            // encode are not lost: they set `isDirty` again for the next save.
            let unchanged = lock.withLock {
                guard tick == snapshotTick else {
                    isDirty = true
                    return false
                }
                return true
            }
            guard unchanged else { return .changedDuringEncode }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            lock.withLock { isDirty = true }
            AppLog.photo.error("Resource cache save failed: \(error.localizedDescription, privacy: .public)")
        }
        return .done
    }

    /// Call with `lock` held.
    private func pruneRemovals() {
        guard let oldest = openStamps.keys.min() else {
            removedAt.removeAll()
            return
        }
        removedAt = removedAt.filter { $0.value > oldest }
    }
}

// MARK: - Change Observer Helper

/// Carries a `PHChange` from PhotoKit's arbitrary callback queue to the
/// service actor. `PHChange` isn't `Sendable`, but the object is immutable
/// once delivered — Apple's own PhotoKit samples hand it across queues the
/// same way — and the box is unwrapped immediately on the actor, never stored.
/// Internal (not private) so the observer helper's initializer can name it.
struct LibraryChangeBox: @unchecked Sendable {
    let change: PHChange
}

final class PhotoLibraryChangeObserverHelper: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable (LibraryChangeBox) -> Void

    init(onChange: @escaping @Sendable (LibraryChangeBox) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange(LibraryChangeBox(change: changeInstance))
    }
}
