import MacOSCleanerCore
import SwiftUI

/// Full iOS-parity compression controls (`IC-01`..`IC-04`) for Image and Video compression.
struct CompressionControlsView: View {
    @Bindable var model: CleanupModel
    let tool: CleanupTool
    let visibleItems: [ReviewItem]
    let selectedItems: [ReviewItem]
    @Binding var showAllImages: Bool

    private var summaryTargets: [ReviewItem] { selectedItems.isEmpty ? visibleItems : selectedItems }

    private var estimatedOutputBytes: Int64 {
        summaryTargets.reduce(0) { sum, item in
            sum + (model.measuredBytes(for: item) ?? MediaCompressionService.estimate(item, settings: model.settings))
        }
    }

    private var originalTotalBytes: Int64 {
        summaryTargets.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                if tool == .imageCompression {
                    imageRowOne
                    imageRowTwo
                } else {
                    videoRow
                }
                originalsAndSavingsBar
            }
            .padding(4)
        }
    }

    private var imageRowOne: some View {
        HStack(spacing: Spacing.elementNormal) {
            Picker(String(localized: "Sort"), selection: $model.settings.photoCompressionSortOrder) {
                ForEach(PhotoCompressionSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .frame(maxWidth: 210)

            Picker(String(localized: "Target Size"), selection: $model.settings.photoMaxSizeMB) {
                Text(String(localized: "Quality Preset")).tag(Optional<Double>.none)
                ForEach(CleanupSettings.photoMaxSizeChoicesMB, id: \.self) { sizeMB in
                    Text(Self.formatMegabytes(sizeMB)).tag(Optional(sizeMB))
                }
            }
            .frame(maxWidth: 210)

            if model.settings.photoMaxSizeMB == nil {
                Picker(String(localized: "Quality"), selection: $model.settings.imageQuality) {
                    Text(String(localized: "High")).tag(ImageQuality.high)
                    Text(String(localized: "Balanced")).tag(ImageQuality.balanced)
                    Text(String(localized: "Small")).tag(ImageQuality.small)
                }
                .frame(maxWidth: 180)
            }

            Spacer()

            Toggle(String(localized: "Show All Images"), isOn: $showAllImages)
                .toggleStyle(.checkbox)
        }
    }

    private var imageRowTwo: some View {
        HStack(spacing: Spacing.elementNormal) {
            Picker(String(localized: "Max Dimension"), selection: $model.settings.photoMaxDimension) {
                ForEach(CleanupSettings.photoMaxDimensionChoices, id: \.self) { dim in
                    Text(dim.map { String(localized: "\($0) px") } ?? String(localized: "Original"))
                        .tag(dim)
                }
            }
            .frame(maxWidth: 210)

            Toggle(String(localized: "Convert to HEIC"), isOn: $model.settings.photoConvertToHEIC)
                .toggleStyle(.checkbox)

            Spacer()

            Button {
                Task { await model.measureCompressionSizes(for: summaryTargets) }
            } label: {
                if model.isMeasuringSizes {
                    Label(String(localized: "Measuring…"), systemImage: "gauge.with.dots.needle.33percent")
                } else {
                    Label(String(localized: "Check Result Sizes"), systemImage: "gauge.with.dots.needle.67percent")
                }
            }
            .disabled(model.isMeasuringSizes || model.isBusy || summaryTargets.isEmpty)
        }
    }

    private var videoRow: some View {
        HStack(spacing: Spacing.elementNormal) {
            Picker(String(localized: "Video Resolution"), selection: $model.settings.videoHeight) {
                Text("1080p").tag(1080)
                Text("720p").tag(720)
                Text("480p").tag(480)
            }
            .frame(maxWidth: 210)

            Toggle(String(localized: "Use HEVC (H.265)"), isOn: $model.settings.videoUseHEVC)
                .toggleStyle(.checkbox)

            Spacer()
        }
    }

    private var originalsAndSavingsBar: some View {
        let savings = max(Int64(0), originalTotalBytes - estimatedOutputBytes)
        return HStack(spacing: Spacing.elementNormal) {
            Picker(String(localized: "Originals"), selection: $model.settings.deleteOriginalsAfterCompression) {
                Text(String(localized: "Keep Both")).tag(false)
                Text(String(localized: "Replace & Trash Original")).tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)

            Spacer()

            if model.settings.deleteOriginalsAfterCompression {
                Label(
                    String(localized: "Delete & reclaim ~\(savings.formattedByteCount)"),
                    systemImage: "arrow.down.circle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(SemanticScale.success)
                .monospacedDigit()
            } else {
                Label(
                    String(localized: "Save original (new copy ~\(estimatedOutputBytes.formattedByteCount))"),
                    systemImage: "doc.on.doc"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    static func formatMegabytes(_ value: Double) -> String {
        if value.rounded() == value {
            return String(localized: "\(Int(value)) MB")
        }
        return String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) MB")
    }
}

/// Summary banner and mode toggle for the Live Photos conversion tool.
struct LivePhotosHeaderView: View {
    let items: [ReviewItem]
    @Bindable var model: CleanupModel
    @Binding var deleteOriginals: Bool

    private var totalVideoBytes: Int64 {
        items.reduce(0) { $0 + model.livePhotoRecoverableBytes(for: $1) }
    }

    private var totalStillBytes: Int64 {
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        return max(0, total - totalVideoBytes)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                HStack {
                    Label(String(localized: "Live Photos → Still Images"), systemImage: "livephoto")
                        .font(.headline)
                    Spacer()
                    Text(
                        String(
                            localized: """
                                \(items.count) items · \(totalVideoBytes.formattedByteCount) motion video \
                                · \(totalStillBytes.formattedByteCount) stills
                                """
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Text(
                    String(
                        localized: """
                            Converting keeps the full-resolution still photo (with date, location, and albums) \
                            and reclaims the paired motion video.
                            """
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Picker(String(localized: "Originals"), selection: $deleteOriginals) {
                    Text(String(localized: "Replace & Trash Live Photo")).tag(true)
                    Text(String(localized: "Keep Both")).tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
            .padding(4)
        }
    }
}

/// Confirmation sheet for Image & Video compression batches.
struct CompressionConfirmationSheet: View {
    let batch: CleanupBatch
    @Bindable var model: CleanupModel
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalBefore: Int64 { batch.items.reduce(0) { $0 + $1.bytes } }
    private var totalAfter: Int64 {
        batch.items.reduce(0) { sum, item in
            sum + (model.measuredBytes(for: item) ?? MediaCompressionService.estimate(item, settings: batch.settings))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            Text(String(localized: "Confirm compression")).font(.title2.weight(.semibold))
            Text(
                batch.settings.deleteOriginalsAfterCompression
                    ? String(
                        localized: """
                            Replacing originals reclaims about \
                            \(max(Int64(0), totalBefore - totalAfter).formattedByteCount).
                            """
                    )
                    : String(localized: "Saving smaller compressed copies while keeping every original.")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            List(batch.items) { item in
                row(for: item)
            }

            Text(
                String(
                    localized: """
                        Estimates can differ from the result. Compression can reduce quality. \
                        Each original is removed only after its smaller replacement verifies. \
                        Photos replacements can lose edit history or compound-media data; \
                        deletion can sync to iCloud. Originals remain recoverable in Trash \
                        or Recently Deleted.
                        """
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(String(localized: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(
                    batch.settings.deleteOriginalsAfterCompression
                        ? String(localized: "Compress and Replace")
                        : String(localized: "Compress and Keep Originals"),
                    action: onConfirm
                )
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.cardPadding)
        .frame(minWidth: 640, minHeight: 460)
        .presentationSizing(.form)
    }

    private func row(for item: ReviewItem) -> some View {
        let measured = model.measuredBytes(for: item)
        let target = (measured ?? MediaCompressionService.estimate(item, settings: batch.settings)).formattedByteCount
        let underTarget = MediaCompressionService.isAlreadyUnderTarget(item, settings: batch.settings)
        return HStack(spacing: Spacing.elementNormal) {
            ReviewPreview(item: item, model: model, thumbnail: true).frame(width: 64, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(ReviewItemLabeling.compactContext(for: item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if underTarget {
                Text(String(localized: "Already Under Target"))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SemanticScale.warningSoft, in: Capsule())
                    .foregroundStyle(SemanticScale.warning)
            }
            let prefix = measured != nil ? String(localized: "Measured") : String(localized: "Est.")
            Text("\(item.bytes.formattedByteCount) → \(prefix) \(target)")
                .font(.callout)
                .monospacedDigit()
        }
    }
}
