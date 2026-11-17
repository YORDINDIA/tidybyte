import SwiftUI
import SwiftData

struct ScreenshotCleanerView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ScreenshotCleanerViewModel()
    @Environment(LibraryChangeMonitor.self) private var libraryMonitor
    @State private var showDeleteConfirm = false
    @State private var isCelebrating = false
    @State private var selectedSwipeRoute: SwipeSessionRoute?
    @State private var previewAsset: AssetSummary?
    @State private var pendingSwipeReview = false
    @State private var cellToDelete: AssetSummary?

    private let photoService = PhotoLibraryService.shared

    private let columns = ResponsiveGrid.photo()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isLoading {
                LimitedLibraryBanner()
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.sm)
            }

            if viewModel.isLoading {
                // D-01: the fetch runs inside a cancellable task, so this is the
                // one loading state that keeps a Cancel.
                ToolLoadingView(onCancel: {
                    HapticHelper.impact(.light)
                    viewModel.cancelScan()
                }) {
                    ScrollView {
                        SkeletonGrid(columns: 3, rows: 5)
                            .padding(Spacing.xs)
                    }
                }
            } else if viewModel.screenshots.isEmpty {
                EmptyStateView(
                    icon: "camera.viewfinder",
                    title: "No Screenshots",
                    message: "You don't have any screenshots in your library.",
                    // D-07: the empty state needs a refresh affordance — new
                    // screenshots (or imports) may have landed since the last
                    // fetch.
                    actionTitle: "Refresh"
                ) {
                    Task { await viewModel.refresh() }
                }
            } else {
                VStack(spacing: 0) {
                    // Header. Stacks at accessibility sizes, as the media
                    // tools do, so the count, button and sort menu do not share
                    // one row.
                    let headerLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm)) : AnyLayout(HStackLayout())
                    headerLayout {
                        Text("\(viewModel.screenshots.count) screenshots \u{00B7} \(viewModel.totalSize.formattedFileSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Button("Review with Swipe") {
                            HapticHelper.impact(.light)
                            startSwipeReview(with: .screenshots)
                        }
                        .font(.caption.bold())
                        .frame(minHeight: 44)

                        Picker("Sort", selection: $viewModel.sortOrder) {
                            ForEach(ScreenshotSortOrder.allCases, id: \.self) { order in
                                // A key, not a rendered `String`, so the menu
                                // label follows a language switch. See `RootView`.
                                Text(LocalizedStringKey(order.displayName)).tag(order)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Spacing.xs) {
                            ForEach(viewModel.sortedScreenshots) { screenshot in
                                screenshotCell(screenshot)
                            }
                        }
                    }
                    .pullToRefresh { await viewModel.refresh() }

                    // Bottom action bar
                    if !viewModel.selectedIds.isEmpty {
                        CleanupActionBar {
                            Text("\(viewModel.selectedIds.count) selected \u{00B7} \(viewModel.selectedSize.formattedFileSize)")
                                .font(.caption)
                            if viewModel.isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            AdaptiveSpacer()

                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .disabled(viewModel.isDeleting)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.reduceMotionAware(.spring(response: 0.35, dampingFraction: 0.85), reduceMotion: reduceMotion), value: viewModel.isLoading)
        .localizedNavigationTitle("Screenshots")
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
        // Items deleted elsewhere (Swipe Review, the Photos app) leave the
        // list when the library changes, instead of lingering as blanks.
        .task(id: libraryMonitor.generation) {
            await viewModel.pruneDeleted()
        }
        .happyPathCelebration(
            isPresented: $isCelebrating,
            statLine: L10n.format(
                "cleared %lld screenshot",
                fallback: "cleared %lld screenshots",
                viewModel.deletedCount
            )
        )
        .onDisappear {
            // D-01: stop an in-flight fetch when the user leaves the screen.
            viewModel.cancelScan()
        }
        .toolbar {
            // "Review with Swipe" lives in the header row only.
            if !viewModel.screenshots.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SelectAllToolbarButton(
                        allSelected: viewModel.allVisibleSelected,
                        selectAll: { viewModel.selectAll() },
                        deselectAll: { viewModel.deselectAll() }
                    )
                }
            }
        }
        .navigationDestination(item: $selectedSwipeRoute) { route in
            SwipeSessionHostView(
                route: route,
                photoService: photoService,
                modelContext: modelContext
            )
        }
        .alert(CleanupDeletion.confirmTitle(count: viewModel.selectedIds.count), isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteSelected()
                    // C12: success feedback, gated on an actual deletion.
                    if viewModel.errorMessage == nil && viewModel.deletedCount > 0 {
                        HappyPathReporter.fire(isCelebrating: $isCelebrating)
                    }
                }
            }
        } message: {
            Text(CleanupDeletion.confirmMessage(L10n.string("The selected screenshots will be deleted from Photos.")))
        }
        // Non-modal error surface. `safeAreaInset` pushes the grid down rather
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
                    title: .runtimeText(CleanupTool.screenshots.name),
                    onDismiss: { viewModel.errorMessage = nil }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
            }
        }
        .alert(CleanupDeletion.confirmTitle(count: 1), isPresented: .init(
            get: { cellToDelete != nil },
            set: { if !$0 { cellToDelete = nil } }
        ), presenting: cellToDelete) { asset in
            Button("Cancel", role: .cancel) { cellToDelete = nil }
            Button("Delete", role: .destructive) {
                let id = asset.id
                cellToDelete = nil
                Task { await viewModel.delete(assetId: id) }
            }
        } message: { _ in
            Text(CleanupDeletion.confirmMessage(L10n.string("This screenshot will be deleted from Photos.")))
        }
        .fullScreenCover(item: $previewAsset, onDismiss: {
            if pendingSwipeReview {
                pendingSwipeReview = false
                startSwipeReview(with: .screenshots)
            }
        }) { asset in
            MediaPreviewView(
                assets: viewModel.sortedScreenshots,
                startIndex: viewModel.sortedScreenshots.firstIndex { $0.id == asset.id } ?? 0,
                photoService: photoService,
                onDelete: { await viewModel.delete(assetId: $0.id) },
                accessory: AccessoryAction(title: "Review with Swipe", systemImage: "hand.draw") {
                    pendingSwipeReview = true
                }
            )
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private func startSwipeReview(with filter: SwipeFilter) {
        selectedSwipeRoute = SwipeSessionRoute(filter: filter)
    }

    private func screenshotCell(_ screenshot: AssetSummary) -> some View {
        SelectableMediaGridCell(
            asset: screenshot,
            photoService: photoService,
            isSelected: viewModel.selectedIds.contains(screenshot.id),
            itemName: "screenshot",
            previewAccessibilityLabel: "Preview screenshot, \(screenshot.displaySize)",
            bottomBadgeText: screenshot.displaySize,
            onPreview: { previewAsset = screenshot },
            onToggleSelection: { viewModel.toggleSelection(screenshot.id) }
        ) {
            Button {
                previewAsset = screenshot
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Button(role: .destructive) {
                cellToDelete = screenshot
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
