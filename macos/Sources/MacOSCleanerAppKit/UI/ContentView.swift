import AppKit
import MacOSCleanerCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppViewModel
    @FocusState private var isSearchFocused: Bool
    @State private var executionRequest: ExecutionRequest?
    @AppStorage(OnboardingView.stepKey) private var onboardingStep = 0
    @SceneStorage("changesMode") private var changesMode = ChangesView.Mode.forecast
    @State private var statusToast: String?
    @State private var statusToastTask: Task<Void, Never>?

    var body: some View {
        let override = model.languageStore.activeOverride
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: Spacing.sidebarWidth, max: 280)
        } detail: {
            searchableDetail(override: override)
                .navigationTitle(model.destination.title(language: override))
                .navigationSubtitle(busyText(override: override) ?? "")
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { StatusNotices(model: model) }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomOverlayStack }
                .inspector(isPresented: $model.showsInspector) {
                    inspectorContent(override: override)
                        .inspectorColumnWidth(min: 280, ideal: Spacing.detailPanelWidth, max: 400)
                }
        }
        .toolbar { toolbar(override: override) }
        .sheet(isPresented: $model.showsScanSetup) { ScanSetupView(model: model) }
        .sheet(isPresented: $model.showsPlanner) { NaturalLanguagePlanView(model: model) }
        .sheet(isPresented: Bindable(model.cleanup).showsScope) { CleanupScopeView(model: model.cleanup) }
        .sheet(item: $executionRequest) { request in ExecutionConfirmView(model: model, request: request) }
        .sheet(item: $model.pendingUndoRestore) { request in
            RegretReasonSheet(
                subject: request.subject,
                override: override,
                onCancel: { model.pendingUndoRestore = nil },
                restore: { reason in
                    model.pendingUndoRestore = nil
                    switch request {
                    case .systemRecord(let record):
                        if let reason {
                            model.selectedRegretReason = reason.rawValue
                            Task { await model.restoreWithReason(record) }
                        } else {
                            Task { await model.restore(record) }
                        }
                    case .mediaEvent(let event):
                        Task { await model.cleanup.restore(event) }
                    }
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { onboardingStep < OnboardingView.doneStep },
                set: { _ in }
            )
        ) {
            OnboardingView(model: model).interactiveDismissDisabled()
        }
        .onKeyPress(.escape) {
            guard isBusy, !isSearchFocused else { return .ignored }
            stop()
            return .handled
        }
        .onChange(of: model.searchFocusRequest) { focusSearchField() }
        .onChange(of: model.errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onChange(of: model.destination) {
            model.searchText = ""
            if !model.destination.supportsInspector {
                model.showsInspector = false
            } else if model.destination == .monitor, model.monitor.selectedGroupID != nil {
                model.showsInspector = true
            }
        }
        .onChange(of: model.monitor.selectedGroupID) { _, selectedID in
            if model.destination == .monitor, selectedID != nil {
                model.showsInspector = true
            }
        }
        .onChange(of: model.showsInspector) { _, shown in
            if !shown, model.destination == .monitor {
                model.monitor.clearSelection()
            }
        }
        .onChange(of: model.statusMessageEpoch) {
            let message = model.statusMessage
            guard !message.isEmpty, !model.isScanning else { return }
            AccessibilityNotification.Announcement(message).post()
            statusToastTask?.cancel()
            statusToast = message
            statusToastTask = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                statusToast = nil
            }
        }
        .task {
            if let message = model.errorMessage { AccessibilityNotification.Announcement(message).post() }
            await model.cleanup.load()
            await model.screenshots.load()
            await model.loadUndoHistory()
            await model.restoreLastSession()
            model.scheduleDeferredMaintenance()
        }
    }

    @ViewBuilder
    private func searchableDetail(override: AppLanguage?) -> some View {
        if model.destination.supportsSearch {
            detail
                .searchable(
                    text: $model.searchText,
                    placement: .toolbar,
                    prompt: L10n.format("Search %@", language: override, model.destination.title(language: override))
                )
                .searchFocused($isSearchFocused)
        } else {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.destination {
        case .overview: OverviewView(model: model)
        case .monitor: MonitorView(model: model.monitor)
        case .systemJunk, .developer, .largeFiles, .leftovers: ActionStackView(model: model)
        case .duplicates: DuplicatesTabView(model: model)
        case .screenshots: ScreenshotsView(model: model)
        case .media: MediaWorkspace(model: model.cleanup)
        case .applications: ApplicationsView(model: model)
        case .loginItems: LoginItemsView(model: model)
        case .explorer: FilesView(model: model)
        case .changes: ChangesView(model: model, mode: $changesMode)
        case .history: HistoryView(model: model, showsMedia: $model.historyShowsMedia)
        }
    }
}

extension ContentView {
    @ViewBuilder
    private func inspectorContent(override: AppLanguage?) -> some View {
        switch model.destination {
        case .explorer:
            SelectionInspectorView(model: model)
        case .systemJunk, .developer, .largeFiles, .leftovers, .duplicates:
            WhyPanelView(model: model)
        case .screenshots:
            ScreenshotInspectorView(model: model)
        case .applications:
            ApplicationDetailsView(model: model)
        case .history:
            HistoryDetailsView(model: model)
        case .monitor:
            if let inspection = model.monitor.inspection {
                ProcessInspectorView(
                    inspection: inspection,
                    history: model.monitor.selectedAppHistory
                ) { pid, force in
                    model.monitor.quit(pid: pid, confirmedStart: inspection.startedAt, force: force)
                }
            } else if model.monitor.selectedGroupID != nil {
                InspectorSkeletonView()
            } else {
                ContentUnavailableView(
                    L10n.string("No selection", language: override),
                    systemImage: "sidebar.trailing",
                    description: Text(L10n.string("Select an app to see its details.", language: override))
                )
            }
        default:
            ContentUnavailableView(
                L10n.string("No selection", language: override),
                systemImage: "sidebar.trailing",
                description: Text(L10n.string("Select an item to see its details.", language: override))
            )
        }
    }

    private var bottomOverlayStack: some View {
        let showsQueueBar = model.destination.isReview || model.destination == .duplicates
        return VStack(spacing: Spacing.elementTight) {
            if statusToast != nil || (model.showScanSummaryToast && model.activeScanSummary != nil) {
                VStack(spacing: Spacing.elementTight) {
                    if let statusToast {
                        toastCapsule(statusToast)
                    }
                    if model.showScanSummaryToast, let summary = model.activeScanSummary {
                        toastCapsule(summary)
                    }
                }
                .allowsHitTesting(false)
                .padding(.bottom, showsQueueBar ? 2 : Spacing.elementNormal)
            }
            if showsQueueBar {
                StagedQueueBar(model: model) {
                    executionRequest = ExecutionRequest(model: model, maximumRisk: $0)
                }
            }
        }
    }

    private var isBusy: Bool { model.isScanning || model.isExecuting || model.cleanup.isBusy }

    private func busyText(override: AppLanguage?) -> String? {
        if model.isScanning {
            return model.scanPhaseText.isEmpty ? L10n.string("Scanning…", language: override) : model.scanPhaseText
        }
        if model.isExecuting { return L10n.string("Applying changes…", language: override) }
        if model.cleanup.isBusy { return model.cleanup.progress.phase }
        return nil
    }

    private func toastCapsule(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, Spacing.elementNormal)
            .padding(.vertical, Spacing.elementTight)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SemanticScale.subtleBorder, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func stop() {
        model.stopActiveWork()
    }

    private func focusSearchField() {
        if model.destination.supportsSearch {
            isSearchFocused = true
        }
        if model.destination.usesEmbeddedSearch {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            if let searchItem = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
                searchItem.beginSearchInteraction()
            }
        }
    }

    private func exportMonitorSnapshot() async {
        let override = model.languageStore.activeOverride
        guard let snapshot = model.monitor.snapshot else { return }
        guard let data = await model.monitor.exportImage(of: MonitorExportView(snapshot: snapshot)) else {
            model.setErrorMessage(L10n.string("The monitor image could not be rendered.", language: override))
            return
        }
        let panel = NSSavePanel()
        let stamp = snapshot.timestamp.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Tidybyte Monitor \(stamp).png"
        panel.allowedContentTypes = [.png]
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: \.isVisible) else {
            model.setErrorMessage(L10n.string(
                "The monitor snapshot could not be saved: no window is available to attach the save panel to.",
                language: override
            ))
            return
        }
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            model.setStatusMessage(L10n.string("Monitor snapshot saved.", language: override))
        } catch {
            model.setErrorMessage(error.localizedDescription)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(override: AppLanguage?) -> some ToolbarContent {
        // SSA-01: constant toolbar slots for the app lifetime; destination switches
        // toggle visibility via HideUnless without mutating NSToolbar items.
        ToolbarItem {
            HStack(spacing: Spacing.elementTight) {
                monitorControls(override: override).modifier(HideUnless(shown: model.destination == .monitor))
                explorerControls(override: override).modifier(HideUnless(shown: model.destination == .explorer))
                reviewControls(override: override).modifier(HideUnless(shown: model.destination.isReview))
                screenshotsControls(override: override).modifier(HideUnless(shown: model.destination == .screenshots))
                changesControls(override: override).modifier(HideUnless(shown: model.destination == .changes))
                historyControls(override: override).modifier(
                    HideUnless(shown: model.destination == .history && DistributionChannel.supportsAdvanced)
                )
                loginItemsControls(override: override).modifier(HideUnless(shown: model.destination == .loginItems))
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                if isBusy { stop() } else { model.scanAll() }
            } label: {
                Label {
                    Text(isBusy
                        ? L10n.string("Stop", language: override)
                        : L10n.string("Scan", language: override))
                } icon: {
                    Image(systemName: isBusy ? "stop.fill" : "arrow.clockwise")
                }
            }
            .buttonStyle(.glassProminent)
            .help(isBusy
                ? L10n.string("Stop the current scan or cleanup", language: override)
                : L10n.string("Scan for cleanup opportunities", language: override))
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            inspectorToggle(override: override).modifier(HideUnless(shown: model.destination.supportsInspector))
        }
    }

    private struct HideUnless: ViewModifier {
        let shown: Bool
        func body(content: Content) -> some View {
            content
                .opacity(shown ? 1 : 0)
                .frame(width: shown ? nil : 0, height: shown ? nil : 0)
                .clipped()
                .disabled(!shown)
                .accessibilityHidden(!shown)
        }
    }

    private func monitorControls(override: AppLanguage?) -> some View {
        Button {
            Task { await exportMonitorSnapshot() }
        } label: {
            Label(L10n.string("Export…", language: override), systemImage: "square.and.arrow.up")
        }
        .help(L10n.string("Save a snapshot image of the monitor", language: override))
    }

    private func explorerControls(override: AppLanguage?) -> some View {
        Menu {
            Picker(L10n.string("View", language: override), selection: $model.exploreViewKindRaw) {
                ForEach(ExploreViewKind.allCases) { kind in Text(kind.title).tag(kind.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(L10n.string("View", language: override), systemImage: "rectangle.3.group")
        }
        .help(L10n.string("Choose how to show files", language: override))
    }

    private func reviewControls(override: AppLanguage?) -> some View {
        HStack(spacing: Spacing.elementTight) {
            Picker(L10n.string("Risk", language: override), selection: $model.reviewRiskFilter) {
                Text(L10n.string("All Risks", language: override)).tag(nil as RiskLevel?)
                ForEach([RiskLevel.low, .medium, .high, .forbidden], id: \.self) { risk in
                    Text(risk.displayName).tag(Optional(risk))
                }
            }
            .help(L10n.string("Show actions of one risk level", language: override))
            Button {
                model.showsPlanner = true
            } label: {
                Label(L10n.string("Ask Tidybyte", language: override), systemImage: "text.bubble")
            }
            .help(L10n.string("Describe what to clean in your own words", language: override))
            .disabled(model.plan == nil || isBusy)
        }
    }

    private func screenshotsControls(override: AppLanguage?) -> some View {
        HStack(spacing: Spacing.elementTight) {
            Menu {
                ForEach(ScreenshotNamingStyle.allCases) { style in
                    Button {
                        Task { await model.screenshots.setNamingStyle(style) }
                    } label: {
                        if model.screenshots.namingStyle == style {
                            Label(style.displayName, systemImage: "checkmark")
                        } else {
                            Text(style.displayName)
                        }
                    }
                }
            } label: {
                Label(model.screenshots.namingStyle.displayName, systemImage: "textformat")
            }
            .help(L10n.string("Choose how renamed screenshots are formatted", language: override))
            Button {
                Task { await model.screenshots.chooseFolderAndTidyUp() }
            } label: {
                Label(L10n.string("Tidy Up…", language: override), systemImage: "sparkles")
            }
            .disabled(model.screenshots.isScanningFolder || model.screenshots.isApplying)
            .help(L10n.string("Rename vague screenshots and images in a folder", language: override))
        }
    }

    private func changesControls(override: AppLanguage?) -> some View {
        Picker(L10n.string("View", language: override), selection: $changesMode) {
            ForEach(ChangesView.Mode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private func historyControls(override: AppLanguage?) -> some View {
        Picker(L10n.string("History", language: override), selection: $model.historyShowsMedia) {
            Text(L10n.string("Cleanup", language: override)).tag(false)
            Text(L10n.string("Photos & Media", language: override)).tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private func loginItemsControls(override: AppLanguage?) -> some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label(L10n.string("Login Items Settings", language: override), systemImage: "gearshape")
        }
        .help(L10n.string("Open System Settings › General › Login Items", language: override))
    }

    private func inspectorToggle(override: AppLanguage?) -> some View {
        Button {
            model.showsInspector.toggle()
        } label: {
            Label(L10n.string("Inspector", language: override), systemImage: "sidebar.trailing")
        }
        .help(L10n.string("Show or hide details", language: override))
    }
}
