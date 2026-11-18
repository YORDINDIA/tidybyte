# Tidybyte for Mac

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS application, SwiftUI (macOS 26 Liquid Glass), Apple silicon (`arm64`), macOS 26 and later. Ships in 21 languages including RTL Arabic and Hebrew with a live in-app switcher.

## Users and purpose

Mac users need to understand disk use, clean up files and Photos libraries safely, inspect app footprints, and monitor live hardware and process activity. Scanned paths and project context inform proposed actions; users review and approve actions before anything executes.

## Capabilities and constraints

- **Mac App Store build (`APP_STORE=1`)**: Sandboxed to user-selected folders and the Apple Photos library (`Overview`, `Photos & Media`, and `History` only). Includes Swipe Review (with album picker and trackpad swipe), Vision quality/aesthetics/lens-smudge analysis, duplicate/similar/burst/blurry/screenshot/large/chat-media tools, verified Image & Video Compression (`Keep Both` / `Replace & Trash Original`, `Max File Size` mode, measured preflight, HEIC/HEVC), dedicated `Live Photos → Still` conversion, iCloud download/Recently Deleted handling, and local restore/activity history. Sends no data anywhere.
- **Direct build (`mac-v*` DMG)**: Adds Full Mac cleanup (`System Junk`, `Developer`, `Large & Old Files`, `Duplicates` with APFS clone folding), `Applications` deep uninstaller, `Leftovers`, `Login Items`, `Space Explorer` (List + 8 visualization modes), `Changes` forecasts/diffs, `System Monitor` (13 dashboards, AppleSMC temperatures & read-only fans, `AGXAccelerator` GPU telemetry, split LTTB Disk/Network charts, outbound-connection process inspector, 1-year SQLite history, alerts, menu bar extras), `tidybyte monitor` CLI, `tidybyte-mcp` stdio server (15 tools, 3 prompts, 2 resources; `execute` restricted to non-deleting APFS clone folding), unattended APFS clone-fold LaunchAgent, Sparkle update checks, and optional user-configured AI classification (`Local Only` by default). Phase 2 cloud and team features are excluded.

## Product principles

- Show scope and evidence before a decision.
- Keep selection, approval, and execution separate.
- Apply safety checks again at execution.
- Describe recovery per operation; do not promise universal undo.
- Use native Mac navigation, keyboard controls, and accessibility behavior.
