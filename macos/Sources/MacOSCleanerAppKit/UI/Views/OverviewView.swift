import Charts
import MacOSCleanerCore
import SwiftUI

/// The home screen: the storage dashboard. One capacity bar, Trash, the
/// kind breakdown, the reclaim hero, and where space goes — modeled on
/// System Settings › General › Storage (PRD section 5).
struct OverviewView: View {
    @Bindable var model: AppViewModel
    @State private var disk = DiskGaugeData.currentHomeVolume()
    @State private var trashBytes: Int64?
    @State private var isMeasuringTrash = true
    @State private var confirmsEmptyTrash = false
    /// True while any scan or media analysis runs; drives the skeletons.
    private var isLoading: Bool { model.isScanning || model.cleanup.isBusy }

    private static let recommendationRows: [AppDestination] = [
        .systemJunk, .developer, .largeFiles, .duplicates, .media, .leftovers
    ]

    var body: some View {
        Form {
            Section { storage }
            if model.outcome == nil && model.cleanup.result == nil {
                Section { firstScan }
            } else {
                if model.cleanup.result != nil { kindBreakdown }
                Section(String(localized: "Recommendations")) {
                    let rows = recommendations
                    if rows.isEmpty {
                        Text(String(localized: "Nothing to clean right now. Scan again after you use your Mac for a while."))
                            .foregroundStyle(.secondary)
                    } else {
                        ReclaimHero(rows: rows) { model.destination = $0 }
                            .skeletonLoading(isLoading)
                    }
                    ForEach(rows, id: \.row) { item in recommendationRow(item.row, bytes: item.bytes) }
                        .skeletonLoading(isLoading)
                }
                if model.cleanup.result?.isFresh == true {
                    Section(String(localized: "Where Space Goes")) {
                        SpaceBuckets(model: model.cleanup) { model.destination = .media }
                            .skeletonLoading(isLoading)
                    }
                }
                if model.cleanup.snapshots.count >= 2 {
                    Section(String(localized: "Trend")) {
                        MediaTrendView(model: model.cleanup)
                    }
                }
            }
            if let outcome = model.outcome { latestScan(outcome) }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            String(localized: "Empty the Trash?"), isPresented: $confirmsEmptyTrash, titleVisibility: .visible
        ) {
            Button(String(localized: "Empty Trash"), role: .destructive) { emptyTrash() }
        } message: {
            Text(
                String(
                    localized: "This permanently erases \((trashBytes ?? 0).formattedByteCount). You can't undo this action."))
        }
        .task {
            disk = DiskGaugeData.currentHomeVolume()
            trashBytes = await TrashMeasure.userTrashBytes()
            isMeasuringTrash = false
        }
    }

    // MARK: Storage by kind (PRD 5.1)

    @ViewBuilder private var kindBreakdown: some View {
        Section(String(localized: "Storage by Kind")) {
            if model.cleanup.result?.isFresh == true {
                MediaKindBreakdown(items: model.cleanup.result?.items ?? []) { model.destination = $0 }
            } else {
                ContentUnavailableView(
                    String(localized: "Not scanned"), systemImage: "arrow.clockwise",
                    description: Text(String(localized: "Run a Photos & Media scan to refresh this breakdown.")))
            }
        }
    }

    // MARK: Storage

    @ViewBuilder private var storage: some View {
        if let total = disk.totalBytes, let free = disk.freeBytes, total > 0 {
            let used = max(0, total - free)
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                LabeledContent {
                    Text(String(localized: "\(free.formattedByteCount) available of \(total.formattedByteCount)"))
                        .monospacedDigit()
                } label: {
                    Label(volumeName, systemImage: "internaldrive").font(.headline)
                }
                ProgressView(value: Double(used), total: Double(total))
                    .tint(Double(used) / Double(total) > 0.9 ? SemanticScale.warning : nil)
                    .accessibilityLabel(String(localized: "Startup disk"))
                    .accessibilityValue(
                        String(localized: "\(used.formattedByteCount) used, \(free.formattedByteCount) available"))
                if Double(used) / Double(total) > 0.9 {
                    Label(String(localized: "Your startup disk is almost full."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SemanticScale.warning)
                        .font(.callout)
                }
            }
        } else {
            Text(String(localized: "Disk capacity is unavailable.")).foregroundStyle(.secondary)
        }
        LabeledContent {
            HStack {
                if isMeasuringTrash {
                    // Measuring walks the Trash; "Unknown" is the answer only
                    // after it finishes (nil usually means missing access).
                    ProgressView().controlSize(.small)
                } else {
                    Text(trashBytes?.formattedByteCount ?? String(localized: "Unknown")).monospacedDigit()
                    if trashBytes == nil {
                        Text(String(
                            localized: "Full Disk Access is needed to measure the Trash.",
                            comment: "Trash measure unavailable hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(String(localized: "Open Trash")) {
                    if let url = URL(string: "trash:///") { NSWorkspace.shared.open(url) }
                }
                if DistributionChannel.supportsAdvanced {
                    Button(String(localized: "Empty Trash…"), role: .destructive) { confirmsEmptyTrash = true }
                        .disabled((trashBytes ?? 0) == 0)
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(String(localized: "Trash"))
                    Text(String(localized: "Space returns after you empty the Trash."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "trash")
            }
        }
    }

    private func emptyTrash() {
        Task { @MainActor in
            // Emptying a full Trash is a synchronous unlinkat loop; run it off
            // the main actor so the window stays responsive, then re-measure.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TrashBin.empty() }
            }.value
            if case .failure(let error) = result {
                model.setErrorMessage(error.localizedDescription)
            }
            trashBytes = await TrashMeasure.userTrashBytes()
            disk = DiskGaugeData.currentHomeVolume()
        }
    }

    private var volumeName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
            ?? String(localized: "Startup Disk")
    }

    // MARK: First scan

    private var firstScan: some View {
        VStack(spacing: Spacing.elementNormal) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(String(localized: "Find what you can clean")).font(.title2.bold())
            Text(
                String(
                    localized: """
                        Tidybyte looks for caches, leftovers, duplicates, and large files. \
                        Nothing changes until you approve it.
                        """)
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            Button(String(localized: "Scan My Mac")) { model.scanAll() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isScanning || model.cleanup.isBusy)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sectionGap)
    }

    // MARK: Recommendations

    private var recommendations: [(row: AppDestination, bytes: Int64)] {
        let pending = model.pendingBytesByDestination
        return Self.recommendationRows.compactMap { row in
            guard AppDestination.sections.flatMap(\.rows).contains(row) else { return nil }
            let bytes = row == .media ? model.cleanup.reclaimableBytes : (pending[row] ?? 0)
            return bytes > 0 ? (row, bytes) : nil
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private func recommendationRow(_ row: AppDestination, bytes: Int64) -> some View {
        LabeledContent {
            HStack(spacing: Spacing.elementNormal) {
                Text(bytes.formattedByteCount).monospacedDigit().foregroundStyle(.secondary)
                Button(String(localized: "Review…")) { model.destination = row }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(Self.summary(for: row)).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: row.icon)
            }
        }
    }

    private static func summary(for row: AppDestination) -> String {
        switch row {
        case .systemJunk: String(localized: "Caches, logs, and browser data that apps rebuild.")
        case .developer: String(localized: "Build folders, package caches, and simulator data.")
        case .largeFiles: String(localized: "Big files, old downloads, and installers.")
        case .duplicates: String(localized: "Identical copies. Fold them to save space without deleting.")
        case .media: String(localized: "Similar photos, screenshots, and large videos.")
        case .leftovers: String(localized: "Files left behind by apps you removed.")
        default: ""
        }
    }

    // MARK: Latest scan

    private func latestScan(_ outcome: ScanOutcome) -> some View {
        Section {
            LabeledContent(
                String(localized: "Items checked"),
                value: outcome.files.count.formatted())
            LabeledContent(
                String(localized: "Size checked"),
                value: outcome.session.totalBytesSeen.formattedByteCount)
            if outcome.session.errorsCount > 0 {
                LabeledContent(
                    String(localized: "Could not read"),
                    value: outcome.session.errorsCount.formatted())
            }
            if let completed = outcome.session.completedAt {
                LabeledContent(String(localized: "Finished"), value: completed.formatted(.relative(presentation: .named)))
            }
            if outcome.wasCancelled {
                Label(
                    String(localized: "Scan stopped early — results cover only what was scanned so far.",
                           comment: "Latest Scan note for a cancelled scan kept as partial results"),
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SemanticScale.warning)
            }
            HStack {
                Button(String(localized: "Export Report…")) { Task { await model.generateReport() } }
                    .disabled(model.isScanning || model.isExecuting)
                if model.generatedReportURL != nil {
                    Button(String(localized: "Open Report")) { model.openLatestReport() }
                }
            }
        } header: {
            Text(String(localized: "Latest Scan"))
        } footer: {
            Text(String(localized: "Results cover the scanned locations, not the whole disk."))
        }
    }
}

/// Donut of the media scope by file kind. Legend rows are buttons that jump
/// to the matching cleanup surface.
private struct MediaKindBreakdown: View {
    let items: [ReviewItem]
    let onPick: (AppDestination) -> Void

    private struct Entry: Identifiable {
        let kind: MediaKind
        let count: Int
        let bytes: Int64
        var id: MediaKind { kind }
    }

    private var entries: [Entry] {
        MediaKind.allCases.compactMap { kind in
            let matching = items.filter { $0.kind == kind }
            guard !matching.isEmpty else { return nil }
            return Entry(kind: kind, count: matching.count, bytes: matching.reduce(0) { $0 + $1.bytes })
        }
        .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        if entries.isEmpty {
            Text(String(localized: "No files in this scope yet.")).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                Chart(entries) { entry in
                    SectorMark(
                        angle: .value(String(localized: "Size"), entry.bytes),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5)
                    .foregroundStyle(entry.kind.palette.mid)
                    .cornerRadius(3)
                }
                .frame(height: 160)
                .accessibilityLabel(
                    entries.first.map { entry in
                        String(
                            localized: "Storage by kind; largest is \(entry.kind.title) at \(entry.bytes.formattedByteCount)")
                    } ?? String(localized: "Storage by kind"))
                ForEach(entries) { entry in legendRow(entry) }
            }
        }
    }

    private func legendRow(_ entry: Entry) -> some View {
        Button { onPick(destination(for: entry.kind)) } label: {
            LabeledContent {
                Text(String(localized: "\(entry.count) · \(entry.bytes.formattedByteCount)", comment: "Item count and size"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(entry.kind.title)
                } icon: {
                    Circle().fill(entry.kind.palette.mid).frame(width: 9, height: 9)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Media kinds review in Photos & Media; everything else lives in Large Files.
    private func destination(for kind: MediaKind) -> AppDestination {
        kind == .image || kind == .video ? .media : .largeFiles
    }
}

/// PRD 5.2: total reclaimable space with one tappable segment per area and a
/// single prominent action for the biggest win.
private struct ReclaimHero: View {
    let rows: [(row: AppDestination, bytes: Int64)]
    let onPick: (AppDestination) -> Void

    private var total: Int64 { rows.reduce(0) { $0 + $1.bytes } }
    private var biggest: AppDestination { rows.first?.row ?? .media }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            LabeledContent {
                Text(total.formattedByteCount)
                    .font(.title3.bold())
                    .monospacedDigit()
            } label: {
                Label(String(localized: "You Could Free"), systemImage: "sparkles")
            }
            if rows.count > 1 { segments }
            HStack(alignment: .center) {
                Text(String(localized: "Biggest win: \(biggest.title)", comment: "Largest reclaim opportunity"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Review now")) { onPick(biggest) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var segments: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(rows, id: \.row) { item in
                    Button { onPick(item.row) } label: {
                        Capsule().fill(item.row.palette.mid)
                            .frame(
                                width: max(12, proxy.size.width * CGFloat(item.bytes) / CGFloat(max(total, 1))),
                                height: 14)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "\(item.row.title) · \(item.bytes.formattedByteCount)"))
                    .accessibilityLabel(String(localized: "\(item.row.title), \(item.bytes.formattedByteCount)"))
                }
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Reclaimable space by area"))
    }
}

extension CleanupModel {
    /// Bytes the Photos & Media tools could reclaim, counting each item once
    /// and never selecting the best copy of a group.
    var reclaimableBytes: Int64 {
        guard result?.isFresh == true else { return 0 }
        let tools: [CleanupTool] = [.duplicates, .similar, .bursts, .blurry, .screenshots, .screenRecordings, .large]
        let keepers = Set(result?.groups.map(\.bestID) ?? [])
        var bytesByID: [String: Int64] = [:]
        for tool in tools {
            for item in items(for: tool) where item.canChange && !keepers.contains(item.id) {
                bytesByID[item.id] = item.bytes
            }
        }
        let allowed = MediaAnalysisService.safeSelection(Set(bytesByID.keys), groups: result?.groups ?? [])
        return bytesByID.filter { allowed.contains($0.key) }.values.reduce(0, +)
    }
}

/// Size of ~/.Trash. Reading it needs Full Disk Access; nil means unknown.
enum TrashMeasure {
    static func userTrashBytes() async -> Int64? {
        await Task.detached(priority: .utility) {
            let trash = ReviewSafety.userHome.appendingPathComponent(".Trash")
            // Listing fails without Full Disk Access; report unknown, not zero.
            guard (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil,
                let files = FileManager.default.enumerator(
                at: trash, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            else { return nil }
            var total: Int64 = 0
            while let file = files.nextObject() as? URL {
                if Task.isCancelled { return nil }
                guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                else { return nil }
                if values.isRegularFile == true { total += Int64(values.totalFileAllocatedSize ?? 0) }
            }
            return total
        }.value
    }
}
