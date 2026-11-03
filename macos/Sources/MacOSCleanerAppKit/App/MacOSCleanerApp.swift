import MacOSCleanerCore
import SwiftUI
import UserNotifications

public struct MacOSCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppViewModel.bootstrap()
    @AppStorage(AppDelegate.menuBarExtraKey) private var showsMenuBarExtra = false
    // The monitor's own keys are read inside their scenes (MonitorMenuBarExtras),
    // never here: a second @AppStorage on the App struct makes SwiftUI's menu bar
    // extra round-trip its isInserted binding through UserDefaults every update
    // pass, spinning one core at 100% (KVO on the status item -> binding write ->
    // preference invalidation -> scene update, forever).

    /// Insertion binding for the status item, guarded against SwiftUI's update
    /// pass: the menu bar controller round-trips this binding on every pass
    /// (status item KVO writes the same value back through it), and the raw
    /// @AppStorage binding turned each round-trip into a UserDefaults write
    /// whose notification re-queued the update — the same 100% CPU loop. The
    /// Settings toggle writes the key through its own binding; this side only
    /// reads, and writes on a real change only.
    private var menuBarExtraInserted: Binding<Bool> {
        Binding(
            get: { showsMenuBarExtra },
            set: { if showsMenuBarExtra != $0 { showsMenuBarExtra = $0 } })
    }

    /// Set by the executable when Sparkle is linked (direct builds only).
    @MainActor public static var checkForUpdates: (() -> Void)?

    public init() {}

    public var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            ContentView(model: model)
                .frame(minWidth: Spacing.windowMinWidth, minHeight: Spacing.windowMinHeight)
                .task {
                    // App-scope startup: the menu bar extras need live samples
                    // even when the Monitor pane was never opened. With no
                    // surface attached the loop self-throttles to a 30 s
                    // heartbeat, so this stays cheap. start() is idempotent,
                    // so MonitorView's own call is a no-op here.
                    if DistributionChannel.supportsAdvanced {
                        model.monitor.start()
                    }
                }
                .onOpenURL { url in
                    // tidybyte://<destination>, plus tidybyte://swipe for Swipe Review.
                    guard url.scheme == AppIdentity.urlScheme, let host = url.host else { return }
                    if host == "swipe" {
                        model.destination = .media
                        model.cleanup.selectedTool = .swipe
                    } else if host == "monitor" {
                        // The monitor reads system-wide state; the sandboxed
                        // build has no monitor to open.
                        guard DistributionChannel.supportsAdvanced else { return }
                        model.destination = .monitor
                    } else if let destination = AppDestination(rawValue: host),
                        AppDestination.available.contains(destination) {
                        model.destination = destination
                    }
                }
                .modifier(MainWindowRegistration(model: model, delegate: appDelegate))
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands { CleanerCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra(AppIdentity.displayName, systemImage: "internaldrive", isInserted: menuBarExtraInserted) {
            MenuBarView()
        }

        #if MONITOR_SCENES
        MonitorMenuBarExtras(model: model.monitor)
        #endif
    }
}

private struct MainWindowRegistration: ViewModifier {
    let model: AppViewModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.setModel(model, openMainWindow: { openWindow(id: "main") })
            model.setRemovalWatching(UserDefaults.standard.object(forKey: AppDelegate.removalWatchKey) as? Bool ?? true)
        }
    }
}

// MARK: - Menu Bar

/// The menu bar extra is a native menu: two status lines, then short commands
/// (each label stays under 30 characters).
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let disk = DiskGaugeData.currentHomeVolume()
        if let free = disk.freeBytes {
            Text(String(localized: "\(free.formattedByteCount) free on disk", comment: "Menu bar disk status"))
        }
        if let memory = SystemStatus.memory() {
            Text(memoryLine(memory))
        }
        Divider()
        Button(String(localized: "Open Tidybyte", comment: "Menu bar: open main window")) { showMainWindow() }
            .keyboardShortcut("o", modifiers: [.command])
        Button(String(localized: "Scan Now", comment: "Menu bar: scan")) {
            showMainWindow()
            AppDelegate.shared?.scanNow()
        }
        Button(String(localized: "Undo Last Cleanup", comment: "Menu bar: undo last cleanup action")) {
            Task { @MainActor in await AppDelegate.shared?.undoLastAction() }
        }
        Divider()
        SettingsLink { Text(String(localized: "Settings…")) }
        Button(String(localized: "Quit Tidybyte", comment: "Menu bar: quit application")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private func showMainWindow() {
        openWindow(id: "main")
        // MB-F1: a status-item interaction confers no activation rights,
        // and the macOS 14+ no-argument activate() does not steal focus.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func memoryLine(_ memory: MemorySnapshot) -> String {
        let used = memory.usedBytes.formattedByteCount
        let total = memory.totalBytes.formattedByteCount
        return switch memory.pressure {
        case .normal: String(localized: "Memory \(used) of \(total)", comment: "Menu bar memory, normal pressure")
        case .warning: String(localized: "Memory pressure is high", comment: "Menu bar memory warning")
        case .critical: String(localized: "Memory pressure is critical", comment: "Menu bar memory critical")
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?
    private var model: AppViewModel?
    private var openMainWindow: (() -> Void)?
    /// A notification tap that arrived before the window existed (it launched the app).
    private var pendingRoute: [AnyHashable: Any]?

    /// The delegate must be set before launch finishes, or a tap that launches
    /// the app is lost.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // UNUserNotificationCenter traps outside an .app bundle (`swift run`).
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func setModel(_ model: AppViewModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        Self.shared = self
        if let pending = pendingRoute {
            pendingRoute = nil
            Task { await route(pending) }
        }
    }

    /// Last-chance cleanup: restore any fan minimums the monitor changed.
    func applicationWillTerminate(_ notification: Notification) {
        model?.monitor.stop()
    }

    private func route(_ info: [AnyHashable: Any]) async {
        guard let model else {
            pendingRoute = info
            return
        }
        let routeKind = info[NotificationScheduler.routeKey] as? String
        if routeKind == "leftovers",
            let bundleID = info[NotificationScheduler.bundleIDKey] as? String {
            await model.reviewLeftovers(
                ofRemovedApp: bundleID,
                name: info[NotificationScheduler.appNameKey] as? String ?? bundleID,
                bundlePath: info[NotificationScheduler.bundlePathKey] as? String ?? "")
        } else if routeKind == "monitor", DistributionChannel.supportsAdvanced {
            // A misbehaving-app alert: open the monitor, not the media tools.
            model.destination = .monitor
        } else if routeKind == "activity" {
            // Scan-complete (and any future tally notifications): open the
            // ledger that records what was reclaimed (PRD 9.5).
            model.destination = .history
        } else {
            model.destination = .media
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // userInfo holds only property-list strings; copy them out before hopping actors.
        let info = response.notification.request.content.userInfo
        let strings = info.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        Task { @MainActor in
            await route(strings)
            openMainWindow?()
            // MB-F1: a status-item interaction confers no activation rights,
        // and the macOS 14+ no-argument activate() does not steal focus.
        NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
        }
        completionHandler()
    }

    static let menuBarExtraKey = "showsMenuBarExtra"
    static let removalWatchKey = "watchesAppRemovals"
    static let monitorExtrasKey = MonitoringKeys.menuBarPanelEnabled

    /// Quit with the last window unless a menu bar extra keeps the app useful.
    /// The monitor extras default to on, so an unset key counts as enabled —
    /// matching the @AppStorage default in the app scene.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let defaults = UserDefaults.standard
        let monitorExtrasEnabled = defaults.object(forKey: Self.monitorExtrasKey) as? Bool ?? true
        return !(defaults.bool(forKey: Self.menuBarExtraKey) || monitorExtrasEnabled)
    }

    /// O-01: SwiftUI sheets run as modal sessions on macOS 26, and a presented
    /// sheet vetoes the quit Apple event — ⌘Q and the menu-bar Quit silently
    /// no-op whenever a sheet is up (first-run onboarding was force-quit-only).
    /// End any open sheets, then terminate once the dismissal has landed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sheets = sender.windows.flatMap(\.sheets)
        guard !sheets.isEmpty else { return .terminateNow }
        for sheet in sheets { sheet.sheetParent?.endSheet(sheet) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func scanNow() {
        model?.scanAll()
    }

    /// Restores the newest change, whichever history it is in.
    func undoLastAction() async {
        guard let model else { return }
        guard !model.isScanning, !model.isExecuting, !model.cleanup.isBusy else {
            model.setStatusMessage(
                String(
                    localized: "Undo skipped. A scan or cleanup is already running.",
                    comment: "Menu-bar undo during busy state"
                ))
            return
        }
        let mediaEvent = model.cleanup.activity
            .filter { $0.state == .complete && !$0.restored && $0.item.url != nil }
            .max { $0.date < $1.date }
        var systemRecord: UndoRecord?
        var systemDate = Date.distantPast
        if DistributionChannel.supportsAdvanced {
            await model.loadUndoHistory()
            systemRecord = model.undoRecords.first { $0.status == .available }
            if let record = systemRecord, let log = await model.historyOperation(id: record.operationLogID) {
                systemDate = log.timestamp
            }
        }
        // MB-10: route through the same regret prompt as a History restore —
        // nothing is restored until the user answers (or skips) on the window.
        if let mediaEvent, systemRecord == nil || mediaEvent.date >= systemDate {
            openMainWindow?()
            model.pendingUndoRestore = .mediaEvent(mediaEvent)
        } else if let systemRecord {
            openMainWindow?()
            model.pendingUndoRestore = .systemRecord(systemRecord)
        } else {
            model.setStatusMessage(
                String(
                    localized: "Nothing to undo. No completed cleanup operations yet.",
                    comment: "Menu-bar undo with empty history"
                ))
        }
    }
}
