import MacOSCleanerCore
import SwiftUI

/// Insights › History: every change Tidybyte made, with restore where the
/// operation supports it. The segmented control lives in ContentView's constant toolbar (SSA-01).
struct HistoryView: View {
    @Bindable var model: AppViewModel
    @Binding var showsMedia: Bool

    var body: some View {
        if showsMedia || !DistributionChannel.supportsAdvanced {
            CleanupActivityView(model: model.cleanup)
        } else {
            UndoHistoryView(model: model)
        }
    }
}
