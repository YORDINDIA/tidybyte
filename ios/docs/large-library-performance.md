# Large photo libraries: performance rules

This document explains why TidyByte can become slow on a large photo library,
what went wrong before, and the rules that keep it fast. Read it before you
change `PhotoLibraryService`, `SummaryBuilder`, `ResourceCache`, or any screen
that loads the whole library.

## Summary

- On a large library, the slow part is reading each asset's resources: file
  size, file name, and iCloud state.
- The app reads them once and keeps them in `ResourceCache`, on disk.
- Clearing that cache, or skipping it, makes every screen wait for a full read
  of the library again.
- A test pins each rule below. If a change makes one of these tests fail, the
  change is wrong, not the test.

## The cost

`PHAssetResource.assetResources(for:)` is one Photos database round trip per
asset. Photos serves these reads one at a time; eight parallel threads were only
about 1.4 times faster (PR #8). So a full read takes time in proportion to the
library size:

| Device | Items | Full read |
|---|---|---|
| iPhone 16 Pro, iCloud library | 16,587 | 21–23 s |
| iPhone 18 Pro simulator, Release build | 27,015 | 87–113 s |

Storage, Cleanup, the widget snapshot, Large Files and the duplicate scans all
need sizes for every asset, so each of them waits for this read when the cache
cannot answer.

## History

| Change | Effect |
|---|---|
| PR #6 | The swipe deck lists assets without reading resources. The first card shows in about 1 s. |
| PR #7 | Library-wide builds run on `SummaryBuilder`, not on `PhotoLibraryService`, so thumbnails do not wait for them. |
| PR #8 | `ResourceCache` keeps reads between builds. A change without per-asset detail does not clear it. |
| PR #27 (shipped in 1.2.0) | **Regression.** `handleLibraryChange` cleared the cache again on every change without per-asset detail, and on every change that did not touch the library list (an album edit). |
| This fix (1.2.1) | Restores the PR #8 rule as tested code, keeps the cache on disk, and removes the other full re-reads. |

### The 1.2.0 report

A user with about 27,000 photos and videos reported that every screen loaded
very slowly, and some screens did not load at all.

On an iCloud library, PhotoKit sends changes every few seconds. With the 1.2.0
code, most of them cleared `ResourceCache`. Each clear started a new full read of
about 90 seconds. A clear during a read also discarded that read's results. So
Storage and Cleanup could wait for a read that never finished.

Three other causes made every launch slow:

1. The cache was in memory only. Every cold launch read the whole library.
2. Entries expired after 30 minutes, and an expired entry was read again before
   the build returned.
3. Pull-to-refresh cleared the cache.

## Rules

### 1. No library change clears `ResourceCache`

`handleLibraryChange` maps each `PHChange` to a `LibraryChangeEffect`, and
`ResourceCache.apply(_:)` applies it. The baseline is the broadest fetch made so
far, and a whole-library fetch always wins:

| PhotoKit result for the baseline fetch | Effect | Resource reads | Thumbnails |
|---|---|---|---|
| `changeDetails(for:)` is `nil`, and the baseline is the whole library (an album, collection or other metadata changed) | `.unaffected` | keep all | keep all |
| `changeDetails(for:)` is `nil`, and the baseline is narrow (screenshots, one album) | `.unknown` | keep all | drop all |
| Incremental details, and the baseline is the whole library | `.assets(removedOrChanged:)` | drop the listed ids | drop the listed ids |
| Incremental details, and the baseline is narrow | `.unknown` | keep all | drop all |
| Details that are not incremental, or no baseline fetch yet | `.unknown` | keep all | drop all |

A narrow baseline lists changes to its own assets only. It cannot show an edit
to an asset outside it, so every answer from it drops the thumbnails. Thumbnails are cached by id alone, with no modification date.

This is safe because an asset's resources change in two ways only:

- An edit. It moves `modificationDate`, and every entry is checked against it.
- An iCloud download or offload. Rule 3 refreshes those.

Tests: `testLibraryChangesWithoutAssetDetailKeepEveryRead`,
`testNilDetailsAreUnaffectedOnlyForAWholeLibraryBaseline`.

### 2. The cache is kept on disk

`ResourceCache` writes `Library/Caches/ResourceCache.plist` (about 4 MB for
27,000 items):

- During a long read, every 10 s, so a launch that iOS ends early is continued
  by the next launch.
- After the first build of each launch, after a build that read 1,000 or more
  assets, and after a build 30 s or more after the last write. The file is not
  written after every small change.
- When the app moves to the background (`RootView`), off the main thread and
  under a background-task assertion, because iOS can end the app there. A build
  that is still running keeps saving every 10 s and at its end.
- A save that finds a removal or clear made during its encode takes a new
  snapshot and tries again, so a dropped entry cannot come back from the file.

The first build of a launch loads the file. If you change `ResourceFacts` or the
stored format, increase `ResourceCache.fileVersion`. A file with another version
is ignored, which costs one full read.

Tests: `testCacheFileCarriesReadsToTheNextLaunch`,
`testRemovalBeforeLoadIsNotBroughtBackByTheFile`,
`testFileWithAnotherVersionIsIgnored`, `testUnreadableFileIsIgnored`.

### 3. Old entries are used, and refreshed a slice at a time

An entry older than `ResourceCache.maxAge` (30 minutes) can have a wrong iCloud
state. The build still uses it. Each build reads again at most
`SummaryBuilder.staleRefreshesPerBuild` (500) of these entries:

- A whole-library build takes the oldest entries in the cache first, so every
  entry gets its turn.
- A narrower build (screenshots, one album, photos only) takes its own old
  entries in fetch order, because the oldest entries in the cache are usually
  not in its fetch.

Do not add a hard expiry: it turns every launch on the next day into a full
read.

Tests: `testStaleEntriesAreRefreshedWithinTheBudgetOnly`,
`testStaleRefreshGoesOldestFirstAcrossExpiries`,
`testBudgetNeverHoldsBackAMissingRead`.

### 4. Only a permission change clears the cache

| Action | Call | Effect |
|---|---|---|
| Pull-to-refresh on Storage or Cleanup | `refreshCachedResources()` | Marks every entry due. The next build refreshes up to 5,000 of them, oldest first, and stops starting new reads after 3 s (the limit is checked before each read). A small library is refreshed in full; a large one continues on later builds. |
| Photo permission changes | `discardCachedResources()` | Deletes the entries and the file. One full read follows. |

Tests: `testRepeatedPullsRefreshNewEntries`, `testRemoveAllDeletesTheFile`.

### 5. Drop an entry only when its original was downloaded

Reading an original with network access can download it, which changes its
iCloud state. `loadFullImageData` and the share export call `forgetResources`
for that reason. The exact-duplicate hash runs with network access off, so it
cannot download, and it keeps the entry. When a hash fails, the scan reads that
asset's resources again (`isOnDevice`). If the original is no longer on the
device, the asset is counted in the "iCloud-only skipped" total, and its
cached read is replaced. Other failures are not counted. Do not add `forgetResources` to a path
that cannot download: after a duplicate scan it made the next Storage load read
every hashed asset again.

### 6. Library-wide work never blocks the UI

- Summary builds run on `SummaryBuilder`, not on `PhotoLibraryService` and not
  on the main actor.
- Passes over every asset (`StorageLibraryTotals`,
  `CleanupHomeViewModel.libraryCounts`) run in a detached task. Only the small
  mapping to UI rows runs on the main actor.
- A scan reports progress through `ProgressStep`, at most once per percent. One
  report per asset queued tens of thousands of main-actor tasks.

### 7. A cancelled load stops its PhotoKit request

Every PhotoKit request in `PhotoLibraryService` uses
`withCancellableContinuation` and `PendingRequest`. When a card leaves the deck
or a cell scrolls off, its request (and any iCloud download) stops. Use the same
pattern for a new request.

Tests: `ContinuationResumerTests`.

### 8. The swipe deck does not read resources

`fetchDeckListing` builds the deck from `PHAsset` properties only.
`fetchSummaries(for:)` reads full details for a 40-card window ahead of the
current card. Do not read resources for the whole deck.

## Measure a change

Use a simulator library at least as large as the reported one. Give numbers in
the pull request.

1. Add photos to the booted simulator. 27,000 take about 10 minutes, and they
   stay in that simulator's library:

   ```sh
   npm run perf:seed -- --count 27000
   ```

2. Keep the app's info-level log lines. Without this, `log show` drops them:

   ```sh
   xcrun simctl spawn booted log config --subsystem com.sakshammittal.tidybyte --mode "level:info,persist:info"
   ```

3. Build the app in Release, install it, and grant photo access:

   ```sh
   xcrun simctl install booted <path to Tidybyte.app>
   xcrun simctl privacy booted grant photos com.sakshammittal.tidybyte
   ```

4. Cold-launch the app and open Storage. Do not use a UI test that resets photo
   permission: a permission change clears the cache (rule 4).

   ```sh
   xcrun simctl terminate booted com.sakshammittal.tidybyte
   xcrun simctl launch booted com.sakshammittal.tidybyte -hasCompletedOnboarding YES
   xcrun simctl openurl booted "tidybyte://storage"
   ```

5. Read the log:

   ```sh
   xcrun simctl spawn booted log show --last 5m --style compact --info \
     --predicate 'subsystem == "com.sakshammittal.tidybyte" AND category == "PhotoLibrary"' \
     | grep -E "Summary build|Library change|Exact duplicate"
   ```

   - `Summary build: N assets, R resource reads, T ms`: one line per library
     build. After the first launch, `R` must stay small.
   - `Library change: unaffected | assets ... | unknown`: which row of
     rule 1 applied.
   - `Exact duplicate scan hashes N of M local assets`: how much the size
     pre-filter removed.

6. Reset the log setting when you finish:

   ```sh
   xcrun simctl spawn booted log config --subsystem com.sakshammittal.tidybyte --reset
   ```

A slow or read-heavy `Summary build` line is logged at notice level, so it is in
a user's device log too. Ask a user who reports slow loading for those lines.

### Results of the 1.2.1 fix

iPhone 18 Pro simulator, Release build, 27,015 items:

| Case | 1.2.0 | 1.2.1 |
|---|---|---|
| First build after a cold launch | 87–113 s, 27,015 reads | 0.76–0.94 s, 0 reads |
| A new album is created | 100 s, 27,015 reads | 0.84 s, 1 read |
| iOS ends the app 45 s into the first read | the next launch starts again | the next launch reads the 14,135 left (42.5 s) |
| Storage after an exact duplicate scan | about 27,000 reads | 0.95 s, 0 reads |
| First launch after install or update | 87–113 s | about 93 s, once |

## Known remaining costs

- The first launch after install, after an update that changes
  `ResourceCache.fileVersion`, after a permission change, or after iOS purges
  the app's caches reads the whole library once.
- Swipe home fetches every swipe record on the main actor after each library
  change.
- The visual duplicate scan keeps one Vision feature print per photo, so its
  memory grows with the library.

## Checklist for a pull request that touches library loading

- [ ] No new call clears `ResourceCache` in response to a library change.
- [ ] No new path reads resources for the whole library outside
      `SummaryBuilder`.
- [ ] A new PhotoKit request uses `withCancellableContinuation`.
- [ ] A new pass over every asset runs off the main actor.
- [ ] The tests named above pass.
- [ ] The pull request gives `Summary build` numbers from a simulator with
      25,000 or more items: a cold launch, and a library change.
