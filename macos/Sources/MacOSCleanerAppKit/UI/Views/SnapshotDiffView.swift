import MacOSCleanerCore
import SwiftUI

/// Snapshots tab: pick any two stored scan snapshots and see which folders
/// grew, ranked by byte delta. Read-only — diffing never modifies data.
struct SnapshotDiffView: View {
    @Bindable var model: AppViewModel

    var body: some View {
        let override = model.languageStore.activeOverride
        List(selection: $model.selectedSnapshotID) {
            Section(L10n.string("Saved scans", language: override)) {
                ForEach(model.storageSnapshots.filter {
                    model.searchText.isEmpty || snapshotLabel(for: $0).localizedCaseInsensitiveContains(model.searchText)
                        || $0.bytesByRootPath.keys.contains { $0.localizedCaseInsensitiveContains(model.searchText) }
                }) { snapshot in
                    Text(snapshotLabel(for: snapshot)).tag(snapshot.id)
                }
            }
            if model.isLoadingSnapshots {
                ProgressView(L10n.string("Loading snapshots…", language: override))
            } else if model.storageSnapshots.count < 2 {
                emptyState(override: override)
            } else {
                pickerCard(override: override)
                diffCard(override: override)
            }
        }
        .listStyle(.inset)
        .skeletonLoading(model.isLoadingSnapshots)
        .task { await model.loadSnapshotHistory() }
    }

    private func emptyState(override: AppLanguage?) -> some View {
        ContentUnavailableView {
            Label(
                L10n.string("Need at least two scans to compare.", language: override),
                systemImage: "square.stack.3d.up"
            )
        } description: {
            Text(L10n.string("Each scan saves a snapshot. Start another scan to compare results.", language: override))
        } actions: {
            EmptyStateActionsView(model: model)
        }
    }

    private func pickerCard(override: AppLanguage?) -> some View {
        Section(L10n.string("Compare Scans", language: override)) {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                Picker(L10n.string("Older snapshot", language: override), selection: Binding(
                    get: { model.olderSnapshotID ?? "" },
                    set: { newValue in
                        model.olderSnapshotID = newValue.isEmpty ? nil : newValue
                        Task { await model.refreshSnapshotDiff() }
                    }
                )) {
                    ForEach(model.storageSnapshots.sorted { $0.createdAt < $1.createdAt }) { snapshot in
                        Text(snapshotLabel(for: snapshot)).tag(snapshot.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel(L10n.string("Older snapshot", language: override))
                Picker(L10n.string("Newer snapshot", language: override), selection: Binding(
                    get: { model.newerSnapshotID ?? "" },
                    set: { newValue in
                        model.newerSnapshotID = newValue.isEmpty ? nil : newValue
                        Task { await model.refreshSnapshotDiff() }
                    }
                )) {
                    ForEach(model.storageSnapshots.sorted { $0.createdAt < $1.createdAt }) { snapshot in
                        Text(snapshotLabel(for: snapshot)).tag(snapshot.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel(L10n.string("Newer snapshot", language: override))
            }
        }
    }

    private func snapshotLabel(for snapshot: StorageSnapshot) -> String {
        let date = snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(date), \(snapshot.totalBytes.formattedByteCount)"
    }

    @ViewBuilder
    private func diffCard(override: AppLanguage?) -> some View {
        if let error = model.snapshotDiffError {
            Text(error)
                .appFont(.labelMedium)
                .foregroundStyle(Primary.label)
                .padding(Spacing.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    SemanticScale.errorSoft,
                    in: RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
                )
        } else if let diff = model.snapshotDiff {
            Section(L10n.string("Snapshot Diff", language: override)) {
                VStack(alignment: .leading, spacing: Spacing.elementTight) {
                    headlineRow(for: diff, override: override)
                    if diff.folderDeltas.isEmpty {
                        Text(L10n.string("No folder changed between these snapshots.", language: override))
                            .appFont(.caption)
                            .foregroundStyle(Color.secondary)
                    } else {
                        Text(L10n.string("Grown folders", language: override))
                            .font(.app(.h3))
                            .foregroundStyle(Color.secondary)
                        let matching = diff.folderDeltas.filter {
                            model.searchText.isEmpty || $0.path.localizedCaseInsensitiveContains(model.searchText)
                        }
                        ForEach(matching) { delta in
                            folderRow(for: delta, override: override)
                        }
                    }
                    if !diff.categoryDeltas.isEmpty {
                        Text(L10n.string("Category shifts", language: override))
                            .font(.app(.h3))
                            .foregroundStyle(Color.secondary)
                        ForEach(diff.categoryDeltas, id: \.category) { entry in
                            HStack {
                                Text(entry.category.displayName)
                                    .appFont(.labelMedium)
                                    .foregroundStyle(Color.secondary)
                                Spacer()
                                deltaChip(entry.deltaBytes)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("Snapshot comparison", language: override))
        }
    }

    private func headlineRow(for diff: SnapshotDiff, override: AppLanguage?) -> some View {
        HStack {
            Text(L10n.string("Total change", language: override))
                .appFont(.h4)
                .foregroundStyle(Color.primary)
            Spacer()
            deltaChip(diff.totalDeltaBytes)
        }
    }

    private func folderRow(for delta: SnapshotFolderDelta, override: AppLanguage?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(delta.path)
                    .appFont(.filePath)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(delta.olderBytes.formattedByteCount) → \(delta.newerBytes.formattedByteCount)")
                    .appFont(.filePath)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
            Spacer()
            deltaChip(delta.deltaBytes)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("%@, change %@", language: override, delta.path, signedBytes(delta.deltaBytes)))
    }

    private func deltaChip(_ value: Int64) -> some View {
        Text(signedBytes(value))
            .appFont(.labelMedium)
            .monospacedDigit()
            .foregroundStyle(value > 0 ? SemanticScale.warning : SemanticScale.success)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(value > 0 ? SemanticScale.warningSoft : SemanticScale.successSoft)
            .clipShape(.rect(cornerRadius: Radius.cardCompact))
    }

    private func signedBytes(_ value: Int64) -> String {
        value >= 0 ? "+\(value.formattedByteCount)" : "−\(abs(value).formattedByteCount)"
    }
}
