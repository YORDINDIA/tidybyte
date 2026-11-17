import AppKit
import MacOSCleanerCore
import SwiftUI

struct ActionStackView: View {
    @Bindable var model: AppViewModel
    @State private var bulkRequest: BulkReviewRequest?
    @State private var selectedIDs: Set<String> = []

    /// Only this sidebar row's actions. Bulk commands never reach rows the user cannot see.
    private var actions: [PlannedAction] { model.actions(in: model.destination) }
    private var visibleActions: [PlannedAction] { model.visibleReviewActions }

    var body: some View {
        let override = model.languageStore.activeOverride
        VStack(spacing: 0) {
            if !actions.isEmpty { controls(override: override) }
            if model.isScanning && model.outcome == nil {
                scanningPlaceholder(override: override)
            } else if actions.isEmpty {
                emptyAreaView(override: override)
            } else if visibleActions.isEmpty {
                filteredEmptyView(override: override)
            } else {
                actionsList(override: override)
            }
        }
        .sheet(item: $bulkRequest) { request in
            bulkConfirmation(request, override: override)
        }
        .onAppear {
            syncSelectionFromModel()
        }
        .onChange(of: model.plan?.id) {
            model.reviewRiskFilter = nil
            bulkRequest = nil
            selectedIDs = []
            model.selectedActionIDs = []
        }
        .onChange(of: model.selectedActionID) { _, newID in
            if let newID, !selectedIDs.contains(newID) {
                selectedIDs = [newID]
                model.selectedActionIDs = selectedIDs
            }
        }
        .onChange(of: visibleActions.map(\.id)) { _, visibleIDs in
            let visibleSet = Set(visibleIDs)
            let pruned = selectedIDs.intersection(visibleSet)
            if pruned != selectedIDs {
                selectedIDs = pruned
                model.selectedActionIDs = pruned
            }
            if model.selectedVisibleReviewAction == nil {
                model.selectedActionID = pruned.first
            }
        }
    }

    private func scanningPlaceholder(override: AppLanguage?) -> some View {
        VStack(spacing: Spacing.elementNormal) {
            ProgressView(
                value: Double(max(0, model.scanCurrentStep)),
                total: Double(max(1, model.scanTotalSteps))
            )
            .frame(maxWidth: 320)
            Text(model.scanPhaseText.isEmpty
                ? L10n.string("Scanning…", language: override)
                : model.scanPhaseText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.elementSection)
    }

    private func emptyAreaView(override: AppLanguage?) -> some View {
        ContentUnavailableView {
            Label(
                model.outcome == nil
                    ? L10n.string("Not scanned yet", language: override)
                    : L10n.string("All Clear", language: override),
                systemImage: model.outcome == nil ? model.destination.icon : "checkmark.circle"
            )
        } description: {
            VStack(spacing: Spacing.elementTight) {
                Text(
                    model.outcome == nil
                        ? L10n.string("Scan to find cleanup opportunities.", language: override)
                        : L10n.string("The latest scan found nothing in this area.", language: override)
                )
                if let errors = model.outcome?.session.errorsCount, errors > 0 {
                    Text(errors == 1
                        ? L10n.string("1 location could not be read during the scan.", language: override)
                        : L10n.format("%lld locations could not be read during the scan.", language: override, errors))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        } actions: {
            if model.outcome == nil {
                Button(L10n.string("Scan My Mac", language: override)) { model.scanAll() }
                    .disabled(model.isScanning || model.isExecuting)
            }
        }
    }

    private func filteredEmptyView(override: AppLanguage?) -> some View {
        let trimmedSearch = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContentUnavailableView {
            Label(
                L10n.string("No matching items for filter", language: override),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            if !trimmedSearch.isEmpty && model.reviewRiskFilter != nil {
                Text(L10n.format(
                    "No %@ risk actions match “%@”.",
                    language: override,
                    model.reviewRiskFilter?.displayName ?? "",
                    trimmedSearch
                ))
            } else if let risk = model.reviewRiskFilter {
                Text(L10n.format("No %@ risk actions in this area.", language: override, risk.displayName))
            } else {
                Text(L10n.format("No actions match “%@”.", language: override, trimmedSearch))
            }
        } actions: {
            Button(L10n.string("Clear Filters", language: override)) {
                model.reviewRiskFilter = nil
                model.searchText = ""
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func actionsList(override: AppLanguage?) -> some View {
        List(selection: $selectedIDs) {
            ForEach(visibleActions) { action in
                ActionRow(model: model, action: action).tag(action.id)
            }
        }
        .listStyle(.inset)
        .skeletonLoading(model.isScanning)
        .onChange(of: selectedIDs) { _, ids in
            model.selectedActionIDs = ids
            if let current = model.selectedActionID, ids.contains(current) {
                // Keep existing primary inspector target when still in selection.
            } else {
                model.selectedActionID = visibleActions.first(where: { ids.contains($0.id) })?.id
            }
            QuickLookCoordinator.shared.updateSelectionIfVisible(selectedTargetURLs)
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            selectedIDs = Set(visibleActions.map(\.id))
        }
        .onDeleteCommand {
            let candidates = visibleActions.filter {
                selectedIDs.contains($0.id) && $0.userDecision == .undecided && canReview($0)
            }
            if !candidates.isEmpty {
                requestBulk(candidates, approve: true)
            }
        }
        .onKeyPress(.space) {
            let urls = selectedTargetURLs
            guard !urls.isEmpty else { return .ignored }
            QuickLookCoordinator.shared.togglePreview(urls)
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenuItems(for: ids, override: override)
        } primaryAction: { ids in
            if let id = ids.first {
                model.selectedActionID = id
                model.showsInspector = true
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for ids: Set<String>, override: AppLanguage?) -> some View {
        let matched = visibleActions.filter { ids.contains($0.id) }
        if let first = matched.first {
            let urls = targetURLs(for: matched)
            Button(L10n.string("Show Details", language: override)) {
                model.selectedActionID = first.id
                model.showsInspector = true
            }
            if !urls.isEmpty {
                Button(L10n.string("Quick Look", language: override)) {
                    QuickLookCoordinator.shared.preview(urls)
                }
            }
            if let firstURL = urls.first {
                Button(L10n.string("Show in Finder", language: override)) {
                    NSWorkspace.shared.activateFileViewerSelecting([firstURL])
                }
            }
            Divider()
            Button(L10n.string("Approve", language: override)) {
                matched.filter(canReview).forEach(model.approve)
            }
            .disabled(!matched.contains(where: canReview))
            Button(L10n.string("Reject", language: override)) {
                matched.filter { $0.executedAt == nil }.forEach(model.reject)
            }
            .disabled(
                !matched.contains { $0.executedAt == nil }
                    || model.isExecuting || model.isScanning || model.isPlanning
            )
        }
    }
}

extension ActionStackView {

    private var selectedTargetURLs: [URL] {
        let selected = visibleActions.filter { selectedIDs.contains($0.id) }
        return targetURLs(for: selected)
    }

    private func targetURLs(for actions: [PlannedAction]) -> [URL] {
        actions.flatMap(\.targets).compactMap { model.filesByID[$0]?.url }
    }

    private func syncSelectionFromModel() {
        if let id = model.selectedActionID, visibleActions.contains(where: { $0.id == id }) {
            selectedIDs = [id]
            model.selectedActionIDs = selectedIDs
        }
    }

    private func controls(override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            ViewThatFits(in: .horizontal) {
                HStack { bulkControls(override: override) }
                VStack(alignment: .leading) { bulkControls(override: override) }
            }
            Text(L10n.string("Select an action to inspect it. Approval is a separate step.", language: override))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.cardPadding)
        .disabled(model.isScanning || model.isExecuting || model.isPlanning)
    }

    @ViewBuilder
    private func bulkControls(override: AppLanguage?) -> some View {
        Button(L10n.string("Approve Visible…", language: override)) {
            requestBulk(visibleActions.filter { $0.userDecision == .undecided && canReview($0) }, approve: true)
        }
        .disabled(!visibleActions.contains { $0.userDecision == .undecided && canReview($0) })
        Button(L10n.string("Approve Low Risk…", language: override)) {
            requestBulk(
                visibleActions.filter { $0.risk == .low && $0.userDecision == .undecided && canReview($0) },
                approve: true
            )
        }
        .disabled(!visibleActions.contains { $0.risk == .low && $0.userDecision == .undecided && canReview($0) })
        Menu(L10n.string("More", language: override)) {
            Button(L10n.string("Reject Undecided…", language: override)) {
                requestBulk(
                    visibleActions.filter { $0.userDecision == .undecided && $0.executedAt == nil },
                    approve: false
                )
            }
            .disabled(!visibleActions.contains { $0.userDecision == .undecided && $0.executedAt == nil })
        }
        .fixedSize()
    }

    private func canReview(_ action: PlannedAction) -> Bool {
        action.executedAt == nil && action.risk != .forbidden
            && action.actionType.isExecutable
            && !model.isScanning && !model.isExecuting && !model.isPlanning
    }

    private func requestBulk(_ actions: [PlannedAction], approve: Bool) {
        guard !actions.isEmpty else { return }
        bulkRequest = BulkReviewRequest(actions: actions, approve: approve, planRevision: model.planRevision)
    }

    private func bulkConfirmation(_ request: BulkReviewRequest, override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementSection) {
            Text(request.approve
                ? L10n.string("Approve Actions", language: override)
                : L10n.string("Reject Actions", language: override))
            .font(.title2.bold())
            Text(L10n.format(
                "Update decisions for %lld actions. No files change.",
                language: override,
                request.actions.count
            ))
            if request.actions.contains(where: { $0.risk == .high }) {
                Label(
                    L10n.string("This includes high-risk actions.", language: override),
                    systemImage: "exclamationmark.triangle"
                )
            }
            if request.planRevision != model.planRevision {
                Text(L10n.string("The plan changed. Cancel and review the current actions.", language: override))
                    .foregroundStyle(SemanticScale.error)
            }
            HStack {
                Button(L10n.string("Cancel", language: override)) { bulkRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.approve
                    ? L10n.string("Approve", language: override)
                    : L10n.string("Reject", language: override)) {
                    guard request.planRevision == model.planRevision else { return }
                    for action in request.actions {
                        if request.approve { model.approve(action) } else { model.reject(action) }
                    }
                    bulkRequest = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    request.planRevision != model.planRevision
                        || model.isScanning || model.isExecuting || model.isPlanning
                )
            }
        }
        .padding(Spacing.screenEdge)
        .frame(minWidth: 420)
        .presentationSizing(.fitted)
    }
}

private struct BulkReviewRequest: Identifiable {
    let id = UUID()
    let actions: [PlannedAction]
    let approve: Bool
    let planRevision: Int
}

struct ActionRow: View {
    @Bindable var model: AppViewModel
    let action: PlannedAction

    var body: some View {
        let override = model.languageStore.activeOverride
        HStack(alignment: .center, spacing: Spacing.elementNormal) {
            VStack(alignment: .leading, spacing: 5) {
                Text(action.reason).font(.headline).lineLimit(2)
                Text(targetDescription(override: override))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: Spacing.elementTight) {
                    Text(action.actionType.displayName).font(.caption)
                    RiskBadge(risk: action.risk)
                    Text(stateLabel(override: override)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: Spacing.elementTight) {
                Text(affectedBytes.formattedByteCount)
                    .monospacedDigit()
                    .font(.callout)
                    .help(L10n.string("Affected file size; reclaimable space depends on the operation", language: override))
                HStack {
                    Button(L10n.string("Reject", language: override)) { model.reject(action) }
                        .disabled(action.executedAt != nil)
                        .fontWeight(isRejected ? .semibold : nil)
                        .foregroundStyle(isRejected ? SemanticScale.error : Color.accentColor)
                        .accessibilityAddTraits(isRejected ? .isSelected : [])
                    Button(L10n.string("Approve", language: override)) { model.approve(action) }
                        .disabled(
                            action.risk == .forbidden || action.executedAt != nil
                                || !action.actionType.isExecutable
                        )
                        .fontWeight(isApproved ? .semibold : nil)
                        .foregroundStyle(isApproved ? SemanticScale.success : Color.accentColor)
                        .accessibilityAddTraits(isApproved ? .isSelected : [])
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
        }
        .padding(.vertical, Spacing.elementTight)
        .disabled(model.isScanning || model.isExecuting || model.isPlanning)
        .accessibilityElement(children: .contain)
    }

    private var isApproved: Bool {
        action.userDecision == .approved || action.userDecision == .alwaysDoThis
    }
    private var isRejected: Bool {
        action.userDecision == .rejected || action.userDecision == .neverDoThisHere
    }
    private func stateLabel(override: AppLanguage?) -> String {
        if action.risk == .forbidden { return L10n.string("Blocked", language: override) }
        if !action.actionType.isExecutable { return L10n.string("Review only", language: override) }
        return action.status.displayName
    }
    private func targetDescription(override: AppLanguage?) -> String {
        guard let id = action.targets.first, let record = model.filesByID[id] else {
            return L10n.format("%lld items", language: override, action.targets.count)
        }
        return action.targets.count > 1
            ? L10n.format("%@ and %lld more", language: override, record.displayPath, action.targets.count - 1)
            : record.displayPath
    }
    private var affectedBytes: Int64 {
        let totals = model.subtreeTotals
        return Set(action.targets).compactMap { model.filesByID[$0] }.reduce(Int64(0)) { total, record in
            total + ExploreSubtreeIndex.subtreeBytes(for: record, totals: totals)
        }
    }
}
