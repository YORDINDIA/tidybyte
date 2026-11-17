import MacOSCleanerCore
import SwiftUI

struct UndoHistoryView: View {
    @Bindable var model: AppViewModel
    @State private var restoreRequest: UndoRecord?

    private var records: [UndoRecord] {
        model.undoRecords.filter {
            model.searchText.isEmpty
                || ($0.restoreURL?.path ?? $0.trashURL?.path ?? "").localizedCaseInsensitiveContains(model.searchText)
                || $0.inverseAction.displayName.localizedCaseInsensitiveContains(model.searchText)
        }
    }

    private var previousActions: [PlannedAction] {
        model.historyActions.filter {
            !model.lastExecutionActionIDs.contains($0.id) && model.actionMatchesSearch($0)
        }
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        List(selection: $model.selectedHistoryID) {
            if let summary = model.executionSummary {
                latestExecutionSection(summary, override: override)
            }
            if !previousActions.isEmpty {
                Section(L10n.string("Previous actions", language: override)) {
                    ForEach(previousActions) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                action.actionType.displayName,
                                systemImage: action.status == .failed ? "exclamationmark.triangle" : "checkmark.circle"
                            )
                            Text(action.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Text(action.status.displayName)
                                if let date = action.executedAt { Text(date, format: .dateTime) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(action.id)
                    }
                }
            }
            if !records.isEmpty {
                Section(L10n.string("Restore records", language: override)) {
                    ForEach(records) { record in
                        HStack(spacing: Spacing.elementNormal) {
                            Image(systemName: record.status == .available ? "arrow.uturn.backward" : "checkmark.circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.inverseAction.displayName).font(.headline)
                                Text(
                                    record.restoreURL?.path ?? record.trashURL?.path
                                        ?? L10n.string("No file path recorded", language: override)
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            }
                            Spacer()
                            Text(record.status.displayName).font(.caption).foregroundStyle(.secondary)
                            Button(L10n.string("Restore", language: override)) { restoreRequest = record }
                                .disabled(record.status != .available || model.isScanning || model.isExecuting)
                        }
                        .padding(.vertical, Spacing.elementTight)
                        .tag(record.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .skeletonLoading(model.isLoadingUndoHistory)
        .overlay {
            if records.isEmpty && previousActions.isEmpty && model.executionSummary == nil {
                if model.isLoadingUndoHistory {
                    ProgressView(L10n.string("Loading history…", language: override))
                } else if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    ContentUnavailableView(
                        L10n.string("No history yet", language: override),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(L10n.string(
                            "Completed changes and available restore actions appear here.",
                            language: override
                        ))
                    )
                }
            }
        }
        .sheet(item: $restoreRequest) { record in
            RegretReasonSheet(
                subject: record.restoreURL?.path ?? record.trashURL?.path ?? record.inverseAction.displayName,
                override: override,
                onCancel: { restoreRequest = nil },
                restore: { reason in
                    restoreRequest = nil
                    guard let reason else {
                        Task { await model.restore(record) }
                        return
                    }
                    model.selectedRegretReason = reason.rawValue
                    Task { await model.restoreWithReason(record) }
                }
            )
        }
    }

    @ViewBuilder
    private func latestExecutionSection(_ summary: ExecutionSummary, override: AppLanguage?) -> some View {
        Section(L10n.string("Latest changes", language: override)) {
            LabeledContent(L10n.string("Completed operations", language: override), value: String(summary.logs.count))
            LabeledContent(L10n.string("Failed actions", language: override), value: String(summary.failedActionIDs.count))
            LabeledContent(
                L10n.string("Skipped or cancelled actions", language: override),
                value: model.lastExecutionActionIDs
                    .subtracting(summary.logs.map(\.plannedActionID))
                    .subtracting(summary.failedActionIDs).count.formatted()
            )
            LabeledContent(
                L10n.string("Pending approved actions", language: override),
                value: String(model.pendingExecutableActions().count)
            )
            ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SemanticScale.error)
                    .textSelection(.enabled)
            }
        }
        Section(L10n.string("Completed operations", language: override)) {
            ForEach(
                summary.logs.filter { log in
                    model.searchText.isEmpty
                        || log.operationType.displayName.localizedCaseInsensitiveContains(model.searchText)
                        || log.beforeState.values.contains { $0.localizedCaseInsensitiveContains(model.searchText) }
                }
            ) { log in
                VStack(alignment: .leading, spacing: 4) {
                    Label(log.operationType.displayName, systemImage: "checkmark.circle")
                    Text(log.beforeState["path"] ?? log.beforeState["command"] ?? log.result)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(log.id)
            }
        }
        Section(L10n.string("Failed or skipped actions", language: override)) {
            ForEach(
                (model.plan?.actions ?? []).filter {
                    model.lastExecutionActionIDs.contains($0.id)
                        && ($0.status != .completed || summary.failedActionIDs.contains($0.id))
                        && model.actionMatchesSearch($0)
                }
            ) { action in
                Label(
                    action.reason,
                    systemImage: action.status == .failed ? "exclamationmark.triangle" : "pause.circle"
                )
                .tag(action.id)
            }
        }
    }
}

struct HistoryDetailsView: View {
    @Bindable var model: AppViewModel
    @State private var storedLog: OperationLog?

    private var record: UndoRecord? { model.undoRecords.first { $0.id == model.selectedHistoryID } }
    private var log: OperationLog? {
        model.executionSummary?.logs.first { $0.id == model.selectedHistoryID } ?? storedLog
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        Form {
            if let record {
                Section(L10n.string("Restore record", language: override)) {
                    LabeledContent(L10n.string("Operation", language: override), value: record.inverseAction.displayName)
                    LabeledContent(L10n.string("Status", language: override), value: record.status.displayName)
                    if let path = record.restoreURL?.path { Text(path).textSelection(.enabled) }
                    if let expiry = record.validUntil {
                        LabeledContent(L10n.string("Valid until", language: override), value: expiry.formatted())
                    }
                    Text(L10n.string(
                        "Use Restore in the history list. Recovery depends on the files remaining available.",
                        language: override
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let log {
                Section(L10n.string("Operation", language: override)) {
                    Text(log.operationType.displayName).font(.headline)
                    Text(log.timestamp, format: .dateTime)
                    if let error = log.error { Text(error).foregroundStyle(SemanticScale.error) }
                }
                Section(L10n.string("Before", language: override)) { stateValues(log.beforeState) }
                Section(L10n.string("After", language: override)) { stateValues(log.afterState) }
                if log.operationType == .runPackageManagerCleanup {
                    Text(L10n.string("This command has no restore action.", language: override))
                }
            } else if let action = selectedAction {
                Section(L10n.string("Action", language: override)) {
                    Text(action.reason).textSelection(.enabled)
                    Text(action.status.displayName)
                    RiskBadge(risk: action.risk)
                    if action.actionType == .runPackageManagerCleanup {
                        Text(L10n.string("This command has no restore action.", language: override))
                    }
                    if action.status == .failed {
                        Text(L10n.string(
                            "See the latest execution errors in History for failure details.",
                            language: override
                        ))
                    }
                }
            } else if record == nil {
                Text(L10n.string("Select a history item to see its details.", language: override))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: model.selectedHistoryID) {
            storedLog = nil
            guard let record else { return }
            let loaded = await model.historyOperation(id: record.operationLogID)
            if !Task.isCancelled { storedLog = loaded }
        }
    }

    private var selectedAction: PlannedAction? {
        model.historyActions.first { $0.id == model.selectedHistoryID }
            ?? model.plan?.actions.first { $0.id == model.selectedHistoryID }
    }

    private func stateValues(_ values: [String: String]) -> some View {
        ForEach(values.keys.sorted(), id: \.self) { key in
            LabeledContent(key, value: values[key] ?? "")
                .font(.caption).textSelection(.enabled)
        }
    }
}
