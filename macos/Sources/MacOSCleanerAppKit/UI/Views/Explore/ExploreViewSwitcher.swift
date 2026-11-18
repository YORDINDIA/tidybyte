import MacOSCleanerCore
import SwiftUI

/// Shared empty state for the Explore visualizations.
struct ExploreEmptyState: View {
    var language: AppLanguage?

    var body: some View {
        VStack(spacing: Spacing.elementTight) {
            Image(systemName: "folder")
                .appFont(.h3, color: Color.secondary)
            Text(L10n.string("Nothing to visualize yet.", language: language))
                .appFont(.bodyMedium)
                .foregroundStyle(Color.secondary)
            Text(L10n.string("Run a scan or clear the name filter to fill this view.", language: language))
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.string("Nothing to visualize yet. Run a scan or clear the name filter.", language: language)
        )
    }
}

/// Which visualization the Explore switcher shows.
enum ExploreViewKind: String, CaseIterable, Identifiable, Sendable {
    case list
    case folders
    case sunburst
    case flame
    case bubbles
    case mindMap
    case topSizes
    case ageMap
    case treemap

    var id: String { rawValue }

    var title: String {
        localizedTitle(language: nil)
    }

    func localizedTitle(language: AppLanguage?) -> String {
        switch self {
        case .list: L10n.string("List", language: language)
        case .folders: L10n.string("Folders", language: language)
        case .sunburst: L10n.string("Sunburst", language: language)
        case .flame: L10n.string("Flame", language: language)
        case .bubbles: L10n.string("Bubbles", language: language)
        case .mindMap: L10n.string("Mind Map", language: language)
        case .topSizes: L10n.string("Top Sizes", language: language)
        case .ageMap: L10n.string("Age Map", language: language)
        case .treemap: L10n.string("Treemap", language: language)
        }
    }

    var tagline: String {
        localizedTagline(language: nil)
    }

    func localizedTagline(language: AppLanguage?) -> String {
        switch self {
        case .list:
            L10n.string("Browse scanned files.", language: language)
        case .folders:
            L10n.string("Browse groups as cards, then drill in.", language: language)
        case .sunburst:
            L10n.string("The whole scan as concentric rings.", language: language)
        case .flame:
            L10n.string("Depth as stacked bars, top group first.", language: language)
        case .bubbles:
            L10n.string("Every group as a bubble, sized by bytes.", language: language)
        case .mindMap:
            L10n.string("Branches fanning out from your scan.", language: language)
        case .topSizes:
            L10n.string("Biggest groups first, ranked.", language: language)
        case .ageMap:
            L10n.string("When files were touched, plus big untouched ones.", language: language)
        case .treemap:
            L10n.string("Every group as a proportional rectangle.", language: language)
        }
    }
}

/// Segmented switcher hosting all Explore visualizations.
struct ExploreViewSwitcher: View {
    @Bindable var model: AppViewModel
    var files: [FileRecord]
    var categorySections: [(FindingCategory, Int64)]

    private var nameFilter: String { model.searchText }
    private var override: AppLanguage? { model.languageStore.activeOverride }

    private var selectedView: ExploreViewKind {
        ExploreViewKind(rawValue: model.exploreViewKindRaw) ?? .folders
    }

    private var grouping: ExploreGrouping {
        ExploreGrouping(rawValue: model.exploreGroupingRaw) ?? .byFolder
    }

    private var depth: Double {
        Double(max(1, min(10, model.exploreDepth)))
    }

    private var depthInt: Int {
        max(1, min(10, Int(depth)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementNormal) {
            controls
            activeView
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selectedView.localizedTitle(language: override))
        .skeletonLoading(model.isScanning)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.elementNormal) {
                groupingPicker
                depthControl
            }
            VStack(alignment: .leading, spacing: Spacing.elementTight) {
                groupingPicker
                depthControl
            }
        }
    }

    private var groupingPicker: some View {
        Picker(
            L10n.string("Group", language: override),
            selection: Binding(
                get: { grouping },
                set: {
                    model.exploreGroupingRaw = $0.rawValue
                    model.saveSettings()
                }
            )
        ) {
            ForEach(ExploreGrouping.allCases) { option in
                Text(option.localizedTitle(language: override)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)
        .accessibilityLabel(L10n.string("Group files by", language: override))
        .disabled(selectedView == .ageMap)
    }

    private var depthControl: some View {
        HStack(spacing: Spacing.elementTight) {
            Text(L10n.string("Depth", language: override))
                .appFont(.caption)
                .foregroundStyle(Color.secondary)
            Slider(
                value: Binding(
                    get: { depth },
                    set: {
                        model.exploreDepth = max(1, min(10, Int($0)))
                        model.saveSettings()
                    }
                ),
                in: 1...10,
                step: 1
            )
            .frame(maxWidth: 140)
            .accessibilityLabel(L10n.string("Folder depth", language: override))
            .accessibilityValue(L10n.format("%lld levels", language: override, depthInt))
            Text("\(depthInt)")
                .appFont(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
        }
        .disabled([.topSizes, .ageMap, .bubbles, .mindMap].contains(selectedView))
    }

    @ViewBuilder
    private var activeView: some View {
        switch selectedView {
        case .list:
            EmptyView()
        case .folders:
            FoldersGridView(
                model: model,
                files: files,
                grouping: grouping,
                maxDepth: depthInt,
                nameFilter: nameFilter
            )
        case .sunburst:
            SunburstView(
                model: model,
                files: files,
                grouping: grouping,
                maxDepth: depthInt,
                nameFilter: nameFilter
            )
        case .flame:
            FlameView(
                model: model,
                files: files,
                grouping: grouping,
                maxDepth: depthInt,
                nameFilter: nameFilter
            )
        case .bubbles:
            BubblesView(
                model: model,
                files: files,
                grouping: grouping,
                maxDepth: depthInt,
                nameFilter: nameFilter
            )
        case .mindMap:
            MindMapView(
                model: model,
                files: files,
                grouping: grouping,
                maxDepth: depthInt,
                nameFilter: nameFilter
            )
        case .topSizes:
            TopSizesView(
                model: model,
                files: files,
                grouping: grouping,
                maxDepth: depthInt,
                nameFilter: nameFilter
            )
        case .ageMap:
            AgeMapView(model: model, files: files, nameFilter: nameFilter)
        case .treemap:
            TreemapView(
                sections: categorySections,
                model: model,
                files: files,
                grouping: grouping,
                maxDepth: depthInt,
                nameFilter: nameFilter
            )
            .frame(minHeight: 300)
        }
    }
}
