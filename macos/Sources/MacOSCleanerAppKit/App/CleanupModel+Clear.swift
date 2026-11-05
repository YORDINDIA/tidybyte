import Foundation
import MacOSCleanerCore

/// Clear All Data support. Lives beside the model rather than inside it so
/// CleanupModel.swift stays under the file-length budget.
extension CleanupModel {
    /// Drops in-memory cleanup state once Clear All Data has wiped the store.
    /// Stale values left in memory could be written back by the next decision:
    /// a leftover session or selection would let the UI re-approve files whose
    /// rows are gone, and a leftover freshness monitor would keep watching
    /// folders the user just cleared.
    func resetAfterClear() async {
        freshnessEpoch += 1  // drops a monitor build still in flight
        rescanEpoch += 1  // drops a debounced rescan still queued
        freshness = nil
        for grant in monitoredGrants { grant.stopAccessingSecurityScopedResource() }
        monitoredGrants = []
        scope = ReviewScope()
        settings = CleanupSettings()
        filter = settings.defaultFilter
        filterFolder = nil
        result = nil
        session = nil
        completedSession = nil
        sessionResults = []
        reviewed = [:]
        activity = []
        snapshots = []
        jobs = []
        selection = []
        selectedItem = nil
        error = nil
        notice = nil
        photosAccessDenied = false
        try? await updateReminder()  // removes the weekly reminder that quotes the old scan
    }
}
