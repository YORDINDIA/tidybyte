import MacOSCleanerCore
import SwiftUI

extension CleanupToolView {
    @ViewBuilder var contentArea: some View {
        if model.isBusy && model.result == nil {
            ProgressView(String(localized: "Scanning…", comment: "Media scan in progress"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 60)
        } else if model.result?.isFresh != true {
            ContentUnavailableView(
                String(localized: "Not scanned"), systemImage: "arrow.clockwise",
                description: Text(String(localized: "Run a scan to refresh this tool.")))
        } else if items.isEmpty {
            emptyToolState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.elementSection) {
                    ForEach(groups) { group in
                        let members = items.filter { group.memberIDs.contains($0.id) }
                        GroupComparisonView(
                            group: group, members: members, model: model,
                            onTrashOthers: { targetGroup in
                                let safe = MediaAnalysisService.autoCleanSelection(
                                    for: [targetGroup], items: members
                                )
                                model.selection = safe
                                model.explicitlySelectedIDs.subtract(safe)
                                present(model.makeBatch(items: selected, tool: tool))
                            },
                            onToggleSelection: { toggle($0) },
                            onSelectResource: { item, idx in
                                resourceChoice = ResourceChoice(item: item, index: idx)
                            }
                        )
                    }
                    if !ungroupedItems.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170), spacing: Spacing.elementNormal)],
                            spacing: Spacing.elementNormal
                        ) {
                            ForEach(ungroupedItems) { item in
                                ToolGridItemCard(
                                    item: item, tool: tool, isSelected: model.selection.contains(item.id),
                                    model: model, onToggle: { toggle(item) },
                                    onQuickLook: { model.selectedItem = item },
                                    onSelectResource: { idx in resourceChoice = ResourceChoice(item: item, index: idx) }
                                )
                            }
                        }
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onCommand(#selector(NSResponder.selectAll(_:))) { toggleSelectAll() }
            .onDeleteCommand { requestTrash() }
            .skeletonLoading(model.isBusy && model.result != nil)
        }
    }

    @ViewBuilder var emptyToolState: some View {
        if tool == .imageCompression && !showAllCompressionImages && !model.items(for: .imageCompression).isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Large Non-HEIC Photos"), systemImage: "photo")
            } description: {
                Text(String(localized: "All remaining images are already under 2 MB or in HEIC format."))
            } actions: {
                Button(String(localized: "Show All Images")) { showAllCompressionImages = true }
            }
        } else {
            ContentUnavailableView(
                String(localized: "No matching items"), systemImage: "checkmark.circle",
                description: Text(String(localized: "No files in this scope match the current filters.")))
        }
    }

    var quickFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.elementTight) {
                ForEach(QuickFilter.allCases) { option in
                    Button {
                        quickFilter = option
                        if option != .screenshotsByApp { selectedAppFilter = nil }
                    } label: {
                        Text(option.title)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                quickFilter == option ? Color.accentColor : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundStyle(quickFilter == option ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
                if (quickFilter == .screenshotsByApp || tool == .screenshots || tool == .downloads)
                    && !availableApps.isEmpty {
                    Divider().frame(height: 16)
                    Menu {
                        Button(String(localized: "All Apps")) { selectedAppFilter = nil }
                        ForEach(availableApps, id: \.self) { app in
                            Button(app) { selectedAppFilter = app }
                        }
                    } label: {
                        Label(
                            selectedAppFilter ?? String(localized: "Filter by App"),
                            systemImage: "app.badge"
                        )
                        .font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder var controls: some View {
        Group {
            if !selectableIDs.isEmpty {
                Button(allSelectableSelected ? String(localized: "Deselect All") : String(localized: "Select All")) {
                    toggleSelectAll()
                }
                .disabled(model.isBusy)
            }
            if tool != .imageCompression {
                Picker(String(localized: "Sort"), selection: $sort) {
                    Text(String(localized: "Newest")).tag(0)
                    Text(String(localized: "Oldest")).tag(1)
                    Text(String(localized: "Largest")).tag(2)
                }
            }
            if tool == .large {
                Picker(String(localized: "Kind"), selection: $kind) {
                    Text(String(localized: "All")).tag(Optional<MediaKind>.none)
                    ForEach([MediaKind.image, .video, .document], id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                Picker(String(localized: "Minimum Size"), selection: $model.settings.largeMegabytes) {
                    let sizes = Set([5.0, 10, 25, 50, 100, 250, 500, model.settings.largeMegabytes]).sorted()
                    ForEach(sizes, id: \.self) { megabytes in
                        Text(String(localized: "\(Int(megabytes)) MB or larger")).tag(megabytes)
                    }
                }
            }
            if tool == .categories {
                Picker(String(localized: "Category"), selection: $category) {
                    Text(String(localized: "All")).tag(Optional<SmartCategory>.none)
                    ForEach(SmartCategory.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
            }
            if tool == .blurry {
                Picker(String(localized: "Quality issue"), selection: $blurryIssue) {
                    Text(String(localized: "All")).tag(Optional<String>.none)
                    Text(String(localized: "Out of focus")).tag(Optional(String(localized: "Out of focus")))
                    Text(String(localized: "Too dark")).tag(Optional(String(localized: "Too dark")))
                    Text(String(localized: "Overexposed")).tag(Optional(String(localized: "Overexposed")))
                    Text(String(localized: "Lens smudge")).tag(Optional(String(localized: "Lens smudge")))
                }
            }
        }
        .onChange(of: model.settings.largeMegabytes) {
            model.result?.settings.largeMegabytes = model.settings.largeMegabytes
            Task { await model.saveSettings() }
        }
    }

    func matchesFilters(_ item: ReviewItem) -> Bool {
        let baseMatch =
            (kind == nil || item.kind == kind || (kind == .document && item.kind == .pdf))
            && (category == nil || item.facts.category == category)
            && (tool != .blurry || blurryIssue == nil
                || MediaAnalysisService.qualityIssues(item, sensitivity: model.settings.blurSensitivity)
                    .contains(blurryIssue ?? ""))
            && (selectedAppFilter == nil || item.facts.savedFromApp == selectedAppFilter)
        guard baseMatch else { return false }
        switch quickFilter {
        case .all:
            return true
        case .safePicks:
            let keepers = Set((model.result?.groups ?? []).map(\.bestID))
            return !item.isFavorite && !item.isBurstPick && !keepers.contains(item.id)
                && CleanupModel.isEligible(item, for: tool)
        case .blurryOrSmudged:
            return item.facts.hasLensSmudge
                || !MediaAnalysisService.qualityIssues(item, sensitivity: model.settings.blurSensitivity).isEmpty
        case .screenshotsByApp:
            return item.facts.isScreenshot || item.facts.savedFromApp != nil
        }
    }

    func toggle(_ item: ReviewItem) {
        guard CleanupModel.isEligible(item, for: tool), !model.isBusy else { return }
        if model.selection.contains(item.id) {
            model.selection.remove(item.id)
            model.explicitlySelectedIDs.remove(item.id)
        } else {
            model.selection.insert(item.id)
            model.explicitlySelectedIDs.insert(item.id)
        }
    }

    func toggleSelectAll() {
        guard !model.isBusy, !selectableIDs.isEmpty else { return }
        if allSelectableSelected {
            model.selection.subtract(selectableIDs)
            model.explicitlySelectedIDs.subtract(selectableIDs)
        } else {
            model.selection.formUnion(selectableIDs)
        }
    }

    func requestTrash() {
        guard !tool.isCompression, tool != .livePhotos, !model.isBusy else { return }
        model.selection = MediaAnalysisService.safeSelection(
            model.selection,
            groups: model.result?.groups ?? [],
            items: model.result?.items ?? [],
            explicitlyChosen: model.explicitlySelectedIDs
        )
        guard !selected.isEmpty else { return }
        present(model.makeBatch(items: selected, tool: tool))
    }

    func present(_ batch: CleanupBatch?) {
        guard let batch else {
            model.error = String(
                localized: "This selection cannot be changed. Scan again if the results are out of date.")
            return
        }
        if batch.tool.isCompression {
            let check = CleanupModel.checkCompressionDiskHeadroom(for: batch.items)
            guard check.isSufficient else {
                headroomAlert = check
                return
            }
        }
        confirmation = batch
    }

    var downloadsNotice: some View {
        VStack(alignment: .leading, spacing: Spacing.elementTight) {
            Button(String(localized: "Choose exported chat folder…")) { showsChatFolder = true }
                .disabled(model.isBusy)
            Text(
                String(
                    localized: """
                        Removing these files removes the local exported or downloaded copy \
                        only. It does not remove the copy inside a chat app.
                        """
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    var compressionJobsStrip: some View {
        ScrollView {
            LazyVStack {
                ForEach(model.jobs) { job in
                    HStack {
                        Text(job.item.name).lineLimit(1)
                        ProgressView(value: min(max(job.progress, 0), 1)).frame(maxWidth: 180)
                        Text(
                            job.event?.error ?? job.event?.state.title
                                ?? (model.isBusy ? String(localized: "Queued") : String(localized: "Unprocessed"))
                        )
                        .font(.caption).lineLimit(2)
                    }
                }
            }
        }.frame(maxHeight: 140)
    }

    var actions: some View {
        let selectedBytes = selected.reduce(0) { $0 + $1.bytes }.formattedByteCount
        return GlassEffectContainer {
            HStack(spacing: Spacing.elementNormal) {
                Button(String(localized: "Review with Swipe", comment: "Start a swipe review session (PRD 4.2.1)")) {
                    Task {
                        await model.startSession(items: items, tool: tool)
                        if model.session != nil { model.selectedTool = .swipe }
                    }
                }
                .buttonStyle(.glass)
                .disabled(model.session != nil)

                if !groups.isEmpty {
                    Button(
                        String(
                            localized: "Auto-Clean All…",
                            comment: "Select every non-best copy for the trash confirm (PRD 4.1.1)")
                    ) {
                        let auto = MediaAnalysisService.autoCleanSelection(
                            for: groups,
                            items: model.result?.items ?? []
                        )
                        model.selection = auto
                        model.explicitlySelectedIDs.subtract(auto)
                        requestTrash()
                    }
                    .buttonStyle(.glass)
                }

                primaryActionButton(selectedBytes: selectedBytes)
            }
            .padding(Spacing.elementTight)
            .glassEffect(in: .capsule)
        }
        .padding(.bottom, Spacing.elementNormal)
        .disabled(model.isBusy || model.result?.isFresh != true)
    }

    @ViewBuilder private func primaryActionButton(selectedBytes: String) -> some View {
        if tool.isCompression {
            let title = selected.count == 1
                ? String(localized: "Compress 1 Item…")
                : String(localized: "Compress \(selected.count) Items…")
            Button(title) {
                present(model.makeBatch(items: selected, tool: tool))
            }
            .buttonStyle(.glassProminent)
            .disabled(selected.isEmpty)
        } else if tool == .livePhotos {
            let localAll = items.filter { $0.canEditLocally && $0.photoID != nil }
            let localSelected = selected.filter { $0.canEditLocally && $0.photoID != nil }
            let targetSet = localSelected.isEmpty ? localAll : localSelected
            let reclaimable = targetSet.reduce(Int64(0)) { $0 + model.livePhotoRecoverableBytes(for: $1) }
                .formattedByteCount
            let title = localSelected.isEmpty
                ? String(localized: "Convert All (\(targetSet.count)) · \(reclaimable)…")
                : String(localized: "Convert Selected (\(targetSet.count)) · \(reclaimable)…")
            Button(title) {
                livePhotoConfirmItems = targetSet
            }
            .buttonStyle(.glassProminent)
            .disabled(targetSet.isEmpty)
        } else {
            Button(String(localized: "Move \(selected.count) to Trash · \(selectedBytes)…"), role: .destructive) {
                requestTrash()
            }
            .buttonStyle(.glassProminent)
            .disabled(selected.isEmpty)
        }
    }

    func previewSheet(_ item: ReviewItem) -> some View {
        VStack {
            Text(item.name).font(.headline)
            ReviewPreview(item: item, model: model)
            Button(String(localized: "Done")) { model.selectedItem = nil }.keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.cardPadding)
        .frame(minWidth: 640, minHeight: 520)
        .presentationSizing(.page)
    }

    @ViewBuilder func confirmationSheet(_ batch: CleanupBatch) -> some View {
        if batch.tool.isCompression {
            CompressionConfirmationSheet(
                batch: batch,
                model: model,
                onCancel: { confirmation = nil },
                onConfirm: {
                    confirmation = nil
                    model.compressSelection(batch)
                }
            )
        } else {
            VStack {
                ReviewBatchSummary(
                    decisions: batch.items.map { ReviewDecision(item: $0, choice: .trash) },
                    model: model,
                    retained: batch.retained
                )
                HStack {
                    Button(String(localized: "Cancel")) { confirmation = nil }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(String(localized: "Move to Trash"), role: .destructive) {
                        confirmation = nil
                        model.trashSelection(batch)
                    }
                }
            }
            .padding(Spacing.cardPadding)
            .frame(minWidth: 600, minHeight: 480)
            .presentationSizing(.form)
        }
    }

    func resourceSheet(_ choice: ResourceChoice) -> some View {
        VStack(spacing: Spacing.elementNormal) {
            ReviewPreview(item: choice.item, model: model).frame(height: 280)
            Text(String(localized: "Keep \(choice.item.resources[choice.index].name)?")).font(.headline)
            Text(
                String(
                    localized: """
                        A verified replacement asset will be created. The original goes to \
                        Recently Deleted and this can sync to iCloud. RAW editing data, motion, \
                        and previous edit history that are not in the selected component will \
                        be lost from the replacement.
                        """
                ))
            let reduction = (choice.item.bytes - choice.item.resources[choice.index].bytes).formattedByteCount
            Text(String(localized: "Estimated reduction: \(reduction)")).monospacedDigit()
            HStack {
                Button(String(localized: "Cancel")) { resourceChoice = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Keep this component"), role: .destructive) {
                    resourceChoice = nil
                    model.keepResource(choice.item, index: choice.index)
                }
            }
        }
        .padding(Spacing.cardPadding)
        .frame(minWidth: 560)
        .presentationSizing(.form)
    }
}
