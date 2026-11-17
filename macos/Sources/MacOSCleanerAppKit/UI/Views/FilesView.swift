import MacOSCleanerCore
import SwiftUI

struct FilesView: View {
    @Bindable var model: AppViewModel
    @State private var sortOrder = [KeyPathComparator(\FileRecord.sizeBytes, order: .reverse)]
    @State private var showsRelationships = false
    @State private var cachedVisibleFiles: [FileRecord] = []

    private var files: [FileRecord] { model.outcome?.files ?? [] }

    var body: some View {
        let override = model.languageStore.activeOverride
        VStack(spacing: 0) {
            if model.isScanning {
                VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                    ForEach(0..<10, id: \.self) { _ in
                        HStack(spacing: Spacing.elementNormal) {
                            SkeletonBlock(height: 16, width: 16)
                            SkeletonBlock(height: 12)
                            SkeletonBlock(height: 12, width: 80)
                        }
                    }
                }
                .padding(Spacing.screenEdge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityLabel(Text(L10n.string("Scanning files…", language: override)))
            } else if model.outcome == nil {
                ContentUnavailableView(
                    L10n.string("No scanned files", language: override),
                    systemImage: "folder",
                    description: Text(L10n.string("Start a scan to browse files and storage.", language: override))
                )
            } else {
                browserControls(override: override)
                if model.exploreViewKindRaw == ExploreViewKind.list.rawValue {
                    fileTable(override: override)
                } else {
                    ScrollView {
                        ExploreViewSwitcher(model: model, files: files, categorySections: model.dashboardSections)
                            .padding(Spacing.cardPadding)
                    }
                }
                if showsRelationships {
                    Divider()
                    RelationshipGraphView(
                        model: model,
                        edges: model.outcome?.edges ?? [],
                        filesByID: model.filesByID
                    )
                    .frame(height: 200)
                    .padding(Spacing.cardPadding)
                }
            }
        }
        .onAppear { recomputeVisibleFiles() }
        .onChange(of: ExploreFilesToken(files)) { recomputeVisibleFiles() }
        .onChange(of: model.focusedExploreRecordID) { recomputeVisibleFiles() }
        .onChange(of: model.searchText) { recomputeVisibleFiles() }
        .onChange(of: sortOrder) { recomputeVisibleFiles() }
        .onChange(of: model.selectedExploreRecordID) { _, newID in
            if let newID, let url = model.filesByID[newID]?.url {
                QuickLookCoordinator.shared.updateSelectionIfVisible([url])
            }
        }
        .onChange(of: model.exploreViewKindRaw) { model.saveSettings() }
    }

    private func recomputeVisibleFiles() {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusedURL = model.focusedExploreRecord?.url.standardizedFileURL
        cachedVisibleFiles = files.filter { record in
            let inFolder = focusedURL.map {
                record.url.deletingLastPathComponent().standardizedFileURL == $0
            } ?? true
            return inFolder && (query.isEmpty || record.displayPath.localizedCaseInsensitiveContains(query))
        }.sorted(using: sortOrder)
    }

    private func browserControls(override: AppLanguage?) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            Button {
                model.focusExploreRecord(id: nil)
            } label: {
                Label(L10n.string("All Scanned Files", language: override), systemImage: "folder")
            }
            .buttonStyle(.borderless)
            if let focused = model.focusedExploreRecord {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Text(focused.fileName).lineLimit(1).help(focused.displayPath)
            }
            Spacer()
            Toggle(L10n.string("Relationships", language: override), isOn: $showsRelationships)
                .toggleStyle(.button)
            Menu {
                Button(L10n.string("Create Inbox Folder", language: override)) {
                    Task { await model.createInbox() }
                }
                .disabled(model.isScanning || model.isExecuting)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help(L10n.string("File actions", language: override))
        }
        .controlSize(.small)
        .padding(Spacing.cardPadding)
    }

    private func fileTable(override: AppLanguage?) -> some View {
        Table(cachedVisibleFiles, selection: $model.selectedExploreRecordID, sortOrder: $sortOrder) {
            TableColumn(L10n.string("Name", language: override), value: \.fileName) { record in
                Label(record.fileName, systemImage: record.kind == .directory ? "folder.fill" : "doc")
                    .help(record.displayPath)
            }
            .width(min: 180, ideal: 300)
            TableColumn(L10n.string("Size", language: override), value: \.sizeBytes) { record in
                Text(record.sizeBytes.formattedByteCount).monospacedDigit()
            }.width(min: 70, ideal: 90)
            TableColumn(L10n.string("Kind", language: override), value: \.kind.rawValue) { record in
                Text(record.kind.displayName)
            }.width(min: 70, ideal: 100)
            TableColumn(L10n.string("Modified", language: override), value: \.sortableModifiedDate) { record in
                if let date = record.modifiedAt { Text(date, style: .date) } else { Text("—") }
            }.width(min: 85, ideal: 110)
        }
        .overlay {
            if cachedVisibleFiles.isEmpty {
                tableEmptyOverlay(override: override)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            tableContextMenu(ids: ids, override: override)
        } primaryAction: { ids in
            guard let id = ids.first, let record = model.filesByID[id] else { return }
            if record.kind == .directory {
                model.focusExploreRecord(id: id)
            } else {
                QuickLookCoordinator.shared.preview(record.url)
            }
        }
        .onKeyPress(.space) {
            guard let record = model.selectedExploreRecord else { return .ignored }
            QuickLookCoordinator.shared.togglePreview([record.url])
            return .handled
        }
    }

    @ViewBuilder
    private func tableEmptyOverlay(override: AppLanguage?) -> some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView(
                L10n.string("No files in this view", language: override),
                systemImage: "folder",
                description: Text(L10n.string("This folder has no scanned files.", language: override))
            )
        }
    }

    @ViewBuilder
    private func tableContextMenu(ids: Set<String>, override: AppLanguage?) -> some View {
        if let id = ids.first, let record = model.filesByID[id] {
            Button(L10n.string("Show Details", language: override)) {
                model.selectedExploreRecordID = id
                model.showsInspector = true
            }
            Button(L10n.string("Quick Look", language: override)) {
                QuickLookCoordinator.shared.preview(record.url)
            }
            Button(L10n.string("Show in Finder", language: override)) {
                NSWorkspace.shared.activateFileViewerSelecting([record.url])
            }
            Button(L10n.string("Add to Review", language: override)) {
                model.stageExploreRecordForCleanup(record)
            }
            .disabled(model.isScanning || model.isExecuting || model.plan == nil)
        }
    }
}

extension FileRecord {
    fileprivate var sortableModifiedDate: Date { modifiedAt ?? .distantPast }
}
