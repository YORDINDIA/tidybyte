import MacOSCleanerCore
import SwiftUI

/// Insights › Changes: how storage moved over time. A toolbar segmented
/// control switches between the forecast, a two-scan comparison, and the
/// cleanup-scope trend.
struct ChangesView: View {
    @Bindable var model: AppViewModel
    @SceneStorage("changesMode") private var mode = Mode.forecast

    enum Mode: String, CaseIterable, Identifiable {
        case forecast, compare, media
        var id: String { rawValue }
        var title: String {
            switch self {
            case .forecast: String(localized: "Forecast")
            case .compare: String(localized: "Compare Scans")
            // Snapshots measure the whole cleanup scope (which may include
            // arbitrary selected folders), so the title must not promise a
            // photos-only trend.
            case .media: String(localized: "Cleanup Scope")
            }
        }
    }

    var body: some View {
        Group {
            switch mode {
            case .forecast: MonitorTabView(model: model)
            case .compare: SnapshotDiffView(model: model)
            case .media: MediaTrendView(model: model.cleanup)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(String(localized: "View"), selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}
