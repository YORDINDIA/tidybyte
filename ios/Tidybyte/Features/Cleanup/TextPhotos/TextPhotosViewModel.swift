import SwiftUI

/// How old a text photo must be to show. Notes, tickets, receipts and boards
/// go out of date within weeks, so the results start a month back by default.
enum TextPhotoAge: String, CaseIterable, Sendable {
    case twoWeeks, oneMonth, threeMonths, oneYear

    var displayName: String {
        switch self {
        case .twoWeeks: L10n.string("Older than 2 weeks")
        case .oneMonth: L10n.string("Older than 1 month")
        case .threeMonths: L10n.string("Older than 3 months")
        case .oneYear: L10n.string("Older than 1 year")
        }
    }

    /// Photos taken on or before this date are old enough.
    func cutoff(from now: Date, calendar: Calendar = .current) -> Date {
        let (component, value): (Calendar.Component, Int) = switch self {
        case .twoWeeks: (.day, -14)
        case .oneMonth: (.month, -1)
        case .threeMonths: (.month, -3)
        case .oneYear: (.year, -1)
        }
        return calendar.date(byAdding: component, value: value, to: now) ?? now
    }
}

/// What counts as a text photo, kept pure so it can be tested.
enum TextPhotoPolicy {
    /// The scan reads only photos at least this old: the youngest age choice.
    static let scanAge = TextPhotoAge.twoWeeks

    /// "A lot of text": a page, a board, a ticket or a receipt, not a sign or a
    /// label. Either many characters, or several lines of a fair amount.
    nonisolated static func isTextHeavy(_ amount: TextAmount) -> Bool {
        amount.succeeded
            && (amount.characterCount >= 80 || (amount.lineCount >= 4 && amount.characterCount >= 40))
    }

    /// Screenshots have their own tool, and a favorite is a photo the user
    /// chose to keep. A photo with no date cannot be shown to be old.
    nonisolated static func isCandidate(_ asset: AssetSummary, cutoff: Date) -> Bool {
        guard !asset.isScreenshot, !asset.isFavorite, let date = asset.creationDate else { return false }
        return date <= cutoff
    }
}

struct TextPhoto: Identifiable, Sendable {
    let id: String
    let asset: AssetSummary
    let characterCount: Int
}

@Observable
@MainActor
final class TextPhotosViewModel {
    /// Every text photo the scan found, at least `TextPhotoPolicy.scanAge` old.
    var photos: [TextPhoto] = [] {
        didSet { refreshVisible() }
    }
    var scanState: ScanState = .idle
    /// Narrows the results without a new scan.
    var age: TextPhotoAge = .oneMonth {
        didSet { refreshVisible() }
    }
    /// Oldest first: the most out-of-date photos lead.
    var sortOrder: MediaSortOrder = .oldest {
        didSet { refreshVisible() }
    }
    static let sortOptions: [MediaSortOrder] = [.oldest, .newest, .largest]
    var errorMessage: String?
    var isDeleting = false
    var selectedIds: Set<String> = []
    private(set) var deletedCount = 0
    private(set) var skippedAnalysisCount = 0
    /// The results for the chosen age, in the chosen order.
    private(set) var visiblePhotos: [TextPhoto] = []

    private let scanRunner = ScanRunner()
    private let photoService = PhotoLibraryService.shared
    private let visionService = VisionAnalysisService()
    /// Fixed for a scan's results, so the age choice compares against one moment.
    private var scanDate = Date()

    var selectedSize: Int64 {
        visiblePhotos.totalFileSize(selectedIds: selectedIds, idOf: \.id, sizeOf: { $0.asset.fileSize })
    }

    var allVisibleSelected: Bool {
        !visiblePhotos.isEmpty && visiblePhotos.allSatisfy { selectedIds.contains($0.id) }
    }

    /// The photos shown for `age`, in `sortOrder`. Pure, for tests.
    nonisolated static func visible(_ photos: [TextPhoto], age: TextPhotoAge, now: Date, order: MediaSortOrder) -> [TextPhoto] {
        let cutoff = age.cutoff(from: now)
        return order.sorted(photos.filter { ($0.asset.creationDate ?? .distantFuture) <= cutoff }, asset: \.asset)
    }

    private func refreshVisible() {
        visiblePhotos = Self.visible(photos, age: age, now: scanDate, order: sortOrder)
        // A pick the age filter hides must not be deleted unseen.
        selectedIds.formIntersection(visiblePhotos.map(\.id))
        if scanState == .completed { ScanResults.record(.textPhotos, count: visiblePhotos.count) }
    }

    func startScan() {
        scanRunner.start { [weak self] token in
            await self?.scan(token: token)
        }
    }

    func cancelScan() {
        guard scanRunner.isRunning else { return }
        scanRunner.cancel()
        if case .scanning = scanState {
            scanState = .idle
        }
    }

    func scan(token: Int) async {
        guard scanRunner.isCurrent(token) else { return }
        // Captured before any await, so a library change during the scan drops
        // this run's count instead of publishing a pre-change one.
        let scanEpoch = ScanResults.epoch
        scanDate = Date()
        scanState = .scanning(0)
        photos = []
        selectedIds.removeAll()
        skippedAnalysisCount = 0
        deletedCount = 0
        pendingPrune = false

        let cutoff = TextPhotoPolicy.scanAge.cutoff(from: scanDate)
        let candidates = await photoService.fetchAllPhotos().filter { TextPhotoPolicy.isCandidate($0, cutoff: cutoff) }
        let total = candidates.count
        let phById = photoService.phAssetsById(candidates.map(\.id))
        var found: [TextPhoto] = []

        for (index, photo) in candidates.enumerated() {
            if Task.isCancelled { return }
            if index % 20 == 0 { await Task.yield() }

            // 1024 pt: small print on a page or a ticket is unreadable at 512.
            guard let phAsset = phById[photo.id],
                  let image = await photoService.loadAnalysisImage(for: phAsset, targetSize: CGSize(width: 1024, height: 1024))?.cgImage else {
                if scanRunner.isCurrent(token) { skippedAnalysisCount += 1 }
                continue
            }
            let amount = await visionService.analyzeText(image: image)
            guard !Task.isCancelled, scanRunner.isCurrent(token) else { return }
            if TextPhotoPolicy.isTextHeavy(amount) {
                found.append(TextPhoto(id: photo.id, asset: photo, characterCount: amount.characterCount))
            }
            if index % 10 == 0 {
                scanRunner.update(token) { self.scanState = .scanning(Float(index + 1) / Float(max(total, 1))) }
            }
        }

        guard !Task.isCancelled, scanRunner.isCurrent(token) else { return }
        guard scanEpoch == ScanResults.epoch else {
            scanState = .idle
            errorMessage = L10n.string("Your library changed during analysis. Scan again for current results.")
            return
        }
        scanState = .scanning(1.0)
        scanState = .completed
        // Assigned after `.completed`, so the didSet records the derived count.
        photos = found
        if pendingPrune {
            pendingPrune = false
            await pruneDeleted()
        }
        ScanResults.record(.textPhotos, count: visiblePhotos.count, epoch: scanEpoch)
    }

    /// A library change that lands mid-scan is applied when the scan ends.
    private var pendingPrune = false

    /// Drops results deleted elsewhere (Swipe Review, the Photos app).
    func pruneDeleted() async {
        if case .scanning = scanState {
            pendingPrune = true
            return
        }
        guard scanState == .completed, !photos.isEmpty, !isDeleting else { return }
        let scannedIds = photos.map(\.id)
        let present = await photoService.existingIds(scannedIds)
        guard present.count < scannedIds.count, scanState == .completed, !isDeleting else { return }
        let goneIds = Set(scannedIds.filter { !present.contains($0) })
        photos.removeAll { goneIds.contains($0.id) }
    }

    func toggleSelection(_ id: String) {
        selectedIds.toggle(id)
    }

    func selectAll() {
        selectedIds.formUnion(visiblePhotos.map(\.id))
    }

    func deselectAll() {
        selectedIds.removeAll()
    }

    func deleteSelected() async {
        deletedCount = 0
        let requested = selectedIds
        guard !requested.isEmpty, !isDeleting else { return }
        await delete(requested)
    }

    func delete(assetId: String) async -> Bool {
        guard !isDeleting else { return !photos.contains { $0.id == assetId } }
        await delete([assetId])
        return !photos.contains { $0.id == assetId }
    }

    private func delete(_ ids: Set<String>) async {
        errorMessage = nil
        isDeleting = true
        defer { isDeleting = false }
        // Sizes captured before the await: the assets are gone afterwards.
        let sizeById = photos.reduce(into: [String: Int64]()) { $0[$1.id] = $1.asset.fileSize }
        let outcome = await CleanupDeletion.delete(
            requestedIds: ids,
            kind: .textPhotos,
            sizeById: sizeById,
            apply: { deletedIds in
                photos.removeAll { deletedIds.contains($0.id) }
                selectedIds.subtract(deletedIds)
            },
            recordDeleted: { self.deletedCount = $0 }
        )
        errorMessage = outcome.errorMessage
    }
}
