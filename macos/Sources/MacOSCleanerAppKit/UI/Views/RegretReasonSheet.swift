import MacOSCleanerCore
import SwiftUI

/// The regret-reason prompt shared by History restore and the menu-bar undo
/// (MB-10): five optional reasons plus "Restore without answering", which
/// completes the restore with no reason recorded.
struct RegretReasonSheet: View {
    let subject: String
    let onCancel: () -> Void
    /// Performs the restore. A nil reason means "without answering".
    let restore: (AppViewModel.RegretReason?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementSection) {
            Text(String(localized: "Restore this change?")).font(.title2.bold())
            Text(subject)
                .textSelection(.enabled)
            Text(String(localized: "Optional: tell Tidybyte why you want to restore it."))
                .foregroundStyle(.secondary)
            ForEach(AppViewModel.RegretReason.allCases, id: \.self) { reason in
                Button(reason.rawValue) { restore(reason) }
            }
            HStack {
                Button(String(localized: "Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Restore without answering")) { restore(nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.screenEdge)
        .frame(minWidth: 460)
        .presentationSizing(.fitted)
    }
}
