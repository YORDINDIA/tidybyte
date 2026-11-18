import Charts
import MacOSCleanerCore
import SwiftUI
import UniformTypeIdentifiers

/// The home screen: the storage dashboard. One capacity bar, Trash, the
/// kind breakdown, the reclaim hero, and where space goes.
struct OverviewView: View {
    @Bindable var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var disk = DiskGaugeData.currentHomeVolume()
    @State private var trashBytes: Int64?
    @State private var isMeasuringTrash = true
    @State private var confirmsEmptyTrash = false
    @State private var isDropTargeted = false

    private var isLoading: Bool { model.isScanning || model.cleanup.isBusy }

    private static let recommendationRows: [AppDestination] = [
        .systemJunk, .developer, .largeFiles, .duplicates, .media, .leftovers
    ]

    var body: some View {
        let override = model.languageStore.activeOverride
        Form {
            Section { storage(override: override) }
            if let summary = model.executionSummary, !summary.logs.isEmpty {
                postCleanSummarySection(summary, override: override)
            }
            if model.outcome == nil && model.cleanup.result == nil {
                Section { firstScan(override: override) }
            } else {
                dashboardSections(override: override)
            }
            if let outcome = model.outcome { latestScan(outcome, override: override) }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.string("Empty the Trash?", language: override),
            isPresented: $confirmsEmptyTrash,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Empty Trash", language: override), role: .destructive) { emptyTrash() }
        } message: {
            Text(
                trashBytes.map {
                    L10n.format("This permanently erases %@. You can't undo this action.", language: override, $0.formattedByteCount)
                } ?? L10n.string("This permanently erases everything in the Trash. You can't undo this action.", language: override)
            )
        }
        .task { await refreshDiskAndTrash() }
        .onChange(of: model.isScanning) { _, scanning in
            if !scanning { Task { await refreshDiskAndTrash() } }
        }
        .onChange(of: model.isExecuting) { _, executing in
            if !executing { Task { await refreshDiskAndTrash() } }
        }
        .onChange(of: model.cleanup.isBusy) { _, busy in
            if !busy { Task { await refreshDiskAndTrash() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshDiskAndTrash() } }
        }
    }
}

extension OverviewView {
    @ViewBuilder
    private func dashboardSections(override: AppLanguage?) -> some View {
        if model.cleanup.result != nil { kindBreakdown(override: override) }
        Section(L10n.string("Recommendations", language: override)) {
            let rows = recommendations
            if rows.isEmpty {
                Text(L10n.string(
                    "Nothing to clean right now. Scan again after you use your Mac for a while.",
                    language: override
                ))
                .foregroundStyle(.secondary)
            } else {
                ReclaimHero(rows: rows, override: override) { model.destination = $0 }
                    .skeletonLoading(isLoading)
            }
            ForEach(rows, id: \.row) { item in
                recommendationRow(item.row, bytes: item.bytes, override: override)
            }
            .skeletonLoading(isLoading)
        }
        if model.cleanup.result?.isFresh == true {
            Section(L10n.string("Where Space Goes", language: override)) {
                SpaceBuckets(model: model.cleanup) { model.destination = .media }
                    .skeletonLoading(isLoading)
            }
        }
        if model.cleanup.snapshots.count >= 2 {
            Section(L10n.string("Trend", language: override)) {
                MediaTrendView(model: model.cleanup)
            }
        }
    }

    private func refreshDiskAndTrash() async {
        disk = DiskGaugeData.currentHomeVolume()
        trashBytes = await TrashMeasure.userTrashBytes()
        isMeasuringTrash = false
    }

    private func postCleanSummarySection(_ summary: ExecutionSummary, override: AppLanguage?) -> some View {
        let completedCount = summary.logs.count
        return Section {
            HStack(spacing: Spacing.elementNormal) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(SemanticScale.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Cleanup Complete", language: override))
                        .font(.headline)
                    Text(completedCount == 1
                        ? L10n.string("1 action completed cleanly. Files in Trash can be restored or emptied anytime.", language: override)
                        : L10n.format(
                            "%lld actions completed cleanly. Files in Trash can be restored or emptied anytime.",
                            language: override,
                            completedCount
                        ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("View History", language: override)) {
                    model.destination = .history
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func kindBreakdown(override: AppLanguage?) -> some View {
        Section(L10n.string("Storage by Kind", language: override)) {
            if model.cleanup.result?.isFresh == true {
                MediaKindBreakdown(items: model.cleanup.result?.items ?? [], override: override) {
                    model.destination = $0
                }
            } else {
                ContentUnavailableView(
                    L10n.string("Not scanned", language: override),
                    systemImage: "arrow.clockwise",
                    description: Text(L10n.string("Run a Photos & Media scan to refresh this breakdown.", language: override))
                )
            }
        }
    }

    @ViewBuilder
    private func storage(override: AppLanguage?) -> some View {
        diskGaugeRow(override: override)
        trashRow(override: override)
    }

    @ViewBuilder
    private func diskGaugeRow(override: AppLanguage?) -> some View {
        if let total = disk.totalBytes, let free = disk.freeBytes, total > 0 {
            let used = max(0, total - free)
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                LabeledContent {
                    Text(L10n.format(
                        "%@ available of %@",
                        language: override,
                        free.formattedByteCount,
                        total.formattedByteCount
                    ))
                    .monospacedDigit()
                } label: {
                    Label(volumeName(override: override), systemImage: "internaldrive").font(.headline)
                }
                ProgressView(value: Double(used), total: Double(total))
                    .tint(Double(used) / Double(total) > 0.9 ? SemanticScale.warning : nil)
                    .accessibilityLabel(L10n.string("Startup disk", language: override))
                    .accessibilityValue(L10n.format(
                        "%@ used, %@ available",
                        language: override,
                        used.formattedByteCount,
                        free.formattedByteCount
                    ))
                if Double(used) / Double(total) > 0.9 {
                    Label(
                        L10n.string("Your startup disk is almost full.", language: override),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(SemanticScale.warning)
                    .font(.callout)
                }
            }
        } else {
            Text(L10n.string("Disk capacity is unavailable.", language: override)).foregroundStyle(.secondary)
        }
    }

    private func trashRow(override: AppLanguage?) -> some View {
        LabeledContent {
            HStack {
                if isMeasuringTrash {
                    ProgressView().controlSize(.small)
                } else {
                    Text(trashBytes?.formattedByteCount ?? L10n.string("Unknown", language: override)).monospacedDigit()
                    if trashBytes == nil {
                        Text(L10n.string("Full Disk Access is needed to measure the Trash.", language: override))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(L10n.string("Open Trash", language: override)) {
                    if let url = URL(string: "trash:///") { NSWorkspace.shared.open(url) }
                }
                if DistributionChannel.supportsAdvanced {
                    Button(L10n.string("Empty Trash…", language: override), role: .destructive) {
                        confirmsEmptyTrash = true
                    }
                    .disabled((trashBytes ?? 0) == 0)
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(L10n.string("Trash", language: override))
                    Text(L10n.string("Space returns after you empty the Trash.", language: override))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "trash")
            }
        }
    }

    private func emptyTrash() {
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TrashBin.empty() }
            }.value
            if case .failure(let error) = result {
                model.setErrorMessage(error.localizedDescription)
            }
            await refreshDiskAndTrash()
        }
    }

    private func volumeName(override: AppLanguage?) -> String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
            ?? L10n.string("Startup Disk", language: override)
    }

    private func firstScan(override: AppLanguage?) -> some View {
        VStack(spacing: Spacing.elementNormal) {
            Image(systemName: isDropTargeted ? "folder.badge.plus" : "sparkle.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(L10n.string("Find what you can clean", language: override)).font(.title2.bold())
            Text(L10n.string(
                "Tidybyte looks for caches, leftovers, duplicates, and large files. Nothing changes until you approve it.",
                language: override
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            selectedFolderChips
            firstScanActions(override: override)
            Text(L10n.string("Or drop folders here to add them to your scan scope.", language: override))
                .font(.caption)
                .foregroundStyle(isDropTargeted ? Primary.primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sectionGap)
        .padding(.horizontal, Spacing.cardPadding)
        .background(
            isDropTargeted ? Primary.selection : .clear,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { AppViewModel.isLocalFolder($0) }
            guard !folders.isEmpty else { return false }
            folders.forEach { model.addScanFolder($0) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    @ViewBuilder
    private var selectedFolderChips: some View {
        if !model.selectedFolders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.selectedFolders, id: \.path) { folder in
                    HStack {
                        Label(folder.lastPathComponent, systemImage: "folder")
                        Spacer()
                        Button {
                            model.removeSelectedFolder(folder)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
            }
            .padding(Spacing.cardInternal)
            .softCardSurface(cornerRadius: Radius.cardCompact)
        }
    }

    private func firstScanActions(override: AppLanguage?) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            Button(
                model.selectedFolders.isEmpty
                    ? L10n.string("Scan My Mac", language: override)
                    : L10n.string("Scan Selected Folders", language: override)
            ) {
                model.scanAll()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isScanning || model.cleanup.isBusy)

            Button(L10n.string("Choose Folders…", language: override)) {
                model.showsScanSetup = true
            }
            .controlSize(.large)
            .disabled(model.isScanning || model.cleanup.isBusy)
        }
    }

    private var recommendations: [(row: AppDestination, bytes: Int64)] {
        let pending = model.pendingBytesByDestination
        return Self.recommendationRows.compactMap { row in
            guard AppDestination.sections.flatMap(\.rows).contains(row) else { return nil }
            let bytes = row == .media ? model.cleanup.reclaimableBytes : (pending[row] ?? 0)
            return bytes > 0 ? (row, bytes) : nil
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private func recommendationRow(_ row: AppDestination, bytes: Int64, override: AppLanguage?) -> some View {
        LabeledContent {
            HStack(spacing: Spacing.elementNormal) {
                Text(bytes.formattedByteCount).monospacedDigit().foregroundStyle(.secondary)
                Button(L10n.string("Review…", language: override)) { model.destination = row }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(Self.summary(for: row, override: override)).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: row.icon)
            }
        }
    }

    private static func summary(for row: AppDestination, override: AppLanguage?) -> String {
        switch row {
        case .systemJunk: L10n.string("Caches, logs, and browser data that apps rebuild.", language: override)
        case .developer: L10n.string("Build folders, package caches, and simulator data.", language: override)
        case .largeFiles: L10n.string("Big files, old downloads, and installers.", language: override)
        case .duplicates: L10n.string("Identical copies. Fold them to save space without deleting.", language: override)
        case .media: L10n.string("Similar photos, screenshots, and large videos.", language: override)
        case .leftovers: L10n.string("Files left behind by apps you removed.", language: override)
        default: ""
        }
    }

    private func latestScan(_ outcome: ScanOutcome, override: AppLanguage?) -> some View {
        Section {
            LabeledContent(L10n.string("Items checked", language: override), value: outcome.files.count.formatted())
            LabeledContent(L10n.string("Size checked", language: override), value: outcome.session.totalBytesSeen.formattedByteCount)
            if outcome.session.errorsCount > 0 {
                LabeledContent(L10n.string("Could not read", language: override), value: outcome.session.errorsCount.formatted())
            }
            if let completed = outcome.session.completedAt {
                LabeledContent(
                    L10n.string("Finished", language: override),
                    value: completed.formatted(.relative(presentation: .named))
                )
            }
            if outcome.wasCancelled {
                Label(
                    L10n.string("Scan stopped early — results cover only what was scanned so far.", language: override),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(SemanticScale.warning)
            }
            HStack {
                Button(L10n.string("Export Report…", language: override)) { Task { await model.generateReport() } }
                    .disabled(model.isScanning || model.isExecuting)
                if model.generatedReportURL != nil {
                    Button(L10n.string("Open Report", language: override)) { model.openLatestReport() }
                }
            }
        } header: {
            Text(L10n.string("Latest Scan", language: override))
        } footer: {
            Text(L10n.string("Results cover the scanned locations, not the whole disk.", language: override))
        }
    }
}
