import AppKit
import MacOSCleanerCore
import SwiftUI

struct ScreenshotInspectorView: View {
    @Bindable var model: AppViewModel
    @State private var customTitle = ""

    private var record: ScreenshotRenameRecord? {
        model.screenshots.selectedRecord
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        Form {
            if let record {
                Section {
                    ScreenshotThumbnailView(url: record.currentURL)
                        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.cardCompact))
                    HStack {
                        Button(L10n.string("Quick Look", language: override)) {
                            QuickLookCoordinator.shared.preview(record.currentURL)
                        }
                        Spacer()
                        Button(L10n.string("Reveal in Finder", language: override)) {
                            NSWorkspace.shared.activateFileViewerSelecting([record.currentURL])
                        }
                    }
                }

                Section(L10n.string("Filename", language: override)) {
                    LabeledContent(L10n.string("Current", language: override), value: record.newFileName)
                    LabeledContent(L10n.string("Original", language: override), value: record.originalFileName)
                    LabeledContent(L10n.string("Style", language: override), value: record.namingStyle.displayName)
                    if record.status != .reverted {
                        TextField(L10n.string("Custom name (teaches style)", language: override), text: $customTitle)
                            .onSubmit { applyCustomRename(record) }
                        HStack {
                            Button(L10n.string("Apply & Teach Style", language: override)) {
                                applyCustomRename(record)
                            }
                            .disabled(customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Spacer()
                            Button(L10n.string("Undo", language: override)) {
                                Task { await model.screenshots.undoRecord(record) }
                            }
                        }
                    }
                }

                if record.originalCreationDate != nil || record.originalModificationDate != nil {
                    Section(L10n.string("Preserved Dates", language: override)) {
                        if let created = record.originalCreationDate {
                            LabeledContent(L10n.string("Created", language: override), value: created.formatted())
                        }
                        if let modified = record.originalModificationDate {
                            LabeledContent(L10n.string("Modified", language: override), value: modified.formatted())
                        }
                    }
                }

                if let snippet = record.ocrSnippet, !snippet.isEmpty {
                    Section(L10n.string("Extracted Text", language: override)) {
                        Text(verbatim: snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if !record.visionLabels.isEmpty {
                    Section(L10n.string("Visual Labels", language: override)) {
                        Text(verbatim: record.visionLabels.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView(
                    L10n.string("No selection", language: override),
                    systemImage: "camera.viewfinder",
                    description: Text(L10n.string("Select a renamed screenshot to inspect or edit it.", language: override))
                )
            }
        }
        .formStyle(.grouped)
        .onChange(of: record?.id) { _, _ in
            if let record {
                customTitle = URL(fileURLWithPath: record.newFileName).deletingPathExtension().lastPathComponent
            } else {
                customTitle = ""
            }
        }
        .onAppear {
            if let record {
                customTitle = URL(fileURLWithPath: record.newFileName).deletingPathExtension().lastPathComponent
            }
        }
    }

    private func applyCustomRename(_ record: ScreenshotRenameRecord) {
        let target = customTitle
        Task { await model.screenshots.renameHistoryRecord(record, to: target) }
    }
}
