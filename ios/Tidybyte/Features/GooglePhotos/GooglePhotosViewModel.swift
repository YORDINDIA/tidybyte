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
    private(set) var phase: Phase = .idle
    private(set) var result: CloudScanResult?
    var selectedIds: Set<String> = []
    /// Items the user marked as deleted in Google Photos.
    private(set) var doneIds: Set<String> = []
    var errorMessage: String?
    private var pickTask: Task<Void, Never>?

    var isConfigured: Bool { GoogleAuthService.isConfigured }

    func signIn() async {
        errorMessage = nil
        do {
            try await auth.signIn()
            isSignedIn = auth.isSignedIn
            await loadQuota()
        } catch GoogleAuthError.cancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        pickTask?.cancel()
        await auth.signOut()
        isSignedIn = false
        quota = nil
        result = nil
        selectedIds = []
        doneIds = []
        phase = .idle
    }

    func loadQuota() async {
        guard isSignedIn else { return }
        do {
            quota = try await api.storageQuota()
        } catch {
            handle(error)
        }
    }

    /// Opens the Google Photos Picker, waits for the user to finish, then scans.
    func pickAndScan(openURL: @escaping (URL) -> Void) {
        guard pickTask == nil else { return }
        errorMessage = nil
        pickTask = Task {
            defer { pickTask = nil; if case .waitingForPick = phase { phase = .idle } }
            do {
                let session = try await api.createSession()
                guard let uri = session.pickerUri, let url = URL(string: uri + "/autoclose") else {
                    throw GoogleAuthError.failed(L10n.string("Google did not return a picker link."))
                }
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
                phase = .scanning(0)
                let scan = await scanner.scan(items) { [weak self] value in self?.phase = .scanning(value) }
                result = scan
                selectedIds = []
                doneIds = []
                phase = .idle
                await loadQuota()
            } catch is CancellationError {
                phase = .idle
            } catch {
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

    private func handle(_ error: Error) {
        if case GoogleAuthError.signedOut = error {
            isSignedIn = false
            result = nil
        }
        errorMessage = error.localizedDescription
    }
}
