import MacOSCleanerCore
import SwiftUI

struct WhyPanelView: View {
    @Bindable var model: AppViewModel

    var body: some View {
        let override = model.languageStore.activeOverride
        if let action = model.selectedAction {
            Form {
                Section(L10n.string("Action", language: override)) {
                    Text(action.actionType.displayName).font(.headline)
                    RiskBadge(risk: action.risk)
                    Text(action.reason).textSelection(.enabled)
                    LabeledContent(L10n.string("Confidence", language: override), value: "\(Int(action.confidence * 100))%")
                    Text(operationDescription(for: action, override: override)).font(.callout)
                }
                Section(L10n.string("Affected files", language: override)) {
                    ForEach(model.selectedActionFiles) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.fileName).font(.headline)
                            Text(file.displayPath).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if !file.riskFlags.isEmpty {
                                Label(
                                    file.riskFlags.map(\.displayName).joined(separator: ", "),
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption)
                            }
                            HStack(spacing: Spacing.elementTight) {
                                Button(L10n.string("Quick Look", language: override)) {
                                    QuickLookCoordinator.shared.preview(file.url)
                                }
                                Button(L10n.string("Show in Finder", language: override)) {
                                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                }
                            }
                        }
                    }
                }
                if action.actionType == .runPackageManagerCleanup {
                    Section(L10n.string("Command preview", language: override)) {
                        ForEach(
                            (model.outcome?.packageCandidates ?? []).filter { action.targets.contains($0.id) },
                            id: \.id
                        ) { candidate in
                            Text(([candidate.commandPath.path] + candidate.arguments).joined(separator: " "))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text(candidate.dryRunOutput).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                Section(L10n.string("Recovery", language: override)) {
                    Text(recoveryText(for: action, override: override)).font(.callout)
                }
                Section(L10n.string("Saved rules", language: override)) {
                    Button(L10n.string("Approve and Save Always Rule", language: override)) {
                        Task { await model.alwaysDoThis(action) }
                    }
                    .disabled(action.risk == .forbidden || !action.actionType.isExecutable)
                    Button(L10n.string("Reject and Save Never Rule", language: override)) {
                        Task { await model.neverDoThisHere(action) }
                    }
                }
                .disabled(model.isScanning || model.isExecuting || model.isPlanning || action.executedAt != nil)
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                L10n.string("Select an action", language: override),
                systemImage: "checklist",
                description: Text(L10n.string(
                    "Its reason, affected files, and recovery details appear here.",
                    language: override
                ))
            )
        }
    }

    private func recoveryText(for action: PlannedAction, override: AppLanguage?) -> String {
        if action.risk == .forbidden {
            return L10n.string("Blocked actions cannot run.", language: override)
        }
        if !action.actionType.isExecutable {
            return L10n.string("This action is for review only. Tidybyte cannot execute it.", language: override)
        }
        if action.actionType == .runPackageManagerCleanup {
            return L10n.string(
                "Package-manager cleanup cannot be undone. Review the command before approval.",
                language: override
            )
        }
        return L10n.string(
            "Restore options appear in History. Recovery needs the saved record and available files.",
            language: override
        )
    }

    private func operationDescription(for action: PlannedAction, override: AppLanguage?) -> String {
        let fileCount = action.targets.count
        let filePart = fileCount == 1
            ? L10n.string("1 file", language: override)
            : L10n.format("%lld files", language: override, fileCount)
        switch action.actionType {
        case .moveToTrash:
            return L10n.format("Move %@ to Trash", language: override, filePart)
        case .move:
            let dest = action.destination?.path ?? L10n.string("destination", language: override)
            return L10n.format("Move %@ to %@", language: override, filePart, dest)
        case .archive:
            return L10n.format("Create ZIP archive of %@, then trash originals", language: override, filePart)
        case .tag:
            return L10n.format("Apply Finder tag to %@", language: override, filePart)
        case .createAlias:
            return L10n.format("Create Finder alias for %@", language: override, filePart)
        case .createSymlink:
            return L10n.format("Create symbolic link for %@", language: override, filePart)
        case .runPackageManagerCleanup:
            return L10n.string("Run package manager cleanup command", language: override)
        case .rename:
            return L10n.format("Rename %@", language: override, filePart)
        case .cloneDeduplicate:
            return L10n.format(
                "Fold %@ onto their keepers as APFS clones (nothing is deleted)",
                language: override,
                filePart
            )
        default:
            return "\(action.actionType.displayName): \(filePart)"
        }
    }
}
