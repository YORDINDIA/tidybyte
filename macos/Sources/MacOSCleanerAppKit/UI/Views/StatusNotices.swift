import MacOSCleanerCore
import SwiftUI

/// Errors and permission notices, plus the live progress strip for scans,
/// executions, and media work.
struct StatusNotices: View {
    @Bindable var model: AppViewModel

    private var hasNotice: Bool {
        model.errorMessage != nil || model.fullDiskAccessHint != nil || model.isUsingTempDatabase
            || model.cleanup.error != nil || model.cleanup.notice != nil
            || !model.activeScanNotices.isEmpty
            || model.monitor.lastError != nil
    }

    private var hasProgress: Bool {
        model.isScanning || model.isExecuting || (model.cleanup.isBusy && model.cleanup.progress.total > 0)
    }

    var body: some View {
        let override = model.languageStore.activeOverride
        if hasNotice || hasProgress {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                progressStrip(override: override)
                if let error = model.errorMessage {
                    notice(error, symbol: "exclamationmark.triangle.fill", tint: SemanticScale.error) {
                        Button(L10n.string("Dismiss", language: override)) { model.dismissError() }
                    }
                }
                if let error = model.cleanup.error {
                    notice(error, symbol: "exclamationmark.triangle.fill", tint: SemanticScale.error) {
                        if model.cleanup.photosAccessDenied {
                            Button(L10n.string("Open Photos Settings", language: override)) {
                                PermissionLinks.openPhotos()
                            }
                        }
                        Button(L10n.string("Dismiss", language: override)) {
                            model.cleanup.error = nil
                            model.cleanup.photosAccessDenied = false
                        }
                    }
                }
                if let error = model.monitor.lastError {
                    notice(error, symbol: "waveform.path.ecg", tint: SemanticScale.warning) {
                        Button(L10n.string("Dismiss", language: override)) { model.monitor.dismissError() }
                    }
                }
                if let hint = model.fullDiskAccessHint {
                    notice(hint, symbol: "lock.shield", tint: SemanticScale.warning) {
                        Button(L10n.string("Open Privacy Settings", language: override)) {
                            PermissionLinks.openFullDiskAccess()
                        }
                        Button(L10n.string("Dismiss", language: override)) { model.dismissFullDiskAccessHint() }
                    }
                }
                ForEach(model.activeScanNotices) { scanNotice in
                    notice(
                        scanNotice.message,
                        symbol: "eye.trianglebadge.exclamationmark",
                        tint: SemanticScale.warning
                    ) {
                        Button(L10n.string("Dismiss", language: override)) {
                            model.dismissScanNotice(scanNotice.id)
                        }
                    }
                }
                if let noticeText = model.cleanup.notice {
                    self.notice(noticeText, symbol: "info.circle", tint: .secondary) {
                        Button(L10n.string("Dismiss", language: override)) { model.cleanup.notice = nil }
                    }
                }
                if model.isUsingTempDatabase {
                    Label(
                        L10n.string(
                            "Temporary storage is in use. History will not persist after this session.",
                            language: override
                        ),
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .foregroundStyle(SemanticScale.warning)
                }
            }
            .font(.callout)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.elementNormal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func progressStrip(override: AppLanguage?) -> some View {
        scanProgress(override: override)
        executionProgressView(override: override)
        cleanupProgress
    }

    @ViewBuilder
    private func scanProgress(override: AppLanguage?) -> some View {
        if model.isScanning {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    Label(L10n.string("Scanning", language: override), systemImage: "magnifyingglass")
                    Spacer()
                    if model.scanTotalSteps > 0 {
                        Text("\(model.scanCurrentStep)/\(model.scanTotalSteps)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(
                    value: Double(max(0, model.scanCurrentStep)),
                    total: Double(max(1, model.scanTotalSteps))
                )
                if !model.scanPhaseText.isEmpty {
                    Text(model.scanPhaseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func executionProgressView(override: AppLanguage?) -> some View {
        if model.isExecuting {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    Label(L10n.string("Applying changes", language: override), systemImage: "checkmark.circle")
                    Spacer()
                    Text("\(model.executionCompletedActions)/\(model.executionTotalActions)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: model.executionProgress)
            }
        }
    }

    @ViewBuilder
    private var cleanupProgress: some View {
        if model.cleanup.isBusy, model.cleanup.progress.total > 0 {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    Label(model.cleanup.progress.phase, systemImage: "photo.on.rectangle")
                    Spacer()
                    Text("\(model.cleanup.progress.completed)/\(model.cleanup.progress.total)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(
                    value: Double(model.cleanup.progress.completed),
                    total: Double(model.cleanup.progress.total)
                )
            }
        }
    }

    private func notice<Actions: View>(
        _ text: String,
        symbol: String,
        tint: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.elementNormal) {
            Label {
                Text(text).textSelection(.enabled)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            Spacer(minLength: Spacing.elementNormal)
            actions().controlSize(.small)
        }
    }
}

/// System Settings deep links used by notices and onboarding.
enum PermissionLinks {
    static func openFullDiskAccess() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    static func openPhotos() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
