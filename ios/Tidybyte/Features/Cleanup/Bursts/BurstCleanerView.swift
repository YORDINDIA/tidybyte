import SwiftUI

/// Identifies which burst group (and which frame) a full-screen preview was
/// opened from. The preview resolves its assets *live* from the view model on
/// presentation (LF-04), so in-preview deletes re-render against the updated
/// group instead of a frozen snapshot.
private struct BurstPreviewContext: Identifiable {
    let id: String
    let groupId: String
}

struct BurstCleanerView: View {
    @State private var viewModel = BurstCleanerViewModel()
    @State private var showAutoCleanConfirm = false
    @State private var showDeleteConfirm = false
    @State private var preview: BurstPreviewContext?
    // statLine is captured at success time: deletableCount/selectedCount are
    // pre-delete values that reset once the action lands.
    @State private var isCelebrating = false
    @State private var celebrationStatLine: String?
    @State private var toast: ToastMessage?
    private let photoService = PhotoLibraryService.shared

    /// The confirm copy must match what Auto-Clean really arms. It never
    /// suggests a favorite, but an explicit Select All can arm one — promising
    /// "Favorites are kept" then would be a lie the delete immediately breaks.
    private var autoCleanMessage: String {
        // Built here rather than in a `Text`, so each sentence resolves through
        // `L10n` on its own; the leading space keeps the sentences joined.
        let favoritesKept = viewModel.autoCleanArmedIncludesFavorite ? "" : L10n.string(" Favorites are kept.")
        let opening = L10n.string("Deletes the frames marked for deletion. The starred frame of each burst is kept.")
        return "\(opening)\(favoritesKept) \(CleanupDeletion.recoverableNote)"
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.groups.isEmpty {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No Burst Photos",
                    message: "You don't have any burst photo groups.",
                    actionTitle: "Refresh",
                    action: { Task { await viewModel.refresh() } }
                )
            } else {
                contentView
            }
        }
        .localizedNavigationTitle("Burst Photos")
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
        .toolbar {
            if !viewModel.groups.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SortMenu(
                        selection: $viewModel.groupSortOrder,
                        options: GroupSortOrder.allCases,
                        title: \.displayName
                    )
                    SelectAllToolbarButton(
                        allSelected: viewModel.allNonBestSelected,
                        selectAll: { viewModel.selectAllNonBest() },
                        deselectAll: { viewModel.deselectAll() }
                    )
                    Button {
                        HapticHelper.impact(.light)
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
        }
        .happyPathCelebration(isPresented: $isCelebrating, statLine: celebrationStatLine)
        .toast($toast)
        .onChange(of: viewModel.errorMessage) { _, newValue in
            if newValue != nil { toast = nil }
        }
        .alert(CleanupDeletion.confirmTitle(count: viewModel.autoCleanArmedCount), isPresented: $showAutoCleanConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    // Celebrate only what really left the library: a declined
                    // iOS prompt or a failure deletes nothing.
                    let removed = await viewModel.autoCleanAll()
                    guard removed > 0, viewModel.errorMessage == nil else { return }
                    HappyPathReporter.fire(
                        isCelebrating: $isCelebrating,
                        statLine: $celebrationStatLine,
                        line: L10n.format(
                            "cleaned %lld burst photo",
                            fallback: "cleaned %lld burst photos",
                            removed
                        )
                    )
                }
            }
        } message: {
            Text(autoCleanMessage)
        }
        .alert(CleanupDeletion.confirmTitle(count: viewModel.selectedCount), isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    // Celebrate only what PhotoKit really deleted: ids that
                    // were already gone leave the list but are not a success.
                    let count = await viewModel.deleteSelected()
                    guard count > 0, viewModel.errorMessage == nil else { return }
                    HappyPathReporter.fire(
                        isCelebrating: $isCelebrating,
                        statLine: $celebrationStatLine,
                        line: L10n.format(
                            "cleared %lld burst frame",
                            fallback: "cleared %lld burst frames",
                            count
                        )
                    )
                }
            }
        } message: {
            Text(CleanupDeletion.confirmMessage(L10n.string("The selected burst frames will be deleted. Your chosen best photos are kept.")))
        }
        // Non-modal error surface. The retry is preserved from the alert it
        // replaces: a failed burst delete leaves the selection intact, so
        // re-running the same delete is the correct recovery.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = viewModel.errorMessage {
                ToolErrorBanner(
                    // Runtime text, so it renders verbatim: the view model
                    // fills this with `error.localizedDescription` or with a
                    // sentence it built through `L10n`, and both are already in
                    // the user's language. Looking it up as a key would miss,
                    // and `Text` would apply Markdown to it.
                    message: .runtimeText(message),
                    title: .runtimeText(CleanupTool.bursts.name),
                    onRetry: {
                        // Retry re-arms the same confirmation as the first
                        // attempt; a delete never runs without it.
                        viewModel.errorMessage = nil
                        showDeleteConfirm = true
                    },
                    onDismiss: { viewModel.errorMessage = nil }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
            }
        }
        // Transient success note, not a modal: the celebration already covers
        // the win, and this only explains why collapsed groups left the list.
        // Clearing the view-model message keeps it one-shot across redraws.
        .onChange(of: viewModel.statusMessage) { _, newValue in
            guard let newValue else { return }
            toast = ToastMessage.success(text: newValue)
            viewModel.statusMessage = nil
        }
        .fullScreenCover(item: $preview) { context in
            // Resolve the group's assets live so an in-preview delete re-renders
            // the pager against the updated frames (LF-04).
            if let group = viewModel.groups.first(where: { $0.id == context.groupId }) {
                MediaPreviewView(
                    assets: group.assets,
                    startIndex: group.assets.firstIndex { $0.id == context.id } ?? 0,
                    photoService: photoService,
                    onDelete: { await viewModel.deleteAsset(id: $0.id, fromGroup: context.groupId) }
                )
            }
        }
        // If the previewed group collapses away (delete down to a single frame),
        // dismiss the cover instead of showing a dead pager (LF-04).
        .onChange(of: viewModel.groups.map(\.id)) { _, newGroupIds in
            if let preview, !newGroupIds.contains(preview.groupId) {
                self.preview = nil
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        ToolLoadingView { ToolSkeletonList() }
    }

    // MARK: - Content View

    private var contentView: some View {
        VStack(spacing: 0) {
            // At accessibility sizes the summary scrolls with the groups. Above the
            // list it, and the taller action bar, left no room for a single group.
            if !dynamicTypeSize.isAccessibilitySize {
                summaryHeader
                    .fadeSlideIn()
            }

            List {
                if dynamicTypeSize.isAccessibilitySize {
                    compactSummary
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(Array(viewModel.sortedGroups.enumerated()), id: \.element.id) { index, group in
                    burstGroupRow(group)
                        .fadeSlideIn(delay: Double(index) * 0.03)
                }
            }
            .listStyle(.plain)
            .pullToRefresh { await viewModel.refresh() }

            // Bottom action bar
            CleanupActionBar {
                if dynamicTypeSize.isAccessibilitySize {
                    Text("\(viewModel.selectedCount) selected · \(viewModel.selectedSavingsBytes.formattedFileSize)")
                        .font(.caption.bold())
                } else {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("\(viewModel.deletableCount) removable")
                            .font(.caption.bold())
                        Text("\(viewModel.selectedCount) selected · \(viewModel.selectedSavingsBytes.formattedFileSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                AdaptiveSpacer()

                // Side by side at default size. At accessibility sizes the primary
                // takes the full width and Auto-Clean drops to a text button below it.
                AdaptiveRow(spacing: Spacing.sm) {
                    Button {
                        HapticHelper.impact(.light)
                        showDeleteConfirm = true
                    } label: {
                        Text(viewModel.selectedCount > 0 && !dynamicTypeSize.isAccessibilitySize
                             ? L10n.format("Delete %lld", fallback: "Delete %lld", viewModel.selectedCount)
                             : L10n.string("Delete"))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                            .background(Color.destructive)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                    }
                    .scaleOnPress()
                    .disabled(viewModel.selectedCount == 0)

                    Button {
                        HapticHelper.impact(.light)
                        showAutoCleanConfirm = true
                    } label: {
                        Text("Auto-Clean")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                            .background(dynamicTypeSize.isAccessibilitySize ? Color.clear : Color.blue)
                            .foregroundStyle(dynamicTypeSize.isAccessibilitySize ? Color.blue : Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                    }
                    .scaleOnPress()
                    .disabled(viewModel.autoCleanArmedCount == 0)
                }
            }
        }
    }

    // MARK: - Summary Header

    /// Accessibility sizes: the counts as one line of text, without the card.
    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.format("%lld burst group", fallback: "%lld burst groups", viewModel.groups.count))
                .font(.caption.bold())
            Text("\(viewModel.totalBurstCount) total · \(viewModel.deletableCount) removable · \(viewModel.savingsBytes.formattedFileSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xs)
    }

    private var summaryHeader: some View {
        CleanupSummaryCard(
            icon: CleanupTool.bursts.icon,
            tint: CleanupTool.bursts.color,
            headline: Text(L10n.format("%lld burst group", fallback: "%lld burst groups", viewModel.groups.count)),
            subtitle: Text("\(viewModel.totalBurstCount) total · \(viewModel.deletableCount) removable · \(viewModel.savingsBytes.formattedFileSize)")
        )
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Burst Group Row

    /// Why the starred frame is the one kept. Plain text, so the user can
    /// check the choice before Auto-Clean. `String` return, so each label
    /// resolves through `L10n`.
    private func keeperReason(for group: BurstGroup) -> String {
        if viewModel.manuallySetBest.contains(group.id) { return L10n.string("Kept: your choice") }
        guard let best = group.assets.first(where: { $0.id == group.bestAssetId }) else { return "" }
        switch best.burstPick {
        case .user: return L10n.string("Kept: your pick in Photos")
        case .iPhone: return L10n.string("Kept: iPhone's pick")
        case .none: return best.isFavorite ? L10n.string("Kept: favorite") : automaticKeeperReason(best: best, in: group)
        }
    }

    /// Which `BestAssetSelector` ladder rung picked an automatic keeper, so the
    /// label matches the actual reason (a resolution win is not "last frame").
    /// Burst picks and favorites are handled above; by the time we get here
    /// every frame is `.none` and unfavorited, leaving pixels → date → id.
    private func automaticKeeperReason(best: AssetSummary, in group: BurstGroup) -> String {
        let bestPixels = best.pixelWidth * best.pixelHeight
        if group.assets.allSatisfy({ $0.id == best.id || $0.pixelWidth * $0.pixelHeight < bestPixels }) {
            return L10n.string("Kept: highest resolution")
        }
        let bestDate = best.creationDate ?? .distantPast
        if group.assets.allSatisfy({ $0.id == best.id || ($0.creationDate ?? .distantPast) < bestDate }) {
            return L10n.string("Kept: last frame")
        }
        return L10n.string("Kept: auto pick")
    }

    /// Accessibility sizes need room for "Keep This" and the star label; the
    /// thumbnails stay 96 pt, centered in a wider column.
    private var groupColumnWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 150 : 96 }

    private func burstGroupRow(_ group: BurstGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            AdaptiveRow(spacing: nil) {
                Text("\(group.assets.count) frames")
                    .font(.subheadline.bold())
                Text(keeperReason(for: group))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AdaptiveSpacer()
                if let date = group.assets.first?.creationDate {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(group.assets) { asset in
                        let isKeeper = asset.id == group.bestAssetId
                        VStack(spacing: Spacing.xs) {
                            AsyncThumbnailView(assetId: asset.id, photoService: photoService)
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                                .overlay(
                                    RoundedRectangle(cornerRadius: CornerRadius.small)
                                        .stroke(isKeeper ? Color.success : Color.clear, lineWidth: 2)
                                )
                                .overlay(alignment: .bottomLeading) {
                                    if asset.isFavorite {
                                        FavoriteMark().padding(Spacing.xs)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    preview = BurstPreviewContext(id: asset.id, groupId: group.id)
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel("Preview burst frame")
                                .overlay(alignment: .topTrailing) {
                                    if !isKeeper {
                                        DeleteToggle(isMarked: viewModel.selectedForDeletion.contains(asset.id)) {
                                            viewModel.toggleSelection(asset.id)
                                        }
                                        .offset(x: Spacing.xs, y: -Spacing.xs)
                                    }
                                }

                            if isKeeper {
                                KeeperMark()
                                    .frame(minHeight: 44)
                            } else {
                                MakeKeeperButton {
                                    viewModel.setBest(assetId: asset.id, in: group.id)
                                }
                            }
                        }
                        .frame(width: groupColumnWidth)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
