import MacOSCleanerCore
import SwiftUI

struct ExecutionConfirmView: View {
    @Bindable var model: AppViewModel
    let request: ExecutionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var planCurrent = true

    private var hasFileActions: Bool {
        request.actions.contains { $0.actionType != .runPackageManagerCleanup }
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            header(override: override)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                    breakdownSection(override: override)
                    batchCapsSection(override: override)
                    itemsSection(override: override)
                    noticesSection(override: override)
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            Divider()
            footer(override: override)
        }
        .padding(Spacing.screenEdge)
        .frame(minWidth: 500, idealWidth: 540)
        .presentationSizing(.fitted)
        .onAppear { planCurrent = request.isCurrent(in: model) }
        .onChange(of: model.planRevision) {
            planCurrent = request.isCurrent(in: model)
        }
    }

    private func header(override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Label(L10n.string("Review Changes", language: override), systemImage: "checklist")
                .font(.title2.bold())
            Text(L10n.format(
                "%lld approved actions · %lld known unique items",
                language: override,
                request.actions.count,
                request.fileCount
            ))
            .foregroundStyle(.secondary)
            if !request.areaCounts.isEmpty {
                Text(
                    request.areaCounts
                        .map { L10n.format("%@ %lld", language: override, $0.area.title, $0.count) }
                        .formatted(.list(type: .and))
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func breakdownSection(override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(L10n.string("Space & Reversibility Breakdown", language: override))
                .appFont(.h4)
            if !request.trashActions.isEmpty {
                breakdownRow(
                    title: L10n.string("Move to Trash (recoverable 30 days)", language: override),
                    symbol: "trash",
                    tint: SemanticScale.warning,
                    count: request.trashActions.count,
                    bytes: request.estimatedBytes
                )
            }
            if !request.cloneActions.isEmpty {
                breakdownRow(
                    title: L10n.string("APFS Clone Fold (no deletion, undoable)", language: override),
                    symbol: "square.on.square.dashed",
                    tint: SemanticScale.success,
                    count: request.cloneActions.count,
                    bytes: request.estimatedCloneBytes
                )
            }
            if !request.otherFileActions.isEmpty {
                breakdownRow(
                    title: L10n.string("Other File Operations (undoable)", language: override),
                    symbol: "folder.badge.gearshape",
                    tint: Primary.primary,
                    count: request.otherFileActions.count,
                    bytes: request.estimatedOtherFileBytes
                )
            }
            if !request.packageActions.isEmpty {
                HStack(spacing: Spacing.elementTight) {
                    Label(
                        L10n.string("Package-Manager Commands (permanent)", language: override),
                        systemImage: "terminal"
                    )
                    .foregroundStyle(SemanticScale.error)
                    Spacer()
                    Text("\(request.packageActions.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(Spacing.cardInternal)
        .softCardSurface(cornerRadius: Radius.cardCompact)
    }

    private func breakdownRow(
        title: String,
        symbol: String,
        tint: Color,
        count: Int,
        bytes: Int64
    ) -> some View {
        HStack(spacing: Spacing.elementTight) {
            Label(title, systemImage: symbol)
                .foregroundStyle(tint)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if bytes > 0 {
                Text("· \(bytes.formattedByteCount)")
                    .monospacedDigit()
                    .font(.callout.weight(.medium))
            }
        }
        .font(.callout)
    }

    private func batchCapsSection(override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("Safety Caps", language: override))
                .appFont(.h4)
            LabeledContent(
                L10n.string("Actions per batch", language: override),
                value: "\(request.actions.count) / \(ExecutionLimits.maxActionsPerBatch)"
            )
            .font(.caption)
            .foregroundStyle(request.exceedsBatchActionCap ? SemanticScale.error : .secondary)
            if request.batchCappedBytes > 0 {
                LabeledContent(
                    L10n.string("File-mutation byte cap", language: override),
                    value: "\(request.batchCappedBytes.formattedByteCount) / \(ExecutionLimits.maxBytesPerBatch.formattedByteCount)"
                )
                .font(.caption)
                .foregroundStyle(request.exceedsBatchByteCap ? SemanticScale.error : .secondary)
            }
            if !request.cloneActions.isEmpty || !request.packageActions.isEmpty {
                Text(L10n.string(
                    "APFS clone folds and package-manager commands do not count toward the file-mutation byte cap.",
                    language: override
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.cardInternal)
        .softCardSurface(cornerRadius: Radius.cardCompact)
    }

    private func itemsSection(override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Text(L10n.format("Included Actions (%lld)", language: override, request.actions.count))
                .appFont(.h4)
            ForEach(request.actions) { action in
                HStack(alignment: .top, spacing: Spacing.elementTight) {
                    RiskBadge(risk: action.risk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.reason)
                            .font(.callout)
                            .lineLimit(2)
                        if let firstTarget = action.targets.first,
                           let path = request.resolvedFileNamesByID[firstTarget] {
                            Text(action.targets.count > 1
                                ? L10n.format("%@ and %lld more", language: override, path, action.targets.count - 1)
                                : path)
                            .appFont(.filePath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(action.actionType.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(Spacing.cardInternal)
        .softCardSurface(cornerRadius: Radius.cardCompact)
    }

    @ViewBuilder
    private func noticesSection(override: AppLanguage?) -> some View {
        if request.unresolvedTargetCount > 0 {
            Label(
                L10n.format(
                    "Missing records: %lld. Rescan to include these items.",
                    language: override,
                    request.unresolvedTargetCount
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(SemanticScale.warning)
        }
        Text(
            request.isTrashOnly
                ? L10n.string(
                    "Files will move to Trash. Restore them from History while they remain available.",
                    language: override)
                : L10n.string(
                    "Restore options appear in History. Package-manager cleanup cannot be undone.",
                    language: override)
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Text(L10n.string(
            "Safety checks run again before any files change. Blocked and review-only actions are excluded.",
            language: override
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        if !planCurrent {
            Label(
                L10n.string("The plan changed. Close this sheet and review it again.", language: override),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(SemanticScale.error)
        }
    }

    private func footer(override: AppLanguage?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            HStack {
                Button(L10n.string("Cancel", language: override)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if hasFileActions {
                    Button(request.confirmTitle, role: request.isTrashOnly ? .destructive : nil) {
                        dismiss()
                        Task { await model.executeConfirmedRequest(request, packageCommandsOnly: false) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!planCurrent)
                }
            }
            if request.hasPackageCommands {
                Divider()
                packageWarningNotice(override: override)
                Button(
                    L10n.string("Run Package-Manager Commands", language: override),
                    role: .destructive
                ) {
                    dismiss()
                    Task { await model.executeConfirmedRequest(request, packageCommandsOnly: true) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!planCurrent)
            }
        }
    }

    private func packageWarningNotice(override: AppLanguage?) -> some View {
        let copy = L10n.string(
            "Package-manager commands are irreversible. They run external tools (brew, docker, npm) and cannot be undone from Tidybyte.",
            language: override
        )
        return Label {
            Text(copy)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(SemanticScale.error)
        .font(.callout)
    }
}
