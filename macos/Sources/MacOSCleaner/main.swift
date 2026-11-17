import Darwin
import MacOSCleanerAppKit
import MacOSCleanerCore

// Entry point. The full SwiftUI app shell (AppViewModel, views, design system)
// lives in the MacOSCleanerAppKit library so it can be unit-tested.

#if !APP_STORE
// `--autoscan` (invoked by the com.sakshammittal.tidybyte.autoscan LaunchAgent)
// runs one unattended maintenance pass — scan, then fold exact duplicates
// only, never delete — and exits without showing a window.
if CommandLine.arguments.contains("--autoscan") {
    exit(await AutoScanRunner.run())
}

// `tidybyte monitor <status|top|ports|agents|limits|history> [options]`:
// one-shot system readings for the terminal and AI assistants. Exits; no window.
if CommandLine.arguments.dropFirst().first == "monitor" {
    let code = await MonitorCLI.run(Array(CommandLine.arguments.dropFirst(2)))
    exit(code)
}
#endif

#if canImport(Sparkle) && !APP_STORE
import Sparkle

// Updates are signed with SUPublicEDKey and fetched from SUFeedURL.
// Builds missing either non-empty Info.plist entry never start the updater.
let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let feedURLString = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let canUpdate = !publicKey.isEmpty && !feedURLString.isEmpty && URL(string: feedURLString) != nil
let updater = SPUStandardUpdaterController(startingUpdater: canUpdate, updaterDelegate: nil, userDriverDelegate: nil)
if canUpdate {
    MacOSCleanerApp.checkForUpdates = { updater.checkForUpdates(nil) }
}
#endif

MacOSCleanerApp.main()
