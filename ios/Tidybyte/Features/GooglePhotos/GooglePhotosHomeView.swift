import SwiftUI

/// Wraps a tab's iPhone content with the "iPhone / Google Photos" switch.
/// Release builds show the switch only when a Google client ID is set, so an
/// unconfigured build looks exactly like before.
struct MediaSourceGate<Content: View>: View {
    @AppStorage(MediaSource.storageKey) private var source: MediaSource = .iPhone
    @ViewBuilder var content: () -> Content

    private var showsSwitch: Bool {
        #if DEBUG
        true
        #else
        GoogleAuthService.isConfigured
        #endif
    }

    var body: some View {
        Group {
            if showsSwitch, source == .googlePhotos {
                GooglePhotosHomeView()
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

/// The Google Photos source: sign in, storage, pick-and-scan, results, review.
struct GooglePhotosHomeView: View {
    /// One model for both tabs, so a scan in Cleanup also shows in Storage.
    @State private var viewModel = GooglePhotosViewModel.shared
    @State private var showReview = false
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
                    storageSection
                    pickSection
                    if let result = viewModel.result { resultSections(result) }
                }
            }
            .padding(Spacing.lg)
        }
        .localizedNavigationTitle("Google Photos")
        .toolbar {
            if viewModel.isSignedIn {
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
            if !viewModel.selectedIds.isEmpty {
                ActionBarView {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("\(viewModel.selectedIds.count) selected").font(.caption.bold())
                        Text(viewModel.selectedBytes.formattedFileSize).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review") { showReview = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showReview) {
            GooglePhotosReviewSheet(viewModel: viewModel)
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
                Text("Sign in with Google")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Google Account Storage").font(.headline)
            if let quota = viewModel.quota {
                if let limit = quota.limit {
                    ProgressView(value: quota.fractionUsed)
                    Text("\(quota.usage.formattedFileSize) of \(limit.formattedFileSize) used")
                        .font(.subheadline)
                } else {
                    Text("\(quota.usage.formattedFileSize) used").font(.subheadline)
                }
                Text("Photos & Gmail: \(quota.photosAndGmail.formattedFileSize) · Drive: \(quota.usageInDrive.formattedFileSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let result = viewModel.result, result.recoverableBytes > 0 {
                    Text("Up to \(result.recoverableBytes.formattedFileSize) can be freed in the items you picked")
                        .font(.caption.bold())
                        .foregroundStyle(Color.success)
                }
            } else {
                ProgressView()
            }
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
                    Label(viewModel.result == nil ? "Pick Photos to Scan" : "Pick Again", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
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
        case .scanning(let value):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Scanning…").font(.subheadline)
                ProgressView(value: value)
            }
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
        return Button {
            HapticHelper.selection()
            viewModel.toggle(id)
        } label: {
            ZStack(alignment: .topTrailing) {
                CloudThumbnail(image: viewModel.thumbnail(id), isVideo: item?.kind == .video)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.blue : Color.white)
                    .padding(Spacing.xs)
            }
            .overlay(alignment: .bottomLeading) {
                Text(badge ?? LocalizedStringKey(item?.fileSize?.formattedFileSize ?? ""))
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(Spacing.xs)
                    .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item?.filename ?? id)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
                            Text(item?.fileSize?.formattedFileSize ?? "—")
                                .font(.subheadline.monospacedDigit())
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
