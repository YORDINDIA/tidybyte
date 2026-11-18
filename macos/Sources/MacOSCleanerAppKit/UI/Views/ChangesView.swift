import MacOSCleanerCore
import SwiftUI

/// Insights › Changes: how storage moved over time. The mode segmented control
/// lives in ContentView's constant toolbar to avoid dynamic NSToolbar mutations (SSA-01).
struct ChangesView: View {
    @Bindable var model: AppViewModel
    @Binding var mode: Mode

    enum Mode: String, CaseIterable, Identifiable {
        case forecast, compare, media
        var id: String { rawValue }
        var title: String {
            switch self {
            case .forecast: L10n.string("Forecast")
            case .compare: L10n.string("Compare Scans")
            case .media: L10n.string("Cleanup Scope")
            }
        }
    }

    var body: some View {
        switch mode {
        case .forecast: MonitorTabView(model: model)
        case .compare: SnapshotDiffView(model: model)
        case .media: MediaTrendView(model: model.cleanup)
        }
    }
}
