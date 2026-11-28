import AppKit
import MacOSCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotsView: View {
    @Bindable var model: AppViewModel
    @State private var isDropTargeted = false
    @State private var editingRecord: ScreenshotRenameRecord?
    @State private var editingTitleText = ""

    private var screenshots: ScreenshotRenameModel { model.screenshots }

    private var filteredHistory: [ScreenshotRenameRecord] {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return screenshots.history }
        return screenshots.history.filter { record in
            record.newFileName.localizedCaseInsensitiveContains(query)
                || record.originalFileName.localizedCaseInsensitiveContains(query)
                || (record.ocrSnippet?.localizedCaseInsensitiveContains(query) ?? false)
                || record.visionLabels.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        Form {
            statusAndPrivacySection(override: override)
            namingStyleSection(override: override)
            tidyUpSection(override: override)
            watchedFoldersSection(override: override)
            if !screenshots.learnedExamples.isEmpty {
                learnedStylesSection(override: override)
            }
            historySection(override: override)
        }
        .formStyle(.grouped)
        .onKeyPress(.space) {
            guard let record = screenshots.selectedRecord else { return .ignored }
            QuickLookCoordinator.shared.togglePreview([record.currentURL])
            return .handled
        }
        .sheet(item: Binding(
            get: { screenshots.pendingTidyUp.map { TidyUpSheetBox(summary: $0) } },
            set: { if $0 == nil { screenshots.pendingTidyUp = nil } }
        )) { box in
            TidyUpPreviewSheet(model: screenshots, initialSummary: box.summary, override: override)
        }
        .alert(
            L10n.string("Rename and Teach Style", language: override),
            isPresented: Binding(
                get: { editingRecord != nil },
                set: { if !$0 { editingRecord = nil } }
            )
        ) {
            TextField(L10n.string("New filename", language: override), text: $editingTitleText)
            Button(L10n.string("Cancel", language: override), role: .cancel) { editingRecord = nil }
            Button(L10n.string("Rename", language: override)) {
                if let record = editingRecord {
                    let target = editingTitleText
                    editingRecord = nil
                    Task { await screenshots.renameHistoryRecord(record, to: target) }
                }
            }
        } message: {
            Text(L10n.string("Future screenshots will learn from the filename style you pick.", language: override))
        }
    }
}

private struct TidyUpSheetBox: Identifiable {
    let id = UUID()
    let summary: TidyUpScanSummary
}

extension ScreenshotsView {
    private func statusAndPrivacySection(override: AppLanguage?) -> some View {
        Section {
            autoRenameToggleRow(override: override)
            privacySummaryRow(override: override)
            if let statusText = screenshots.lastStatusText {
                statusBannerRow(statusText, override: override)
            }
            if let errorMessage = screenshots.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(SemanticScale.error)
            }
        } header: {
            Text(L10n.string("Automatic Screenshot Naming", language: override))
        }
    }

    private func autoRenameToggleRow(override: AppLanguage?) -> some View {
        Toggle(
            isOn: Binding(
                get: { screenshots.isAutoRenameEnabled },
                set: { enabled in Task { await screenshots.setAutoRenameEnabled(enabled) } }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Auto-rename new screenshots", language: override))
                Text(L10n.string(
                    "Watches for ⇧⌘3, ⇧⌘4, ⇧⌘5, CleanShot, downloads, and synced camera roll captures.",
                    language: override
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func privacySummaryRow(override: AppLanguage?) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            Label(
                screenshots.appleIntelligenceAvailable
                    ? L10n.string("Apple Intelligence Ready", language: override)
                    : L10n.string("On-Device OCR & Vision Active", language: override),
                systemImage: screenshots.appleIntelligenceAvailable ? "apple.intelligence" : "eye"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(screenshots.appleIntelligenceAvailable ? SemanticScale.success : .secondary)

            Spacer()

            Text(
                screenshots.totalNamedCount == 1
                    ? L10n.string("0 bytes uploaded · 1 named on this Mac", language: override)
                    : L10n.format(
                        "0 bytes uploaded · %lld named on this Mac",
                        language: override,
                        screenshots.totalNamedCount
                    )
            )
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private func statusBannerRow(_ statusText: String, override: AppLanguage?) -> some View {
        HStack(spacing: Spacing.elementTight) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SemanticScale.success)
            Text(verbatim: statusText)
                .font(.callout)
            Spacer()
            if screenshots.canUndoLast {
                Button(L10n.string("Undo (⌘Z)", language: override)) {
                    Task { await screenshots.undoLast() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func namingStyleSection(override: AppLanguage?) -> some View {
        Section {
            Picker(
                L10n.string("Naming style", language: override),
                selection: Binding(
                    get: { screenshots.namingStyle },
                    set: { style in Task { await screenshots.setNamingStyle(style) } }
                )
            ) {
                ForEach(ScreenshotNamingStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            LabeledContent(L10n.string("Preview", language: override)) {
                Text(verbatim: screenshots.namingStyle.exampleFilename)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.string("Naming Format", language: override))
        } footer: {
            Text(L10n.string("Original created and modified dates never change.", language: override))
        }
    }

    private func tidyUpSection(override: AppLanguage?) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                dropZone(override: override)
                HStack(spacing: Spacing.elementTight) {
                    if DistributionChannel.supportsAdvanced {
                        Button {
                            Task { await screenshots.tidyUpDesktop() }
                        } label: {
                            Label(L10n.string("Tidy Up Desktop", language: override), systemImage: "desktopcomputer")
                        }
                        Button {
                            Task { await screenshots.tidyUpDownloads() }
                        } label: {
                            Label(L10n.string("Tidy Up Downloads", language: override), systemImage: "arrow.down.circle")
                        }
                    }
                    Button {
                        Task { await screenshots.chooseFolderAndTidyUp() }
                    } label: {
                        Label(L10n.string("Choose Folder…", language: override), systemImage: "folder")
                    }
                    Spacer()
                    if screenshots.isScanningFolder || screenshots.isApplying {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(screenshots.isScanningFolder || screenshots.isApplying)

                Toggle(
                    L10n.string("Rename immediately on drag & drop", language: override),
                    isOn: Binding(
                        get: { screenshots.renameImmediatelyOnDrop },
                        set: { screenshots.setRenameImmediatelyOnDrop($0) }
                    )
                )
                .font(.callout)
            }
        } header: {
            Text(L10n.string("Tidy Up Folder", language: override))
        } footer: {
            Text(L10n.string(
                "Renames vague files like Screenshot, IMG_4471, Untitled, or image (2). Well-named files are left alone.",
                language: override
            ))
        }
    }

    private func dropZone(override: AppLanguage?) -> some View {
        VStack(spacing: Spacing.elementTight) {
            Image(systemName: "photo.badge.arrow.down")
                .font(.title2)
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(L10n.string("Drop screenshots, images, or a folder here to tidy up", language: override))
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardCompact)
                .fill(isDropTargeted ? Primary.selection : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.cardCompact)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : SemanticScale.subtleBorder,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedFileURLs(from: providers)
            return true
        }
    }

    private func watchedFoldersSection(override: AppLanguage?) -> some View {
        Section {
            if screenshots.watchedFolders.isEmpty {
                Text(L10n.string("No folders watched yet. Add a folder to enable automatic renaming.", language: override))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(screenshots.watchedFolders) { folder in
                    HStack(spacing: Spacing.elementNormal) {
                        Toggle(
                            isOn: Binding(
                                get: { folder.isEnabled },
                                set: { _ in Task { await screenshots.toggleWatchedFolder(folder) } }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: folder.url.lastPathComponent)
                                Text(verbatim: folder.url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        if !folder.isSystemDetected {
                            Button(role: .destructive) {
                                Task { await screenshots.removeWatchedFolder(folder) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Button {
                Task { await screenshots.addWatchedFolderViaPanel() }
            } label: {
                Label(L10n.string("Add Watched Folder…", language: override), systemImage: "folder.badge.plus")
            }
        } header: {
            Text(L10n.string("Watched Folders", language: override))
        }
    }

    private func learnedStylesSection(override: AppLanguage?) -> some View {
        Section {
            ForEach(screenshots.learnedExamples) { example in
                HStack(spacing: Spacing.elementNormal) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: example.userChosenTitle).font(.headline)
                        Text(L10n.format("From: %@", language: override, example.suggestedTitle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let prefix = example.learnedPrefix {
                        Text(verbatim: prefix)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Primary.selection, in: Capsule())
                    }
                    Button(role: .destructive) {
                        Task { await screenshots.deleteStyleExample(example) }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text(L10n.string("Learned Naming Style", language: override))
        } footer: {
            Text(L10n.string("Rename any file in Finder or here and future screenshots follow your lead.", language: override))
        }
    }

    private func historySection(override: AppLanguage?) -> some View {
        Section {
            if filteredHistory.isEmpty {
                Text(
                    model.searchText.isEmpty
                        ? L10n.string("No screenshots renamed yet.", language: override)
                        : L10n.string("No renamed screenshots match your search.", language: override)
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(filteredHistory) { record in
                    historyRow(record, override: override)
                }
            }
        } header: {
            HStack {
                Text(L10n.string("Rename History", language: override))
                Spacer()
                if screenshots.canUndoLast {
                    Button(L10n.string("Undo Last", language: override)) {
                        Task { await screenshots.undoLast() }
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    private func historyRow(_ record: ScreenshotRenameRecord, override: AppLanguage?) -> some View {
        HStack(spacing: Spacing.elementNormal) {
            ScreenshotThumbnailView(url: record.currentURL)
                .frame(width: 40, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            historyRowLabels(record)
            Spacer()
            historyRowControls(record, override: override)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            screenshots.selectedHistoryID = record.id
            model.showsInspector = true
        }
        .contextMenu { historyContextMenu(record, override: override) }
    }

    private func historyRowLabels(_ record: ScreenshotRenameRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: record.newFileName)
                .font(.headline)
                .lineLimit(1)
                .strikethrough(record.status == .reverted)
            Text(verbatim: record.originalFileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func historyRowControls(_ record: ScreenshotRenameRecord, override: AppLanguage?) -> some View {
        Text(record.createdAt, format: .dateTime.month().day().hour().minute())
            .font(.caption)
            .foregroundStyle(.secondary)
        Button {
            editingRecord = record
            editingTitleText = URL(fileURLWithPath: record.newFileName).deletingPathExtension().lastPathComponent
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help(L10n.string("Edit name to teach your style", language: override))
        .disabled(record.status == .reverted)

        if record.status == .reverted {
            Text(L10n.string("Restored", language: override))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button(L10n.string("Undo", language: override)) {
                Task { await screenshots.undoRecord(record) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(screenshots.isApplying)
        }
    }

    @ViewBuilder
    private func historyContextMenu(_ record: ScreenshotRenameRecord, override: AppLanguage?) -> some View {
        Button(L10n.string("Quick Look", language: override)) {
            QuickLookCoordinator.shared.preview(record.currentURL)
        }
        Button(L10n.string("Reveal in Finder", language: override)) {
            NSWorkspace.shared.activateFileViewerSelecting([record.currentURL])
        }
        if record.status != .reverted {
            Button(L10n.string("Rename & Teach Style…", language: override)) {
                editingRecord = record
                editingTitleText = URL(fileURLWithPath: record.newFileName).deletingPathExtension().lastPathComponent
            }
            Divider()
            Button(L10n.string("Undo Rename", language: override)) {
                Task { await screenshots.undoRecord(record) }
            }
        }
    }

    private func loadDroppedFileURLs(from providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await loadURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                await screenshots.handleDroppedURLs(urls)
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

struct ScreenshotThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.primary.opacity(0.06)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            image = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
        }
    }
}
