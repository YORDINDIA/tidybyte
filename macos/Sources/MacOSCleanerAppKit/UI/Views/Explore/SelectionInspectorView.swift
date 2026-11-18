import AppKit
import MacOSCleanerCore
import SwiftUI

/// File metadata and navigation. Staging is separate from approval in Review.
struct SelectionInspectorView: View {
    @Bindable var model: AppViewModel
    @State private var didCopyPath = false

    @State private var liveSizes: FileSizeProbe.Sizes?
    @State private var liveOwner: String?
    @State private var liveTags: [String]?

    private var override: AppLanguage? {
        model.languageStore.activeOverride
    }

    private var record: FileRecord? {
        model.selectedExploreRecord ?? model.focusedExploreRecord
    }

    private var files: [FileRecord] {
        model.outcome?.files ?? []
    }

    var body: some View {
        Group {
            if let record {
                Form {
                    identitySection(record)
                    sizeDetails(record)
                    dateDetails(record)
                    riskDetails(record)
                    children(record)
                    fileActions(record)
                    reviewActions(record)
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    L10n.string("No file selected", language: override),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L10n.string("Select a file to see its details.", language: override))
                )
            }
        }
        .onChange(of: record?.id) {
            didCopyPath = false
            liveSizes = nil
            liveOwner = nil
            liveTags = nil
        }
        .task(id: record?.id) {
            guard let selected = record else { return }
            let url = selected.url
            let live = await Task.detached(priority: .utility) {
                (
                    FileSizeProbe.sizes(for: url),
                    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountName] as? String,
                    (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames
                )
            }.value
            guard !Task.isCancelled else { return }
            liveSizes = live.0
            liveOwner = live.1
            liveTags = live.2
        }
    }

    private func identitySection(_ record: FileRecord) -> some View {
        Section {
            Label(record.fileName, systemImage: record.kind == .directory ? "folder" : "doc")
                .font(.headline)
                .textSelection(.enabled)
            Text(record.displayPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            LabeledContent(L10n.string("Kind", language: override), value: record.kind.displayName)
        }
    }

    private func sizeDetails(_ record: FileRecord) -> some View {
        let totals = model.subtreeTotals
        let total = ExploreSubtreeIndex.subtreeBytes(for: record, totals: totals)
        let sizes = liveSizes
        let isContainer = record.kind == .directory || record.kind == .package
        let logical = isContainer ? total : sizes?.logical ?? total
        let allocated = isContainer ? nil : sizes?.allocated
        let parent = ExploreSubtreeIndex.parentPath(of: record.displayPath)
        let parentBytes = totals[parent] ?? files.filter { $0.kind != .directory }.reduce(0) { $0 + $1.sizeBytes }
        return Section(L10n.string("Size", language: override)) {
            LabeledContent(L10n.string("Logical size", language: override), value: logical.formattedByteCount)
            if let allocated {
                LabeledContent(L10n.string("Size on disk", language: override), value: allocated.formattedByteCount)
                if logical > allocated {
                    LabeledContent(
                        L10n.string("Compression savings", language: override),
                        value: (logical - allocated).formattedByteCount
                    )
                }
            }
            if parentBytes > 0 {
                LabeledContent(
                    L10n.string("Share of parent", language: override),
                    value: min(1, Double(total) / Double(parentBytes)).formatted(.percent.precision(.fractionLength(1)))
                )
            }
            if let items = record.rolledUpItemCount {
                LabeledContent(L10n.string("Items inside", language: override), value: items.formatted())
            } else if isContainer {
                let descendants = ExploreSubtreeIndex.descendants(ofParentPath: record.displayPath, in: files)
                LabeledContent(
                    L10n.string("Scanned files", language: override),
                    value: descendants.filter { $0.kind == .regularFile }.count.formatted()
                )
                LabeledContent(
                    L10n.string("Scanned folders", language: override),
                    value: descendants.filter { $0.kind == .directory }.count.formatted()
                )
            }
        }
    }

    private func dateDetails(_ record: FileRecord) -> some View {
        Section(L10n.string("Information", language: override)) {
            if let date = record.createdAt {
                LabeledContent(
                    L10n.string("Created", language: override),
                    value: date.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let date = record.modifiedAt {
                LabeledContent(
                    L10n.string("Modified", language: override),
                    value: date.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let date = record.lastOpenedAt {
                LabeledContent(
                    L10n.string("Last opened", language: override),
                    value: date.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let owner = liveOwner {
                LabeledContent(L10n.string("Owner", language: override), value: owner)
            }
            if let tags = liveTags, !tags.isEmpty {
                LabeledContent(L10n.string("Tags", language: override), value: tags.joined(separator: ", "))
            }
            if let target = record.symlinkTarget {
                LabeledContent(L10n.string("Link target", language: override), value: target.path)
            }
        }
    }

    @ViewBuilder
    private func riskDetails(_ record: FileRecord) -> some View {
        if !record.riskFlags.isEmpty || record.cloudProvider != nil {
            Section(L10n.string("Risk information", language: override)) {
                ForEach(Array(record.riskFlags).sorted { $0.rawValue < $1.rawValue }, id: \.self) { flag in
                    Label(flag.displayName, systemImage: "exclamationmark.shield")
                        .foregroundStyle(SemanticScale.warning)
                }
                if let provider = record.cloudProvider {
                    LabeledContent(L10n.string("Cloud provider", language: override), value: provider)
                }
            }
        }
    }

    @ViewBuilder
    private func children(_ record: FileRecord) -> some View {
        if record.kind == .directory || record.kind == .package {
            let totals = model.subtreeTotals
            let childRecords = ExploreSubtreeIndex.directChildren(ofParentPath: record.displayPath, in: files)
                .sorted {
                    ExploreSubtreeIndex.subtreeBytes(for: $0, totals: totals)
                        > ExploreSubtreeIndex.subtreeBytes(for: $1, totals: totals)
                }
            Section(L10n.string("Largest inside", language: override)) {
                if childRecords.isEmpty {
                    Text(L10n.string("No scanned children.", language: override))
                        .foregroundStyle(.secondary)
                }
                ForEach(childRecords.prefix(10)) { child in
                    Button {
                        model.selectExploreRecord(id: child.id)
                    } label: {
                        LabeledContent(
                            child.fileName,
                            value: ExploreSubtreeIndex.subtreeBytes(for: child, totals: totals).formattedByteCount
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func fileActions(_ record: FileRecord) -> some View {
        Section(L10n.string("File actions", language: override)) {
            Button(L10n.string("Show in Finder", language: override), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([record.url])
            }
            Button(L10n.string("Quick Look", language: override), systemImage: "eye") {
                QuickLookCoordinator.shared.preview(record.url)
            }
            if record.kind == .directory {
                Button(L10n.string("Open Folder", language: override), systemImage: "folder.badge.plus") {
                    model.focusExploreRecord(id: record.id)
                }
            }
            Button(
                didCopyPath
                    ? L10n.string("Copied", language: override)
                    : L10n.string("Copy Path", language: override),
                systemImage: "doc.on.doc"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.url.path, forType: .string)
                didCopyPath = true
            }
        }
    }

    private func reviewActions(_ record: FileRecord) -> some View {
        Section(L10n.string("Cleanup", language: override)) {
            if let action = model.stagedExploreAction(matching: record) {
                Button(L10n.string("Review Action", language: override)) {
                    model.showReviewAction(id: action.id)
                }
                Button(L10n.string("Remove from Plan", language: override)) {
                    model.unstageExploreAction(matching: record)
                }
                .disabled(action.executedAt != nil)
            } else {
                Button(L10n.string("Add to Review", language: override)) {
                    model.stageExploreRecordForCleanup(record)
                }
                .disabled(model.plan == nil)
            }
            Text(L10n.string("Review and approve proposed changes before applying them.", language: override))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(model.isScanning || model.isExecuting || model.isPlanning)
    }
}
