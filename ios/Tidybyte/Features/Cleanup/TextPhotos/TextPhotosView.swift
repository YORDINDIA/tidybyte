import SwiftUI
import SwiftData

/// Photos full of text (notes, tickets, receipts, boards) taken weeks ago,
/// which are often out of date. Review them in a grid or with swipe.
struct TextPhotosView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LibraryChangeMonitor.self) private var libraryMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Read so the date badges and the age menu resolve again after an in-app
    /// language change.
    @Environment(\.locale) private var locale
    @State private var viewModel = TextPhotosViewModel()
    @State private var showDeleteConfirm = false
    @State private var isCelebrating = false
    @State private var selectedSwipeRoute: SwipeSessionRoute?
    @State private var previewPhoto: TextPhoto?
    @State private var pendingSwipeReview = false
    @State private var cellToDelete: TextPhoto?

    private let photoService = PhotoLibraryService.shared
    private let columns = ResponsiveGrid.photo()

    var body: some View {
        VStack(spacing: 0) {
            if let message = viewModel.errorMessage {
                ToolErrorBanner(
                    message: .runtimeText(message),
                    title: .runtimeText(CleanupTool.textPhotos.name),
                    onDismiss: { viewModel.errorMessage = nil }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)
            }

            Group {
                switch viewModel.scanState {
                case .idle:
                    idleView
                        .transition(.stateTransition)
                case .scanning(let progress):
                    scanningView(progress: progress)
                        .transition(.stateTransition)
                case .completed:
                    resultsView
                        .transition(.stateTransition)
                }
            }
        }
        .animation(.reduceMotionAware(.spring(response: 0.4, dampingFraction: 0.85), reduceMotion: reduceMotion), value: viewModel.scanState)
        .localizedNavigationTitle(CleanupTool.textPhotos.nameKey)
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
        // Items deleted elsewhere (Swipe Review, the Photos app) leave the list.
        .task(id: libraryMonitor.generation) {
            await viewModel.pruneDeleted()
        }
        .happyPathCelebration(
            isPresented: $isCelebrating,
            statLine: L10n.format("cleared %lld photo", fallback: "cleared %lld photos", viewModel.deletedCount)
        )
        .onDisappear {
            // A scan left running off screen would keep using CPU and PhotoKit.
            viewModel.cancelScan()
        }
        .toolbar {
            if viewModel.scanState == .completed {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !viewModel.visiblePhotos.isEmpty {
                        SelectAllToolbarButton(
                            allSelected: viewModel.allVisibleSelected,
                            selectAll: { viewModel.selectAll() },
                            deselectAll: { viewModel.deselectAll() }
                        )
                    }
                    Menu {
                        if !viewModel.visiblePhotos.isEmpty {
                            Button {
                                HapticHelper.impact(.light)
                                startSwipeReview()
                            } label: {
                                Label("Review with Swipe", systemImage: "hand.draw")
                            }
                            SortMenu(
                                selection: $viewModel.sortOrder,
                                options: TextPhotosViewModel.sortOptions,
                                title: \.displayName
                            )
                        }
                        Button {
                            HapticHelper.impact(.light)
                            viewModel.scanState = .idle
                        } label: {
                            Label("New Scan", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More actions")
                }
            }
        }
        .navigationDestination(item: $selectedSwipeRoute) { route in
            SwipeSessionHostView(route: route, photoService: photoService, modelContext: modelContext)
        }
        .alert(CleanupDeletion.confirmTitle(count: viewModel.selectedIds.count), isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteSelected()
                    if viewModel.errorMessage == nil && viewModel.deletedCount > 0 {
                        HappyPathReporter.fire(isCelebrating: $isCelebrating)
                    }
                }
            }
        } message: {
            Text(CleanupDeletion.confirmMessage(L10n.string("The selected photos will be deleted from Photos.")))
        }
        .alert(CleanupDeletion.confirmTitle(count: 1), isPresented: .init(
            get: { cellToDelete != nil },
            set: { if !$0 { cellToDelete = nil } }
        ), presenting: cellToDelete) { photo in
            Button("Cancel", role: .cancel) { cellToDelete = nil }
            Button("Delete", role: .destructive) {
                let id = photo.id
                cellToDelete = nil
                Task { await viewModel.delete(assetId: id) }
            }
        } message: { _ in
            Text(CleanupDeletion.confirmMessage(L10n.string("This photo will be deleted from Photos.")))
        }
        .fullScreenCover(item: $previewPhoto, onDismiss: {
            if pendingSwipeReview {
                pendingSwipeReview = false
                startSwipeReview()
            }
        }) { photo in
            MediaPreviewView(
                assets: viewModel.visiblePhotos.map(\.asset),
                startIndex: viewModel.visiblePhotos.firstIndex { $0.id == photo.id } ?? 0,
                photoService: photoService,
                onDelete: { await viewModel.delete(assetId: $0.id) },
                accessory: AccessoryAction(title: "Review with Swipe", systemImage: "hand.draw") {
                    pendingSwipeReview = true
                }
            )
        }
    }

    private func startSwipeReview() {
        selectedSwipeRoute = SwipeSessionRoute(filter: .customAssetIds(viewModel.visiblePhotos.map(\.id)), deckKey: "textPhotos.\(viewModel.age.rawValue)")
    }

    // MARK: - Idle

    private var idleView: some View {
        ToolIdleView(
            icon: CleanupTool.textPhotos.icon,
            tint: CleanupTool.textPhotos.color,
            title: "Find Photos Full of Text",
            message: "Notes, tickets, receipts and boards you photographed are often out of date after a few weeks.",
            primaryTitle: "Start Analysis",
            primaryHint: "Reads the text in your photos on this device",
            footnote: "Screenshots and favorites are not included.",
            primaryAction: {
                HapticHelper.impact(.light)
                viewModel.startScan()
            }
        ) {
            EmptyView()
        }
        .fadeSlideIn()
    }

    // MARK: - Scanning

    private func scanningView(progress: Float) -> some View {
        ToolScanningView(
            icon: "text.magnifyingglass",
            tint: CleanupTool.textPhotos.color,
            title: "Analyzing photos...",
            progress: progress,
            onCancel: {
                HapticHelper.impact(.light)
                viewModel.cancelScan()
            }
        )
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(spacing: 0) {
            LimitedLibraryBanner()
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)

            AdaptiveRow(spacing: Spacing.sm) {
                ageMenu
                AdaptiveSpacer()
                Text(L10n.format("%lld text photo", fallback: "%lld text photos", viewModel.visiblePhotos.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)

            if viewModel.visiblePhotos.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: "All Clear",
                    message: "No photos full of text are this old.",
                    iconColor: .green,
                    actionTitle: "Scan Again"
                ) {
                    viewModel.startScan()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.xs) {
                        ForEach(viewModel.visiblePhotos) { photo in
                            photoCell(photo)
                        }
                    }
                }
            }

            if !viewModel.selectedIds.isEmpty {
                CleanupActionBar {
                    Text("\(viewModel.selectedIds.count) selected \u{00B7} \(viewModel.selectedSize.formattedFileSize)")
                        .font(.caption)
                    if viewModel.isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    AdaptiveSpacer()
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(viewModel.isDeleting)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if viewModel.skippedAnalysisCount > 0 {
                Text(L10n.format("%lld photo had no local analysis image.",
                                 fallback: "%lld photos had no local analysis image.",
                                 viewModel.skippedAnalysisCount))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.lg)
            }
            if viewModel.failedAnalysisCount > 0 {
                Text(L10n.format("%lld photo could not be analyzed.",
                                 fallback: "%lld photos could not be analyzed.",
                                 viewModel.failedAnalysisCount))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.lg)
            }
        }
    }

    private var ageMenu: some View {
        let _ = locale
        return Menu {
            Picker("Age", selection: $viewModel.age) {
                ForEach(TextPhotoAge.allCases, id: \.self) { age in
                    Text(age.displayName).tag(age)
                }
            }
        } label: {
            Label(viewModel.age.displayName, systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("textPhotosAge")
    }

    private func photoCell(_ photo: TextPhoto) -> some View {
        SelectableMediaGridCell(
            asset: photo.asset,
            photoService: photoService,
            isSelected: viewModel.selectedIds.contains(photo.id),
            // The date, not the size: age is what makes a text photo stale.
            bottomBadgeText: photo.asset.creationDate.map { Formatters.monthYear($0) },
            onPreview: { previewPhoto = photo },
            onToggleSelection: { viewModel.toggleSelection(photo.id) }
        ) {
            Button {
                previewPhoto = photo
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Button(role: .destructive) {
                cellToDelete = photo
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
