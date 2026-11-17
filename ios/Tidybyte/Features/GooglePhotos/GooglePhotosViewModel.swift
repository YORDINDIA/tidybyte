import SwiftUI
import UIKit

/// Which library the Cleanup and Storage tabs work on.
enum MediaSource: String, CaseIterable, Identifiable {
    case iPhone, googlePhotos
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .iPhone: "iPhone"
        case .googlePhotos: "Google Photos"
        }
    }
    static let storageKey = "mediaSource"
}

@Observable
@MainActor
final class GooglePhotosViewModel {
    static let shared = GooglePhotosViewModel()
    enum Phase: Equatable {
        case idle
        case waitingForPick
        case scanning(Double)
    }

    private let auth = GoogleAuthService.shared
    private let api = GooglePhotosAPI()
    private let scanner = GooglePhotosScanner()

    private(set) var isSignedIn = GoogleAuthService.shared.isSignedIn
    private(set) var quota: GoogleStorageQuota?
    private(set) var isLoadingQuota = false
    private(set) var phase: Phase = .idle
    private(set) var result: CloudScanResult?
    var selectedIds: Set<String> = []
    /// Items the user marked as deleted in Google Photos.
    private(set) var doneIds: Set<String> = []
    var errorMessage: String?
    private var pickTask: Task<Void, Never>?
    /// Bumped on sign-out. A pick or scan keeps the value it started with and
    /// writes no state once it no longer matches, so an old account's results
    /// cannot land after sign-out.
    private var sessionGeneration = 0
    private var quotaGeneration: Int?

    var isConfigured: Bool { GoogleAuthService.isConfigured }

    func signIn() async {
        errorMessage = nil
        do {
            try await auth.signIn()
            sessionGeneration += 1
            isSignedIn = auth.isSignedIn
            await loadQuota()
        } catch GoogleAuthError.cancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        // Before the first await: the in-flight pick/scan must see the new
        // generation before it can write anything.
        sessionGeneration += 1
        pickTask?.cancel()
        pickTask = nil
        phase = .idle
        guard await auth.signOut() else {
            // The tokens stay on this device, so the account is still signed in.
            errorMessage = L10n.string("Couldn't sign out of Google. Check your connection and try again.")
            return
        }
        clearAccountState()
    }

    func loadQuota() async {
        guard isSignedIn else { return }
        let generation = sessionGeneration
        if isLoadingQuota && quotaGeneration == generation { return }
        quotaGeneration = generation
        isLoadingQuota = true
        defer {
            if quotaGeneration == generation { isLoadingQuota = false }
        }
        do {
            let fetched = try await api.storageQuota()
            guard generation == sessionGeneration else { return }
            quota = fetched
        } catch {
            guard generation == sessionGeneration else { return }
            handle(error)
        }
    }

    func loadPreviewImage(for item: CloudMediaItem) async -> UIImage? {
        guard isSignedIn else { return nil }
        let generation = sessionGeneration
        guard let data = try? await api.thumbnailData(of: item, size: 1600),
              generation == sessionGeneration else {
            return nil
        }
        return UIImage(data: data)
    }

    func deselectAll() {
        selectedIds.removeAll()
    }

    /// Opens the Google Photos Picker, waits for the user to finish, then scans.
    func pickAndScan(openURL: @escaping (URL) -> Void) {
        guard pickTask == nil else { return }
        errorMessage = nil
        let generation = sessionGeneration
        pickTask = Task {
            // Only the current session may clear shared pick state: after a
            // sign-out, `pickTask` may already belong to a newer pick.
            defer {
                if generation == sessionGeneration {
                    pickTask = nil
                    if case .waitingForPick = phase { phase = .idle }
                }
            }
            do {
                let session = try await api.createSession()
                guard let uri = session.pickerUri, let url = URL(string: uri + "/autoclose") else {
                    throw GoogleAuthError.failed(L10n.string("Google did not return a picker link."))
                }
                guard generation == sessionGeneration else { return }
                phase = .waitingForPick
                openURL(url)
                let interval = GooglePhotosAPI.PickerSession.seconds(session.pollingConfig?.pollInterval) ?? 3
                let timeout = GooglePhotosAPI.PickerSession.seconds(session.pollingConfig?.timeoutIn) ?? 1800
                let deadline = Date().addingTimeInterval(timeout)
                var picked = false
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(for: .seconds(max(1, interval)))
                    if try await api.session(id: session.id).mediaItemsSet == true { picked = true; break }
                }
                guard picked else { await api.deleteSession(id: session.id); return }
                let items = try await api.mediaItems(sessionId: session.id)
                await api.deleteSession(id: session.id)
                guard generation == sessionGeneration else { return }
                phase = .scanning(0)
                let scan = await scanner.scan(items) { value in
                    if self.sessionGeneration == generation { self.phase = .scanning(value) }
                }
                // Signed out during the scan: these results belong to the old account.
                guard generation == sessionGeneration else { return }
                result = scan
                selectedIds = []
                doneIds = []
                phase = .idle
                await loadQuota()
            } catch is CancellationError {
                if generation == sessionGeneration { phase = .idle }
            } catch {
                // An error from a cancelled, signed-out session is not news to the user.
                guard generation == sessionGeneration else { return }
                phase = .idle
                handle(error)
            }
        }
    }

    func cancelPick() {
        pickTask?.cancel()
        phase = .idle
    }

    /// Ids in a section, minus items the user already marked done.
    func visible(_ ids: [String]) -> [String] { ids.filter { !doneIds.contains($0) } }

    struct VisibleInsights: Equatable, Sendable {
        let recoverableBytes: Int64
        let findingCount: Int
        let hasUnknownSizes: Bool
    }

    var visibleDuplicateGroups: [CloudScanResult.Group] {
        result?.duplicateGroups.filter { visible($0.itemIds).count > 1 } ?? []
    }

    var visibleSimilarGroups: [CloudScanResult.Group] {
        result?.similarGroups.filter { visible($0.itemIds).count > 1 } ?? []
    }

    var visibleBlurryIds: [String] { visible(result?.blurry ?? []) }
    var visibleScreenshotIds: [String] { visible(result?.screenshots ?? []) }
    var visibleLargeVideoIds: [String] { visible(result?.largeVideos ?? []) }

    var visibleInsights: VisibleInsights {
        guard let result else { return VisibleInsights(recoverableBytes: 0, findingCount: 0, hasUnknownSizes: false) }
        return Self.visibleInsights(for: result, excluding: doneIds)
    }

    static func visibleInsights(for result: CloudScanResult, excluding doneIds: Set<String>) -> VisibleInsights {
        var candidateIds = Set<String>()
        for group in result.duplicateGroups {
            let shown = group.itemIds.filter { !doneIds.contains($0) }
            if shown.count > 1 { candidateIds.formUnion(shown.dropFirst()) }
        }
        for group in result.similarGroups {
            let shown = group.itemIds.filter { !doneIds.contains($0) }
            if shown.count > 1 { candidateIds.formUnion(shown.dropFirst()) }
        }
        candidateIds.formUnion(result.blurry.filter { !doneIds.contains($0) })
        candidateIds.formUnion(result.screenshots.filter { !doneIds.contains($0) })
        candidateIds.formUnion(result.largeVideos.filter { !doneIds.contains($0) })

        var bytes: Int64 = 0
        var unknown = false
        for id in candidateIds {
            if let size = result.items[id]?.fileSize {
                bytes += size
            } else {
                unknown = true
            }
        }
        return VisibleInsights(recoverableBytes: bytes, findingCount: candidateIds.count, hasUnknownSizes: unknown)
    }

    func item(_ id: String) -> CloudMediaItem? { result?.items[id] }
    func thumbnail(_ id: String) -> UIImage? { result?.thumbnails[id] }

    func toggle(_ id: String) { selectedIds.toggle(id) }

    /// Selects every extra copy in the groups, keeping the first (best) one.
    func selectExtras(in groups: [CloudScanResult.Group]) {
        for group in groups { selectedIds.formUnion(visible(Array(group.itemIds.dropFirst()))) }
    }

    func selectAll(_ ids: [String]) { selectedIds.formUnion(visible(ids)) }

    var selectedBytes: Int64 { selectedIds.reduce(0) { $0 + (item($1)?.fileSize ?? 0) } }

    /// The user deleted these in Google Photos: drop them from the results.
    func markSelectedDone() {
        doneIds.formUnion(selectedIds)
        selectedIds = []
    }

    /// Drops everything that belongs to the signed-in account. Shared by sign-out
    /// and the signed-out error, so the two cannot drift apart.
    private func clearAccountState() {
        isSignedIn = false
        quotaGeneration = nil
        isLoadingQuota = false
        result = nil
        quota = nil
        selectedIds = []
        doneIds = []
    }

    private func handle(_ error: Error) {
        if case GoogleAuthError.signedOut = error {
            clearAccountState()
        }
        errorMessage = error.localizedDescription
    }
}
