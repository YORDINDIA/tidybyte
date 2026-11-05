import MacOSCleanerCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppViewModel
    @FocusState private var isSearchFocused: Bool
    @State private var executionRequest: ExecutionRequest?
    @AppStorage(OnboardingView.stepKey) private var onboardingStep = 0
    /// Transient confirmation for the model's statusMessage ("Undo completed.",
    /// "Restored your last scan…"). Status messages were written at ~50 sites
    /// but rendered nowhere — every non-error outcome was invisible.
    @State private var statusToast: String?
    @State private var statusToastTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: Spacing.sidebarWidth, max: 280)
        } detail: {
            searchableDetail
                .navigationTitle(model.destination.title)
                .navigationSubtitle(busyText ?? "")
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { StatusNotices(model: model) }
                .safeAreaBar(edge: .bottom) {
                    if model.destination.isReview || model.destination == .duplicates {
                        StagedQueueBar(model: model) { executionRequest = ExecutionRequest(model: model, maximumRisk: $0) }
                    }
                }
                .inspector(isPresented: $model.showsInspector) {
                    inspectorContent.inspectorColumnWidth(min: 280, ideal: Spacing.detailPanelWidth, max: 400)
                }
                .overlay(alignment: .bottom) {
                    // The model computes a scan summary (duration, candidates,
                    // errors) and retires it after 6 seconds; this renders it.
                    // MB-F3: the summary stacks above a concurrent status toast
                    // instead of displacing it, so a message set during or right
                    // after a scan stays readable for its full lifetime.
                    VStack(spacing: Spacing.elementTight) {
                        if let statusToast {
                            toastCapsule(statusToast)
                        }
                        if model.showScanSummaryToast, let summary = model.activeScanSummary {
                            toastCapsule(summary)
                        }
                    }
                    .padding(.bottom, Spacing.elementNormal)
                }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.showsScanSetup) { ScanSetupView(model: model) }
        .sheet(isPresented: $model.showsPlanner) { NaturalLanguagePlanView(model: model) }
        .sheet(isPresented: Bindable(model.cleanup).showsScope) { CleanupScopeView(model: model.cleanup) }
        .sheet(item: $executionRequest) { request in ExecutionConfirmView(model: model, request: request) }
        .sheet(item: $model.pendingUndoRestore) { request in
            // MB-10: menu-bar undo asks the same regret question as History.
            RegretReasonSheet(
                subject: request.subject,
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
                })
        }
        .sheet(
            isPresented: Binding(
                get: { onboardingStep < OnboardingView.doneStep },
                set: { _ in
                    // O-02: the step is the single source of truth — only the
                    // explicit completion buttons mark onboarding done. Writing
                    // it here force-completed onboarding when the environment
                    // (a quit, a windowless launch) tore the sheet down.
                })
        ) {
            OnboardingView(model: model).interactiveDismissDisabled()
        }
        .onChange(of: model.searchFocusRequest) { isSearchFocused = true }
        .onChange(of: model.destination) {
            model.searchText = ""
            if !model.destination.supportsInspector { model.showsInspector = false }
        }
        .onChange(of: model.statusMessageEpoch) {
            // The epoch bumps on every assignment, so repeated identical
            // messages still toast (MB-F4). Scan-step chatter repaints at 2 Hz
            // and is shown by the progress strip instead; everything else is a
            // one-shot outcome worth a toast.
            let message = model.statusMessage
            guard !message.isEmpty, !model.isScanning else { return }
            statusToastTask?.cancel()
            statusToast = message
            statusToastTask = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                statusToast = nil
            }
        }
        .task {
            await model.cleanup.load()
            await model.loadUndoHistory()
            await model.restoreLastSession()
        }
    }

    @ViewBuilder
    private var searchableDetail: some View {
        if model.destination.supportsSearch {
            detail
                .searchable(
                    text: $model.searchText, placement: .toolbar,
                    prompt: String(localized: "Search \(model.destination.title)"))
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
        case .media: MediaWorkspace(model: model.cleanup)
        case .applications: ApplicationsView(model: model)
        case .loginItems: LoginItemsView(model: model)
        case .explorer: FilesView(model: model)
        case .changes: ChangesView(model: model)
        case .history: HistoryView(model: model)
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch model.destination {
        case .explorer: SelectionInspectorView(model: model)
        case .systemJunk, .developer, .largeFiles, .leftovers, .duplicates: WhyPanelView(model: model)
        case .applications: ApplicationDetailsView(model: model)
        case .history: HistoryDetailsView(model: model)
        case .monitor: EmptyView()
        default:
            ContentUnavailableView(
                String(localized: "No selection"), systemImage: "sidebar.trailing",
                description: Text(String(localized: "Select an item to see its details.")))
        }
    }

    private var isBusy: Bool { model.isScanning || model.isExecuting || model.cleanup.isBusy }

    private var busyText: String? {
        if model.isScanning {
            return model.scanPhaseText.isEmpty ? String(localized: "Scanning…") : model.scanPhaseText
        }
        if model.isExecuting { return String(localized: "Applying changes…") }
        if model.cleanup.isBusy { return model.cleanup.progress.phase }
        return nil
    }

    /// One capsule style shared by the status toast and the scan summary.
    private func toastCapsule(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, Spacing.elementNormal)
            .padding(.vertical, Spacing.elementTight)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func stop() {
        if model.isScanning { model.cancelScan() }
        if model.isExecuting { model.cancelExecution() }
        if model.cleanup.isBusy { model.cleanup.cancel() }
    }

    /// Renders the monitor's fixed summary card and saves it as a PNG next to
    /// the window. One snapshot in, one static image out — nothing live.
    private func exportMonitorSnapshot() async {
        guard let snapshot = model.monitor.snapshot else { return }
        guard let data = await model.monitor.exportImage(of: MonitorExportView(snapshot: snapshot)) else {
            model.setErrorMessage(String(
                localized: "The monitor image could not be rendered.",
                comment: "Monitor export render failure"))
            return
        }
        let panel = NSSavePanel()
        let stamp = snapshot.timestamp.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Tidybyte Monitor \(stamp).png"
        panel.allowedContentTypes = [.png]
        // MON-04: a backgrounded app has no key window; fall back to any
        // visible window of ours instead of silently returning.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: \.isVisible) else {
            model.setErrorMessage(String(
                localized: "The monitor snapshot could not be saved: no window is available to attach the save panel to.",
                comment: "Monitor export without a window"))
            return
        }
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            model.setStatusMessage(String(
                localized: "Monitor snapshot saved.",
                comment: "Monitor export success"))
        } catch {
            model.setErrorMessage(error.localizedDescription)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // SSA-01: exactly four toolbar slots, constant for the app's whole
        // lifetime — destination changes only mutate content in place. Items
        // that entered and left the toolbar (and content that swapped view
        // types) raced AppKit's layout pass and threw NSException during
        // NSToolbar insertion (crash reports + a live repro on a ⌘2 switch).
        // Hidden controls collapse via width and are disabled + hidden from
        // accessibility, never removed from the tree.
        ToolbarItem {
            HStack(spacing: Spacing.elementTight) {
                monitorControls.modifier(HideUnless(shown: model.destination == .monitor))
                explorerControls.modifier(HideUnless(shown: model.destination == .explorer))
                reviewControls.modifier(HideUnless(shown: model.destination.isReview))
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            // One identity-stable item that adapts, instead of two branches.
            Button {
                if isBusy { stop() } else { model.scanAll() }
            } label: {
                Label {
                    Text(isBusy
                        ? String(localized: "Stop", comment: "Toolbar stop label")
                        : String(localized: "Scan", comment: "Toolbar scan label"))
                } icon: {
                    Image(systemName: isBusy ? "stop.fill" : "arrow.clockwise")
                }
            }
            .buttonStyle(.glassProminent)
            .help(isBusy
                ? String(localized: "Stop the current scan or cleanup", comment: "Toolbar stop help")
                : String(localized: "Scan for cleanup opportunities", comment: "Toolbar scan help"))
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            inspectorToggle.modifier(HideUnless(shown: model.destination.supportsInspector))
        }
    }

    /// Marks a contextual control hidden without removing it from the tree:
    /// collapsed, inert, and invisible to accessibility.
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

    /// The Monitor destination's Export… control, always mounted.
    private var monitorControls: some View {
        Button {
            Task { await exportMonitorSnapshot() }
        } label: {
            Label(
                String(localized: "Export…", comment: "Monitor toolbar action"),
                systemImage: "square.and.arrow.up")
        }
        .help(String(localized: "Save a snapshot image of the monitor", comment: "Monitor export help"))
    }

    /// The Space Explorer's View-kind menu, always mounted.
    private var explorerControls: some View {
        Menu {
            Picker(String(localized: "View"), selection: $model.exploreViewKindRaw) {
                ForEach(ExploreViewKind.allCases) { kind in Text(kind.title).tag(kind.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(String(localized: "View"), systemImage: "rectangle.3.group")
        }
        .help(String(localized: "Choose how to show files"))
    }

    /// The review destinations' Risk filter and Ask Tidybyte, always mounted.
    private var reviewControls: some View {
        HStack(spacing: Spacing.elementTight) {
            Picker(String(localized: "Risk"), selection: $model.reviewRiskFilter) {
                Text(String(localized: "All Risks")).tag(nil as RiskLevel?)
                ForEach([RiskLevel.low, .medium, .high, .forbidden], id: \.self) { risk in
                    Text(risk.displayName).tag(Optional(risk))
                }
            }
            .help(String(localized: "Show actions of one risk level"))
            Button {
                model.showsPlanner = true
            } label: {
                Label(String(localized: "Ask Tidybyte"), systemImage: "text.bubble")
            }
            .help(String(localized: "Describe what to clean in your own words"))
            .disabled(model.plan == nil || isBusy)
        }
    }

    private var inspectorToggle: some View {
        Button {
            model.showsInspector.toggle()
        } label: {
            Label(String(localized: "Inspector"), systemImage: "sidebar.trailing")
        }
        .help(String(localized: "Show or hide details"))
    }

}
