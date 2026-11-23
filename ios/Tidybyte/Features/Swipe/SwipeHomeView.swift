import SwiftUI
import SwiftData

struct SwipeHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(LibraryChangeMonitor.self) private var libraryMonitor
    @State private var selectedRoute: SwipeSessionRoute?
    @State private var showAlbumSelection = false
    @State private var pendingAlbumFilter: SwipeFilter?
    @State private var showDateSelection = false
    @State private var pendingDateFilter: SwipeFilter?
    @State private var libraryTotalCount: Int = 0
    @State private var swipedRecordCount: Int = 0

    @AppStorage(AppPreferences.Key.defaultSwipeFilter) private var defaultFilterRaw: String = DefaultSwipeFilterPreference.notSwipedYet.rawValue

    // The service is the app-wide singleton — every surface shares one image
    // cache, so identity survives body re-evals without @State (APP-10/A11).
    private let photoService = PhotoLibraryService.shared

    private var defaultFilterPreference: DefaultSwipeFilterPreference {
        DefaultSwipeFilterPreference(rawValue: defaultFilterRaw) ?? .notSwipedYet
    }

    var body: some View {
        mainContent
        .localizedNavigationTitle("Swipe")
        .navigationDestination(item: $selectedRoute) { route in
            SwipeSessionHostView(
                route: route,
                photoService: photoService,
                modelContext: modelContext
            )
        }
        .onChange(of: appNavigation.swipeDismissRequestID) { _, _ in
            // APP-07: a live session with uncommitted deletions must run its
            // review instead of being torn down here. Nil-ing the route removes
            // the navigationDestination that hosts the session (and anything it
            // pushed), so the review could not survive.
            if let session = appNavigation.activeSwipeSession, session.hasPendingDeletions {
                session.requestDeletionReview()
                return
            }
            selectedRoute = nil
        }
        .onChange(of: appNavigation.pendingSwipeFilter) { _, _ in
            consumePendingFilter()
        }
        .onAppear {
            consumePendingFilter()
        }
        .onChange(of: selectedRoute) { oldRoute, newRoute in
            if oldRoute != nil, newRoute == nil {
                Task { await refreshHomeCounts() }
            }
        }
        .task(id: libraryMonitor.generation) {
            await refreshHomeCounts()
        }
        .sheet(isPresented: $showAlbumSelection, onDismiss: {
            // Start the session only after the sheet has fully dismissed —
            // pushing a navigationDestination while a sheet is dismissing in the
            // same update drops the push.
            if let filter = pendingAlbumFilter {
                pendingAlbumFilter = nil
                startSwipeSession(with: filter)
            }
        }) {
            SwipeAlbumPickerSheet(photoService: photoService) { albumId in
                pendingAlbumFilter = .specificAlbum(id: albumId)
            }
        }
        .sheet(isPresented: $showDateSelection, onDismiss: {
            // Same dismiss-then-push pattern as the album sheet: starting the
            // session during sheet dismissal drops the navigation push.
            if let filter = pendingDateFilter {
                pendingDateFilter = nil
                startSwipeSession(with: filter)
            }
        }) {
            SwipeDateCutoffSheet { cutoff in
                pendingDateFilter = .allMediaBefore(date: cutoff)
            }
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: Spacing.xxl) {
                // Limited access is the state that makes the whole app look
                // broken, so it is surfaced before anything else on the screen.
                LimitedLibraryBanner()
                    .padding(.horizontal, Spacing.lg)

                // Hero header
                heroHeader
                    .fadeSlideIn()

                // Filter cards
                VStack(spacing: Spacing.md) {
                    filterCard(
                        title: "Not Swiped Yet",
                        description: "Photos you haven't reviewed yet",
                        icon: "sparkles",
                        color: .blue,
                        filter: .notSwipedYet,
                        isDefault: defaultFilterPreference == .notSwipedYet
                    )
                    .fadeSlideIn(delay: 0.05)

                    if #available(iOS 18, *) {
                        filterCard(
                            title: "Worst Shots",
                            description: "Review low-scoring photos, lowest first",
                            icon: "camera.metering.unknown",
                            color: .orange,
                            filter: .worstShots,
                            tag: "Scans library"
                        )
                        .fadeSlideIn(delay: 0.08)
                    }

                    filterCard(
                        title: "Largest First",
                        description: "Biggest photos and videos first",
                        icon: "arrow.up.arrow.down",
                        color: .green,
                        filter: .largestFirst,
                        tag: "Scans library"
                    )
                    .fadeSlideIn(delay: 0.09)

                    filterCard(
                        title: "All Media",
                        description: "Start from the beginning — includes skipped items",
                        icon: "photo.on.rectangle.angled",
                        color: .purple,
                        filter: .allMedia,
                        isDefault: defaultFilterPreference == .allMedia,
                        count: libraryTotalCount > 0 ? libraryTotalCount : nil
                    )
                    .fadeSlideIn(delay: 0.1)

                    filterCard(
                        title: "Photos Before a Date",
                        description: "Review photos and videos taken on or before a date",
                        icon: "calendar",
                        color: .indigo,
                        filter: nil,
                        onCustomAction: { showDateSelection = true }
                    )
                    .fadeSlideIn(delay: 0.12)

                    filterCard(
                        title: "Not in Any User Album",
                        description: "Photos not organized into your albums",
                        icon: "folder.badge.questionmark",
                        color: .cyan,
                        filter: .notInAnyAlbum,
                        isDefault: defaultFilterPreference == .notInAnyAlbum
                    )
                    .fadeSlideIn(delay: 0.15)

                    filterCard(
                        title: "Specific Album",
                        description: "Review photos from a specific album",
                        icon: "rectangle.stack",
                        color: .teal,
                        filter: nil
                    )
                    .fadeSlideIn(delay: 0.2)
                }
                .padding(.horizontal, Spacing.lg)
            }
            .padding(.bottom, Spacing.xxl)
            // Cards stop stretching across a landscape iPad.
            .readableWidth()
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                // Stacked card icons
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.blue.opacity(0.3))
                        .frame(width: 40, height: 52)
                        .rotationEffect(.degrees(-12))
                        .offset(x: -8)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(.blue.opacity(0.5))
                        .frame(width: 40, height: 52)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(.blue.opacity(0.8))
                        .frame(width: 40, height: 52)
                        .rotationEffect(.degrees(12))
                        .offset(x: 8)
                }
            }

            VStack(spacing: Spacing.xs) {
                Text("Swipe to Organize")
                    .font(.title.bold())

                Text("Choose a filter to start reviewing your photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if libraryTotalCount > 0, swipedRecordCount > 0 {
                    Text("\(swipedRecordCount) of \(libraryTotalCount) reviewed")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Button {
                HapticHelper.impact(.light)
                startSwipeSession(with: defaultFilterPreference.swipeFilter)
            } label: {
                Label("Start with \(defaultFilterPreference.title)", systemImage: "play.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.sm + 2)
                    .background(Color.actionFill)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .scaleOnPress()
        }
        .padding(.top, Spacing.lg)
    }

    // MARK: - Filter Card

    // `LocalizedStringKey`, not `String`: every call site passes a literal, and
    // a `String` parameter would render it raw instead of resolving it against
    // the environment locale the app injects at the root.
    private func filterCard(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        icon: String,
        color: Color,
        filter: SwipeFilter?,
        isDefault: Bool = false,
        count: Int? = nil,
        tag: LocalizedStringKey? = nil,
        onCustomAction: (() -> Void)? = nil
    ) -> some View {
        Button {
            HapticHelper.impact(.light)
            if let onCustomAction {
                onCustomAction()
            } else if let filter {
                startSwipeSession(with: filter)
            } else {
                // The picker sheet loads its own album list on appear.
                showAlbumSelection = true
            }
        } label: {
            HStack(spacing: Spacing.lg) {
                // Bare glyph in the filter's color: no tile behind it.
                // Fixed-width slot, so every title starts on the same line.
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .scaledSquare(40)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if isDefault {
                            Text("Default")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.actionText)
                                .padding(.horizontal, Spacing.xs + 2)
                                .padding(.vertical, 2)
                                .background(Color.actionText.opacity(0.12), in: Capsule())
                        }
                        if let tag {
                            Text(tag)
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                if let count {
                    Text(verbatim: "\(count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.forward")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .glassCard()
        }
        .scaleOnPress()
        // Reads as one control: the icon, the "Default" pill, the title, and the
        // description would otherwise become four separate VoiceOver stops.
        .accessibilityElement(children: .combine)
    }

    private func refreshHomeCounts() async {
        let total = await photoService.totalAssetCount()
        libraryTotalCount = total
        let records = (try? modelContext.fetch(FetchDescriptor<SwipeRecord>())) ?? []
        if records.isEmpty {
            swipedRecordCount = 0
        } else {
            let ids = records.map(\.assetLocalIdentifier)
            let liveCount = await photoService.existingIds(ids).count
            swipedRecordCount = min(total, liveCount)
        }
    }

    private func startSwipeSession(with filter: SwipeFilter) {
        selectedRoute = SwipeSessionRoute(filter: filter)
    }

    /// Consumes a pending filter set by another tab (e.g., Storage → Swipe deep-link).
    ///
    /// A1 (review-pass fix): the gate must live HERE, not only in
    /// AppNavigation.showSwipeSession. Setting `pendingSwipeFilter` alone made
    /// this observer drain the queue instantly — tearing down a mounted session
    /// with uncommitted deletions even though showSwipeSession had "gated" it.
    /// Now a gated session keeps the filter parked until its review resolves;
    /// SwipeHomeView.onAppear picks it up once the route is gone.
    private func consumePendingFilter() {
        if let session = appNavigation.activeSwipeSession, session.hasPendingDeletions {
            session.requestDeletionReview()
            return
        }
        guard let filter = appNavigation.consumePendingSwipeFilter() else { return }
        // If a previous swipe session is still mounted (no pending deletions),
        // clear it first so the next route builds a fresh view model.
        selectedRoute = nil
        Task { @MainActor in
            await Task.yield()
            startSwipeSession(with: filter)
        }
    }
}

/// Date picker for the "Photos Before a Date" swipe filter. The session
/// starts on sheet dismissal (same pattern as the album picker) so the
/// navigation push isn't dropped while the sheet is still up.
///
/// Co-located with SwipeHomeView instead of its own file so the XcodeGen
/// project doesn't need regenerating to pick up a new source file.
struct SwipeDateCutoffSheet: View {
    /// Called with the chosen cutoff date. The session starts on dismissal.
    let onStart: (Date) -> Void

    @State private var cutoff: Date = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Scrolls, so the note under the calendar is never clipped on a
            // small phone or at large text sizes.
            ScrollView {
            VStack(spacing: Spacing.lg) {
                HStack(spacing: Spacing.sm) {
                    presetButton(title: "6 Months", months: -6)
                    presetButton(title: "1 Year", months: -12)
                    presetButton(title: "3 Years", months: -36)
                }

                DatePicker(
                    "Date",
                    selection: $cutoff,
                    in: ...Date.now,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)

                Text("The session includes every photo and video taken on or before this date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            }
            .localizedNavigationTitle("Photos Before a Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start") {
                        onStart(cutoff)
                        dismiss()
                    }
                    .font(.headline)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func presetButton(title: LocalizedStringKey, months: Int) -> some View {
        let target = Calendar.current.date(byAdding: .month, value: months, to: .now) ?? .now
        let isSelected = Calendar.current.isDate(cutoff, inSameDayAs: target)
        return Button {
            HapticHelper.selection()
            cutoff = target
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.actionFill : Color.cardSurface, in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
