# Tidybyte for Mac

Tidybyte finds space you can reclaim on your Mac and removes it only after you approve. It is the Mac companion to [Tidybyte for iPhone and iPad](https://apps.apple.com/app/tidybyte/id6775769763).

Everything runs on your Mac. Files move to the Trash, Photos items move to Recently Deleted, and History can restore supported operations. Ships in **21 languages** (including right-to-left Arabic and Hebrew) with a live language switcher in Settings.

## Features

| Area | What it does |
| --- | --- |
| Overview | Startup disk capacity, Trash size (`Empty Trash…` in direct builds, `Open Trash` in App Store builds), Storage by Kind, reclaim recommendations, and Latest Scan diagnostics. |
| System Junk | Caches, logs, browser data, and app support caches that apps rebuild. Top-level `Caches` and `Logs` containers are never proposed whole. |
| Developer | `node_modules`, build folders, Xcode DerivedData and old Device Support, unavailable simulators, and Homebrew, npm, pip, pnpm, and Docker cleanup (`docker system df` reclaimable estimates) through each tool's own command. |
| Large & Old Files | Large files, old downloads, and installers (`.dmg`, `.pkg`, `.xip`, `.iso`) older than 30 days. |
| Duplicates | Exact copies verified with SHA-256. Fold them into APFS clones to save space without deleting anything, or move extras to the Trash. |
| Photos & Media | Duplicates, similar shots, blurry/smudged photos (Vision Aesthetics, Lens Smudge, 512 px focus/exposure, `Favorite` and `Burst Pick` protection), bursts, screenshots, screen recordings, large files, downloads & chat media, synchronized zoomable Side-by-Side Comparison, iCloud download + delete, Swipe Review (`Add to Album…`, trackpad horizontal swipe, `⌘Z` undo), Image & Video Compression (`Keep Both` vs `Replace & Trash Original`, Recently Added / Date Taken / Largest sort, `Max File Size` target + `"Check Result Sizes"` preflight, HEIC / 3024 px / 2048 px / HEVC), and dedicated `Live Photos → Still` conversion with `PHLivePhotoView`. |
| Applications | Uninstall an app with its launch agents/daemons, privileged helpers, UUID/app-group containers, WebKit data, and cookies. Each item shows match evidence and confidence; shared or uncertain matches stay review-only. |
| Leftovers | Data of deleted apps, surfaced only when the app inventory is known, no installed app from the same developer owns it, and nothing inside changed for 30 days. An upgrade-safe watcher verifies LaunchServices outside Trash before offering leftover review after you remove an app. |
| Login Items | Agents and daemons that start with your Mac, with missing programs marked. |
| Space Explorer | Sortable `List` table plus **8 visual modes**: `Folders`, `Sunburst`, `Flame`, `Bubbles`, `Mind Map`, `Top Sizes`, `Age Map`, and 2D squarified `Treemap`, with memoized layout caches and shared `QLPreviewPanel` Quick Look (`Space`). |
| Changes | Storage forecast, comparison of two scans, and the Photos & Media trend. |
| History | Cleanup undo records and Photos & Media activity, with Restore where supported. |
| Monitor | 13 dashboards (`Overview`, `CPU`, `Memory`, `Disk`, `Network`, `GPU`, `Neural`, `Battery`, `Sound`, `Bluetooth`, `Projects`, `Agents`, `Containers`). Processes group by app with an inspector showing code signature, entitlements, parentage, command line, open files, listening ports, outbound network connections, and PID + start-time verified Quit/Force Quit. Includes 80-byte AppleSMC temperatures and read-only fan telemetry (`"Automatic (Apple SMC)"`), `AGXAccelerator` GPU renderer/tiler/in-use memory, Thermal Pressure, split Disk Read/Write and Network Down/Up LTTB charts, 1 year of local SQLite history with hourly rollups, opt-in alerts, PNG export, and live menu bar extras gated by a master toggle that pauses polling when off and the window is closed. |

Optional extras: a Cleaner menu bar item with free space and memory status (off by default); Monitor menu bar items (combined panel plus CPU, Memory, and Network on by default, Disk and Energy off by default, all controlled by **Show the monitor in the menu bar**); post-uninstall leftover prompts; weekly cleanup reminders; natural-language review (`⌘K`) with an optional AI provider you configure (`Local Only` by default); the `tidybyte` CLI; and the `tidybyte-mcp` server.

## Direct vs Mac App Store

| Capability | Direct download (`direct`) | Mac App Store (`APP_STORE=1`) |
| --- | --- | --- |
| Distribution & updates | Notarized DMG (`mac-v*`) with Sparkle self-updates | Sandboxed App Store package; no Sparkle linked |
| Photos & Media + Overview + History | Yes | Yes (user-selected folders + Photos library) |
| System Junk, Developer, Large & Old Files, Duplicates, Apps, Space Explorer, Changes | Yes (Full Mac + APFS clone folding + `Empty Trash…`) | Not included (requires unsandboxed system access) |
| System Monitor & menu bar extras | Yes (13 tabs + 6 Monitor menu bar extras) | Not included |
| `tidybyte` CLI, `tidybyte-mcp`, unattended APFS autoscan agent | Yes | Not included in bundle |
| Opt-in AI gateway | Yes (off by default; HTTPS or loopback HTTP) | Disabled (`localOnly` only) |

## Requirements

- macOS 26 or later
- A Mac with Apple silicon (`arm64`)

## Install

1. Download `Tidybyte-<version>.dmg` from the [releases page](https://github.com/YORDINDIA/tidybyte/releases) (or install from the Mac App Store when listed).
2. Open the disk image and drag Tidybyte to Applications.
3. Open Tidybyte. Onboarding guides you through Full Disk Access (direct build) and Photos access.

Direct builds update themselves with Sparkle: choose **Tidybyte › Check for Updates…** to check manually.

## Permissions

| Permission | Why | Without it |
| --- | --- | --- |
| Full Disk Access | Read Mail, Safari, Trash size, and other apps' containers and caches (direct builds). | Those areas are skipped and sizes show as Unknown. |
| Photos | Scan and clean similar, blurry, Live Photo, and large items in your Photos library. | Photos & Media covers your selected folders only; Limited Access displays a prompt to expand selection. |
| Notifications | Scan reminders, misbehaving-app alerts, and post-delete leftover prompts. | No notifications. |

## Safety model

- **Selection, approval, and execution are separate.** Selecting a row never approves it. Every run goes through one confirmation sheet that lists counts per area and revalidates the plan.
- **Trash first.** Files move to the Trash; Photos items move to Recently Deleted. `Empty Trash…` (direct builds only) is the only permanent user-invoked command, and it asks first.
- **Checked twice.** Each file's identity (device, inode, size, and modification time) is verified again just before it changes.
- **Protected paths.** Keychains, certificates and keys, provisioning profiles, `.ssh`, `.gnupg`, source code, coding-agent configs, system paths, Xcode UserData, and simulator devices are never changed; `PathSafetyPolicy` resolves against the user's real home directory (`getpwuid`) and never proposes top-level `Caches` or `Logs` containers. Xcode archives stay review-only.
- **Honest sizes.** A hard link with other names, or an APFS clone sharing blocks, frees nothing alone, and the estimate says so. Compression checks for `2×` batch free disk space before starting and verifies every output before replacing or trashing originals.
- **Tool commands.** Package-manager and simulator cleanups run the tool's own command and cannot be undone. Simulator cleanup waits until Simulator and Xcode quit.
- **Unattended runs never delete.** Automatic maintenance (`SMAppService` LaunchAgent in direct builds installed in `/Applications` or `~/Applications`) only folds exact duplicates into APFS clones when idle and plugged in (or ≥50% battery).

## For developers

Run these commands from `macos/`:

```sh
swift build                    # build (direct)
swift test                     # unit, safety, integration, and UI-logic suites (fixtures only)
swiftlint lint --strict --baseline .swiftlint-baseline.json
./Scripts/localization/refresh.sh && node Scripts/localization/check.mjs
NO_SPARKLE=1 Scripts/build-app.sh direct    # .build/Tidybyte.app (omit NO_SPARKLE=1 with release keys)

# App Store variant: scratch-path form only — a bare APP_STORE=1 swift build
# reuses the shared .build link plan and false-positives the Sparkle check
APP_STORE=1 swift build -Xswiftc -DAPP_STORE --scratch-path .build/app-store-scratch
otool -L .build/app-store-scratch/debug/Tidybyte \
  .build/app-store-scratch/debug/tidybyte-mcp | grep -ci sparkle   # expect 0
```

CI (`.github/workflows/macos.yml`) runs SwiftLint, localization checks (`format-placeholders.test.mjs`, `check.mjs`), direct and `APP_STORE=1` builds (asserting zero Sparkle linkage), `DistributionChannel` tests, `xcodebuild` tests (skipping `NearDuplicateTests` and `NotificationSchedulerTests` on headless runners where Vision feature-prints and `UNUserNotificationCenter` authorization stall without a WindowServer session), `Scripts/mcp-e2e.py`, and an app-bundle smoke check.

Pure SwiftPM, Swift 6 language mode, strict concurrency.

| Target | Role |
| --- | --- |
| `MacOSCleanerCore` | Services, models, safety policy, sensors/probes, localization (`L10n`), SQLite store |
| `MacOSCleanerAppKit` | SwiftUI app: views, view models, design tokens, `LanguageStore` |
| `MacOSCleaner` | App executable (`Tidybyte`); handles `--autoscan` and `monitor` CLI subcommands |
| `MacOSCleanerMCPLibrary` | Shared MCP JSON-RPC dispatcher, tool/prompt/resource catalogs, and monitor router |
| `MacOSCleanerMCP` | Executable `tidybyte-mcp` server over stdio JSON-RPC |

### MCP server and CLI

In direct builds, `Tidybyte.app/Contents/MacOS/tidybyte-mcp` exposes **15 tools**, **3 prompts** (`diagnose-slowdown`, `review-safe-duplicates`, `reclaim-dev-bloat`), and **2 resources** (`tidybyte://monitor/live` in direct builds, `tidybyte://scan/summary`):

- **Cleanup tools (7)**: `scan`, `list_findings`, `show_plan`, `check_finding`, `execute`, `history`, `undo`.
- **Read-only monitor tools (8, direct builds)**: `monitor_status`, `monitor_top`, `monitor_ports`, `monitor_agents`, `monitor_limits`, `monitor_history`, `monitor_inspect`, `monitor_hardware`.

`execute` and `undo` are dry runs unless called with `confirm: true`. `execute` strictly allows only non-deleting `apfs_clone` duplicate folding (recording full SQLite `UndoRecord` entries); destructive or high-risk actions and Trash-moving undos are refused over MCP and remain in the app.

The app executable answers the same monitor queries from the terminal (`Settings › General` can install a symlink at `~/.local/bin/tidybyte` or copy the command for `/usr/local/bin/tidybyte`):

```sh
tidybyte monitor status|top|ports|agents|limits|history [--json]
```

### Release

```sh
SIGNING_IDENTITY="Developer ID Application: NAME (TEAMID)" \
NOTARY_PROFILE=tidybyte-notary \
SPARKLE_PUBLIC_KEY=<base64 key> SPARKLE_PRIVATE_KEY_FILE=<path> \
Scripts/package-release.sh direct
```

The script signs inside out with the hardened runtime, notarizes and staples the app and DMG, and writes a one-item `appcast.xml`. `NO_SPARKLE=1 SIGNING_IDENTITY=- SKIP_NOTARIZE=1 Scripts/package-release.sh direct` runs a local unsigned test build without credentials. `Scripts/package-release.sh app-store` produces `.build/app-store/Tidybyte.pkg`. The update feed is `https://tidybyte.yord.si/mac/appcast.xml` (override with `SPARKLE_FEED_URL`).

See [DESIGN.md](DESIGN.md) for the interface and [CHANGELOG.md](CHANGELOG.md) for changes.

## FAQ

**Why is there no "Free up RAM" button?** macOS manages memory better than any app can. Tidybyte reports live memory use and pressure, and never purges memory.

**Why do some sizes say Unknown?** Tidybyte could not read that location, usually because Full Disk Access is off. It does not guess.

**Is anything sent over the network?** No, unless you turn on an AI provider in `Settings › AI & Privacy` (direct builds only; supports HTTPS or loopback HTTP for local models). Direct builds check the Sparkle update feed unless disabled; the Mac App Store build makes no network connections.
