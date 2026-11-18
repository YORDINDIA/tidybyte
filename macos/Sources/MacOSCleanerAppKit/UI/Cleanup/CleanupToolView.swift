import MacOSCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct CleanupToolView: View {
    @Bindable var model: CleanupModel
    let tool: CleanupTool
    @State var sort: Int
    @State var kind: MediaKind?
    @State var category: SmartCategory?
    @State var blurryIssue: String?
    @State var quickFilter: QuickFilter = .all
    @State var selectedAppFilter: String?
    @State var showAllCompressionImages = false
    @State var deleteOriginalsOnLiveConvert = true
    @State var showsChatFolder = false
    @State var confirmation: CleanupBatch?
    @State var livePhotoConfirmItems: [ReviewItem]?
    @State var headroomAlert: DiskHeadroomCheck?
    @State var resourceChoice: ResourceChoice?

    struct ResourceChoice: Identifiable {
        let item: ReviewItem
        let index: Int
        var id: String { item.id + "\(index)" }
    }

    init(model: CleanupModel, tool: CleanupTool) {
        self.model = model
        self.tool = tool
        _sort = State(initialValue: tool == .large ? 2 : 0)
    }

    var baseItems: [ReviewItem] {
        guard let result = model.result else { return [] }
        if tool == .imageCompression {
            return MediaAnalysisService.imageCompressionCandidates(in: result, showAll: showAllCompressionImages)
        }
        return model.items(for: tool)
    }

    var availableApps: [String] {
        Set(baseItems.compactMap { $0.facts.savedFromApp }).sorted()
    }

    var items: [ReviewItem] {
        let filtered = baseItems.filter { matchesFilters($0) }
        if tool == .imageCompression {
            return PhotoCompressionSortOrder.ordered(filtered, by: model.settings.photoCompressionSortOrder)
        }
        return filtered.sorted {
            if sort == 2, $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            let lhs = $0.facts.capturedAt ?? $0.modifiedAt ?? .distantPast
            let rhs = $1.facts.capturedAt ?? $1.modifiedAt ?? .distantPast
            if lhs != rhs { return sort == 1 ? lhs < rhs : lhs > rhs }
            return $0.id < $1.id
        }
    }

    var groups: [AnalysisGroup] {
        let visibleIDs = Set(items.map(\.id))
        return (model.result?.groups ?? []).filter { group in
            group.tool == tool && group.memberIDs.contains(where: visibleIDs.contains)
        }
    }

    var ungroupedItems: [ReviewItem] {
        guard [.duplicates, .similar, .bursts, .formatPairs].contains(tool) else { return items }
        let grouped = Set(groups.flatMap(\.memberIDs))
        return items.filter { !grouped.contains($0.id) }
    }

    var selectableIDs: Set<String> {
        let eligible = Set(items.filter { CleanupModel.isEligible($0, for: tool) }.map(\.id))
        if tool.isCompression || tool == .livePhotos { return eligible }
        return MediaAnalysisService.safeSelection(
            eligible,
            groups: model.result?.groups ?? [],
            items: model.result?.items ?? []
        )
    }

    var allSelectableSelected: Bool {
        !selectableIDs.isEmpty && selectableIDs.isSubset(of: model.selection)
    }

    var selected: [ReviewItem] {
        let safe: Set<String>
        if tool.isCompression || tool == .livePhotos {
            safe = model.selection
        } else {
            safe = MediaAnalysisService.safeSelection(
                model.selection,
                groups: model.result?.groups ?? [],
                items: model.result?.items ?? [],
                explicitlyChosen: model.explicitlySelectedIDs
            )
        }
        return items.filter { safe.contains($0.id) && CleanupModel.isEligible($0, for: tool) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            if tool == .downloads { downloadsNotice }
            if model.result?.isFresh == true {
                quickFilterBar
                if tool.isCompression {
                    CompressionControlsView(
                        model: model, tool: tool, visibleItems: items,
                        selectedItems: selected, showAllImages: $showAllCompressionImages
                    )
                } else if tool == .livePhotos && !items.isEmpty {
                    LivePhotosHeaderView(
                        items: items, model: model, deleteOriginals: $deleteOriginalsOnLiveConvert
                    )
                }
            }
            contentArea
            if !model.jobs.isEmpty { compressionJobsStrip }
        }
        .padding(Spacing.cardPadding)
        .navigationTitle(tool.title)
        .navigationSubtitle(
            items.count == 1
                ? String(localized: "1 item", comment: "Single tool item count")
                : String(localized: "\(items.count) items", comment: "Tool item count"))
        .toolbar { ToolbarItemGroup { controls } }
        .safeAreaBar(edge: .bottom) { actions }
        .onChange(of: model.result?.items.map(\.id) ?? []) { _, newIDs in
            let valid = Set(newIDs)
            model.selection.formIntersection(valid)
            model.explicitlySelectedIDs.formIntersection(valid)
        }
        .fileImporter(isPresented: $showsChatFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await model.scanChatFolder(url) } }
        }
        .sheet(item: $model.selectedItem) { previewSheet($0) }
        .sheet(item: $confirmation) { confirmationSheet($0) }
        .sheet(item: $resourceChoice) { resourceSheet($0) }
        .confirmationDialog(
            String(localized: "Convert Live Photos to Still Images?"),
            isPresented: Binding(
                get: { livePhotoConfirmItems != nil },
                set: { if !$0 { livePhotoConfirmItems = nil } }
            ),
            presenting: livePhotoConfirmItems
        ) { targets in
            Button(String(localized: "Convert \(targets.count) Live Photos")) {
                livePhotoConfirmItems = nil
                model.convertLivePhotosToStills(targets, deleteOriginals: deleteOriginalsOnLiveConvert)
            }
        } message: { targets in
            let bytes = targets.reduce(Int64(0)) { $0 + model.livePhotoRecoverableBytes(for: $1) }.formattedByteCount
            Text(
                deleteOriginalsOnLiveConvert
                    ? String(
                        localized: """
                            Creates verified still photos and moves \(targets.count) original Live Photos \
                            to Recently Deleted, reclaiming about \(bytes).
                            """)
                    : String(localized: "Saves still copies for \(targets.count) Live Photos and keeps originals.")
            )
        }
        .alert(
            String(localized: "Not Enough Free Disk Space"),
            isPresented: Binding(
                get: { headroomAlert != nil },
                set: { if !$0 { headroomAlert = nil } }
            ),
            presenting: headroomAlert
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) { headroomAlert = nil }
        } message: { check in
            let availableText = check.availableBytes?.formattedByteCount ?? String(localized: "unknown")
            Text(
                String(
                    localized: """
                        Compression requires \(check.requiredBytes.formattedByteCount) of free disk space \
                        (2× the selected batch) to write verified copies safely. Available: \(availableText). \
                        Deselect some large items or free up space first.
                        """
                )
            )
        }
    }
}
