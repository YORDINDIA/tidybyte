import MacOSCleanerCore
import SwiftUI

/// Errors and permission notices, plus the live progress strip for scans,
/// executions, and media work. One top-of-window strip: what needs attention,
/// and what is currently running.
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
        if hasNotice || hasProgress {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                progressStrip
                if let error = model.errorMessage {
                    notice(error, symbol: "exclamationmark.triangle.fill", tint: SemanticScale.error) {
                        Button(String(localized: "Dismiss")) { model.dismissError() }
                    }
                }
                if let error = model.cleanup.error {
                    notice(error, symbol: "exclamationmark.triangle.fill", tint: SemanticScale.error) {
                        Button(String(localized: "Dismiss")) { model.cleanup.error = nil }
                    }
                }
                if let error = model.monitor.lastError {
                    notice(error, symbol: "waveform.path.ecg", tint: SemanticScale.warning) {
                        Button(String(localized: "Dismiss")) { model.monitor.dismissError() }
                    }
                }
                if let hint = model.fullDiskAccessHint {
                    notice(hint, symbol: "lock.shield", tint: SemanticScale.warning) {
                        Button(String(localized: "Open Privacy Settings")) { PermissionLinks.openFullDiskAccess() }
                        Button(String(localized: "Dismiss")) { model.dismissFullDiskAccessHint() }
                    }
                }
                // Scan diagnostics: locations the scan could not read, sections
                // it had to skip. An empty review must be distinguishable from
                // a scan that could not see everything.
                ForEach(model.activeScanNotices) { scanNotice in
                    notice(scanNotice.message, symbol: "eye.trianglebadge.exclamationmark", tint: SemanticScale.warning) {
                        Button(String(localized: "Dismiss")) { model.dismissScanNotice(scanNotice.id) }
                    }
                }
                if let notice = model.cleanup.notice {
                    self.notice(notice, symbol: "info.circle", tint: .secondary) {
                        Button(String(localized: "Dismiss")) { model.cleanup.notice = nil }
                    }
                }
                if model.isUsingTempDatabase {
                    Label(
                        String(localized: "Temporary storage is in use. History will not persist after this session."),
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

    // MARK: Progress

    @ViewBuilder private var progressStrip: some View {
        if model.isScanning {
            // Determinate per pipeline step (crawl ticks are throttled in the
            // model, so the bar moves in steps, not per file).
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    Label(String(localized: "Scanning"), systemImage: "magnifyingglass")
                    Spacer()
                    if model.scanTotalSteps > 0 {
                        Text("\(model.scanCurrentStep)/\(model.scanTotalSteps)").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(
                    value: Double(max(0, model.scanCurrentStep)),
                    total: Double(max(1, model.scanTotalSteps)))
                if !model.scanPhaseText.isEmpty {
                    Text(model.scanPhaseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        if model.isExecuting {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    Label(String(localized: "Applying changes"), systemImage: "checkmark.circle")
                    Spacer()
                    Text("\(model.executionCompletedActions)/\(model.executionTotalActions)").monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // executionProgress is completed/total with a max(1, total)
                // denominator, so it stays inside 0...1.
                ProgressView(value: model.executionProgress)
            }
        }
        if model.cleanup.isBusy, model.cleanup.progress.total > 0 {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    Label(model.cleanup.progress.phase, systemImage: "photo.on.rectangle")
                    Spacer()
                    Text("\(model.cleanup.progress.completed)/\(model.cleanup.progress.total)").monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(model.cleanup.progress.completed), total: Double(model.cleanup.progress.total))
            }
        }
    }

    private func notice<Actions: View>(
        _ text: String, symbol: String, tint: Color, @ViewBuilder actions: () -> Actions
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
