import SwiftUI

/// Which surface `GooglePhotosHomeView` presents across the two Google Photos tabs.
enum GooglePhotosMode: Sendable {
    case cleanup
    case storage
}

/// Wraps a tab's iPhone content with the "iPhone / Google Photos" switch.
/// Every build (Debug and Release) shows the switch only when a valid Google
/// client ID is set, so an unconfigured build has no Google Photos UI at all.
struct MediaSourceGate<Content: View>: View {
    var mode: GooglePhotosMode = .cleanup
    @AppStorage(MediaSource.storageKey) private var source: MediaSource = .iPhone
    @ViewBuilder var content: () -> Content

    private var showsSwitch: Bool { GoogleAuthService.isConfigured }

    var body: some View {
        Group {
            if showsSwitch, source == .googlePhotos {
                GooglePhotosHomeView(mode: mode)
            } else {
                content()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsSwitch {
                Picker("Library", selection: $source) {
                    ForEach(MediaSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .background(.bar)
            }
        }
    }
}

/// The Google Photos source: split across the two tabs (`Storage` shows quota
/// and scan savings insights; `Cleanup` handles Pick & Scan, selection, and review).
struct GooglePhotosHomeView: View {
    var mode: GooglePhotosMode = .cleanup
    /// One model for both tabs, so a scan in Cleanup also shows in Storage.
    @State private var viewModel = GooglePhotosViewModel.shared
    @State private var showReview = false
    @State private var previewItem: CloudMediaItem?
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if !viewModel.isConfigured {
                    EmptyStateView(
                        icon: "cloud",
                        title: "Google Photos Not Set Up",
                        message: "This build has no Google client ID. See ios/docs/google-photos-oauth-setup.md."
                    )
                } else if !viewModel.isSignedIn {
                    signInSection
                } else {
                    switch mode {
                    case .storage:
                        storageSection
                        storageInsightsSection
                    case .cleanup:
                        pickSection
                        if let result = viewModel.result { resultSections(result) }
                    }
                }
            }
            .padding(Spacing.lg)
            .readableWidth()
        }
        .localizedNavigationTitle(mode == .storage ? "Storage" : "Cleanup")
        .toolbar {
            if viewModel.isSignedIn {
                if mode == .cleanup, !viewModel.selectedIds.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Deselect All") {
                            HapticHelper.selection()
                            viewModel.deselectAll()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign Out", role: .destructive) { Task { await viewModel.signOut() } }
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = viewModel.errorMessage {
                ToolErrorBanner(message: .runtimeText(message), onDismiss: { viewModel.errorMessage = nil })
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if mode == .cleanup, !viewModel.selectedIds.isEmpty {
                ActionBarView {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("\(viewModel.selectedIds.count) selected").font(.caption.bold())
                        Text(viewModel.selectedBytes.formattedFileSize).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review") { showReview = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.actionFill)
                }
            }
        }
        .sheet(isPresented: $showReview) {
            GooglePhotosReviewSheet(viewModel: viewModel)
        }
        .fullScreenCover(item: $previewItem) { item in
            CloudMediaPreviewSheet(item: item, thumbnail: viewModel.thumbnail(item.id)) {
                await viewModel.loadPreviewImage(for: item)
            }
        }
        .task { await viewModel.loadQuota() }
    }

    // MARK: - Sections

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Clean up Google Photos")
                .font(.title2.bold())
            Text("Sign in, pick the photos and videos to check, and TidyByte finds duplicates, blurry shots, screenshots, and large videos. TidyByte connects to Google only after you sign in here, and reads only the items you pick. Nothing goes to a TidyByte server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await viewModel.signIn() }
            } label: {
                PrimaryActionLabel(title: "Sign in with Google", icon: "person.crop.circle")
            }
            .scaleOnPress()
        }
        .glassCard()
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Google Account Storage").font(.headline)
                Spacer()
                if viewModel.isLoadingQuota {
                    ProgressView()
                } else {
                    Button {
                        Task { await viewModel.loadQuota() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .accessibilityLabel("Refresh")
                }
            }

            if let quota = viewModel.quota {
                if let limit = quota.limit {
                    ProgressView(value: quota.fractionUsed)
                        .tint(quota.fractionUsed > 0.9 ? Color.destructive : Color.accentColor)
                    Text("\(quota.usage.formattedFileSize) of \(limit.formattedFileSize) used")
                        .font(.subheadline.bold())
                } else {
                    Text("\(quota.usage.formattedFileSize) used").font(.subheadline.bold())
                }
                Text("Photos & Gmail: \(quota.photosAndGmail.formattedFileSize) · Drive: \(quota.usageInDrive.formattedFileSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !viewModel.isLoadingQuota {
                HStack {
                    Text("Unable to load quota.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") {
                        Task { await viewModel.loadQuota() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                SkeletonRow()
            }
        }
        .glassCard()
    }

    @ViewBuilder
    private var storageInsightsSection: some View {
        if let result = viewModel.result {
            let insights = viewModel.visibleInsights
            VStack(alignment: .leading, spacing: Spacing.md) {
                if insights.recoverableBytes > 0 {
                    Text("Up to \(insights.recoverableBytes.formattedFileSize) can be freed in the items you picked")
                        .font(.headline)
                        .foregroundStyle(Color.successText)
                } else if insights.findingCount > 0 {
                    Text(L10n.format("%lld item", fallback: "%lld items", insights.findingCount))
                        .font(.headline)
                        .foregroundStyle(.primary)
                } else {
                    Text("Nothing to clean in the \(result.items.count) items you picked.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: Spacing.sm) {
                    MetadataRow(label: "Duplicates", value: "\(viewModel.visibleDuplicateGroups.count)")
                    MetadataRow(label: "Similar", value: "\(viewModel.visibleSimilarGroups.count)")
                    MetadataRow(label: "Blurry", value: "\(viewModel.visibleBlurryIds.count)")
                    MetadataRow(label: "Screenshots & Recordings", value: "\(viewModel.visibleScreenshotIds.count)")
                    MetadataRow(label: "Large Videos", value: "\(viewModel.visibleLargeVideoIds.count)")
                }

                Button {
                    appNavigation.showCleanup()
                } label: {
                    SecondaryActionLabel(title: "Go to Cleanup Tools", icon: "sparkles")
                }
                .scaleOnPress()
            }
            .glassCard()
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Scan in Cleanup to estimate recoverable Google Photos storage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    appNavigation.showCleanup()
                } label: {
                    PrimaryActionLabel(title: "Go to Cleanup Tools", icon: "sparkles")
                }
                .scaleOnPress()
            }
            .glassCard()
        }
    }

    @ViewBuilder
    private var pickSection: some View {
        switch viewModel.phase {
        case .idle:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Button {
                    viewModel.pickAndScan { openURL($0) }
                } label: {
                    if viewModel.result == nil {
                        PrimaryActionLabel(title: "Pick Photos to Scan", icon: "photo.on.rectangle.angled")
                    } else {
                        SecondaryActionLabel(title: "Pick Again", icon: "photo.on.rectangle.angled")
                    }
                }
                .scaleOnPress()
                Text("Google lets apps read only the items you pick, up to 2,000 at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .waitingForPick:
            HStack(spacing: Spacing.md) {
                ProgressView()
                Text("Pick items in Google Photos, tap Done, then come back.").font(.subheadline)
                Spacer()
                Button("Cancel") { viewModel.cancelPick() }
            }
            .glassCard()
        case .scanning(let value):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Scanning…").font(.subheadline)
                ProgressView(value: value)
            }
            .glassCard()
        }
    }

    @ViewBuilder
    private func resultSections(_ result: CloudScanResult) -> some View {
        groupSection("Duplicates", groups: result.duplicateGroups)
        groupSection("Similar", groups: result.similarGroups)
        itemSection("Blurry", ids: result.blurry)
        itemSection("Screenshots & Recordings", ids: result.screenshots)
        itemSection("Large Videos", ids: result.largeVideos)
        if result.duplicateGroups.isEmpty, result.similarGroups.isEmpty, result.blurry.isEmpty,
           result.screenshots.isEmpty, result.largeVideos.isEmpty {
            Text("Nothing to clean in the \(result.items.count) items you picked.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func groupSection(_ title: LocalizedStringKey, groups: [CloudScanResult.Group]) -> some View {
        let shown = groups.filter { viewModel.visible($0.itemIds).count > 1 }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text(title).font(.headline)
                    Text("\(shown.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Select Extras") { viewModel.selectExtras(in: shown) }.font(.caption.bold())
                }
                ForEach(shown) { group in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(Array(viewModel.visible(group.itemIds).enumerated()), id: \.element) { index, id in
                                tile(id, badge: index == 0 ? "Keep" : nil)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemSection(_ title: LocalizedStringKey, ids: [String]) -> some View {
        let shown = viewModel.visible(ids)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text(title).font(.headline)
                    Text("\(shown.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All") { viewModel.selectAll(shown) }.font(.caption.bold())
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.sm)], spacing: Spacing.sm) {
                    ForEach(shown, id: \.self) { tile($0, badge: nil) }
                }
            }
        }
    }

    private func tile(_ id: String, badge: LocalizedStringKey?) -> some View {
        let selected = viewModel.selectedIds.contains(id)
        let item = viewModel.item(id)
        return ZStack(alignment: .topTrailing) {
            Color.clear
                .frame(width: 96, height: 96)
                .overlay {
                    CloudThumbnail(image: viewModel.thumbnail(id), isVideo: item?.kind == .video)
                }
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                .contentShape(Rectangle())
                .onTapGesture {
                    if let item { previewItem = item } else { viewModel.toggle(id) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(tilePreviewAccessibilityLabel(for: item))
                .accessibilityAction(.default) {
                    if let item { previewItem = item } else { viewModel.toggle(id) }
                }

            Button {
                HapticHelper.selection()
                viewModel.toggle(id)
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.blue : Color.white)
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .padding(Spacing.xs)
                    .frame(minWidth: 36, minHeight: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item?.filename ?? id)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: CornerRadius.small)
                    .strokeBorder(Color.blue, lineWidth: 2)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let badge {
                Text(badge)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xs + 2)
                    .padding(.vertical, 2)
                    .background(Color.successFill, in: Capsule())
                    .padding(Spacing.xs)
            } else if let size = item?.fileSize?.formattedFileSize {
                Text(verbatim: size)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xs + 2)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.68), in: Capsule())
                    .padding(Spacing.xs)
            }
        }
    }
    private func tilePreviewAccessibilityLabel(for item: CloudMediaItem?) -> String {
        if let size = item?.fileSize?.formattedFileSize {
            return item?.kind == .video
                ? L10n.format("Preview video, %@", size)
                : L10n.format("Preview photo, %@", size)
        }
        return L10n.string("Preview")
    }
}

private struct CloudMediaPreviewSheet: View {
    let item: CloudMediaItem
    let thumbnail: UIImage?
    let loadFullImage: @MainActor () async -> UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let displayImage = fullImage ?? thumbnail {
                    Image(uiImage: displayImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.kind == .video ? "video" : "photo")
                        .scaledGlyph(56)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: item.id) {
                fullImage = nil
                fullImage = await loadFullImage()
            }
            .localizedNavigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(verbatim: item.filename)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    HStack {
                        if let date = item.createTime {
                            Text(date, style: .date)
                        }
                        if let size = item.fileSize?.formattedFileSize {
                            Text(verbatim: size)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .background(.ultraThinMaterial)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct CloudThumbnail: View {
    let image: UIImage?
    var isVideo = false

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: isVideo ? "video" : "photo").foregroundStyle(.secondary)
            }
        }
    }
}

/// Google offers no delete API, so the review lists what to delete and hands
/// off to the Google Photos app. TidyByte never deletes cloud items itself.
struct GooglePhotosReviewSheet: View {
    let viewModel: GooglePhotosViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copiedId: String?

    private var ids: [String] {
        viewModel.selectedIds.sorted {
            (viewModel.item($0)?.fileSize ?? 0) > (viewModel.item($1)?.fileSize ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Google does not let other apps delete from Google Photos. Open Google Photos, find these items by date and name, and move them to Trash. Then come back and tap Mark as Deleted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(ids, id: \.self) { id in
                        let item = viewModel.item(id)
                        HStack(spacing: Spacing.md) {
                            CloudThumbnail(image: viewModel.thumbnail(id), isVideo: item?.kind == .video)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(item?.filename ?? "").font(.subheadline).lineLimit(1)
                                if let date = item?.createTime {
                                    Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: Spacing.xs) {
                                Text(item?.fileSize?.formattedFileSize ?? "—")
                                    .font(.subheadline.monospacedDigit())
                                if let filename = item?.filename, !filename.isEmpty {
                                    Button {
                                        UIPasteboard.general.string = filename
                                        copiedId = id
                                        HapticHelper.selection()
                                    } label: {
                                        Image(systemName: copiedId == id ? "checkmark" : "doc.on.doc")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(filename)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Total: \(viewModel.selectedBytes.formattedFileSize)")
                }
            }
            .localizedNavigationTitle("Review \(ids.count) Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Spacing.sm) {
                    Button {
                        openGooglePhotos()
                    } label: {
                        Text("Open Google Photos").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Mark as Deleted") {
                        viewModel.markSelectedDone()
                        dismiss()
                    }
                    .frame(minHeight: 44)
                }
                .padding(Spacing.lg)
                .background(.bar)
            }
        }
    }

    private func openGooglePhotos() {
        let app = URL(string: "googlephotos://")!
        if UIApplication.shared.canOpenURL(app) {
            openURL(app)
        } else {
            openURL(URL(string: "https://photos.google.com/")!)
        }
    }
}
