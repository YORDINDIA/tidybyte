# Tidybyte for Mac — Design

## Direction

Tidybyte looks and behaves like Apple's own Mac apps: System Settings › Storage for the overview, Photos for media review, Finder for files. Standard SwiftUI navigation, toolbars, sheets, and controls receive macOS 26 Liquid Glass from the system. Custom floating glass (`floatingGlassOverlay` in `GlassEffectContainer`) is used only for navigation-layer action bars. macOS 26 is the minimum supported version.

## Layout and navigation

One `NavigationSplitView` with a source-list sidebar, one detail column, and a unified native `.inspector`.

| Sidebar | Rows |
| --- | --- |
| (top) | Overview |
| Monitor | Monitor (13-tab system dashboard; direct builds only) |
| Clean | System Junk, Developer, Large & Old Files, Duplicates, Photos & Media |
| Apps | Applications, Leftovers, Login Items |
| Insights | Space Explorer, Changes, History |

- Each review row shows only its own plan actions (`AppDestination.forCategory`). Bulk Approve and Reject act on the current row only.
- Sidebar badges show bytes still waiting for a decision.
- Photos & Media is a `NavigationStack`: a grouped list covering Swipe Review plus 13 tools across Free Up Space, Review & Organize, and Reclaim Without Deleting (including `Live Photos` with `PHLivePhotoView` playback and `IC-01..IC-04` image/video compression controls).
- Space Explorer offers a sortable `List` table plus **8 visual modes** (`Folders`, `Sunburst`, `Flame`, `Bubbles`, `Mind Map`, `Top Sizes`, `Age Map`, and 2D squarified `Treemap`), grouped by Folder, Type, or Age (depth 1–10), with deterministic `FolderPastel` colors, memoized snapshot caches (`ExploreSnapshotCache`), and shared `QLPreviewPanel` Quick Look (`QuickLookCoordinator`).
- Monitor hosts 13 tabs (`Overview` through `Containers`) on a top icon rail with embedded search, LTTB-downsampled single and split Disk/Network history charts, and process inspection (`ProcessInspectorView`) inside the unified `.inspector`.
- Changes and History switch sub-views with segmented controls in the toolbar.
- The App Store build (`APP_STORE=1`) shows `Overview`, `Clean › Photos & Media`, and `History` only (and hides the `Review` menu, `Empty Trash…`, Monitor menu bar extras, and the Monitoring, Scanning, AI & Privacy, and Data settings tabs).

Default window 1200 × 800 points, clamped at a 900 × 640 minimum; detail column minimum 420 points, so macOS collapses the sidebar before content clips. Sidebar 200–280 points (ideal 220). Inspector 280–400 points (ideal 320); it never turns into a sheet.

## Toolbar

The toolbar keeps constant slots for the app's entire lifetime using `HideUnless` visibility modifiers so switching destinations never mutates `NSToolbar` items: contextual items first (`Export…` in Monitor, `View` menu in Space Explorer, `Risk` filter and `Ask Tidybyte` on review rows, view picker in Changes, `Cleanup` / `Photos & Media` switcher in direct History, `Login Items Settings` in Login Items), a fixed `ToolbarSpacer`, **Scan** as the one `.glassProminent` action (`Stop` while busy), a second fixed `ToolbarSpacer`, and the Inspector toggle (when the destination supports `.inspector`). Progress renders in the window subtitle; errors and permission notices appear in a top strip only while they need attention.

## Visual system

- System text styles and SF Symbols through `Label`. Monospaced text only for paths and commands; sizes and counters use monospaced digits.
- Semantic system colors and the user's accent color; categorical color (`CategoricalPalette` / `FolderPastel`) only for data. Risk always pairs a colored SF Symbol with text, never color alone.
- Rounded rectangles with `Radius.card` (12 pt) and `Radius.cardCompact` (8 pt); no square strokes. Selection uses an accent border plus a check badge (Photos style).
- Glass only on navigation-layer controls: the approved-changes bar (`StagedQueueBar`), the media tool action bar, and the Swipe action buttons, each in one `GlassEffectContainer`. No glass on rows, cards, forms, grid cells, sheets, or charts.
- **Appearance & localization**: Follows System Settings for light/dark appearance (Monitor adds optional compact rows and a colorblind-safe chart palette in `Settings › Monitoring`). Ships **21 languages** (`en` + 20 languages) with an in-app live language switcher in `Settings › General` (`LanguageStore`) that updates SwiftUI views and `L10n` lookups immediately without relaunch, including automatic RTL layout mirroring (`\.layoutDirection`) for Arabic (`ar`) and Hebrew (`he`). System dialogs follow on next launch.

## Keyboard and menus

| Shortcut | Command |
| --- | --- |
| ⌘R | Scan |
| ⌘. | Stop active scan or cleanup |
| ⌘N | Scan Options… |
| ⌘1 – ⌘9 | Go to Overview, System Junk, Developer, Large & Old Files, Duplicates, Photos & Media, Applications, Space Explorer, History |
| ⌘⌥1 – ⌘⌥9 | Switch Monitor tabs (direct builds) |
| ⌘F | Find in the current row (or focus Monitor search / Space Explorer) |
| ⌘K | Ask Tidybyte (direct builds) |
| ⇧⌘A / ⇧⌘R | Approve / Reject selected action (direct builds) |
| View menu | Show or hide the sidebar, inspector, and toolbar (system commands) |
| Space | Toggle Quick Look (`QLPreviewPanel`) in Space Explorer, Duplicates, and Action Stack; Skip in Swipe Review |
| ⌘A, Delete, double-click | Select all, Move to Trash…, Quick Look / preview in media grids and review views |
| ⌘Z | Edit ▸ Undo reverts the last Swipe decision |

## Behavior and safety

Selection, approval, and execution are separate steps. Every cleanup runs through one immutable confirmation sheet that lists counts per sidebar area, revalidates the plan, and states exact reversibility (Trash, APFS clone fold, Recently Deleted, or permanent package-manager command). Service safety policy is unchanged by the UI.

Accessibility: VoiceOver labels and selected state on grid cells and chart summaries, keyboard paths for every pointer action, Reduce Motion, Reduce Transparency (system glass falls back), and Increase Contrast.
