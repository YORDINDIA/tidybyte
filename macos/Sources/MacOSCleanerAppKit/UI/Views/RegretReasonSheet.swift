import MacOSCleanerCore
import SwiftUI

/// The regret-reason prompt shared by History restore and the menu-bar undo.
struct RegretReasonSheet: View {
    let subject: String
    var override: AppLanguage?
    let onCancel: () -> Void
    /// Performs the restore. A nil reason means "without answering".
    let restore: (AppViewModel.RegretReason?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementSection) {
            Text(L10n.string("Restore this change?", language: override)).font(.title2.bold())
            Text(subject)
                .appFont(.filePath)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Text(L10n.string("Optional: tell Tidybyte why you want to restore it.", language: override))
                .foregroundStyle(.secondary)
            ForEach(AppViewModel.RegretReason.allCases, id: \.self) { reason in
                Button(reason.title) { restore(reason) }
            }
            HStack {
                Button(L10n.string("Cancel", language: override)) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("Restore without answering", language: override)) { restore(nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.screenEdge)
        .frame(minWidth: 460)
        .presentationSizing(.fitted)
    }
}
