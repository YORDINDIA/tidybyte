import MacOSCleanerCore
import SwiftUI

/// Floating Liquid Glass bar with the approved-change count and confirmation triggers.
struct StagedQueueBar: View {
    @Bindable var model: AppViewModel
    var onConfirm: (RiskLevel) -> Void

    var body: some View {
        let override = model.languageStore.activeOverride
        let actions = model.pendingExecutableActions()
        if !actions.isEmpty {
            GlassEffectContainer {
                HStack(spacing: Spacing.elementNormal) {
                    Label(
                        L10n.format("%lld approved", language: override, actions.count),
                        systemImage: "checkmark.circle"
                    )
                    .monospacedDigit()
                    .padding(.leading, Spacing.elementTight)
                    if !model.pendingExecutableActions(upTo: .low).isEmpty {
                        Button(L10n.string("Clean Low Risk Only…", language: override)) { onConfirm(.low) }
                            .buttonStyle(.glass)
                    }
                    Button(L10n.string("Review & Clean…", language: override)) { onConfirm(.high) }
                        .buttonStyle(.glassProminent)
                }
                .padding(Spacing.elementTight)
                .floatingGlassOverlay(in: Capsule())
            }
            .disabled(model.isScanning || model.isExecuting || model.isPlanning)
            .padding(.bottom, Spacing.elementNormal)
        }
    }
}
