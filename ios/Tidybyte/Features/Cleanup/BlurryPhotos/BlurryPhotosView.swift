import SwiftUI
import SwiftData

struct BlurryPhotosView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = BlurryPhotosViewModel()
    @Environment(LibraryChangeMonitor.self) private var libraryMonitor
    @State private var showDeleteConfirm = false
    @State private var isCelebrating = false
    @State private var selectedSwipeRoute: SwipeSessionRoute?
    @State private var previewPhoto: AnalyzedPhoto?
    @State private var pendingSwipeReview = false
    @State private var cellToDelete: AnalyzedPhoto?
    @AppStorage(AppPreferences.Key.blurSensitivity) private var blurSensitivityRaw: String = BlurSensitivity.medium.rawValue

    private let photoService = PhotoLibraryService.shared

    private let columns = ResponsiveGrid.photo()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(spacing: 0) {
            // Non-modal error surface. Replaces the OK-only alert: an alert
            // interrupts the task and costs a tap to dismiss, and it left the
            // screen exactly as it already was.
            if let message = viewModel.errorMessage {
                ToolErrorBanner(
                    // Runtime text, so it renders verbatim. The view model
                    // fills this with `error.localizedDescription` or with a
                    // sentence it built through `L10n`, and either is already
                    // in the user's language, so looking it up as a key would
                    // miss, and `Text` would apply Markdown to it.
                    message: .runtimeText(message),
                    // The tool's own name, which `CleanupTool.name` already
                    // resolved. A banner that says only "Something went wrong"
                    // loses the one piece of context the screen provides.
                    title: .runtimeText(CleanupTool.blurry.name),
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
        .localizedNavigationTitle(CleanupTool.blurry.nameKey)
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
        // Items deleted elsewhere (Swipe Review, the Photos app) leave the
        // list when the library changes, instead of lingering as blanks.
        .task(id: libraryMonitor.generation) {
            await viewModel.pruneDeleted()
        }
        .happyPathCelebration(
            isPresented: $isCelebrating,
            statLine: L10n.format(
                "cleared %lld blurry photo",
                fallback: "cleared %lld blurry photos",
                viewModel.deletedCount
            )
        )
        .onDisappear {
            // D-01: a scan left running after the user leaves the screen would
            // keep consuming CPU (and PhotoKit calls) in the background.
            viewModel.cancelScan()
        }
        .toolbar {
            if viewModel.scanState == .completed {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !viewModel.filteredPhotos.isEmpty {
                        SelectAllToolbarButton(
                            allSelected: viewModel.allVisibleSelected,
                            selectAll: { viewModel.selectAll() },
                            deselectAll: { viewModel.deselectAll() }
                        )
                    }
                    Menu {
                        if !viewModel.filteredPhotos.isEmpty {
                            Button {
                                HapticHelper.impact(.light)
                                let ids = viewModel.filteredPhotos.map(\.id)
                                startSwipeReview(with: .customAssetIds(ids))
                            } label: {
                                Label("Review with Swipe", systemImage: "hand.draw")
                            }
                            SortMenu(
                                selection: $viewModel.sortOrder,
                                options: BlurryPhotosViewModel.sortOptions,
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
            SwipeSessionHostView(
                route: route,
                photoService: photoService,
                modelContext: modelContext
            )
        }
        .alert(CleanupDeletion.confirmTitle(count: viewModel.totalSelectedCount), isPresented: $showDeleteConfirm) {
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
                let ids = viewModel.filteredPhotos.map(\.id)
                startSwipeReview(with: .customAssetIds(ids))
            }
        }) { photo in
            MediaPreviewView(
                assets: viewModel.filteredPhotos.map(\.asset),
                startIndex: viewModel.filteredPhotos.firstIndex { $0.id == photo.id } ?? 0,
                photoService: photoService,
                onDelete: { await viewModel.delete(assetId: $0.id) },
                accessory: AccessoryAction(title: "Review with Swipe", systemImage: "hand.draw") {
                    pendingSwipeReview = true
                }
            )
        }
    }

    private func startSwipeReview(with filter: SwipeFilter) {
        selectedSwipeRoute = SwipeSessionRoute(filter: filter, deckKey: "blurry")
    }

    // MARK: - Idle View

    private var idleView: some View {
        ToolIdleView(
            icon: "camera.metering.unknown",
            tint: CleanupTool.blurry.color,
            title: "Detect Low-Quality Photos",
            message: "Find blurry, too dark, and overexposed photos.",
            primaryTitle: "Start Analysis",
            primaryHint: "Scans your library for out-of-focus and poorly lit photos",
            primaryAction: {
                HapticHelper.impact(.light)
                viewModel.startScan()
            }
        ) {
            VStack(spacing: Spacing.sm) {
                Text("Blur Detection Sensitivity")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Picker("Blur Detection Sensitivity", selection: $blurSensitivityRaw) {
                    ForEach(BlurSensitivity.allCases, id: \.rawValue) { sensitivity in
                        Text(sensitivity.displayName).tag(sensitivity.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .fadeSlideIn()
    }

    // MARK: - Scanning View

    private func scanningView(progress: Float) -> some View {
        ToolScanningView(
            icon: "magnifyingglass",
            tint: CleanupTool.blurry.color,
            title: "Analyzing photos...",
            progress: progress,
            detail: L10n.format(
                "%lld issues found",
                fallback: "%lld issues found",
                viewModel.analyzedPhotos.count
            ),
            onCancel: {
                HapticHelper.impact(.light)
                viewModel.cancelScan()
            }
        )
    }

    // MARK: - Results View

    private var resultsView: some View {
        VStack(spacing: 0) {
            LimitedLibraryBanner()
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)

            // Horizontal category chips matching Smart Categories
            categoryChips

            if viewModel.filteredPhotos.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: "All Clear",
                    message: "No issues found in this category.",
                    iconColor: .green,
                    actionTitle: "Scan Again"
                ) {
                    viewModel.startScan()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.xs) {
                        ForEach(viewModel.filteredPhotos) { photo in
                            photoCell(photo)
                        }
                    }
                }
            }

            // Outside the list branch: picks on other tabs stay reachable
            // even when this tab is empty.
            if !viewModel.selectedIds.isEmpty {
                CleanupActionBar {
                    Text(viewModel.selectedOnOtherTabs > 0 ? "\(viewModel.selectedIds.count) selected (\(viewModel.selectedOnOtherTabs) on other tabs) \u{00B7} \(viewModel.selectedSize.formattedFileSize)" : "\(viewModel.selectedIds.count) selected \u{00B7} \(viewModel.selectedSize.formattedFileSize)")
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
            if viewModel.skippedSmudgeCount > 0 {
                Text(L10n.format("Lens analysis skipped %lld photo.",
                                 fallback: "Lens analysis skipped %lld photos.",
                                 viewModel.skippedSmudgeCount))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.lg)
            }
            if #available(iOS 26, *), !viewModel.supportsLensSmudge {
                Text("Lens smudge analysis is unavailable on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // D-04: tell the user why their library may look smaller than the
            // full photo count.
            if viewModel.skippedScreenshotCount > 0 {
                Text("\(viewModel.skippedScreenshotCount) screenshots skipped \u{00B7} covered by the Screenshots tool")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)
            }
        }
    }

    // MARK: - Category Chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                categoryChip(.blurry, count: viewModel.blurryCount, title: L10n.format("Blurry (%lld)", viewModel.blurryCount), icon: "camera.metering.unknown")
                categoryChip(.tooDark, count: viewModel.darkCount, title: L10n.format("Dark (%lld)", viewModel.darkCount), icon: "moon.fill")
                categoryChip(.overexposed, count: viewModel.overexposedCount, title: L10n.format("Bright (%lld)", viewModel.overexposedCount), icon: "sun.max.fill")
                if viewModel.supportsLensSmudge {
                    categoryChip(.lensSmudge, count: viewModel.smudgeCount, title: L10n.format("Lens Smudge (%lld)", viewModel.smudgeCount), icon: "sparkles")
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
    }

    private func categoryChip(_ tab: BlurryTab, count: Int, title: String, icon: String) -> some View {
        let isActive = viewModel.activeTab == tab
        let tint = scoreColor(for: tab)
        return Button {
            withAnimation(.reduceMotionAware(.spring(response: 0.3, dampingFraction: 0.8), reduceMotion: reduceMotion)) {
                viewModel.activeTab = tab
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.caption)
                Text(verbatim: title)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(isActive ? tint : Color.secondary.opacity(0.15))
            .foregroundStyle(isActive ? .white : .primary)
            .clipShape(Capsule())
            .opacity(isActive || count > 0 ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Photo Cell

    private func photoCell(_ photo: AnalyzedPhoto) -> some View {
        SelectableMediaGridCell(
            asset: photo.asset,
            photoService: photoService,
            isSelected: viewModel.selectedIds.contains(photo.id),
            itemName: "photo",
            scoreBar: (
                value: scoreValue(for: photo, tab: viewModel.activeTab),
                color: scoreColor(for: viewModel.activeTab),
                label: scoreLabel(for: viewModel.activeTab)
            ),
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

    /// `LocalizedStringKey`, not `String`: this feeds `accessibilityLabel`,
    /// whose `String` overload does not localize, so a `String` return would
    /// read the tab name in English to VoiceOver in every language.
    private func scoreLabel(for tab: BlurryTab) -> LocalizedStringKey {
        switch tab {
        case .blurry: "Blur"
        case .tooDark: "Darkness"
        case .overexposed: "Brightness"
        case .lensSmudge: "Lens smudge confidence"
        }
    }

    private func scoreColor(for tab: BlurryTab) -> Color {
        switch tab {
        case .blurry: return .orange
        case .tooDark: return .purple
        case .overexposed: return .yellow
        case .lensSmudge: return .pink
        }
    }

    private func scoreValue(for photo: AnalyzedPhoto, tab: BlurryTab) -> Float {
        switch tab {
        case .blurry:
            return photo.blurScore
        case .tooDark:
            return max(0, min(1, 1 - photo.luminance))
        case .overexposed:
            return photo.luminance
        case .lensSmudge:
            return photo.smudgeConfidence ?? 0
        }
    }
}
