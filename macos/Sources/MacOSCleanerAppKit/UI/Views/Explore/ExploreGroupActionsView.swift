import MacOSCleanerCore
import SwiftUI

/// Focus + Quick Look + Stage actions for an Explore group selection.
struct ExploreGroupActionsView: View {
    @Bindable var model: AppViewModel
    var group: ExploreGroup
    var files: [FileRecord]
    /// Drill callback used by FoldersGridView (re-roots the grid on the record).
    var onFocus: ((FileRecord) -> Void)?

    @State private var actionMessage: String?

    private var override: AppLanguage? {
        model.languageStore.activeOverride
    }

    private var representative: FileRecord? {
        ExploreTreeBuilder.largestMember(of: group, in: files)
    }

    var body: some View {
        if let record = representative {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack(spacing: Spacing.elementTight) {
                    SecondaryButton(
                        title: L10n.string("Focus", language: override),
                        icon: "scope",
                        action: {
                            if let onFocus {
                                onFocus(record)
                            } else {
                                model.focusExploreRecord(id: record.id)
                                model.selectExploreRecord(id: record.id)
                            }
                            actionMessage = L10n.format("Focused %@.", language: override, record.fileName)
                        }
                    )
                    SecondaryButton(
                        title: L10n.string("Quick Look", language: override),
                        icon: "eye",
                        action: {
                            QuickLookCoordinator.shared.preview(record.url)
                        }
                    )
                    if let staged = model.stagedExploreAction(matching: record) {
                        SecondaryButton(
                            title: L10n.string("Approve", language: override),
                            icon: "checkmark",
                            action: {
                                model.approve(staged)
                                actionMessage = L10n.string(
                                    "Approved. Review it in Proposed Actions.",
                                    language: override
                                )
                            }
                        )
                    } else {
                        SecondaryButton(
                            title: L10n.string("Stage", language: override),
                            icon: "plus.circle",
                            action: { stageRepresentative(record) }
                        )
                    }
                }
                Text(L10n.format(
                    "Acts on largest member: %@ (%@)",
                    language: override,
                    record.fileName,
                    record.sizeBytes.formattedByteCount
                ))
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                if let actionMessage {
                    Text(actionMessage)
                        .appFont(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.format("Group actions for %@", language: override, group.name))
            .onChange(of: group.id) { _, _ in
                actionMessage = nil
            }
        }
    }

    private func stageRepresentative(_ record: FileRecord) {
        if model.stageExploreRecordForCleanup(record) != nil {
            actionMessage = L10n.string(
                "Added to the cleanup plan. Review it in Proposed Actions.",
                language: override
            )
            return
        }
        actionMessage = L10n.string(
            "Could not stage. A scan, execution, or plan change is in flight — or there is nothing to stage yet.",
            language: override
        )
    }
}
