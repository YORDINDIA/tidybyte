# Changelog

## 1.0.0 (unreleased)

First public release, as Tidybyte for Mac (`com.sakshammittal.tidybyte`), shipping as both a Direct download (`mac-v*` DMG with Sparkle self-updates) and a sandboxed Mac App Store (`APP_STORE=1`) build.

### Added

- **One native macOS 26 window**: `NavigationSplitView` + unified `.inspector` column spanning Overview, Monitor (direct builds), Clean (`System Junk`, `Developer`, `Large & Old Files`, `Duplicates`, `Photos & Media`), Apps (`Applications`, `Leftovers`, `Login Items`), and Insights (`Space Explorer`, `Changes`, `History`). The Mac App Store build is sandboxed to user-selected folders and the Photos library (`Overview`, `Photos & Media`, `History`).
- **First-run onboarding**: Guided setup with a Full Disk Access check that advances automatically once access is on (skipped in the sandboxed App Store build), Photos library access prompt, and `"I'll scan later"` completion.
- **Deeper uninstaller, Leftovers, and Login Items**: Launch agents and daemons, privileged helpers, UUID-named containers, app-group containers from the code signature, WebKit data, and cookies with match confidence and evidence; 30-day inactive orphaned leftovers; post-delete orphan prompt; Login Items management with missing programs flagged.
- **Developer & system cleanup**: Homebrew (`brew cleanup --prune=all`), Docker (`docker builder prune`, `docker system df` reclaimable estimates, non-interactive prune options), pnpm (`pnpm store prune`), unavailable simulators (`xcrun simctl delete unavailable`, waiting until Simulator and Xcode quit), older Xcode Device Support folders, local Time Machine snapshots (review only, direct builds), and old installers across Downloads, Desktop, and Documents.
- **Photos & Media iOS parity (`IC-01..IC-04`)**:
  - Image & Video Compression with `Keep Both` vs `Replace & Trash Original`, sort orders (`Recently Added`, `Date Taken`, `Largest First`), `Max File Size` target mode (`1`–`10 MB`) with `"Check Result Sizes"` measured preflight and `"Already Under Target"` indicator, max dimension caps (`Original`, `3024 px`, `2048 px`), `Convert to HEIC`, `Use HEVC (H.265)` video export, and a `2×` free-disk-space headroom check before starting.
  - Dedicated `Live Photos` (`Live Photos → Still Images`) converter with interactive `PHLivePhotoView` playback, showing motion video vs still byte breakdown and converting verified full-resolution stills (`Replace & Trash Live Photo` or `Keep Both`).
  - On-device Vision Aesthetics scoring, Lens Smudge detection (Apple GPU family 7+), 512 px blur/exposure/perceptual-hash analysis, `Favorite` and `Burst Pick` protection in auto-clean selections, Quick Filters (`All`, `Safe Picks`, `Blurry / Smudged`, `Screenshots by App`) + `Filter by App`, synchronized zoomable `Side-by-Side Comparison`, iCloud download + delete, incremental freshness pruning, Swipe Review (`Add to Album…` picker/creator, two-finger trackpad horizontal swipe, `⌘Z` undo), and Limited/Denied Photos access guidance banners.
- **Space Explorer (sortable List + 8 visual modes)**: `Folders`, `Sunburst`, `Flame`, `Bubbles`, `Mind Map`, `Top Sizes`, `Age Map`, and 2D squarified `Treemap` visualizations grouped by Folder, Type, or Age, backed by memoized snapshot layout caches and shared `QLPreviewPanel` Quick Look (`Space` / double-click / context menu).
- **System Monitor & Apple Silicon hardware telemetry (direct builds)**:
  - 13 dashboards (`Overview` through `Containers`) with process grouping by app, an inspector with code signature, entitlements, parentage, command line, open files, listening ports, outbound network connections, and PID + kernel start-time verification before Quit/Force Quit.
  - Canonical 80-byte AppleSMC reads and `#KEY` dynamic sensor discovery for Apple Silicon and Intel temperatures and fan RPM/ranges (with fan control writes safely disabled as `"Automatic (Apple SMC)"`), `AGXAccelerator` (`IOAccelerator`) GPU renderer/tiler/in-use memory telemetry, Thermal Pressure state, and split Disk Read/Write & Network Download/Upload LTTB-downsampled charts excluding virtual overlay tunnels.
  - Up to 1 year of per-metric SQLite history with 48-hour raw samples and hourly rollups, opt-in misbehaving-app alerts, live menu bar extras gated by a master `"Show the monitor in the menu bar"` toggle that pauses background polling when off and the window is closed, and PNG snapshot export.
- **CLI & MCP server (`tidybyte-mcp`, direct builds)**: `tidybyte monitor status|top|ports|agents|limits|history` (table or `--json`) with a Settings symlink installer (`~/.local/bin/tidybyte`), plus `tidybyte-mcp` exposing 15 tools (7 cleanup + 8 read-only monitor tools), 3 prompts, and 2 resources (`execute` and `undo` enforce `confirm: true`; MCP execution is restricted to non-deleting `apfs_clone` duplicate folding with SQLite undo history).
- **21-language localization & RTL**: English plus 20 languages matching iOS (including right-to-left Arabic and Hebrew), live in-app language switcher in `Settings › General` without relaunch, localized `InfoPlist.xcstrings` permission descriptions, and `Scripts/localization/` CI validation.
- **Empty Trash, notifications, optional AI, and icon**: Overview Trash size readout with confirmed `Empty Trash…` (direct builds; `Open Trash` in App Store builds), optional Cleaner menu bar item (off by default), opt-in AI provider support (`Local Only` by default, supporting HTTPS and loopback HTTP endpoints, disabled in App Store builds), and Icon Composer layered app icon (`Assets.car`).

### Changed

- The app is now Tidybyte (`com.sakshammittal.tidybyte`), following the system light/dark appearance with macOS 26 Liquid Glass styling on floating action bars (`StagedQueueBar`, tool bars, Swipe controls) and native inspector/toolbar/sheet chrome.
- Scanning runs `~/Library` in parallel with duplicate pre-hashing and package-manager probes, displays live progress in the window subtitle, and preserves partial findings with a "stopped early" notice when cancelled.
- Reclaimable sizes account for hard links and APFS clones accurately and prevent double-counting `node_modules/.cache` inside project roots.
- Bulk Approve and Reject act only on the rows in the current area.
- Local SQLite database and Sparkle/AI/CLI/autoscan capabilities are cleanly partitioned by `DistributionChannel` (`APP_STORE` vs direct).

### Fixed

- Quitting works cleanly even when onboarding or confirmation sheets are open on macOS 26.
- Rapidly switching sidebar destinations no longer triggers an AppKit `NSToolbar` mutation crash: the toolbar keeps constant slots for the app lifetime using `HideUnless` visibility modifiers.
- `ApplicationRemovalWatcher` verifies bundle presence via LaunchServices (`NSWorkspace`) outside Trash before prompting for leftover cleanup, preventing false positives during Homebrew Cask upgrades, Sparkle self-updates, or app moves.
- Quitting mid-onboarding preserves your step, and the final step allows completing without running a scan.
- Cleanup posture (`Conservative`, `Balanced`, `Aggressive`) properly adjusts age and size thresholds.
- Folder rows and sidebar badges reflect true subtree sizes without double-counting nested suggestions, and higher-risk actions lead the review list.
- Menu bar undo prompts for the same optional regret reason as History.
- Monitor Battery/Power tiles agree on charging state, port numbers render without digit grouping, process footers pluralize cleanly, saving monitor snapshots works from backgrounded windows, and stale quit sheets cancel if a process exits or its PID is reused.
- Empty review states and Overview Latest Scan clearly surface missing Full Disk Access, unreadable locations, Spotlight-disabled checks, and skipped AI passes.
- Large home-folder scans stay bounded in memory by summarizing build/cache/simulator directories and capping detailed file records at one million (retaining individual records above the cap only for files ≥ 1 GB).
- `PathSafetyPolicy` resolves protected paths against the real home directory (`getpwuid`), uses slash-delimited cloud-provider matching, protects Xcode archives, UserData, simulator devices, keychains, and provisioning profiles, keeps duplicate folding out of `~/Library`, and never proposes top-level `Caches` or `Logs` containers for deletion.
- The unattended `--autoscan` LaunchAgent is bundled and registered via `SMAppService` (direct builds installed in `/Applications` or `~/Applications`) and strictly filters to pending APFS clone folds only.
- Direct builds carry the Photos entitlement required under the hardened runtime, Docker aggressive prune avoids interactive confirmation hangs, and long package-manager commands no longer time out prematurely.

### Verification

- Automated checks cover unit, safety, integration, localization (`Scripts/localization/check.mjs`), App Store channel (`DistributionChannel` and zero Sparkle linkage), and APFS `Scripts/mcp-e2e.py` verification (`NearDuplicateTests` and `NotificationSchedulerTests` run locally and are skipped on headless CI runners without a WindowServer or notification session).
