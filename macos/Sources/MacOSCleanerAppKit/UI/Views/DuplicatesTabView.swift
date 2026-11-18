import AppKit
import MacOSCleanerCore
import SwiftUI

struct DuplicatesTabView: View {
    @Bindable var model: AppViewModel
    @State private var selection: String?

    private var findings: [Finding] {
        model.duplicateFindings.filter { finding in
            model.searchText.isEmpty || finding.summary.localizedCaseInsensitiveContains(model.searchText)
                || finding.targetFileIDs.contains {
                    model.filesByID[$0]?.displayPath.localizedCaseInsensitiveContains(model.searchText) == true
                }
        }
    }

    private func resolutionStrategy(for finding: Finding) -> DuplicateStrategy {
        let action = model.plan?.actions.first { $0.findingID == finding.id }
        return action?.actionType == .cloneDeduplicate ? .apfsClone : .moveToTrash
    }

    private func canSwitchResolution(for finding: Finding) -> Bool {
        !(model.plan?.actions.contains {
            $0.findingID == finding.id && ($0.userDecision != .undecided || $0.executedAt != nil)
        } ?? false)
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        List(selection: $selection) {
            ForEach(findings) { finding in
                findingRow(finding, override: override)
                    .padding(.vertical, Spacing.elementTight)
                    .tag(finding.id)
            }
        }
        .listStyle(.inset)
        .skeletonLoading(model.isScanning)
        .overlay {
            if model.isScanning && findings.isEmpty {
                VStack(spacing: Spacing.elementNormal) {
                    ProgressView(L10n.string("Scanning…", language: override))
                    Text(L10n.string("Duplicate results appear when the scan finishes.", language: override))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if findings.isEmpty {
                emptyState(override: override)
            }
        }
        .onKeyPress(.space) {
            let urls = selectedFindingURLs
            guard !urls.isEmpty else { return .ignored }
            QuickLookCoordinator.shared.togglePreview(urls)
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let findingID = ids.first,
               let finding = findings.first(where: { $0.id == findingID }) {
                let urls = finding.targetFileIDs.compactMap { model.filesByID[$0]?.url }
                Button(L10n.string("Show Details", language: override)) {
                    model.selectedActionID = model.plan?.actions.first { $0.findingID == findingID }?.id
                    model.showsInspector = true
                }
                if !urls.isEmpty {
                    Button(L10n.string("Quick Look", language: override)) {
                        QuickLookCoordinator.shared.preview(urls)
                    }
                }
                Divider()
                let pending = (model.plan?.actions ?? []).filter {
                    $0.findingID == findingID && $0.executedAt == nil
                }
                Button(L10n.string("Approve", language: override)) {
                    pending.filter { $0.risk != .forbidden && $0.actionType.isExecutable }.forEach(model.approve)
                }
                .disabled(pending.isEmpty)
                Button(L10n.string("Reject", language: override)) {
                    pending.forEach(model.reject)
                }
                .disabled(pending.isEmpty)
            }
        } primaryAction: { ids in
            if let findingID = ids.first {
                model.selectedActionID = model.plan?.actions.first { $0.findingID == findingID }?.id
                model.showsInspector = true
            }
        }
        .onChange(of: selection) {
            model.selectedActionID = model.plan?.actions.first { $0.findingID == selection }?.id
            QuickLookCoordinator.shared.updateSelectionIfVisible(selectedFindingURLs)
        }
    }

    private var selectedFindingURLs: [URL] {
        guard let selection,
              let finding = findings.first(where: { $0.id == selection }) else { return [] }
        return finding.targetFileIDs.compactMap { model.filesByID[$0]?.url }
    }

    private func findingRow(_ finding: Finding, override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            HStack {
                Image(systemName: "square.on.square").foregroundStyle(.secondary)
                Text(finding.summary).font(.headline)
                Spacer()
                Text(finding.bytesReclaimable.formattedByteCount).monospacedDigit()
            }
            HStack {
                RiskBadge(risk: finding.severity)
                Text(L10n.format("%lld files", language: override, finding.targetFileIDs.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                resolutionMenu(for: finding, override: override)
                decisionButtons(for: finding, override: override)
            }
            if resolutionStrategy(for: finding) == .apfsClone,
               let action = model.plan?.actions.first(where: { $0.findingID == finding.id }),
               action.actionType == .cloneDeduplicate {
                cloneHint(for: action, override: override)
            }
            DisclosureGroup(L10n.string("Files in this group", language: override)) {
                ForEach(finding.targetFileIDs, id: \.self) { id in
                    if let record = model.filesByID[id] {
                        HStack {
                            Text(record.displayPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(L10n.string("Quick Look", language: override)) {
                                QuickLookCoordinator.shared.preview(record.url)
                            }
                            .buttonStyle(.borderless)
                            Button(L10n.string("Show in Finder", language: override)) {
                                NSWorkspace.shared.activateFileViewerSelecting([record.url])
                            }
                            .buttonStyle(.borderless)
                        }.font(.caption)
                    }
                }
                if let kept = finding.evidence["kept_file"] {
                    Text(L10n.format("Kept file: %@", language: override, kept))
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func emptyState(override: AppLanguage?) -> some View {
        ContentUnavailableView {
            Label(
                model.searchText.isEmpty
                    ? L10n.string("No duplicates found", language: override)
                    : L10n.string("No matching duplicates", language: override),
                systemImage: "doc.on.doc"
            )
        } description: {
            Text(
                model.outcome == nil
                    ? L10n.string("Scan folders to compare files.", language: override)
                    : L10n.string("Results come from the latest scan.", language: override)
            )
        } actions: {
            if model.outcome == nil {
                Button(L10n.string("New Scan…", language: override)) { model.showsScanSetup = true }
            }
        }
    }

    private func cloneHint(for action: PlannedAction, override: AppLanguage?) -> some View {
        let bytes = action.targets
            .compactMap { model.filesByID[$0]?.sizeBytes }
            .reduce(Int64(0), +)
            .formattedByteCount
        return Label(
            L10n.format(
                "Reclaims %@ without deleting anything. Every file keeps its name and metadata. Undoable.",
                language: override,
                bytes
            ),
            systemImage: "square.on.square.dashed"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func resolutionMenu(for finding: Finding, override: AppLanguage?) -> some View {
        let current = resolutionStrategy(for: finding)
        let canSwitch = canSwitchResolution(for: finding)
        return Menu {
            Button {
                model.switchDuplicateResolution(forFinding: finding.id, to: .apfsClone)
            } label: {
                if current == .apfsClone {
                    Label(
                        L10n.string("Fold into APFS clone (nothing deleted)", language: override),
                        systemImage: "checkmark"
                    )
                } else {
                    Text(L10n.string("Fold into APFS clone (nothing deleted)", language: override))
                }
            }
            .disabled(!canSwitch)
            Button {
                model.switchDuplicateResolution(forFinding: finding.id, to: .moveToTrash)
            } label: {
                if current == .moveToTrash {
                    Label(L10n.string("Move duplicates to Trash", language: override), systemImage: "checkmark")
                } else {
                    Text(L10n.string("Move duplicates to Trash", language: override))
                }
            }
            .disabled(!canSwitch)
        } label: {
            Label(L10n.string("Resolve", language: override), systemImage: "arrow.triangle.branch")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!canSwitch)
    }

    @ViewBuilder
    private func decisionButtons(for finding: Finding, override: AppLanguage?) -> some View {
        let actions = (model.plan?.actions ?? []).filter { $0.findingID == finding.id && $0.executedAt == nil }
        if !actions.isEmpty {
            let approved = actions.allSatisfy { $0.userDecision == .approved }
            let canApprove = actions.allSatisfy {
                $0.risk != .forbidden && $0.actionType.isExecutable
            }
            HStack {
                if approved {
                    Label(L10n.string("Approved", language: override), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(SemanticScale.success)
                }
                Button(L10n.string("Reject", language: override)) { actions.forEach(model.reject) }
                Button(L10n.string("Approve", language: override)) { actions.forEach(model.approve) }
                    .disabled(approved || !canApprove)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(model.isScanning || model.isExecuting || model.isPlanning)
        }
    }
}
