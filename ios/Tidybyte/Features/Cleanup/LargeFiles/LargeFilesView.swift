import SwiftUI

struct LargeFilesView: View {
    @State private var viewModel = LargeFilesViewModel()
    @State private var showDeleteConfirm = false
    @State private var previewStart: AssetSummary?
    @State private var rowToDelete: AssetSummary?
    @State private var isCelebrating = false
    @State private var celebrationStatLine: String?
    @State private var toast: ToastMessage?
    /// Mirrors SettingsView's control so the threshold never diverges between
    /// screens while the tool is open (LF-06).
    @AppStorage(AppPreferences.Key.largeFileThresholdMB) private var thresholdMB: Double = AppPreferences.Default.largeFileThresholdMB
    private let photoService = PhotoLibraryService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if viewModel.isLoading {
                ToolLoadingView { ToolSkeletonList(rows: 8) }
            } else {
                VStack(spacing: 0) {
                    // Controls
                    VStack(spacing: Spacing.sm) {
                        LimitedLibraryBanner()

                        HStack {
                            // Binary display, consistent with each row's
                            // `formattedFileSize` (LF-05).
                            Text(LargeFilesViewModel.minSizeLabel(thresholdMB: thresholdMB))
                                .font(.caption)
                            Spacer()
                            Text("\(viewModel.filteredAssets.count) files \u{00B7} \(viewModel.totalSize.formattedFileSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $thresholdMB, in: 5...500, step: 5)

                        let controlsLayout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
                            : AnyLayout(HStackLayout(spacing: Spacing.sm))
                        controlsLayout {
                            Picker("Filter", selection: $viewModel.mediaFilter) {
                                ForEach(MediaFilter.allCases, id: \.self) { filter in
                                    // Keys, not rendered `String`s, so both control
                                    // labels follow a language switch. See `RootView`.
                                    Text(LocalizedStringKey(filter.displayName)).tag(filter)
                                }
                            }
                            .pickerStyle(.segmented)

                            Picker("Sort", selection: $viewModel.sortOrder) {
                                ForEach(MediaSortOrder.options(includingVideos: viewModel.mediaFilter != .photos), id: \.self) { order in
                                    Text(LocalizedStringKey(order.displayName)).tag(order)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .padding(Spacing.lg)
                    .readableWidth()

                    if viewModel.filteredAssets.isEmpty {
                        emptyResultsView
                    } else {
                        List {
                            ForEach(viewModel.filteredAssets) { asset in
                                LargeFileRow(
                                    asset: asset,
                                    isSelected: viewModel.selectedIds.contains(asset.id),
                                    photoService: photoService,
                                    onToggle: { viewModel.toggleSelection(asset.id) },
                                    onPreview: { previewStart = asset }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        rowToDelete = asset
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            if viewModel.zeroSizeCount > 0 {
                                Text("\(viewModel.zeroSizeCount) items with unknown size are not listed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .pullToRefresh { await viewModel.refresh() }
                    }

                    if viewModel.selectedVisibleCount > 0 || viewModel.isPreparingShare {
                        CleanupActionBar {
                            if viewModel.isPreparingShare {
                                ProgressView()
                                    .padding(.trailing, Spacing.sm)
                                Text("Preparing \(viewModel.shareProgress.completed)/\(viewModel.shareProgress.total)\u{2026}")
                                    .font(.caption)
                                AdaptiveSpacer()
                                Button("Cancel") { viewModel.cancelShare() }
                            } else {
                                // Picks hidden by the media filter or sort order
                                // are kept, but only the visible ones are shared
                                // or deleted. A pick that falls below the size
                                // slider is cleared on the next refresh, which
                                // raises a toast instead of dropping it quietly.
                                let hidden = viewModel.selectedIds.count - viewModel.selectedVisibleCount
                                Text(hidden > 0
                                     ? "\(viewModel.selectedVisibleCount) selected \u{00B7} \(viewModel.selectedSize.formattedFileSize) (\(hidden) hidden by filter)"
                                     : "\(viewModel.selectedVisibleCount) selected \u{00B7} \(viewModel.selectedSize.formattedFileSize)")
                                    .font(.caption)
                                AdaptiveSpacer()
                                Button { viewModel.startShare() } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.headline)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityLabel("Share selected")
                                .disabled(viewModel.selectedVisibleCount == 0)
                                Button(role: .destructive) { showDeleteConfirm = true } label: {
                                    Label("Delete", systemImage: "trash")
                                        .font(.headline)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .disabled(viewModel.selectedVisibleCount == 0)
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.reduceMotionAware(.spring(response: 0.35, dampingFraction: 0.85), reduceMotion: reduceMotion), value: viewModel.isLoading)
        .localizedNavigationTitle("Large Files")
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
        .happyPathCelebration(isPresented: $isCelebrating, statLine: celebrationStatLine)
        .toolbar {
            if !viewModel.filteredAssets.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SelectAllToolbarButton(
                        allSelected: viewModel.areAllVisibleSelected,
                        selectAll: { viewModel.selectAll() },
                        deselectAll: { viewModel.deselectAll() }
                    )
                }
            }
        }
        .alert(CleanupDeletion.confirmTitle(count: viewModel.selectedVisibleCount), isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    // Celebrate only what PhotoKit really deleted: a no-op or
                    // ids that were already gone are not a success.
                    let count = await viewModel.deleteSelected()
                    guard count > 0, viewModel.errorMessage == nil else { return }
                    HappyPathReporter.fire(
                        isCelebrating: $isCelebrating,
                        statLine: $celebrationStatLine,
                        line: L10n.format(
                            "cleared %lld large file",
                            fallback: "cleared %lld large files",
                            count
                        )
                    )
                }
            }
        } message: {
            Text(CleanupDeletion.confirmMessage(L10n.format("%@ of media will be deleted from Photos.", viewModel.selectedSize.formattedFileSize)))
        }
        // Non-modal error surface. `safeAreaInset` pushes the list down rather
        // than floating the banner over its first row.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = viewModel.errorMessage {
                ToolErrorBanner(
                    // Runtime text, so it renders verbatim: the view model
                    // fills this with `error.localizedDescription` or with a
                    // sentence it built through `L10n`, and both are already in
                    // the user's language. Looking it up as a key would miss,
                    // and `Text` would apply Markdown to it.
                    message: .runtimeText(message),
                    title: .runtimeText(CleanupTool.largeFiles.name),
                    onDismiss: { viewModel.errorMessage = nil }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
            }
        }
        .toast($toast)
        .onChange(of: viewModel.errorMessage) { _, newValue in
            if newValue != nil { toast = nil }
        }
        // A load/refresh that had to clear picks below the size slider says so,
        // instead of the selection just disappearing.
        .onChange(of: viewModel.droppedSelectionNotice) { _, notice in
            guard let notice else { return }
            toast = ToastMessage(text: notice.text)
        }
        .alert(CleanupDeletion.confirmTitle(count: 1), isPresented: .init(
            get: { rowToDelete != nil },
            set: { if !$0 { rowToDelete = nil } }
        ), presenting: rowToDelete) { asset in
            Button("Cancel", role: .cancel) { rowToDelete = nil }
            Button("Delete", role: .destructive) {
                let id = asset.id
                rowToDelete = nil
                Task { await viewModel.deleteAsset(id: id) }
            }
        } message: { _ in
            Text(CleanupDeletion.confirmMessage(L10n.string("This item will be deleted from Photos.")))
        }
        .fullScreenCover(item: $previewStart) { start in
            MediaPreviewView(
                assets: viewModel.filteredAssets,
                startIndex: viewModel.filteredAssets.firstIndex { $0.id == start.id } ?? 0,
                photoService: photoService,
                onDelete: { await viewModel.deleteAsset(id: $0.id) }
            )
        }
        .sheet(item: $viewModel.sharePayload, onDismiss: { viewModel.cleanupShareExport() }) { payload in
            ShareSheet(urls: payload.urls)
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    @ViewBuilder
    private var emptyResultsView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: emptyIcon)
                .scaledGlyph(48, weight: .light)
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            if viewModel.zeroSizeCount > 0 {
                Text("\(viewModel.zeroSizeCount) items with unknown size are not listed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.xxxl)
                    .padding(.vertical, Spacing.md)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
            }
            .scaleOnPress()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        switch viewModel.mediaFilter {
        case .all: "externaldrive"
        case .photos: "photo"
        case .videos: "video"
        }
    }

    /// `LocalizedStringKey`, not `String`: `Text(String)` is the
    /// non-localizing overload, so a `String` return renders English in every
    /// language.
    private var emptyTitle: LocalizedStringKey {
        switch viewModel.mediaFilter {
        case .all: "No Large Files"
        case .photos: "No Large Photos"
        case .videos: "No Large Videos"
        }
    }

    private var emptyMessage: LocalizedStringKey {
        let threshold = Int(thresholdMB)
        switch viewModel.mediaFilter {
        case .all:
            return "No files larger than \(threshold) MB. Lower the threshold to see more."
        case .photos:
            return "No photos larger than \(threshold) MB. Lower the threshold or switch to All/Videos."
        case .videos:
            return "No videos larger than \(threshold) MB. Lower the threshold or switch to All/Photos."
        }
    }

}

/// One row of the Large Files list. At accessibility sizes the details and the
/// size move below the controls, so they get the full row width. Beside the
/// fixed 44 pt checkbox, 60 pt thumbnail and 44 pt trash, they wrapped one word
/// per line.
struct LargeFileRow: View {
    let asset: AssetSummary
    let isSelected: Bool
    let photoService: PhotoLibraryService
    let onToggle: () -> Void
    let onPreview: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                // Always-visible selection checkbox. Tapping it (de)selects the row;
                // tapping anywhere else on the row opens the preview.
                SelectToggle(isSelected: isSelected, itemName: "file", overPhoto: false, action: onToggle)

                AsyncThumbnailView(assetId: asset.id, photoService: photoService)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                    .overlay(alignment: .bottomLeading) {
                        if asset.isFavorite {
                            FavoriteMark().padding(Spacing.xs)
                        }
                    }

                if isAX {
                    Spacer()
                } else {
                    details
                    Spacer()
                    sizeLabel
                }
            }

            if isAX {
                details
                sizeLabel
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPreview)
    }

    @ViewBuilder
    private var details: some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let filename = asset.filename, !filename.isEmpty {
                Text(filename)
                    .font(.subheadline.bold())
                    .lineLimit(1)
            }
            HStack(spacing: Spacing.xs) {
                Image(systemName: asset.mediaType == .video ? "video" : "photo")
                    .font(.caption)
                if let date = asset.creationDate {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                        .font(.subheadline)
                        // Full-width at accessibility sizes: wrap, do not truncate.
                        .fixedSize(horizontal: false, vertical: isAX)
                }
            }

            Text(asset.resolution)
                .font(.caption)
                .foregroundStyle(.secondary)

            if asset.mediaType == .video {
                Text(asset.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sizeLabel: some View {
        Text(asset.displaySize)
            .font(.headline.monospacedDigit())
            .foregroundStyle(.primary)
    }
}
