import MacOSCleanerCore
import SwiftUI

/// One sidebar row per destination. Each review row shows only its own share
/// of the plan, so no action appears twice.
enum AppDestination: String, CaseIterable, Identifiable {
    case overview
    case monitor
    case systemJunk, developer, largeFiles, duplicates, media
    case applications, leftovers, loginItems
    case explorer, changes, history

    var id: String { rawValue }

    /// Rows backed by the shared review list (ActionStackView).
    var isReview: Bool { [.systemJunk, .developer, .largeFiles, .leftovers].contains(self) }

    /// App Store History shows Photos & Media activity only, which has no search.
    /// The Monitor owns its own search field, so the shared one stands down
    /// there (attaching a second would bind it to the wrong model).
    var supportsSearch: Bool {
        isReview || [.duplicates, .applications, .explorer].contains(self)
            || ((self == .history || self == .changes) && DistributionChannel.supportsAdvanced)
    }

    /// Unified ContentView inspector supports searchable rows AND Monitor.
    var supportsInspector: Bool { supportsSearch || self == .monitor }

    /// Surfaces whose search lives inside their own view. ⌘F focuses it
    /// there instead of jumping away to Space Explorer.
    var usesEmbeddedSearch: Bool { self == .monitor }

    /// The monitor reads system-wide state, which the sandboxed build cannot.
    var isAvailable: Bool { self != .monitor || DistributionChannel.supportsAdvanced }

    var title: String { title(language: nil) }

    func title(language: AppLanguage?) -> String {
        scanDestinationTitle(language: language) ?? managementDestinationTitle(language: language)
    }

    private func scanDestinationTitle(language: AppLanguage?) -> String? {
        switch self {
        case .overview: L10n.string("Overview", language: language)
        case .monitor: L10n.string("Monitor", language: language)
        case .systemJunk: L10n.string("System Junk", language: language)
        case .developer: L10n.string("Developer", language: language)
        case .largeFiles: L10n.string("Large & Old Files", language: language)
        case .duplicates: L10n.string("Duplicates", language: language)
        case .media: L10n.string("Photos & Media", language: language)
        default: nil
        }
    }

    private func managementDestinationTitle(language: AppLanguage?) -> String {
        switch self {
        case .applications: L10n.string("Applications", language: language)
        case .leftovers: L10n.string("Leftovers", language: language)
        case .loginItems: L10n.string("Login Items", language: language)
        case .explorer: L10n.string("Space Explorer", language: language)
        case .changes: L10n.string("Changes", language: language)
        case .history: L10n.string("History", language: language)
        default: ""
        }
    }

    var icon: String {
        switch self {
        case .overview: "internaldrive"
        case .monitor: "waveform.path.ecg"
        case .systemJunk: "trash"
        case .developer: "hammer"
        case .largeFiles: "doc.badge.clock"
        case .duplicates: "square.on.square"
        case .media: "photo.on.rectangle"
        case .applications: "square.grid.3x3"
        case .leftovers: "shippingbox"
        case .loginItems: "power"
        case .explorer: "chart.pie"
        case .changes: "chart.line.uptrend.xyaxis"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Rows this build shows; routes and menus go nowhere else.
    static var available: [AppDestination] { sections.flatMap(\.rows).filter(\.isAvailable) }

    /// Sidebar sections in order. The App Store build has no system access,
    /// so it shows only the folder-scoped rows.
    static var sections: [(title: String?, rows: [AppDestination])] { sections(language: nil) }

    static func sections(language: AppLanguage?) -> [(title: String?, rows: [AppDestination])] {
        guard DistributionChannel.supportsAdvanced else {
            return [(nil, [.overview]), (L10n.string("Clean", language: language), [.media]), (nil, [.history])]
        }
        return [
            (nil, [.overview]),
            (L10n.string("Monitor", language: language), [.monitor]),
            (L10n.string("Clean", language: language), [.systemJunk, .developer, .largeFiles, .duplicates, .media]),
            (L10n.string("Apps", language: language), [.applications, .leftovers, .loginItems]),
            (L10n.string("Insights", language: language), [.explorer, .changes, .history])
        ]
    }

    /// The row that owns a finding category. Exhaustive on purpose: a new
    /// category does not compile until it has a home in the sidebar.
    static func forCategory(_ category: FindingCategory?) -> AppDestination {
        guard let category else { return .largeFiles }
        return switch category {
        case .cache, .log, .systemDeep, .userEssentials, .finderMetadata, .macOSSystemCache, .sandboxedAppCache,
            .browserCache, .cloudStorageCache, .officeAppCache, .applicationSupportCache, .appleSiliconUpdate,
            .iosDeviceBackup, .timeMachineBackup:
            .systemJunk
        case .developerArtifact, .codingAgentArtifact, .packageManagerCleanup, .dockerCleanup, .developerToolCache,
            .developmentAppCache, .vmToolCache:
            .developer
        case .largeFile, .largeFileReview, .oldDownload, .oldInstaller, .screenshot, .organization, .protected:
            .largeFiles
        case .duplicate:
            .duplicates
        case .appLeftover, .uninstalledAppData:
            .leftovers
        }
    }
}

struct CleanerCommands: Commands {
    @Bindable var model: AppViewModel
    @Environment(\.openWindow) private var openWindow

    private var isBusy: Bool { model.isScanning || model.isExecuting || model.cleanup.isBusy }
    private var canReviewSelection: Bool {
        if model.destination == .duplicates {
            return !model.selectedDuplicatePendingActions.isEmpty
                && !model.isScanning && !model.isExecuting && !model.isPlanning
        }
        return model.selectedVisibleReviewAction?.executedAt == nil
            && model.selectedVisibleReviewAction != nil
            && !model.isScanning && !model.isExecuting && !model.isPlanning
    }

    private var canApproveSelection: Bool {
        guard canReviewSelection else { return false }
        if model.destination == .duplicates {
            return model.selectedDuplicatePendingActions.contains {
                $0.risk != .forbidden && $0.actionType.isExecutable
            }
        }
        return model.selectedVisibleReviewAction?.risk != .forbidden
            && model.selectedVisibleReviewAction.map { $0.actionType.isExecutable } == true
    }

    /// ⌘1–⌘9 go to the rows people use most.
    private static let shortcutRows: [AppDestination] = [
        .overview, .systemJunk, .developer, .largeFiles, .duplicates, .media, .applications, .explorer, .history
    ]

    var body: some Commands {
        let override = model.languageStore.activeOverride
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("Scan", language: override)) {
                openWindow(id: "main")
                model.scanAll()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isBusy)
            Button(L10n.string("Stop", language: override)) {
                model.stopActiveWork()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!isBusy)
            Button(L10n.string("Scan Options…", language: override)) {
                openWindow(id: "main")
                if model.destination == .media || !DistributionChannel.supportsAdvanced {
                    model.cleanup.showsScope = true
                } else {
                    model.showsScanSetup = true
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(isBusy)
            Divider()
            Button(L10n.string("Export Report…", language: override)) {
                Task { await model.generateReport() }
            }
            .disabled(model.outcome == nil || isBusy)
        }
        CommandGroup(after: .textEditing) {
            Button(L10n.string("Find", language: override)) {
                if !model.destination.supportsSearch, !model.destination.usesEmbeddedSearch,
                   DistributionChannel.supportsAdvanced {
                    model.destination = .explorer
                }
                model.searchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu(L10n.string("Go", language: override)) {
            ForEach(AppDestination.sections(language: override).flatMap(\.rows)) { row in
                if let index = Self.shortcutRows.firstIndex(of: row) {
                    Button(row.title(language: override)) { model.destination = row }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                } else {
                    Button(row.title(language: override)) { model.destination = row }
                }
            }
        }
        if DistributionChannel.supportsAdvanced {
            CommandMenu(L10n.string("Review", language: override)) {
                Button(L10n.string("Ask Tidybyte…", language: override)) { model.showsPlanner = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.plan == nil || isBusy)
                Divider()
                Button(L10n.string("Approve Selected Action", language: override)) {
                    model.approveSelectedCommandTarget()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!canApproveSelection)
                Button(L10n.string("Reject Selected Action", language: override)) {
                    model.rejectSelectedCommandTarget()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!canReviewSelection)
            }
        }
        if let checkForUpdates = MacOSCleanerApp.checkForUpdates {
            CommandGroup(after: .appInfo) {
                Button(L10n.string("Check for Updates…", language: override), action: checkForUpdates)
            }
        }
        SidebarCommands()
        InspectorCommands()
        ToolbarCommands()
    }
}
