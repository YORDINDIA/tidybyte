import SwiftUI

/// Swipe state of a Live Photo review: the photo on top and each decision.
/// Nothing changes in the library until the review's Convert, which converts
/// every marked photo in one batch, so iOS asks once.
struct LivePhotoReviewDeck: Equatable {
    /// Deck order: the list order, rotated to start at the photo the user tapped.
    let ids: [String]
    private(set) var index = 0
    /// True = convert to a still, false = keep the Live Photo.
    private(set) var decisions: [String: Bool] = [:]

    init(ids: [String], startingAt startId: String? = nil) {
        if let startId, let start = ids.firstIndex(of: startId) {
            self.ids = Array(ids[start...] + ids[..<start])
        } else {
            self.ids = ids
        }
    }

    var current: String? { index < ids.count ? ids[index] : nil }
    var isFinished: Bool { index >= ids.count }
    var canUndo: Bool { index > 0 }
    /// Photos marked to convert, in deck order.
    var markedIds: [String] { ids.filter { decisions[$0] == true } }

    mutating func decide(convert: Bool) {
        guard let id = current else { return }
        decisions[id] = convert
        index += 1
    }

    mutating func undo() {
        guard canUndo else { return }
        index -= 1
        decisions[ids[index]] = nil
    }

    /// Flips a decided photo between convert and keep (the review grid's checkbox).
    mutating func toggle(_ id: String) {
        guard let convert = decisions[id] else { return }
        decisions[id] = !convert
    }
}

/// Full-screen swipe review for Live Photos. Swipe forward (right; left in
/// Arabic and Hebrew) marks a photo to convert to a still, swipe back keeps it.
/// The review at the end hands the marked ids to `onConvert`.
struct LivePhotoSwipeReviewView: View {
    let photoService: PhotoLibraryService
    let onConvert: (Set<String>) -> Void

    private let assets: [String: AssetSummary]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    private var isRightToLeft: Bool { layoutDirection == .rightToLeft }

    @State private var deck: LivePhotoReviewDeck
    /// Ids shown in the review grid, frozen when the review opens so an
    /// unchecked photo stays on screen and can be checked again.
    @State private var reviewIds: [String]?
    @State private var previewId: String?
    @State private var motion = CardMotion()
    @State private var departing: [Slot] = []
    @State private var deckSize: CGSize = .zero
    @State private var playRequest = 0
    @State private var confirmDiscard = false
    /// Photos the review grid has listed, kept across Resume so an unchecked
    /// photo stays there to check again.
    @State private var listedInReview: [String] = []
    /// Cards whose image is on screen. Convert stays off for a card that never
    /// showed its photo, as Delete does in the swipe session.
    @State private var shownIds: Set<String> = []

    init(
        items: [LivePhotoItem],
        startId: String?,
        photoService: PhotoLibraryService,
        onConvert: @escaping (Set<String>) -> Void
    ) {
        self.photoService = photoService
        self.onConvert = onConvert
        assets = Dictionary(items.map { ($0.id, $0.asset) }, uniquingKeysWith: { first, _ in first })
        let ids = LivePhotosConverterViewModel.eligibleIds(items: items, accepted: nil)
        _deck = State(initialValue: LivePhotoReviewDeck(ids: ids, startingAt: startId))
        // Nothing to swipe: open on the review, which says so.
        _reviewIds = State(initialValue: ids.isEmpty ? [] : nil)
    }

    /// One rendered card: `depth` 0 is the top card, nil a departing one.
    private struct Slot: Identifiable {
        let asset: AssetSummary
        let depth: Int?
        let motion: CardMotion?
        var id: String { asset.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let reviewIds {
                    reviewPanel(reviewIds)
                } else {
                    deckPanel
                }
            }
            .localizedNavigationTitle("Live Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Decisions live only in this screen: ask before dropping them.
                    Button("Cancel") {
                        if deck.decisions.isEmpty { dismiss() } else { confirmDiscard = true }
                    }
                    .confirmationDialog("Discard your choices?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                        Button("Discard", role: .destructive) { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if reviewIds == nil {
                        Button("Done") { openReview() }
                            .font(.body.weight(.semibold))
                    } else if !deck.isFinished {
                        Button("Resume Session") { reviewIds = nil }
                    } else if deck.canUndo {
                        // The last swipe opened the review: take it back.
                        Button("Undo") {
                            deck.undo()
                            reviewIds = nil
                        }
                    }
                }
            }
        }
        .onChange(of: deck.isFinished) { _, finished in
            if finished { openReview() }
        }
        .fullScreenCover(item: Binding(
            get: { previewId.map(PreviewTarget.init) },
            set: { previewId = $0?.id }
        )) { target in
            let list = (reviewIds ?? []).compactMap { assets[$0] }
            MediaPreviewView(
                assets: list,
                startIndex: list.firstIndex { $0.id == target.id } ?? 0,
                photoService: photoService
            )
        }
    }

    private struct PreviewTarget: Identifiable { let id: String }

    private func openReview() {
        motion.isDragging = false
        motion.offset = .zero
        listedInReview += deck.markedIds.filter { !listedInReview.contains($0) }
        // An undone photo has no decision to show until it is swiped again.
        reviewIds = listedInReview.filter { deck.decisions[$0] != nil }
    }

    private var canConvertTopCard: Bool {
        deck.current.map(shownIds.contains) ?? false
    }

    // MARK: - Deck

    private var deckPanel: some View {
        VStack(spacing: 0) {
            if !deck.ids.isEmpty {
                Text("\(min(deck.index + 1, deck.ids.count)) of \(deck.ids.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, Spacing.xs)
            }
            cardStack
                .readableWidth(560)
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)
            actionBar
                .padding(.top, 12)
                .padding(.bottom, Spacing.sm)
        }
        .onAppear {
            HapticHelper.prepare(.light)
            HapticHelper.prepare(.heavy)
        }
        .onChange(of: deckSize) {
            guard motion.isDragging || motion.offset != .zero else { return }
            motion.isDragging = false
            snapBack()
        }
    }

    /// Top two cards (back to front), then departing cards on top. A card that
    /// is both on top and still departing (undo mid-fling) renders on top.
    private var slots: [Slot] {
        let end = min(deck.index + 2, deck.ids.count)
        let visible = deck.index < end ? deck.ids[deck.index..<end].compactMap { assets[$0] } : []
        let visibleIds = Set(visible.map(\.id))
        let stack = visible.enumerated().reversed().map { depth, asset in
            Slot(asset: asset, depth: depth, motion: depth == 0 ? motion : nil)
        }
        return stack + departing.filter { !visibleIds.contains($0.id) }
    }

    private var flingDistance: CGFloat {
        deckSize == .zero ? 1000 : deckSize.width + deckSize.height
    }

    private var cardStack: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(slots) { slot in
                    let isTop = slot.depth == 0
                    let depth = CGFloat(slot.depth ?? 0)
                    CardView(
                        asset: slot.asset,
                        photoService: photoService,
                        isTopCard: isTop,
                        motion: slot.motion,
                        isRightToLeft: isRightToLeft,
                        stamps: .livePhotoReview,
                        playRequest: isTop ? playRequest : 0,
                        onSwipeDragChanged: handleDragChanged,
                        onSwipeDragEnded: handleDragEnded,
                        onImageShown: { shownIds.insert($0) }
                    )
                    .animation(.reduceMotionAware(.smooth(duration: 0.3), reduceMotion: reduceMotion)) {
                        $0.scaleEffect(1.0 - depth * 0.05)
                            .offset(y: depth * 10)
                    }
                    .transition(.stateTransition)
                    .allowsHitTesting(isTop)
                    .accessibilityElement(children: .ignore)
                    .accessibilityHidden(!isTop)
                    .accessibilityLabel(isTop ? accessibilityLabel(for: slot.asset) : Text(""))
                    .accessibilityActions {
                        if isTop {
                            Button("Convert") { commit(convert: true) }
                            Button("Skip") { commit(convert: false) }
                            Button("Live Photo") { playRequest += 1 }
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { deckSize = $0 }
        }
    }

    private func accessibilityLabel(for asset: AssetSummary) -> Text {
        var parts = [L10n.string("Live Photo.")]
        if let date = asset.creationDate { parts.append(Formatters.mediumDate(date)) }
        parts.append(asset.displaySize)
        return Text(parts.joined(separator: ", "))
    }

    // MARK: - Swipe (relayed from CardView, which owns the gesture)

    private func handleDragChanged(_ assetId: String, _ translation: CGSize) {
        // An undo mid-drag puts another card on top: ignore the old gesture.
        guard assetId == deck.current else { return }
        if !motion.isDragging {
            motion.isDragging = true
            HapticHelper.impact(.light)
        }
        motion.offset = translation
    }

    private func handleDragEnded(_ assetId: String, _ value: DragGesture.Value, cardSize: CGSize) {
        motion.isDragging = false
        guard assetId == deck.current,
              let direction = SwipeDirection.resolve(
                translation: value.translation,
                predicted: value.predictedEndTranslation,
                cardWidth: cardSize.width,
                cardHeight: cardSize.height,
                isRightToLeft: isRightToLeft
              ) else {
            snapBack()
            return
        }
        switch direction {
        case .keep: commit(convert: true, velocity: value.velocity)
        case .delete: commit(convert: false, velocity: value.velocity)
        // There is no album or skip-down here.
        case .album, .skip: snapBack()
        }
    }

    /// The one path for every swipe, button, arrow key and VoiceOver action.
    private func commit(convert: Bool, velocity: CGSize = .zero) {
        guard let id = deck.current, let asset = assets[id] else { return }
        motion.isDragging = false
        if convert, !canConvertTopCard {
            // The photo never showed: refuse, as the session deck refuses Delete.
            HapticHelper.notification(.warning)
            snapBack()
            return
        }
        HapticHelper.impact(convert ? .heavy : .light)
        // Forward (right in LTR) converts, the same side the stamp shows.
        let direction: SwipeDirection = convert ? .keep : .delete
        let start = motion.offset
        let target = direction.flingOffset(from: start, distance: flingDistance, isRightToLeft: isRightToLeft)
        let flying = CardMotion(offset: target)
        let fling = Animation.interpolatingSpring(
            duration: 0.35,
            bounce: 0,
            initialVelocity: SwipeDirection.relativeVelocity(velocity, from: start, to: target)
        )
        withAnimation(.reduceMotionAware(fling, reduceMotion: reduceMotion), completionCriteria: .logicallyComplete) {
            departing.removeAll { $0.id == id }
            departing.append(Slot(asset: asset, depth: nil, motion: flying))
            motion.offset = .zero
            deck.decide(convert: convert)
        } completion: {
            departing.removeAll { $0.motion === flying }
        }
        playRequest = 0
    }

    private func undo() {
        guard deck.canUndo else { return }
        HapticHelper.impact(.light)
        deck.undo()
        playRequest = 0
        // The returning card may still be flying out. Animating the offset home
        // lets it travel back from where it is instead of jumping to the center.
        if let id = deck.current, departing.contains(where: { $0.id == id }) {
            withAnimation(.reduceMotionAware(.spring(response: 0.35, dampingFraction: 0.8), reduceMotion: reduceMotion)) {
                motion.offset = .zero
            }
        }
    }

    private func snapBack() {
        withAnimation(.reduceMotionAware(.spring(response: 0.4, dampingFraction: 0.7), reduceMotion: reduceMotion)) {
            motion.offset = .zero
        }
    }

    // MARK: - Buttons

    private var actionBar: some View {
        // Fixed circles: at accessibility sizes pick the widest spacing that fits.
        ViewThatFits(in: .horizontal) {
            actionBarRow(spacing: 40)
            actionBarRow(spacing: Spacing.lg)
            actionBarRow(spacing: Spacing.xs)
        }
    }

    private func actionBarRow(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button { commit(convert: false) } label: {
                actionLabel(systemImage: "livephoto", title: "Skip", size: ScaledSize.actionButton,
                            font: .title2.bold(), fill: Color(.systemGray))
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(deck.isFinished)
            .accessibilityLabel("Skip")

            Button { undo() } label: {
                actionLabel(systemImage: "arrow.uturn.backward", title: "Undo", size: ScaledSize.secondaryActionButton,
                            font: .title3, fill: Color.actionFill)
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!deck.canUndo)
            .opacity(deck.canUndo ? 1 : 0.4)
            .accessibilityLabel("Undo")

            Button { commit(convert: true) } label: {
                actionLabel(systemImage: "livephoto.slash", title: "Convert", size: ScaledSize.actionButton,
                            font: .title2.bold(), fill: Color.successFill)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(deck.isFinished || !canConvertTopCard)
            .opacity(canConvertTopCard ? 1 : 0.4)
            .accessibilityLabel("Convert")
        }
    }

    private func actionLabel(
        systemImage: String,
        title: LocalizedStringKey,
        size: CGFloat,
        font: Font,
        fill: Color
    ) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(.white)
                .scaledSquare(size)
                .background(fill, in: Circle())
            if !dynamicTypeSize.isAccessibilitySize {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.footnoteText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: - Review

    private func reviewPanel(_ ids: [String]) -> some View {
        let marked = deck.markedIds
        let savings = marked.reduce(Int64(0)) { $0 + (assets[$1]?.fileSize ?? 0) / 2 }
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if ids.isEmpty {
                    Text("Nothing marked to convert")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.xxxl)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L10n.format(
                            "%lld Live Photo to convert",
                            fallback: "%lld Live Photos to convert",
                            marked.count
                        ))
                        .font(.headline)
                        Text("est. ~\(savings.formattedFileSize) savings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Spacing.lg)

                    Text(LivePhotoConvertExplainer.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.lg)

                    LazyVGrid(columns: ResponsiveGrid.photo(), spacing: Spacing.xs) {
                        ForEach(ids, id: \.self) { id in
                            if let asset = assets[id] {
                                SelectableMediaGridCell(
                                    asset: asset,
                                    photoService: photoService,
                                    isSelected: deck.decisions[id] == true,
                                    bottomBadgeText: asset.displaySize,
                                    onPreview: { previewId = id },
                                    onToggleSelection: { deck.toggle(id) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xs)
                }
            }
            .padding(.vertical, Spacing.sm)
            .readableWidth()
        }
        .safeAreaInset(edge: .bottom) {
            ActionBarView {
                Spacer(minLength: 0)
                Button {
                    HapticHelper.impact(.medium)
                    onConvert(Set(marked))
                } label: {
                    PrimaryActionLabel(title: "Convert", icon: "livephoto.slash", fill: Color.successFill)
                }
                .disabled(marked.isEmpty)
                .opacity(marked.isEmpty ? 0.5 : 1)
                Spacer(minLength: 0)
            }
        }
    }
}
