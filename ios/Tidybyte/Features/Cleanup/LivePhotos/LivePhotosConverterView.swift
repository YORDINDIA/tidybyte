import SwiftUI
import SwiftData

struct LivePhotosConverterView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel = LivePhotosConverterViewModel()
    @State private var showConvertAllConfirm = false
    /// The open swipe review. Its Convert closes it, then converts the marked
    /// photos in one batch, so iOS asks once for the whole review.
    @State private var review: ReviewStart?
    @State private var isCelebrating = false
    @State private var celebrationStatLine: String?
    private let photoService = PhotoLibraryService.shared

    private var hasIdleItems: Bool {
        viewModel.items.contains { $0.conversionState.isConvertible }
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.items.isEmpty {
                EmptyStateView(
                    icon: "livephoto",
                    title: "No Live Photos",
                    message: "You don't have any Live Photos in your library.",
                    iconColor: CleanupTool.livePhotos.color,
                    // D12: refresh affordance — new Live Photos may have landed
                    // since the last fetch (parity with Large Files/Bursts).
                    actionTitle: "Refresh"
                ) {
                    Task {
                        await viewModel.refresh()
                        await viewModel.markAlreadyConverted(modelContext: modelContext)
                    }
                }
            } else {
                contentView
            }
        }
        .localizedNavigationTitle("Live Photos")
        .toolbar {
            // Conversions are logged in the same history as compression.
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !viewModel.items.isEmpty {
                    SortMenu(
                        selection: $viewModel.sortOrder,
                        options: LivePhotosConverterViewModel.sortOptions,
                        title: \.displayName
                    )
                    .disabled(viewModel.convertingAll)
                }
                NavigationLink {
                    CompressionHistoryView()
                } label: {
                    Label("Conversion History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .happyPathCelebration(isPresented: $isCelebrating, statLine: celebrationStatLine)
        .onDisappear {
            // D2: leaving the screen must stop Convert All — the loop deletes
            // originals and previously had no stop at all.
            viewModel.cancelConvertAll()
        }
        .alert("Convert All Live Photos", isPresented: $showConvertAllConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Convert All") {
                // D2: VM-owned task so cancellation works; haptic on full success.
                viewModel.startConvertAll(modelContext: modelContext)
            }
        } message: {
            Text(LivePhotoConvertExplainer.message)
        }
        .originalsKeptAlert(
            // No settable state backs this condition — keptOriginals is
            // VM-owned and the review gate is local — so a constant binding.
            // An alert cannot present over the review's full-screen cover.
            isPresented: .constant(!viewModel.keptOriginals.isEmpty && review == nil),
            onTryAgain: { viewModel.retryRemovingOriginals() },
            onRemoveCopies: { viewModel.removeCopies() }
        )
        .onChange(of: viewModel.convertingAll) { was, isNow in
            // Happy path: celebrate only a fully-successful Convert All (the
            // COMP-09 pattern) — a user-cancelled batch is not a milestone.
            guard was, !isNow, !viewModel.isCancelled,
                  viewModel.errorMessage == nil,
                  let batch = viewModel.lastBatch,
                  batch.failed == 0, batch.converted > 0,
                  // Kept originals leave the "Originals Kept" alert open: not
                  // a clean success, and the rating sheet would collide with it.
                  viewModel.keptOriginals.isEmpty else { return }
            HappyPathReporter.fire(
                isCelebrating: $isCelebrating,
                statLine: $celebrationStatLine,
                line: L10n.format(
                    "converted %lld Live Photo",
                    fallback: "converted %lld Live Photos",
                    batch.converted
                )
            )
        }
        // Non-modal error surface. Also covers the batch summary
        // ("Converted 8 of 10. 2 failed."), which is a report rather than a
        // failure, so no retry is offered.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = viewModel.errorMessage {
                ToolErrorBanner(
                    // Runtime text, so it renders verbatim. `errorMessage`
                    // holds either `error.localizedDescription` or a sentence
                    // the view model built through `L10n`, including the batch
                    // summary, which `L10n.format` localizes with a catalog key.
                    // Nothing here is a key any more, and `Text` must not apply
                    // Markdown to text that can contain a file name.
                    message: .runtimeText(message),
                    onDismiss: { viewModel.errorMessage = nil }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
            }
        }
        .fullScreenCover(item: $review) { start in
            LivePhotoSwipeReviewView(
                items: viewModel.items,
                startId: start.itemId,
                saved: start.saved,
                photoService: photoService
            ) { marked in
                review = nil
                viewModel.startConvertAll(ids: marked, modelContext: modelContext)
            }
        }
        .task {
            // D1 (review pass): resolve any conversions a crash interrupted.
            // Before loading, like the compression tools: finishing a swap
            // deletes Live Photos the list must not show.
            await CompressionJournal.reconcile(modelContext: modelContext)
            await viewModel.loadIfNeeded()
            await viewModel.markAlreadyConverted(modelContext: modelContext)
        }
    }

    /// The saved review's decisions for photos still in the list. A converted
    /// or deleted Live Photo has left the library, so its decision goes too.
    private func savedReviewDecisions() -> [String: Bool] {
        let key = SwipeDeckStore.livePhotosKey
        let entries = SwipeDeckStore.decisions(deckKey: key, context: modelContext)
        let listed = Set(viewModel.items.map(\.id))
        if viewModel.hasLoadedItems {
            let gone = Set(entries.map(\.assetLocalIdentifier)).subtracting(listed)
            SwipeDeckStore.remove(assetIds: gone, deckKey: key, context: modelContext)
        }
        return entries.reduce(into: [:]) { result, entry in
            guard listed.contains(entry.assetLocalIdentifier) else { return }
            switch entry.deckDecision {
            case .convert: result[entry.assetLocalIdentifier] = true
            case .keepLive: result[entry.assetLocalIdentifier] = false
            default: break
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        ToolLoadingView { ToolSkeletonList() }
    }

    // MARK: - Content View

    private var contentView: some View {
        VStack(spacing: 0) {
            LimitedLibraryBanner()
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)

            // Summary header
            summaryHeader
                .fadeSlideIn()

            List {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    livePhotoRow(item)
                        .fadeSlideIn(delay: Double(index) * 0.03)
                }
            }
            .listStyle(.plain)
            .pullToRefresh {
                await viewModel.refresh()
                await viewModel.markAlreadyConverted(modelContext: modelContext)
            }

            // Bottom action bar
            ActionBarView {
                if viewModel.convertingAll || viewModel.phase != .idle {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("\(viewModel.items.count) Live Photos")
                            .font(.caption.bold())
                        Text("est. ~\(viewModel.estimatedSavings.formattedFileSize) savings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ProgressView()
                        .padding(.trailing, Spacing.sm)
                    Text(ReplaceOriginalsNotice.phaseText(viewModel.phase))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    // D2: a real stop control. Step 2 is one iOS alert, so
                    // there is nothing left to stop then.
                    if viewModel.convertingAll, case .savingCopies = viewModel.phase {
                        Button("Stop", role: .destructive) {
                            HapticHelper.impact(.light)
                            viewModel.cancelConvertAll()
                        }
                        .font(.subheadline.bold())
                    }
                } else {
                    // The summary card above already shows the count and the
                    // savings, so the bar holds only the two actions.
                    AdaptiveRow(spacing: Spacing.md) {
                        Button("Convert All") {
                            HapticHelper.impact(.light)
                            showConvertAllConfirm = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(viewModel.isBusy || !hasIdleItems)

                        AdaptiveSpacer()

                        Button {
                            HapticHelper.impact(.light)
                            review = ReviewStart(itemId: nil, saved: savedReviewDecisions())
                        } label: {
                            Label("Review with Swipe", systemImage: "hand.draw")
                                .font(.headline)
                                .padding(.horizontal, Spacing.lg)
                                .padding(.vertical, Spacing.sm)
                                .frame(minHeight: 44)
                                .background(Color.actionFill)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                        }
                        .scaleOnPress()
                        .disabled(viewModel.isBusy || !hasIdleItems)
                    }
                }
            }
        }
    }

    // MARK: - Summary Header

    private var summaryHeader: some View {
        CleanupSummaryCard(
            icon: CleanupTool.livePhotos.icon,
            tint: CleanupTool.livePhotos.color,
            headline: Text("\(viewModel.items.count) Live Photos"),
            subtitle: Text("Total: \(viewModel.totalSize.formattedFileSize) · est. savings ~\(viewModel.estimatedSavings.formattedFileSize)")
        )
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Live Photo Row

    private func livePhotoRow(_ item: LivePhotoItem) -> some View {
        // Accessibility sizes stack the Convert control under the item, so the
        // date and size get the full width instead of a squeezed column.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.md))
            : AnyLayout(HStackLayout(spacing: Spacing.md))
        return layout {
            Button {
                HapticHelper.impact(.light)
                review = ReviewStart(itemId: item.id, saved: savedReviewDecisions())
            } label: {
                HStack(spacing: Spacing.md) {
                    AsyncThumbnailView(assetId: item.id, photoService: photoService)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                        .overlay(alignment: .bottomLeading) {
                            if item.asset.isFavorite {
                                FavoriteMark().padding(Spacing.xs)
                            }
                        }

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if let date = item.asset.creationDate {
                            Text(date, format: .dateTime.day().month(.abbreviated).year())
                                .font(.subheadline)
                        }

                        // Current size. Actual savings depend on the photo and are shown
                        // after conversion rather than guessed up front.
                        HStack(spacing: Spacing.xs) {
                            Text(verbatim: "\(item.asset.fileSize.formattedFileSize) · \(item.asset.resolution)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Converting, saved and converted rows have nothing left to review.
            .disabled(!item.conversionState.isConvertible || viewModel.convertingAll || viewModel.isBusy)
            .accessibilityHint("Review with Swipe")

            conversionButton(for: item)
        }
    }

    // MARK: - Conversion Button

    @ViewBuilder
    private func conversionButton(for item: LivePhotoItem) -> some View {
        switch item.conversionState {
        case .idle:
            EmptyView()

        case .converting:
            ProgressView()

        case .copySaved:
            Label("Copy saved", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .completed:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if item.savedBytes > 0 {
                    Text("-\(item.savedBytes.formattedFileSize)")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

        case .failed(let error):
            VStack(spacing: Spacing.xs) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.destructive)
                    .lineLimit(3)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What a Live Photo conversion does. Shown in the Convert All alert and on
/// the swipe review's Convert screen.
enum LivePhotoConvertExplainer {
    /// Computed, not stored: a `static let` resolves once, the first time the
    /// type is touched, and then keeps serving that language after the user
    /// switches — the same caching bug the other `static let` copy sites had.
    static var message: String {
        ReplaceOriginalsNotice.explainer(
            copies: L10n.string("the still image of each Live Photo as a new photo"),
            originals: L10n.string("the Live Photos")
        )
    }
}

/// Where a swipe review starts: a tapped row, or the first idle photo, plus
/// the decisions the saved review already holds.
private struct ReviewStart: Identifiable {
    let id = UUID()
    let itemId: String?
    /// True = convert, false = keep the Live Photo.
    let saved: [String: Bool]
}
