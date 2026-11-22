import XCTest
import SwiftUI
import UIKit
@testable import Tidybyte

final class UtilityAndStorageTests: XCTestCase {

    func testSetToggleInsertsThenRemoves() {
        var set: Set<String> = []
        set.toggle("a")
        XCTAssertTrue(set.contains("a"))
        set.toggle("a")
        XCTAssertFalse(set.contains("a"))
    }

    func testDeviceUsedCapacityIsNonNegativeWhenAvailableExceedsTotal() {
        // available-for-important-usage can momentarily exceed total capacity.
        let info = DeviceStorageInfo(totalCapacity: 100, availableCapacity: 150)
        XCTAssertEqual(info.usedCapacity, 0)
    }

    func testDeviceUsedCapacityNormalCase() {
        let info = DeviceStorageInfo(totalCapacity: 256_000_000_000, availableCapacity: 56_000_000_000)
        XCTAssertEqual(info.usedCapacity, 200_000_000_000)
    }

    // (burstBadgeCount test removed with the helper itself, E8: it asserted
    // `groups.count == groups.count` — a tautology around an inlined value.)

    @MainActor
    func testOnDeviceMediaExcludesICloudOnly() {
        let vm = StorageDashboardViewModel()
        vm.categories = [StorageCategory(id: "photos", name: "Photos", bytes: 100, count: 1, color: .blue)]
        vm.iCloudOnlySize = 40
        // 100 total library − 40 iCloud-only = 60 locally resident.
        XCTAssertEqual(vm.onDeviceMediaSize, 60)
    }

    @MainActor
    func testAppsAndOtherIsUsedMinusOnDeviceMedia() {
        let vm = StorageDashboardViewModel()
        vm.categories = [StorageCategory(id: "photos", name: "Photos", bytes: 100, count: 1, color: .blue)]
        vm.iCloudOnlySize = 40
        vm.deviceStorage = DeviceStorageInfo(totalCapacity: 1000, availableCapacity: 900) // used = 100
        // used 100 − on-device media 60 = 40 for apps/system/other.
        XCTAssertEqual(vm.appsAndOtherSize, 40)
    }

    @MainActor
    func testAppsAndOtherClampsToZeroWhenMediaExceedsUsed() {
        let vm = StorageDashboardViewModel()
        vm.categories = [StorageCategory(id: "photos", name: "Photos", bytes: 200, count: 1, color: .blue)]
        vm.iCloudOnlySize = 0
        vm.deviceStorage = DeviceStorageInfo(totalCapacity: 100, availableCapacity: 0) // used = 100
        // on-device media (200) > used (100) → clamp to 0 rather than render negative.
        XCTAssertEqual(vm.appsAndOtherSize, 0)
    }

    // MARK: - Thumbnail cache staleness is scoped per asset (PR #2 finding)

    /// The eviction counter used to be global, so editing asset B discarded a
    /// perfectly fresh in-flight load of unrelated asset A — and the next scroll
    /// re-fetched from disk for no reason.
    func testImageCacheStampIsScopedPerAsset() async {
        let cache = ImageCache(countLimit: 10, totalCostLimit: 1_000_000)
        let image = makeTestImage()
        let stampA = await cache.stamp(for: "a")
        let stampB = await cache.stamp(for: "b")

        await cache.removeAllVariants(of: "b")

        let storedA = await cache.setImage(image, for: "a", assetId: "a", ifStamp: stampA)
        XCTAssertTrue(storedA, "an edit of another asset must not invalidate this load")

        let storedB = await cache.setImage(image, for: "b", assetId: "b", ifStamp: stampB)
        XCTAssertFalse(storedB, "this asset's own eviction must refuse the stale store")
    }

    /// A global flush (`removeAll`) invalidates every in-flight load, including
    /// ones whose per-asset version did not move.
    func testImageCacheStampRejectsAfterGlobalFlush() async {
        let cache = ImageCache(countLimit: 10, totalCostLimit: 1_000_000)
        let stamp = await cache.stamp(for: "a")

        await cache.removeAll()

        let stored = await cache.setImage(makeTestImage(), for: "a", assetId: "a", ifStamp: stamp)
        XCTAssertFalse(stored)
    }

    // MARK: - Resource cache

    func testResourceCacheReusesAnUnchangedAsset() {
        let cache = ResourceCache()
        let date = Date(timeIntervalSince1970: 1_000)
        var reads = 0
        for _ in 0..<2 {
            _ = cache.resources(id: "a", modifiedAt: date, stamp: cache.stamp()) { reads += 1; return facts() }
        }
        XCTAssertEqual(reads, 1)
    }

    /// An edit moves the asset's modification date: read it again.
    func testResourceCacheRereadsAnEditedAsset() {
        let cache = ResourceCache()
        _ = cache.resources(id: "a", modifiedAt: Date(timeIntervalSince1970: 1_000), stamp: cache.stamp()) { facts(size: 1) }
        let edited = cache.resources(id: "a", modifiedAt: Date(timeIntervalSince1970: 2_000), stamp: cache.stamp()) { facts(size: 2) }
        XCTAssertEqual(edited.fileSize, 2)
    }

    /// iCloud downloads don't always produce a library change: an old read
    /// is read again even if nothing evicted it.
    func testResourceCacheRereadsAfterMaxAge() {
        let clock = TestClock()
        let cache = ResourceCache(now: { clock.now })
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: cache.stamp()) { facts() }
        var reads = 0
        clock.now += ResourceCache.maxAge - 1
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: cache.stamp()) { reads += 1; return facts() }
        XCTAssertEqual(reads, 0)
        clock.now += 2
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: cache.stamp()) { reads += 1; return facts() }
        XCTAssertEqual(reads, 1)
    }

    func testResourceCacheRereadsRemovedAssetsOnly() {
        let cache = ResourceCache()
        func read(_ ids: [String]) -> [String] {
            let stamp = cache.stamp()
            var reads: [String] = []
            for id in ids {
                _ = cache.resources(id: id, modifiedAt: nil, stamp: stamp) { reads.append(id); return facts() }
            }
            return reads
        }
        XCTAssertEqual(read(["a", "b"]), ["a", "b"])
        cache.remove(["a"])
        XCTAssertEqual(read(["a", "b"]), ["a"])
        cache.removeAll()
        XCTAssertEqual(read(["a", "b"]), ["a", "b"])
        XCTAssertEqual(read(["a", "b"]), [])
    }

    /// A fetch made before a change holds the changed asset as it was, even if
    /// its build only starts after the change (queued behind another build):
    /// nothing it reads for that asset is kept.
    func testResourceCacheKeepsNothingAFetchReadForAnAssetRemovedAfterIt() {
        let cache = ResourceCache()
        let stamp = cache.stamp()
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: stamp) { facts() }
        cache.remove(["b"])
        _ = cache.resources(id: "b", modifiedAt: nil, stamp: stamp) { facts() }
        _ = cache.resources(id: "c", modifiedAt: nil, stamp: stamp) { facts() }

        var reads: [String] = []
        let next = cache.stamp()
        for id in ["a", "b", "c"] {
            _ = cache.resources(id: id, modifiedAt: nil, stamp: next) { reads.append(id); return facts() }
        }
        XCTAssertEqual(reads, ["b"], "only the asset removed after the fetch is read again")
    }

    func testResourceCacheKeepsNothingAFetchReadAfterAClear() {
        let cache = ResourceCache()
        let stamp = cache.stamp()
        cache.removeAll()
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: stamp) { facts() }
        var reads = 0
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: cache.stamp()) { reads += 1; return facts() }
        XCTAssertEqual(reads, 1)
    }

    /// Duplicate scans and exports drop one asset at a time, thousands of
    /// times: that must never wipe the rest of the cache.
    func testResourceCacheKeepsOtherAssetsThroughManyRemovals() {
        let cache = ResourceCache()
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: cache.stamp()) { facts() }
        for index in 0..<20_000 { cache.remove(["removed-\(index)"]) }
        var reads = 0
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: cache.stamp()) { reads += 1; return facts() }
        XCTAssertEqual(reads, 0)
    }

    /// Pruning removals (on later removals and on releases) must keep the
    /// ones a still-open fetch needs: its stale read of "a" is not kept.
    func testResourceCachePruningKeepsRemovalsAnOpenFetchNeeds() {
        let cache = ResourceCache()
        let open = cache.stamp()
        cache.remove(["a"])
        for index in 0..<100 { cache.remove(["other-\(index)"]) }
        cache.release(cache.stamp())
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: open) { facts() }
        cache.release(open)

        var reads = 0
        _ = cache.resources(id: "a", modifiedAt: nil, stamp: cache.stamp()) { reads += 1; return facts() }
        XCTAssertEqual(reads, 1)
    }

    // MARK: Large-library report (27,000 items): no change may force a full re-read

    private func readAll(_ cache: ResourceCache, _ ids: [String]) -> [String] {
        let stamp = cache.stamp()
        defer { cache.release(stamp) }
        var reads: [String] = []
        for id in ids {
            _ = cache.resources(id: id, modifiedAt: nil, stamp: stamp) { reads.append(id); return facts() }
        }
        return reads
    }

    /// PR #27 cleared the cache on every change without per-asset detail, and
    /// on every change that did not touch the library list at all (an album
    /// edit). On an iCloud library those arrive every few seconds, so every
    /// scan read the whole library again and never finished.
    func testLibraryChangesWithoutAssetDetailKeepEveryRead() {
        let cache = ResourceCache()
        XCTAssertEqual(readAll(cache, ["a", "b", "c"]), ["a", "b", "c"])
        cache.apply(.unknown)
        cache.apply(.unaffected)
        XCTAssertEqual(readAll(cache, ["a", "b", "c"]), [])
        cache.apply(.assets(removedOrChanged: ["b"]))
        XCTAssertEqual(readAll(cache, ["a", "b", "c"]), ["b"])
    }

    /// One build with a stale-refresh budget of `limit`. Returns the ids read.
    private func refreshBuild(_ cache: ResourceCache, _ ids: [String], limit: Int) -> [String] {
        var budget = cache.staleRefreshBudget(limit)
        let stamp = cache.stamp()
        defer { cache.release(stamp) }
        var reads: [String] = []
        for id in ids {
            _ = cache.resources(id: id, modifiedAt: nil, stamp: stamp, staleRefreshes: &budget) { reads.append(id); return facts() }
        }
        return reads
    }

    /// A launch the next day finds every entry past `maxAge`. A build reuses
    /// them and re-reads only as many as its budget allows.
    func testStaleEntriesAreRefreshedWithinTheBudgetOnly() {
        let clock = TestClock()
        let cache = ResourceCache(now: { clock.now })
        _ = readAll(cache, ["a", "b", "c"])
        clock.now += ResourceCache.maxAge + 1
        XCTAssertEqual(refreshBuild(cache, ["a", "b", "c"], limit: 2), ["a", "b"])
        // The next build refreshes the one still stale; fresh ones cost nothing.
        XCTAssertEqual(refreshBuild(cache, ["a", "b", "c"], limit: 2), ["c"])
        XCTAssertEqual(refreshBuild(cache, ["a", "b", "c"], limit: 2), [])
    }

    /// The budget goes to the oldest reads. Taken in fetch order, the first
    /// assets would take it after every expiry and the rest would never refresh.
    func testStaleRefreshGoesOldestFirstAcrossExpiries() {
        let clock = TestClock()
        let cache = ResourceCache(now: { clock.now })
        _ = readAll(cache, ["a", "b", "c"])
        clock.now += ResourceCache.maxAge + 1
        XCTAssertEqual(refreshBuild(cache, ["a", "b", "c"], limit: 1), ["a"])
        clock.now += ResourceCache.maxAge + 1
        XCTAssertEqual(refreshBuild(cache, ["a", "b", "c"], limit: 1), ["b"])
        XCTAssertEqual(refreshBuild(cache, ["a", "b", "c"], limit: 1), ["c"])
    }

    /// A new or edited asset is always read, whatever the budget.
    func testBudgetNeverHoldsBackAMissingRead() {
        let cache = ResourceCache()
        var budget = ResourceCache.StaleRefreshBudget(remaining: 0, readAtOrBefore: .distantPast)
        var reads = 0
        _ = cache.resources(id: "new", modifiedAt: nil, stamp: cache.stamp(), staleRefreshes: &budget) { reads += 1; return facts() }
        XCTAssertEqual(reads, 1)
    }

    /// Pull-to-refresh makes entries due, without a full re-read, and each
    /// pull refreshes entries the last one did not reach.
    func testRepeatedPullsRefreshNewEntries() {
        let clock = TestClock()
        let cache = ResourceCache(now: { clock.now })
        _ = readAll(cache, ["a", "b"])
        clock.now += 10
        cache.markAllStale()
        XCTAssertEqual(refreshBuild(cache, ["a", "b"], limit: 1), ["a"])
        clock.now += 10
        cache.markAllStale()
        XCTAssertEqual(refreshBuild(cache, ["a", "b"], limit: 1), ["b"])
    }

    /// Nil change details mean "nothing changed" only for a whole-library
    /// baseline. With a narrow one (the first fetch was the screenshots), an
    /// edit elsewhere also gives nil, and its old thumbnail must go.
    func testNilDetailsAreUnaffectedOnlyForAWholeLibraryBaseline() {
        XCTAssertEqual(LibraryChangeEffect(baselineIsFullLibrary: true, details: nil), .unaffected)
        XCTAssertEqual(LibraryChangeEffect(baselineIsFullLibrary: false, details: nil), .unknown)
        XCTAssertEqual(LibraryChangeEffect(baselineIsFullLibrary: nil, details: nil), .unknown)
        let incremental = LibraryChangeEffect.Details(isIncremental: true, removedOrChanged: ["a"])
        XCTAssertEqual(LibraryChangeEffect(baselineIsFullLibrary: false, details: incremental), .assets(removedOrChanged: ["a"]))
        let whole = LibraryChangeEffect.Details(isIncremental: false, removedOrChanged: [])
        XCTAssertEqual(LibraryChangeEffect(baselineIsFullLibrary: true, details: whole), .unknown)
    }

    /// A build that saw as many ids as the cache holds can still leave an
    /// entry for a deleted asset: its own read of another asset was not kept.
    func testRetainOnlyDropsADeadEntryWhenTheCountsMatch() {
        let cache = ResourceCache()
        _ = readAll(cache, ["dead", "a"])
        cache.retainOnly(["a", "b"])
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(readAll(cache, ["a"]), [])
    }

    func testRetainOnlyDropsDeletedAssets() {
        let cache = ResourceCache()
        _ = readAll(cache, ["a", "b"])
        cache.retainOnly(["a"])
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(readAll(cache, ["a", "b"]), ["b"])
    }

    // MARK: Cache file

    private func temporaryCacheURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceCacheTest-\(UUID().uuidString).plist")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A cold launch reuses what the last launch read.
    func testCacheFileCarriesReadsToTheNextLaunch() {
        let url = temporaryCacheURL()
        let date = Date(timeIntervalSince1970: 1_234.5678)
        let first = ResourceCache(fileURL: url)
        first.loadIfNeeded()
        let stamp = first.stamp()
        let stored = ResourceFacts(fileSize: 42, filename: "IMG_1.HEIC", isLocallyAvailable: false,
                                   hasScreenRecordingFilename: false, primaryFileSize: 40)
        _ = first.resources(id: "a", modifiedAt: date, stamp: stamp) { stored }
        first.saveIfDirty()

        let next = ResourceCache(fileURL: url)
        next.loadIfNeeded()
        var reads = 0
        let loaded = next.resources(id: "a", modifiedAt: date, stamp: next.stamp()) { reads += 1; return facts() }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(loaded, stored)
    }

    /// Permission changes clear the file too, so a later launch cannot load it.
    func testRemoveAllDeletesTheFile() {
        let url = temporaryCacheURL()
        let cache = ResourceCache(fileURL: url)
        cache.loadIfNeeded()
        _ = readAll(cache, ["a"])
        cache.saveIfDirty()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        cache.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A change that lands before the first build loads the file must not be
    /// undone by the load.
    func testRemovalBeforeLoadIsNotBroughtBackByTheFile() {
        let url = temporaryCacheURL()
        let first = ResourceCache(fileURL: url)
        first.loadIfNeeded()
        _ = readAll(first, ["a", "b"])
        first.saveIfDirty()

        let next = ResourceCache(fileURL: url)
        next.apply(.assets(removedOrChanged: ["a"]))
        next.loadIfNeeded()
        XCTAssertEqual(readAll(next, ["a", "b"]), ["a"])
    }

    func testUnreadableOrOtherVersionFileIsIgnored() throws {
        let url = temporaryCacheURL()
        struct Other: Codable { var version: Int; var items: [String] }
        try PropertyListEncoder().encode(Other(version: ResourceCache.fileVersion + 1, items: ["x"])).write(to: url)
        let cache = ResourceCache(fileURL: url)
        cache.loadIfNeeded()
        XCTAssertEqual(cache.count, 0)
    }

    private final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
    }

    private func facts(size: Int64 = 1_000) -> ResourceFacts {
        ResourceFacts(fileSize: size, filename: nil, isLocallyAvailable: true, hasScreenRecordingFilename: false)
    }

    private func makeTestImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}
