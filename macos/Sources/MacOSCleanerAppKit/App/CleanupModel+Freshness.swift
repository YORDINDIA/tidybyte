import Foundation

// The freshness-monitor wiring, split out of CleanupModel to keep that file's
// lint budget (file/function lengths) intact.

extension CleanupModel {
    /// Rebuilds the freshness monitor for the current scope. PSA-01:
    /// FSEventStreamCreate can block indefinitely, so the monitor is built
    /// off the main actor and handed back; a build superseded by a newer call
    /// loses the race and is dropped.
    func startMonitoring() {
        freshnessEpoch += 1
        let epoch = freshnessEpoch
        let roots = scope.roots
        let includesPhotos = scope.includesPhotos
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.freshnessDidChange()
            }
        }
        Task.detached(priority: .utility) {
            let monitor = CleanupFreshnessMonitor(roots: roots, includesPhotos: includesPhotos, changed: changed)
            await MainActor.run {
                guard epoch == self.freshnessEpoch else { return }
                self.freshness = monitor
            }
        }
    }

    /// Freshness callback from the monitor: mark staleness immediately and
    /// auto-rescan only when idle. Rescans are debounced so a burst of file
    /// changes (S-04) coalesces into one pass. Internal so tests can drive it.
    func freshnessDidChange() {
        changeGeneration += 1
        result?.isFresh = false
        guard !isBusy, session == nil else { return }
        rescanEpoch += 1
        let epoch = rescanEpoch
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard epoch == self.rescanEpoch, !self.isBusy, self.session == nil else { return }
            self.scan()
        }
    }
}
