import MacOSCleanerCore
import SwiftUI

enum QuickFilter: String, CaseIterable, Identifiable {
    case all, safePicks, blurryOrSmudged, screenshotsByApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .safePicks: String(localized: "Safe Picks")
        case .blurryOrSmudged: String(localized: "Blurry / Smudged")
        case .screenshotsByApp: String(localized: "Screenshots by App")
        }
    }
}

struct ToolGridItemCard: View {
    let item: ReviewItem
    let tool: CleanupTool
    let isSelected: Bool
    @Bindable var model: CleanupModel
    let onToggle: () -> Void
    let onQuickLook: () -> Void
    let onSelectResource: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Text(ReviewItemLabeling.compactContext(for: item))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            sizeAndDetails
            MediaIntelligencePills(item: item)
            statusAndActions
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onQuickLook() }
        .onTapGesture { onToggle() }
        .contextMenu {
            Button(String(localized: "Quick Look")) { onQuickLook() }
            Button(isSelected ? String(localized: "Deselect") : String(localized: "Select")) { onToggle() }
                .disabled(!CleanupModel.isEligible(item, for: tool))
            if !item.isDownloaded && item.photoID != nil {
                Button(String(localized: "Download from iCloud")) {
                    Task { await model.downloadFromICloud(item) }
                }
            }
            if let url = item.url {
                Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.name), \(item.bytes.formattedByteCount)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onToggle() }
        .accessibilityAction(named: Text(String(localized: "Quick Look"))) { onQuickLook() }
    }

    private var thumbnail: some View {
        ReviewPreview(item: item, model: model, thumbnail: true)
            .frame(height: 120).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .font(.title2)
                        .padding(6)
                }
            }
    }

    @ViewBuilder private var sizeAndDetails: some View {
        HStack(spacing: 6) {
            Text(item.bytes.formattedByteCount).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let seconds = item.facts.duration, seconds.isFinite {
                Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        if tool == .livePhotos {
            let videoBytes = model.livePhotoRecoverableBytes(for: item)
            let stillBytes = max(Int64(0), item.bytes - videoBytes)
            Text(String(localized: "Video: \(videoBytes.formattedByteCount) · Still: \(stillBytes.formattedByteCount)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        if tool == .imageCompression {
            compressionBadge
        }
        if tool == .blurry, let score = item.facts.sharpness {
            Text(String(localized: "Sharpness \(score.formatted(.number.precision(.fractionLength(3))))"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private var compressionBadge: some View {
        if MediaCompressionService.isAlreadyUnderTarget(item, settings: model.settings) {
            Text(String(localized: "Already Under Target"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(SemanticScale.warning)
        } else if let measured = model.measuredBytes(for: item) {
            Text(String(localized: "Measured → \(measured.formattedByteCount)"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(SemanticScale.success)
                .monospacedDigit()
        } else {
            let est = MediaCompressionService.estimate(item, settings: model.settings)
            Text(String(localized: "Est. → \(est.formattedByteCount)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder private var statusAndActions: some View {
        if !item.isDownloaded {
            if let progress = model.downloadingItemIDs[item.id] {
                ProgressView(value: min(max(progress, 0), 1))
            } else if item.photoID != nil {
                Button(String(localized: "Download from iCloud")) {
                    Task { await model.downloadFromICloud(item) }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Text(String(localized: "Not downloaded")).font(.caption).foregroundStyle(.secondary)
            }
        }
        if item.isCloudSynced {
            Text(String(localized: "Cloud-synced file. Read only")).font(.caption).foregroundStyle(.secondary)
        }
        if tool == .formatPairs, MediaAnalysisService.isCompoundPhoto(item) {
            Menu(String(localized: "Keep one component…")) {
                ForEach(Array(item.resources.enumerated()), id: \.offset) { index, resource in
                    if [1, 2, 4, 9].contains(resource.type) {
                        Button(resource.name) { onSelectResource(index) }
                    }
                }
            }.disabled(!item.canEditLocally || model.isBusy)
        }
    }
}
