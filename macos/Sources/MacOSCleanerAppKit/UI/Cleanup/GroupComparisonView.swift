import MacOSCleanerCore
import SwiftUI

/// Rich group comparison card for Duplicate, Similar, Burst, and Format Pair groups.
struct GroupComparisonView: View {
    let group: AnalysisGroup
    let members: [ReviewItem]
    @Bindable var model: CleanupModel
    let onTrashOthers: (AnalysisGroup) -> Void
    let onToggleSelection: (ReviewItem) -> Void
    var onSelectResource: ((ReviewItem, Int) -> Void)?

    @State private var showsCompareSheet = false

    private var nonBestReclaimableBytes: Int64 {
        let safeIDs = MediaAnalysisService.autoCleanSelection(for: [group], items: members)
        return members.filter { safeIDs.contains($0.id) && $0.canDelete }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                header
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: Spacing.elementNormal) {
                        ForEach(members) { item in
                            memberCard(item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(4)
        }
        .sheet(isPresented: $showsCompareSheet) {
            GroupSideBySideSheet(
                group: group,
                members: members,
                model: model,
                onPromoteBest: promoteBest
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.elementNormal) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.elementTight) {
                    Text(group.explanation).font(.headline)
                    Text(String(localized: "\(members.count) items"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let reason = group.bestReason {
                    Label(String(localized: "Best Shot: \(reason)"), systemImage: "star.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SemanticScale.success)
                }
            }
            Spacer()
            if members.count >= 2 {
                Button(String(localized: "Compare Side-by-Side…"), systemImage: "rectangle.split.2x1") {
                    showsCompareSheet = true
                }
                .controlSize(.small)
            }
            Button(
                String(localized: "Move Others to Trash (\(nonBestReclaimableBytes.formattedByteCount))…"),
                role: .destructive
            ) {
                onTrashOthers(group)
            }
            .controlSize(.small)
            .disabled(model.isBusy || nonBestReclaimableBytes == 0)
        }
    }

    private func memberCard(_ item: ReviewItem) -> some View {
        let isBest = group.bestID == item.id
        let isSelected = model.selection.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            ReviewPreview(item: item, model: model, thumbnail: true)
                .frame(width: 170, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.cardCompact, style: .continuous)
                        .strokeBorder(
                            isBest ? SemanticScale.success : (isSelected ? Color.accentColor : .clear),
                            lineWidth: isBest || isSelected ? 3 : 0
                        )
                }
                .overlay(alignment: .topLeading) {
                    if isBest {
                        Label(String(localized: "Best"), systemImage: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .foregroundStyle(.white)
                            .background(SemanticScale.success, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .font(.title3)
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.selectedItem = item }
                .onTapGesture {
                    if !isBest { onToggleSelection(item) }
                }

            Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text(ReviewItemLabeling.compactContext(for: item))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            metricsRow(for: item)
            MediaIntelligencePills(item: item, bestReason: group.bestReason, isBest: isBest)
            memberActions(for: item, isBest: isBest)
        }
        .frame(width: 176, alignment: .leading)
    }

    private func metricsRow(for item: ReviewItem) -> some View {
        HStack(spacing: 6) {
            Text(item.bytes.formattedByteCount)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let width = item.facts.width, let height = item.facts.height, width > 0, height > 0 {
                Text("\(width)×\(height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder private func memberActions(for item: ReviewItem, isBest: Bool) -> some View {
        HStack(spacing: 6) {
            Button(isBest ? String(localized: "Best Shot") : String(localized: "Keep as Best")) {
                promoteBest(item)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(isBest || model.isBusy)

            if !item.isDownloaded && item.photoID != nil {
                Button(String(localized: "Download")) {
                    Task { await model.downloadFromICloud(item) }
                }
                .controlSize(.mini)
                .disabled(model.downloadingItemIDs[item.id] != nil)
            }
            if group.tool == .formatPairs, MediaAnalysisService.isCompoundPhoto(item),
                let onSelectResource {
                Menu(String(localized: "Keep…")) {
                    ForEach(Array(item.resources.enumerated()), id: \.offset) { index, resource in
                        if [1, 2, 4, 9].contains(resource.type) {
                            Button(resource.name) { onSelectResource(item, index) }
                        }
                    }
                }
                .controlSize(.mini)
                .disabled(!item.canEditLocally || model.isBusy)
            }
        }
    }

    private func promoteBest(_ item: ReviewItem) {
        guard let index = model.result?.groups.firstIndex(where: { $0.id == group.id }) else { return }
        model.result?.groups[index].bestID = item.id
        model.result?.groups[index].bestReason = String(localized: "Selected by you")
        model.selection.remove(item.id)
        model.explicitlySelectedIDs.remove(item.id)
    }
}

/// Synchronized zoomable side-by-side compare modal for inspecting group members.
private struct GroupSideBySideSheet: View {
    let group: AnalysisGroup
    let members: [ReviewItem]
    @Bindable var model: CleanupModel
    let onPromoteBest: (ReviewItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var leftID: String
    @State private var rightID: String
    @State private var syncZoom = 1.0

    init(
        group: AnalysisGroup,
        members: [ReviewItem],
        model: CleanupModel,
        onPromoteBest: @escaping (ReviewItem) -> Void
    ) {
        self.group = group
        self.members = members
        self.model = model
        self.onPromoteBest = onPromoteBest
        let best = members.first { $0.id == group.bestID } ?? members.first
        let other = members.first { $0.id != best?.id } ?? members.last
        _leftID = State(initialValue: best?.id ?? "")
        _rightID = State(initialValue: other?.id ?? "")
    }

    private var leftItem: ReviewItem? { members.first { $0.id == leftID } ?? members.first }
    private var rightItem: ReviewItem? { members.first { $0.id == rightID } ?? members.last }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Side-by-Side Comparison")).font(.title2.weight(.semibold))
                    Text(group.bestReason.map { String(localized: "Why Best Shot won: \($0)") } ?? group.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: Spacing.elementTight) {
                    Text(String(localized: "Zoom")).font(.caption).foregroundStyle(.secondary)
                    Slider(value: $syncZoom, in: 1...4)
                        .frame(width: 140)
                    Text("\(Int((syncZoom * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: Spacing.elementNormal) {
                if let leftItem { comparePane(item: leftItem, selection: $leftID) }
                if let rightItem { comparePane(item: rightItem, selection: $rightID) }
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.cardPadding)
        .frame(minWidth: 780, minHeight: 560)
        .presentationSizing(.page)
    }

    private func comparePane(item: ReviewItem, selection: Binding<String>) -> some View {
        let isBest = model.result?.groups.first { $0.id == group.id }?.bestID == item.id
        return VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Picker(String(localized: "Item"), selection: selection) {
                ForEach(members) { candidate in
                    Text(candidate.name).tag(candidate.id)
                }
            }
            .labelsHidden()

            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ReviewPreview(item: item, model: model, thumbnail: true)
                        .frame(
                            width: max(proxy.size.width, 280) * syncZoom,
                            height: max(proxy.size.height, 260) * syncZoom
                        )
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.cardCompact))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.bytes.formattedByteCount).font(.callout.weight(.semibold)).monospacedDigit()
                if let width = item.facts.width, let height = item.facts.height {
                    Text(String(localized: "Resolution: \(width) × \(height)")).font(.caption).monospacedDigit()
                }
                if let sharp = item.facts.sharpness {
                    Text(String(localized: "Sharpness: \(sharp.formatted(.number.precision(.fractionLength(2))))"))
                        .font(.caption).monospacedDigit()
                }
                if let aesthetics = item.facts.aestheticsScore {
                    Text(String(localized: "Aesthetics: \(aesthetics.formatted(.number.precision(.fractionLength(2))))"))
                        .font(.caption).monospacedDigit()
                }
                MediaIntelligencePills(item: item, bestReason: group.bestReason, isBest: isBest)
            }
            Button(isBest ? String(localized: "Current Best Shot") : String(localized: "Use as Best Shot")) {
                onPromoteBest(item)
            }
            .disabled(isBest || model.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared disambiguation label helper so identically named items stay distinguishable.
enum ReviewItemLabeling {
    static func compactContext(for item: ReviewItem) -> String {
        var parts: [String] = []
        if let date = item.facts.capturedAt ?? item.createdAt ?? item.modifiedAt {
            parts.append(String(Calendar.current.component(.year, from: date)))
        }
        if let url = item.url {
            let folder = url.deletingLastPathComponent().lastPathComponent
            if !folder.isEmpty { parts.append(folder) }
        } else if item.photoID != nil {
            parts.append(String(localized: "Photos"))
        }
        return parts.joined(separator: " · ")
    }
}
