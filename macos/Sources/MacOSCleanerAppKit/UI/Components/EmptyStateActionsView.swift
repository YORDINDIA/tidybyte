import MacOSCleanerCore
import SwiftUI

/// Shared recovery-button cluster for empty states (proposed actions, undo
/// history, relationship graph).
struct EmptyStateActionsView: View {
    @Bindable var model: AppViewModel

    var body: some View {
        let override = model.languageStore.activeOverride
        HStack(spacing: 10) {
            SecondaryButton(
                title: L10n.string("New Scan…", language: override),
                icon: "magnifyingglass",
                action: {
                    model.showsScanSetup = true
                }
            )
            SecondaryButton(
                title: L10n.string("Re-run with safer mode", language: override),
                icon: "shield.lefthalf.fill",
                action: {
                    model.runSaferScan()
                }
            )
            if model.generatedReportURL != nil {
                SecondaryButton(
                    title: L10n.string("View last report", language: override),
                    icon: "doc.plaintext",
                    action: {
                        model.openLatestReport()
                    }
                )
            }
        }
    }
}
