import MacOSCleanerCore
import SwiftUI
import UserNotifications

public struct MacOSCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppViewModel.bootstrap()
    @AppStorage(AppDelegate.menuBarExtraKey) private var showsMenuBarExtra = false

    private var menuBarExtraInserted: Binding<Bool> {
        Binding(
            get: { showsMenuBarExtra },
            set: { if showsMenuBarExtra != $0 { showsMenuBarExtra = $0 } }
        )
    }

    /// Set by the executable when Sparkle is linked (direct builds only).
    @MainActor public static var checkForUpdates: (() -> Void)?

    public init() {}

    public var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            ContentView(model: model)
                .frame(minWidth: Spacing.windowMinWidth, minHeight: Spacing.windowMinHeight)
                .environment(model.languageStore)
                .environment(\.locale, model.languageStore.locale)
                .environment(\.layoutDirection, model.languageStore.layoutDirection)
                .task {
                    startMonitorIfMenuBarEnabled()
                }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                    startMonitorIfMenuBarEnabled()
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
                .modifier(MainWindowRegistration(model: model, delegate: appDelegate))
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CleanerCommands(model: model)
            CommandGroup(replacing: .appTermination) {
                Button(L10n.string("Quit Tidybyte", language: model.languageStore.activeOverride)) {
                    AppDelegate.shared?.requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        Settings {
            SettingsView(model: model)
                .environment(model.languageStore)
                .environment(\.locale, model.languageStore.locale)
                .environment(\.layoutDirection, model.languageStore.layoutDirection)
        }

        MenuBarExtra(AppIdentity.displayName, systemImage: "internaldrive", isInserted: menuBarExtraInserted) {
            MenuBarView(model: model)
                .environment(model.languageStore)
                .environment(\.locale, model.languageStore.locale)
                .environment(\.layoutDirection, model.languageStore.layoutDirection)
        }

        #if MONITOR_SCENES
        MonitorMenuBarExtras(model: model.monitor)
        #endif
    }

    @MainActor
    private func startMonitorIfMenuBarEnabled() {
        guard DistributionChannel.supportsAdvanced else { return }
        if model.monitor.settings.isMenuBarPanelEnabled || model.monitor.settings.hasEnabledMenuBarMetric {
            model.monitor.start()
        }
    }

    @MainActor
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == AppIdentity.urlScheme, let host = url.host else { return }
        switch host {
        case "swipe":
            model.destination = .media
            model.cleanup.selectedTool = .swipe
        case "cleanup":
            model.destination = .media
            model.cleanup.selectedTool = nil
        case "activity":
            model.historyShowsMedia = true
            model.destination = .history
        case "screenshots":
            model.destination = .screenshots
        case "monitor":
            guard DistributionChannel.supportsAdvanced else { return }
            let tabName = url.pathComponents.dropFirst().first
            let tab = tabName.flatMap(MonitorTab.init(rawValue:))
            if let tab, MonitorTab.visibleTabs.contains(tab) {
                model.monitor.selectedTab = tab
            }
            model.monitor.start()
            model.destination = .monitor
        default:
            if let destination = AppDestination(rawValue: host),
               AppDestination.available.contains(destination) {
                model.destination = destination
            }
        }
    }
}

private struct MainWindowRegistration: ViewModifier {
    let model: AppViewModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.setModel(model, openMainWindow: { openWindow(id: "main") })
            model.setRemovalWatching(
                UserDefaults.standard.object(forKey: AppDelegate.removalWatchKey) as? Bool ?? true
            )
        }
    }
}

// MARK: - Menu Bar

/// The menu bar extra is a native menu: two status lines, then short commands.
struct MenuBarView: View {
    @Bindable var model: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let override = model.languageStore.activeOverride
        let disk = DiskGaugeData.currentHomeVolume()
        if let free = disk.freeBytes {
            Text(L10n.format("%@ free on disk", language: override, free.formattedByteCount))
        }
        if let memory = SystemStatus.memory() {
            Text(memoryLine(memory, override: override))
        }
        if model.screenshots.totalNamedCount > 0 {
            Text(
                model.screenshots.totalNamedCount == 1
                    ? L10n.string("1 screenshot named on this Mac", language: override)
                    : L10n.format("%lld screenshots named on this Mac", language: override, model.screenshots.totalNamedCount)
            )
        }
        Divider()
        Button(L10n.string("Open Tidybyte", language: override)) { showMainWindow() }
            .keyboardShortcut("o", modifiers: [.command])
        Button(L10n.string("Scan Now", language: override)) {
            showMainWindow()
            AppDelegate.shared?.scanNow()
        }
        Toggle(
            L10n.string("Auto-Rename Screenshots", language: override),
            isOn: Binding(
                get: { model.screenshots.isAutoRenameEnabled },
                set: { enabled in Task { await model.screenshots.setAutoRenameEnabled(enabled) } }
            )
        )
        Button(L10n.string("Tidy Up Screenshots…", language: override)) {
            showMainWindow()
            model.destination = .screenshots
            Task { await model.screenshots.chooseFolderAndTidyUp() }
        }
        if model.screenshots.canUndoLast {
            Button(L10n.string("Undo Last Screenshot Rename", language: override)) {
                Task { await model.screenshots.undoLast() }
            }
        }
        Button(L10n.string("Undo Last Cleanup", language: override)) {
            Task { @MainActor in await AppDelegate.shared?.undoLastAction() }
        }
        Divider()
        SettingsLink { Text(L10n.string("Settings…", language: override)) }
        Button(L10n.string("Quit Tidybyte", language: override)) {
            AppDelegate.shared?.requestQuit()
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func memoryLine(_ memory: MemorySnapshot, override: AppLanguage?) -> String {
        let used = memory.usedBytes.formattedByteCount
        let total = memory.totalBytes.formattedByteCount
        return switch memory.pressure {
        case .normal: L10n.format("Memory %@ of %@", language: override, used, total)
        case .warning: L10n.string("Memory pressure is high", language: override)
        case .critical: L10n.string("Memory pressure is critical", language: override)
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?
    private var model: AppViewModel?
    private var openMainWindow: (() -> Void)?
    private var pendingRoute: [AnyHashable: Any]?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @MainActor func requestQuit() {
        endSheetsAndQuit()
    }

    @objc func handleQuitAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { self.endSheetsAndQuit() }
    }

    private func endSheetsAndQuit() {
        let sheets = NSApp.windows.filter { $0.sheetParent != nil }
        for sheet in sheets {
            sheet.sheetParent?.endSheet(sheet)
        }
        model?.prepareForTermination()
        if sheets.isEmpty {
            NSApp.terminate(nil)
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                NSApp.terminate(nil)
            }
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

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareForTermination()
    }

    @MainActor
    func openDestination(_ destination: AppDestination) {
        guard let model, AppDestination.available.contains(destination) else { return }
        model.destination = destination
        bringMainWindowForward()
    }

    @MainActor
    func openMonitor(tab: MonitorTab? = nil, selectAppGroup groupID: String? = nil) {
        guard DistributionChannel.supportsAdvanced, let model else { return }
        model.monitor.start()
        if let tab, MonitorTab.visibleTabs.contains(tab) {
            model.monitor.selectedTab = tab
        }
        if let groupID,
           let group = model.monitor.snapshot?.groups.first(where: { $0.id == groupID }) {
            model.monitor.select(group: group)
            model.showsInspector = true
        }
        openDestination(.monitor)
    }

    private func bringMainWindowForward() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
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
                bundlePath: info[NotificationScheduler.bundlePathKey] as? String ?? ""
            )
            bringMainWindowForward()
        } else if routeKind == "monitor", DistributionChannel.supportsAdvanced {
            let tab = (info[NotificationScheduler.metricKey] as? String).flatMap(MonitorTab.init(rawValue:))
            let bundleID = info[NotificationScheduler.bundleIDKey] as? String
            let appName = info[NotificationScheduler.appNameKey] as? String
            let matchedGroup = model.monitor.snapshot?.groups.first { group in
                if let bundleID, !bundleID.isEmpty, group.id == bundleID { return true }
                if let appName, !appName.isEmpty, group.name == appName { return true }
                return false
            }
            openMonitor(tab: tab, selectAppGroup: matchedGroup?.id)
        } else if routeKind == "activity" {
            model.historyShowsMedia = true
            openDestination(.history)
        } else if routeKind == "cleanup" {
            model.cleanup.selectedTool = nil
            openDestination(.media)
        } else {
            openDestination(.media)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let strings = info.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        Task { @MainActor in
            await route(strings)
        }
        completionHandler()
    }

    static let menuBarExtraKey = "showsMenuBarExtra"
    static let removalWatchKey = "watchesAppRemovals"
    static let monitorExtrasKey = MonitoringKeys.menuBarPanelEnabled

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.menuBarExtraKey) {
            return false
        }
        #if MONITOR_SCENES
        if DistributionChannel.supportsAdvanced {
            let monitorPanelEnabled = defaults.object(forKey: Self.monitorExtrasKey) as? Bool
                ?? MonitoringDefaults.menuBarPanelEnabled
            let anyMetricEnabled = MonitoringKeys.menuBarMetrics.contains { metric in
                defaults.object(forKey: metric.key) as? Bool ?? metric.defaultEnabled
            }
            if monitorPanelEnabled || anyMetricEnabled {
                return false
            }
        }
        #endif
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.prepareForTermination()
        let sheets = sender.windows.flatMap(\.sheets)
        guard !sheets.isEmpty else { return .terminateNow }
        for sheet in sheets { sheet.sheetParent?.endSheet(sheet) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func scanNow() {
        model?.scanAll()
    }

    func undoLastAction() async {
        guard let model else { return }
        let override = model.languageStore.activeOverride
        guard !model.isScanning, !model.isExecuting, !model.cleanup.isBusy else {
            model.setStatusMessage(
                L10n.string("Undo skipped. A scan or cleanup is already running.", language: override)
            )
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
        if let mediaEvent, systemRecord == nil || mediaEvent.date >= systemDate {
            openMainWindow?()
            model.pendingUndoRestore = .mediaEvent(mediaEvent)
        } else if let systemRecord {
            openMainWindow?()
            model.pendingUndoRestore = .systemRecord(systemRecord)
        } else {
            model.setStatusMessage(
                L10n.string("Nothing to undo. No completed cleanup operations yet.", language: override)
            )
        }
    }
}
