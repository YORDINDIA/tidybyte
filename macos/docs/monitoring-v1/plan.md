# Monitoring v1 — System Activity Monitor for Tidybyte Mac

Parity plan for adding a full system-activity monitoring suite to the Mac app,
modeled on the feature set of vitalsmac.com (researched 2026-11-01: site copy,
OG screenshots, and the interactive tab demos embedded in its homepage HTML).
All code, UI copy, and assets are original to Tidybyte; only the feature
*concepts* (process grouping, menu bar items, history, alerts, dev tooling)
are carried over. The monitor integrates with the existing cleaner app as a new
sidebar destination — it does not fork the app.

## Feature inventory → implementation

| # | Feature (from vitalsmac.com) | Implementation |
| --- | --- | --- |
| 1 | Apps, not processes — helpers roll into their parent app | `AppProcessCatalog` groups by `.app` bundle; grouping modes By App / By Process / By Helper; per-app CPU, memory, disk, network, wakeups |
| 2 | Process Inspector — signature, parent, command line, files, ports | `ProcessInspector` (Security.framework code signing, `lsof`, `proc_pid_rusage`, `kinfo_proc` parent/children) + `ProcessInspectorView` inspector column |
| 3 | Menu bar monitor — one item per metric with dropdown | One `MenuBarExtra` per enabled metric (window style, live text) + a combined panel extra: tile grid, busiest apps, Open/Settings/Quit; order + selection in Settings |
| 4 | History — every metric, per app, up to a year | `MetricsHistoryStore` (own SQLite actor, WAL): raw samples → hourly rollups, pruning per retention setting |
| 5 | Alerts — high CPU, growing memory, heavy disk/network | `AlertEngine` evaluates sliding windows; posts via existing `NotificationScheduler` with per-app cooldown |
| 6 | Dev servers and ports — by project, idle flagged | `DevEnvironmentProbe`: `lsof` listeners + cwd → project grouping (ProjectDetector heuristics), idle = low CPU while listening |
| 7 | Docker containers — mem/CPU/net/ports per container | `ContainerProbe`: `docker ps` + `docker stats --no-stream` (JSON), graceful absence |
| 8 | Coding agents + AI usage limits | `AgentProbe`: detect agent CLIs as processes, session start, cwd project, child processes, CPU; local-only usage-limit readers for known agents (best effort, honest "unknown") |
| 9 | MCP server — AI assistants query the monitor | New tools in `MCPKit`: `monitor_status`, `monitor_top`, `monitor_ports`, `monitor_agents`, `monitor_limits` |
| 10 | CLI — table or JSON | `Tidybyte` executable subcommands: `monitor status|top|ports|agents|limits [--json]` |
| 11 | Volume mixer — per app + mic | `AudioProbe`: macOS 14.2+ public per-process audio properties (CoreAudio), device volume, mic-in-use badge; sliders disabled with tooltip when the API is unavailable |
| 12 | Temperature and fans — sensors, speeds, control | `SMCSensors`: IOKit SMC user client; temperature keys with friendly names, fan speeds/min/max; fan target behind explicit confirmation, restored on quit |
| 13 | Battery — level, drain, what keeps the Mac awake | `PowerProbe` (IOPS + IORegistry amperage/voltage/wattage) + `pmset -g assertions` parse |
| 14 | GPU and Neural Engine — utilization + who uses it | `GPUProbe`: Metal devices + IOAccelerator `PerformanceStatistics` device utilization; `NeuralEngineProbe`: IOReport best-effort, honest unavailable state |
| 15 | Overview — tiles + busiest + load/temperature cards | Overview tab: metric tile grid with Canvas sparklines, Load Average and Temperature cards, Busiest list, uptime |
| 16 | Quit / force quit, export as image | Context menu on processes (confirmations); `ImageRenderer` PNG export of the current tab |
| 17 | Arrange, units, calm/colorful/compact, colorblind palette | Settings › Monitoring: tab visibility + order, per-metric units, density, categorical palette (incl. colorblind-safe), sampling interval, history retention, alert thresholds |

Tabs: Overview, CPU, Memory, Disk, Network, GPU, Neural, Battery, Sound,
Bluetooth, Projects, Agents, Containers — matching the competitor's tab list.

## Architecture

```
MacOSCleanerCore/Services/Monitoring/
  SystemSnapshot.swift        // one Sendable snapshot of everything per tick
  ProcessProbe.swift          // kinfo_proc table, CPU deltas, rusage, load, uptime
  AppProcessCatalog.swift     // grouping into apps (pure, testable)
  SMCSensors.swift            // IOKit SMC: temps, fans, (guarded) fan target
  PowerProbe.swift            // battery, power source, wattage, assertions
  GPUProbe.swift              // Metal info + IOAccelerator utilization
  NeuralEngineProbe.swift     // IOReport best-effort
  AudioProbe.swift            // CoreAudio device + per-process volume
  BluetoothProbe.swift        // system_profiler SPBluetoothDataType
  DiskIOProbe.swift           // system-wide read/write rates
  NetworkProbe.swift          // interface throughput (sysctl route tables)
  PortProbe.swift             // lsof listeners + per-pid cwd
  DevEnvironmentProbe.swift   // listeners → dev servers → projects, idle flags
  ContainerProbe.swift        // docker ps/stats JSON parsing
  AgentProbe.swift            // coding-agent sessions + children
  AgentUsageReader.swift      // local-only plan-usage readers
  MetricsHistoryStore.swift   // SQLite samples, rollups, pruning
  AlertEngine.swift           // threshold windows → notifications
  MonitoringEngine.swift      // actor: sampling loop, TaskGroup, AsyncStream
  ProcessInspector.swift      // signature/entitlements/files/ports details
  ProcessActions.swift        // quit / force-quit with confirmation policy
  MonitoringSettings.swift    // UserDefaults-backed settings store
  VitalsCLI.swift             // table/JSON renderers for the CLI
```

AppKit layer (`MacOSCleanerAppKit/Monitor/`): `MonitorModel` (@MainActor
@Observable facade owning the engine stream), `MonitorView` with a toolbar
tab switcher, one view per tab, `ProcessTableView` (Table), inspector,
metric tiles + sparklines (Canvas), history charts (Swift Charts), menu bar
extras, export as image.

Integration points: `AppDestination.monitor` (advanced builds only, sidebar
section after Overview; not in the ⌘1–⌘9 list to avoid churning shortcuts),
`MacOSCleanerApp` starts the engine + menu bar extras, `SettingsView` gains a
Monitoring pane, MCP dispatcher gains monitor tools, executable `main.swift`
gains `monitor` subcommands.

## Constraints (repo rules)

- Apple frameworks only; sampling uses public APIs (sysctl/libproc, IOKit,
  CoreAudio, Security, Metal, IOPS) plus Apple system tools via the existing
  `ProcessRunner` pattern (`lsof`, `nettop`, `iostat`, `pmset`,
  `system_profiler`, `docker`). No network calls; no analytics.
- Swift 6 strict concurrency: every probe is an actor or an `enum` namespace
  of static functions; `MonitorModel` is `@MainActor @Observable`.
- All user-facing strings through `String(localized:)` (English Mac catalog).
- No force unwraps; typed errors conforming to `LocalizedError`; `os.Logger`.
- SwiftLint: new code must be clean against the baseline (line ≤ 140,
  function bodies ≤ 50, files ≤ 500 warning / 1000 error — split accordingly).
- The App Store build (`APP_STORE=1`) keeps its sandbox: the Monitor
  destination and menu bar extras are hidden there, same as other advanced
  features (`DistributionChannel.supportsAdvanced`).
- Safety: never kill a process without an explicit confirmation sheet; the
  fan control write requires confirmation and restores the previous value on
  quit; agent usage readers are strictly read-only.

## Phases

1. Core probes + snapshot model + app grouping (builds green).
2. History store + alerts + monitoring engine.
3. Main-window UI: tab views, process table, inspector, export.
4. Menu bar extras + settings pane.
5. CLI subcommands + MCP tools.
6. Tests (grouping, deltas, parsing, thresholds, pruning, CLI format),
   `swift build`, `swift test`, lint, app-bundle smoke build.

## Review round (2026-11-01, later)

Four-agent review (parity audit, Core review, UI review, gate runner) found
and fixed: a dead network probe (wrong sysctl mib + wrong route-message
offsets), per-process rates inflated by a never-assigned timestamp, an SMC
write path that zeroed fan values, energy read as bit-pattern garbage,
unwired battery probe, a Cancel button that SIGTERM'd the target, dead
force-quit controls, menu-bar staleness (sampling now app-wide), never-called
history pruning, history keys that never matched queries, missing
notification authorization, and a 100% CPU update loop caused by
MenuBarExtra insertion round-trips (fixed with change-guarded AppStorage
bindings). Known follow-ups: fan-control UI awaits SMC availability on
target hardware; Neural load and per-app volume remain platform-limited.

## Status (2026-11-01)

Implemented through phase 6. Live-verified on this machine: process table,
app grouping, CLI commands, MCP tools, GPU utilization, battery/uptime.
Known platform limits, surfaced honestly in the UI: macOS 26 gates AppleSMC
reads (temperatures/fans show unavailable), Neural Engine load has no public
API, and macOS exposes per-app audio activity but not per-app volume control.
