# AGENTS.md

This file provides guidance to coding agents working on the iOS app. The app lives in `ios/` of the TidyByte monorepo; run every command below from `ios/`. The root `AGENTS.md` describes the other folders.

## Project Overview

TidyByte is a native iOS app (Swift/SwiftUI, iOS 17+) that helps users clean up their photo library. Core UX is a Tinder-style swipe interface for reviewing media. The app is free, has no backend, and all processing is on-device. The app makes no network connections unless the user signs in to the optional Google Photos source (`Services/Google/`). Only then does it connect, and only to Google APIs. **No third-party dependencies** — Apple frameworks only.

## Build & Run

- **Xcode project**: `Tidybyte.xcodeproj` (generated from `project.yml` via XcodeGen)
- **Build**: `xcodebuild -project Tidybyte.xcodeproj -scheme Tidybyte -destination 'platform=iOS Simulator,name=<installed iPhone simulator>' build` (list simulators with `xcrun simctl list devices available`; CI picks the newest non-Duo iPhone automatically)
- **Swift version**: 5.9 language mode (Xcode 15.3+ toolchain — `ContinuationResumer` uses the `sending` keyword), strict concurrency enabled (`SWIFT_STRICT_CONCURRENCY: complete`)
- **Min deployment**: iOS 17
- **Universal** (`TARGETED_DEVICE_FAMILY: 1,2`, iPhone + iPad + iPhone Duo) — iPhone stays portrait-only (the swipe UX is portrait-centric), iPad supports all orientations, and iPhone Duo runs the same build on both of its displays (see `docs/duo-readiness.md`).
- **App icon** uses Xcode's single-size format: one opaque 1024×1024 PNG per appearance (`icon_1024.png`, `icon_1024_dark.png`, `icon_1024_tinted.png`) on `universal` / `platform: ios` slots. There are no per-idiom slots; Xcode derives every smaller size, including the iPad 152×152 icon. The dark and tinted appearances only work in this format — the older per-size format silently drops the `appearances` keys. Regenerate with `swift Tidybyte/Scripts/GenerateAppIcon.swift`; add `--sync-site` to refresh the site's logo, favicon and touch icons, or `--check` to verify what is on disk. One script renders both the app icon and the site marks, but the two now have separate geometry (`art` for the app, `siteArt` for the site): the app icon leads, so the site keeps the art it already has until someone runs `--sync-site`. `--check` also measures small-size legibility from the shipped 1024 and fails on a flat card, a lost card, or a missing shine; it runs on the light icon only.
- Must test on a physical device for photo library operations — simulator has a fake photo library

## Testing devices

- **Boot one iPhone simulator only.** Run every simulator build, test and manual layout check on that one device. Do not boot an iPad or an iPhone Duo simulator to check a layout, and do not run the suite again once per device. Photo-library operations still need a physical device (see above).
- **Every change must still work on iPhone, iPad and iPhone Duo.** Check the other sizes from the one booted iPhone:
  1. Base layout on geometry (window width, size class), not on `userInterfaceIdiom`. A Duo inner display reports `.phone` but is wide.
  2. Make sure the view works at these widths: Duo outer 466 × 678 pt, Duo inner 669 × 951 pt, narrowest iPad 744 pt, and iPad in all orientations.
  3. To see a view at one of these sizes, host it at a fixed frame inside the booted iPhone (a unit test with `UIHostingController` at that frame, or a `#Preview` with a fixed-size layout). A fixed frame does not change the size class, so also set it: `.environment(\.horizontalSizeClass, .regular)` for the 669 pt and iPad widths, `.compact` for 466 pt. Do not boot a new device for it.
  4. `IPadLayoutUITests` skips when the window is narrower than 600 pt, so it skips on the iPhone. `DuoLayoutUITests` runs on every window and only changes its edge-band assertion at 600 pt. A new test that checks only the wide layout must skip explicitly (`XCTSkipUnless` on window width), or it passes on the iPhone without testing anything.

## Architecture

**MVVM + Actors + SwiftData**

### Services (all Swift `actor` types)
Services are instantiated on-demand and injected via initializers, except a few intentional shared instances (`ImageCache.shared`, `PhotoLibraryService.shared`, `CleanupLedger.shared`, `PendingRoute.shared`). Dependencies are injected via initializers:
- `PhotoLibraryService` — wraps all PhotoKit operations (fetching, mutations, change observation, image loading). Uses `withCancellableContinuation` (`Shared/Utilities/ContinuationResumer.swift`) to bridge PHImageManager callbacks to async/await, so a cancelled task also cancels its PhotoKit request. Accesses undocumented KVC properties (`fileSize`, `locallyAvailable`) with `responds(to:)` guards. Library-wide summary builds run on its private `SummaryBuilder` actor and reuse resource reads from `ResourceCache`, which is kept on disk. **Read `docs/large-library-performance.md` before you change any of these.**
- `DuplicateDetectionService(photoService:, visionService:)` — exact (SHA-256) and near-duplicate (Vision feature prints) detection
- `VisionAnalysisService` — blur detection, exposure analysis, feature print generation. Works with CGImage inputs, no library access.
- `VideoCompressionService(photoService:)` — AVAssetExportSession-based compression with progress polling
- `NotificationService` — static methods only (not an actor), wraps UNUserNotificationCenter

### ViewModels
One `@Observable @MainActor` ViewModel per major screen. Progress reporting from services uses `@Sendable` closures normalized to 0.0–1.0 float range.

### Models
- **SwiftData models**: `SwipeRecord`, `CompressionRecord`, `StorageSnapshot`, `CleanupActivityRecord` — simple record types with `@Model` macro
- **Value types**: `AssetSummary` (DTO decoupling UI from PHAsset), `AlbumInfo` — both `Sendable`, `Identifiable`, `Hashable`

### Design System
`Color+Theme.swift` defines the design system: `Spacing` enum (xs=4 to xxxl=32), `CornerRadius` enum, semantic colors (`appBackground`, `destructive`, `success`), category colors, gradients, and shadow view modifiers.

## Large libraries

Some users have 25,000 or more photos and videos. Reading one asset's resources (file size, filename, iCloud state) is one Photos database round trip, so a full read of such a library takes 1–2 minutes. Version 1.2.0 shipped a change that cleared the resource cache on most library changes, and on those libraries Storage and Cleanup stopped loading. The rules that prevent this are in `docs/large-library-performance.md`. The short form:

- No library change clears `ResourceCache`. Only a change that lists assets drops those entries (`LibraryChangeEffect`, `ResourceCache.apply`).
- Pull-to-refresh marks entries for refresh (`refreshCachedResources`); only a permission change clears them.
- Old entries are used and refreshed a slice per build, oldest first. Do not add a hard expiry.
- Library-wide passes run off the main actor; PhotoKit requests stop when their task is cancelled.
- A pull request that changes library loading gives `Summary build` numbers from a simulator seeded with `npm run perf:seed -- --count 27000`.

## Key Conventions

- **Actors for all services** — no locks, no dispatch queues
- **`@Observable` macro** throughout — not `ObservableObject`/`@StateObject`
- **`Sendable` on all value types** passed across actor boundaries
- **Long-running operations yield periodically**: `if index % 20 == 0 { await Task.yield() }`, and report progress at most once per percent (`ProgressStep`)
- **Error enums** conform to `LocalizedError` (`PhotoServiceError`, `CompressionError`)
- **Non-critical failures** use `try?` (e.g., temp file cleanup, notification scheduling)
- **Tab structure**: `TabView` with independent `NavigationStack` per tab in `RootView`

## File Layout

```
Tidybyte/
├── App/           # @main entry + RootView (TabView)
├── Models/        # SwiftData models + DTOs
├── Services/      # Actor-based services
├── Features/      # Feature modules (Swipe/, Cleanup/, Storage/, Activity/, Settings/)
│   └── Cleanup/   # Sub-modules per tool (Duplicates/, Screenshots/, etc.)
└── Shared/
    ├── Components/ # Reusable UI (SkeletonView, EmptyStateView, GlassCard, etc.)
    ├── Extensions/ # Color+Theme, PHAsset+Extensions, etc.
    └── Utilities/  # ImageCache (actor singleton), PhotoPermissionHandler, CleanupLedger
```

## PRD Reference

`docs/prd.md` contains the full product requirements document with detailed feature specifications, data models, and UI/UX direction. Consult it for feature requirements and expected behavior.
