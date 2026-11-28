import MacOSCleanerCore
import SwiftUI

struct TidyUpPreviewSheet: View {
    @Bindable var model: ScreenshotRenameModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [TidyUpCandidate]
    let folderName: String
    let skippedWellNamedCount: Int
    let override: AppLanguage?

    init(model: ScreenshotRenameModel, initialSummary: TidyUpScanSummary, override: AppLanguage?) {
        self.model = model
        self._candidates = State(initialValue: initialSummary.candidates)
        self.folderName = initialSummary.folderURL.lastPathComponent
        self.skippedWellNamedCount = initialSummary.skippedWellNamedCount
        self.override = override
    }

    private var selectedCount: Int {
        candidates.filter(\.isSelected).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            header
            List {
                ForEach($candidates) { $candidate in
                    HStack(spacing: Spacing.elementNormal) {
                        Toggle("", isOn: $candidate.isSelected)
                            .labelsHidden()
                        ScreenshotThumbnailView(url: candidate.url)
                            .frame(width: 44, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: candidate.currentFileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                TextField(L10n.string("Title", language: override), text: $candidate.proposedTitle)
                                    .textFieldStyle(.roundedBorder)
                                let ext = candidate.url.pathExtension
                                if !ext.isEmpty {
                                    Text(verbatim: ".\(ext)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            footer
        }
        .padding(Spacing.cardPadding)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 500)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.format("Tidy Up %@", language: override, folderName))
                .font(.title2.bold())
            Text(
                skippedWellNamedCount == 1
                    ? L10n.string("1 well-named file will be left alone.", language: override)
                    : L10n.format("%lld well-named files will be left alone.", language: override, skippedWellNamedCount)
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.string("Cancel", language: override)) {
                model.pendingTidyUp = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(
                selectedCount == 1
                    ? L10n.string("Tidy Up 1 File", language: override)
                    : L10n.format("Tidy Up %lld Files", language: override, selectedCount)
            ) {
                model.pendingTidyUp?.candidates = candidates
                dismiss()
                Task { await model.applyPendingTidyUp() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCount == 0)
        }
    }
}
