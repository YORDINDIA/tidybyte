import MacOSCleanerCore
import os
@preconcurrency import Photos
import PhotosUI
import SwiftUI

/// Reusable intelligence & protection pill badges for media items.
struct MediaIntelligencePills: View {
    let item: ReviewItem
    var bestReason: String?
    var isBest = false
    var showReviewReason = false

    var body: some View {
        let pills = buildPills()
        if !pills.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pills) { pill in
                        Label(pill.title, systemImage: pill.symbol)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundStyle(pill.tint)
                            .background(pill.tint.opacity(0.14), in: Capsule())
                    }
                }
            }
        }
    }

    private struct Pill: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let tint: Color
    }

    private func buildPills() -> [Pill] {
        var result: [Pill] = []
        if isBest {
            let title = bestReason.map { String(localized: "Best · \($0)") } ?? String(localized: "Best Shot")
            result.append(Pill(id: "best", title: title, symbol: "star.fill", tint: SemanticScale.success))
        }
        if item.isFavorite {
            result.append(Pill(id: "fav", title: String(localized: "Favorite"), symbol: "heart.fill", tint: .pink))
        }
        if item.isBurstPick {
            result.append(
                Pill(
                    id: "burst", title: String(localized: "Burst Pick"),
                    symbol: "square.stack.3d.down.right.fill", tint: .blue))
        }
        if item.facts.hasLensSmudge {
            result.append(
                Pill(
                    id: "smudge", title: String(localized: "Lens Smudge"),
                    symbol: "exclamationmark.triangle.fill", tint: SemanticScale.warning))
        }
        if let app = item.facts.savedFromApp {
            result.append(
                Pill(
                    id: "app", title: String(localized: "From \(app)"),
                    symbol: "square.and.arrow.down", tint: .teal))
        }
        if let score = item.facts.aestheticsScore {
            let formatted = score.formatted(.number.precision(.fractionLength(2)))
            result.append(
                Pill(
                    id: "aesthetics",
                    title: String(localized: "Score \(formatted)"),
                    symbol: "sparkles",
                    tint: score >= 0 ? .purple : SemanticScale.warning))
        }
        if item.isHEIC {
            result.append(Pill(id: "heic", title: "HEIC", symbol: "photo", tint: .secondary))
        }
        if showReviewReason, let reason = item.facts.reviewReason {
            result.append(Pill(id: "reason", title: reason, symbol: "info.circle", tint: .secondary))
        }
        return result
    }
}

/// Live Photo playback card using AppKit/PhotosUI `PHLivePhotoView`.
struct LivePhotoPlayerCard: View {
    let item: ReviewItem
    @State private var livePhoto: PHLivePhoto?
    @State private var isPlaying = false
    @State private var isMuted = true
    @State private var playbackToken = 0
    @State private var loadError: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let livePhoto {
                NativeLivePhotoView(
                    livePhoto: livePhoto,
                    isMuted: isMuted,
                    playbackToken: playbackToken,
                    isPlaying: $isPlaying
                )
            } else if let loadError {
                ContentUnavailableView(
                    String(localized: "Live Photo unavailable"),
                    systemImage: "livephoto.slash",
                    description: Text(loadError))
            } else {
                ProgressView(String(localized: "Loading Live Photo…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 6) {
                Label(
                    isPlaying ? String(localized: "Playing Live") : String(localized: "LIVE"),
                    systemImage: isPlaying ? "livephoto.play" : "livephoto"
                )
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

                if livePhoto != nil {
                    Button {
                        playbackToken += 1
                    } label: {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? String(localized: "Stop Live playback") : String(localized: "Play Live Photo"))

                    Button {
                        isMuted.toggle()
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.plain)
                    .help(isMuted ? String(localized: "Unmute") : String(localized: "Mute"))
                }
            }
            .padding(Spacing.elementTight)
        }
        .task(id: item.reviewKey) { await loadLivePhoto() }
        .onDisappear {
            livePhoto = nil
            isPlaying = false
        }
    }

    private func loadLivePhoto() async {
        livePhoto = nil
        loadError = nil
        isPlaying = false
        guard let photoID = item.photoID,
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject
        else {
            loadError = String(localized: "Photos asset unavailable.")
            return
        }
        do {
            let loaded = try await LivePhotoLoader.load(asset: asset, targetSize: CGSize(width: 1200, height: 1200))
            guard !Task.isCancelled else { return }
            livePhoto = loaded.value
            playbackToken += 1
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }
}

private struct UncheckedLivePhoto: @unchecked Sendable {
    let value: PHLivePhoto?
}

private enum LivePhotoLoader {
    private final class PendingRequest: @unchecked Sendable {
        private struct State {
            var requestID: PHImageRequestID = PHInvalidImageRequestID
            var cancelled = false
            var continuation: CheckedContinuation<UncheckedLivePhoto, Error>?
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())

        func store(_ continuation: CheckedContinuation<UncheckedLivePhoto, Error>) {
            let alreadyCancelled = lock.withLock { state -> Bool in
                if state.cancelled { return true }
                state.continuation = continuation
                return false
            }
            if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
        }

        func setRequestID(_ id: PHImageRequestID) {
            let cancelNow = lock.withLock { state -> Bool in
                state.requestID = id
                return state.cancelled
            }
            if cancelNow, id != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(id)
            }
        }

        func complete(livePhoto: PHLivePhoto?, error: Error?) {
            let continuation = lock.withLock { state -> CheckedContinuation<UncheckedLivePhoto, Error>? in
                let pending = state.continuation
                state.continuation = nil
                return pending
            }
            if let error {
                continuation?.resume(throwing: error)
            } else if let livePhoto {
                continuation?.resume(returning: UncheckedLivePhoto(value: livePhoto))
            } else {
                continuation?.resume(throwing: CleanupError.message(String(localized: "Live Photo unavailable.")))
            }
        }

        func cancel() {
            let (requestID, continuation) = lock.withLock { state -> (PHImageRequestID, CheckedContinuation<UncheckedLivePhoto, Error>?) in
                state.cancelled = true
                let pending = state.continuation
                state.continuation = nil
                return (state.requestID, pending)
            }
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    static func load(asset: PHAsset, targetSize: CGSize) async throws -> UncheckedLivePhoto {
        let pending = PendingRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let options = PHLivePhotoRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat
                pending.store(continuation)
                let requestID = PHImageManager.default().requestLivePhoto(
                    for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
                ) { photo, info in
                    if info?[PHLivePhotoInfoCancelledKey] as? Bool == true { return }
                    if info?[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                    let error = info?[PHLivePhotoInfoErrorKey] as? Error
                    pending.complete(livePhoto: photo, error: error)
                }
                pending.setRequestID(requestID)
            }
        } onCancel: {
            pending.cancel()
        }
    }
}

private struct NativeLivePhotoView: NSViewRepresentable {
    let livePhoto: PHLivePhoto
    let isMuted: Bool
    let playbackToken: Int
    @Binding var isPlaying: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isPlaying: $isPlaying) }

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .aspectFit
        view.delegate = context.coordinator
        view.isMuted = isMuted
        view.livePhoto = livePhoto
        return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.stopPlayback(animated: false)
            view.livePhoto = livePhoto
        }
        view.isMuted = isMuted
        if context.coordinator.lastToken != playbackToken {
            context.coordinator.lastToken = playbackToken
            if context.coordinator.currentlyPlaying {
                view.stopPlayback(animated: true)
            } else {
                view.startPlayback(with: .full)
            }
        }
    }

    static func dismantleNSView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback(animated: false)
        view.livePhoto = nil
        view.delegate = nil
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        @Binding var isPlaying: Bool
        var currentlyPlaying = false
        var lastToken = 0

        init(isPlaying: Binding<Bool>) {
            _isPlaying = isPlaying
        }

        func livePhotoView(
            _ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle
        ) {
            currentlyPlaying = true
            isPlaying = true
        }

        func livePhotoView(
            _ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle
        ) {
            currentlyPlaying = false
            isPlaying = false
        }
    }
}
