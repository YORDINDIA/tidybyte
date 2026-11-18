import AppKit
import MacOSCleanerCore
import SwiftUI
import UniformTypeIdentifiers

/// Photos & Media: a native list of tools that pushes each tool's detail.
struct MediaWorkspace: View {
    @Bindable var model: CleanupModel
    @State private var showsPhotosDeniedAlert = false

    private var path: Binding<[CleanupTool]> {
        Binding(
            get: { model.selectedTool.map { [$0] } ?? [] },
            set: { newPath in
                model.selection = []
                model.explicitlySelectedIDs = []
                model.selectedTool = newPath.last
            })
    }

    var body: some View {
        NavigationStack(path: path) {
            home.navigationDestination(for: CleanupTool.self) { tool in
                if tool == .swipe {
                    SwipeReviewView(model: model)
                } else {
                    CleanupToolView(model: model, tool: tool)
                }
            }
        }
        .onAppear { model.refreshPhotoAuthorizationState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPhotoAuthorizationState()
        }
        .alert(String(localized: "Photos Access Denied"), isPresented: $showsPhotosDeniedAlert) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Open Photos Settings…")) { PermissionLinks.openPhotos() }
        } message: {
            Text(
                String(
                    localized: """
                        Tidybyte does not have permission to access your Photos library. \
                        Allow access in System Settings › Privacy & Security › Photos.
                        """
                )
            )
        }
    }

    private var home: some View {
        Form {
            photoPermissionBanners
            if model.result == nil {
                Section {
                    Text(
                        String(
                            localized: """
                                Scan your personal folders and the Photos library for duplicates, \
                                similar shots, and large media. Scanning does not change your files.
                                """))
                    Button(String(localized: "Choose What to Scan…")) { model.showsScope = true }
                } header: {
                    Text(String(localized: "Not Scanned Yet"))
                }
            } else if model.result?.isFresh == false {
                Section {
                    Label(
                        String(localized: "Files changed since the last scan. Scan again to refresh."),
                        systemImage: "arrow.clockwise")
                }
            }
            Section(String(localized: "Review with Swipe")) {
                NavigationLink(value: CleanupTool.swipe) {
                    LabeledContent {
                        Text(model.session == nil ? String(localized: "Start") : String(localized: "Resume"))
                    } label: {
                        Label(CleanupTool.swipe.title, systemImage: CleanupTool.swipe.symbol)
                    }
                }
            }
            ForEach(0..<3, id: \.self) { group in
                Section(groupTitle(group)) {
                    ForEach(CleanupTool.allCases.filter { $0.group == group && $0 != .swipe }) { tool in
                        NavigationLink(value: tool) {
                            LabeledContent {
                                Text(badge(tool)).monospacedDigit()
                            } label: {
                                Label(tool.title, systemImage: tool.symbol)
                            }
                        }
                    }
                }
            }
            if model.result?.isFresh == true { SpaceBuckets(model: model) }
            Section {
            } footer: {
                Text(
                    String(
                        localized: """
                            Analysis runs on this Mac. Files go to Trash. Photos changes use \
                            Recently Deleted and can sync to iCloud.
                            """))
            }
        }
        .formStyle(.grouped)
        .skeletonLoading(model.isBusy)
    }

    @ViewBuilder private var photoPermissionBanners: some View {
        if model.photoAuthorizationState == .limited {
            Section {
                LimitedPhotosAccessBanner(onOpenSettings: { PermissionLinks.openPhotos() })
            }
        } else if model.photoAuthorizationState == .denied && model.scope.includesPhotos {
            Section {
                HStack(alignment: .center, spacing: Spacing.elementNormal) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Photos Access Denied")).font(.headline)
                            Text(
                                String(
                                    localized:
                                        "Allow Photos access in System Settings to scan your library."
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(SemanticScale.error)
                    }
                    Spacer()
                    Button(String(localized: "Open Photos Settings…")) {
                        showsPhotosDeniedAlert = true
                    }
                }
            }
        }
    }

    private func badge(_ tool: CleanupTool) -> String {
        guard model.result?.isFresh == true else { return String(localized: "Not scanned") }
        let items = model.items(for: tool)
        let bytes: Int64 = tool == .livePhotos
            ? items.reduce(0) { $0 + model.livePhotoRecoverableBytes(for: $1) }
            : items.reduce(0) { $0 + $1.bytes }
        return items.isEmpty
            ? String(localized: "None")
            : String(localized: "\(items.count) · \(bytes.formattedByteCount)", comment: "Item count and size")
    }

    private func groupTitle(_ group: Int) -> String {
        switch group {
        case 0: String(localized: "Free Up Space")
        case 1: String(localized: "Review & Organize")
        default: String(localized: "Reclaim Without Deleting")
        }
    }
}

struct LimitedPhotosAccessBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.elementNormal) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Limited Photos Access")).font(.headline)
                    Text(
                        String(
                            localized: """
                                Tidybyte only sees the photos you allowed. Update your selection or \
                                grant Full Access in System Settings.
                                """
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(SemanticScale.warning)
            }
            Spacer()
            Button(String(localized: "Select More Photos…"), action: onOpenSettings)
        }
    }
}

/// Year and source buckets. Each starts a Swipe session for that slice.
/// Also embedded on the Overview dashboard, which navigates to Photos & Media
/// via `onSessionStart`.
struct SpaceBuckets: View {
    @Bindable var model: CleanupModel
    var onSessionStart: (() -> Void)?
    private var items: [ReviewItem] { model.result?.items ?? [] }

    private struct SourceBucket: Identifiable {
        let id: String
        let title: String
        let items: [ReviewItem]
    }

    private var years: [Int] {
        Set(
            items.compactMap {
                ($0.facts.capturedAt ?? $0.createdAt ?? $0.modifiedAt)
                    .map { Calendar.current.component(.year, from: $0) }
            }
        ).sorted().reversed()
    }

    private var sourceBuckets: [SourceBucket] {
        let grouped = Dictionary(grouping: items) { $0.root?.standardizedFileURL.path ?? "photos" }
        let rootNames = grouped.values.compactMap { $0.first?.root?.lastPathComponent }
        let duplicateNames = Set(
            Dictionary(grouping: rootNames, by: { $0 }).filter { $0.value.count > 1 }.keys
        )
        return grouped.map { key, groupItems in
            let title: String
            if let root = groupItems.first?.root {
                let name = root.lastPathComponent
                let parent = root.deletingLastPathComponent().lastPathComponent
                title = duplicateNames.contains(name) && !parent.isEmpty ? "\(parent)/\(name)" : name
            } else {
                title = String(localized: "Photos Library")
            }
            return SourceBucket(id: key, title: title, items: groupItems)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Section(String(localized: "By Year")) {
            ForEach(years, id: \.self) { year in
                bucket(String(year), items.filter {
                    ($0.facts.capturedAt ?? $0.createdAt ?? $0.modifiedAt)
                        .map { Calendar.current.component(.year, from: $0) } == year
                })
            }
        }
        Section(String(localized: "By Location")) {
            ForEach(sourceBuckets) { source in
                bucket(source.title, source.items)
            }
        }
    }

    private func bucket(_ title: String, _ items: [ReviewItem]) -> some View {
        Button {
            Task {
                await model.startSession(items: items)
                guard model.session != nil else { return }
                model.selectedTool = .swipe
                onSessionStart?()
            }
        } label: {
            LabeledContent(title, value: items.reduce(Int64(0)) { $0 + $1.bytes }.formattedByteCount)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .disabled(model.session != nil)
        .help(String(localized: "Review these files one by one"))
    }
}

extension CleanupTool {
    var symbol: String {
        switch self {
        case .duplicates: "square.on.square"
        case .similar: "photo.stack"
        case .blurry: "camera.aperture"
        case .large: "externaldrive"
        case .bursts: "square.stack.3d.down.right"
        case .screenRecordings: "record.circle"
        case .screenshots: "camera.viewfinder"
        case .categories: "tag"
        case .downloads: "arrow.down.circle"
        case .videoCompression: "film"
        case .imageCompression: "photo"
        case .formatPairs: "rectangle.on.rectangle.angled"
        case .livePhotos: "livephoto"
        case .swipe: "hand.draw"
        }
    }
}

struct CleanupScopeView: View {
    @Bindable var model: CleanupModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsPicker = false
    @State private var requestedRoot: URL?
    @State private var scope: ReviewScope
    @State private var showsPhotosDeniedAlert = false

    init(model: CleanupModel) {
        self.model = model
        _scope = State(initialValue: model.scope)
    }

    var body: some View {
        VStack {
            scopeForm
            HStack {
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Scan")) {
                    model.scope = scope
                    model.scan()
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || (scope.roots.isEmpty && !scope.includesPhotos))
            }.padding(Spacing.cardPadding)
        }
        .frame(minWidth: 560, minHeight: 480)
        .presentationSizing(.form)
        .onAppear { model.refreshPhotoAuthorizationState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPhotoAuthorizationState()
        }
        .onChange(of: scope.mode) { _, mode in
            scope.roots =
                mode == .fullMac
                ? ReviewScope.presetFolders.map { ReviewSafety.userHome.appendingPathComponent($0) } : []
            scope.exportedChatFolder = nil
            if mode == .folder { scope.includesPhotos = false }
        }
        .onChange(of: scope.includesPhotos) { _, enabled in
            if enabled && model.photoAuthorizationState == .denied {
                showsPhotosDeniedAlert = true
            }
        }
        .alert(String(localized: "Photos Access Denied"), isPresented: $showsPhotosDeniedAlert) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Open Photos Settings…")) { PermissionLinks.openPhotos() }
        } message: {
            Text(
                String(
                    localized: """
                        Photos access was denied. Enable Tidybyte in System Settings › Privacy & Security › Photos \
                        to scan your Photos library.
                        """
                )
            )
        }
        .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.folder]) { handleFolderImport($0) }
    }

    private var scopeForm: some View {
        Form {
            Picker(String(localized: "Mode"), selection: $scope.mode) {
                Text(String(localized: "Folder Mode")).tag(ReviewMode.folder)
                Text(String(localized: "Full Mac Mode")).tag(ReviewMode.fullMac)
            }.pickerStyle(.segmented)
            if scope.mode == .folder {
                Text(scope.roots.first?.path ?? String(localized: "No folder selected"))
                Button(String(localized: "Choose Folder…")) {
                    requestedRoot = nil
                    showsPicker = true
                }
                Text(String(localized: "Includes nested files. Hidden files and protected folders are excluded."))
                    .font(.caption)
            } else {
                ForEach(ReviewScope.presetFolders, id: \.self) { name in
                    presetFolderRow(name)
                }
                Toggle(String(localized: "Include System Photos Library"), isOn: $scope.includesPhotos)
                if scope.includesPhotos && model.photoAuthorizationState == .limited {
                    LimitedPhotosAccessBanner(onOpenSettings: { PermissionLinks.openPhotos() })
                }
                Text(
                    String(
                        localized: """
                            Photos access uses Apple's library API. Library packages are never \
                            scanned as folders.
                            """
                    )
                )
                .font(.caption)
            }
            Text(
                String(
                    localized: """
                        Full Mac Mode covers these personal folders. It does not scan system \
                        or application folders. Folder access can be changed in System Settings.
                        """
                )
            )
            .foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    private func presetFolderRow(_ name: String) -> some View {
        let url = ReviewSafety.userHome.appendingPathComponent(name)
        return HStack {
            Toggle(
                name,
                isOn: Binding(
                    get: { scope.roots.contains(url) },
                    set: { enabled in
                        scope.roots.removeAll { $0 == url }
                        if enabled { scope.roots.append(url) }
                    }))
            Button(String(localized: "Grant access…")) {
                requestedRoot = url
                showsPicker = true
            }
        }
    }

    private func handleFolderImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            if let requestedRoot, requestedRoot.standardizedFileURL != url.standardizedFileURL {
                model.error = String(
                    localized: "Choose the \(requestedRoot.lastPathComponent) folder to grant access.")
            } else {
                Task {
                    do {
                        try await model.access.grant(url)
                        if scope.mode == .folder {
                            scope.roots = [url]
                            scope.exportedChatFolder = nil
                        } else if !scope.roots.contains(url) {
                            scope.roots.append(url)
                        }
                    } catch { model.error = error.localizedDescription }
                }
            }
        case .failure(let error):
            model.error = error.localizedDescription
        }
    }
}
