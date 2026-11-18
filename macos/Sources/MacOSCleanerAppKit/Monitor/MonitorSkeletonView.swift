import SwiftUI

/// One gray placeholder block with the design system's corner radius.
struct SkeletonBlock: View {
    var height: CGFloat
    var width: CGFloat?

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.cardCompact)
            .fill(.quaternary)
            .frame(width: width, height: height)
    }
}

/// The warm-up placeholder shown before the monitor's first snapshot lands.
struct MonitorSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                MetricTileGrid {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonBlock(height: 64)
                    }
                }
                SkeletonBlock(height: 160)
                SkeletonBlock(height: 24, width: 140)
                VStack(alignment: .leading, spacing: Spacing.elementTight) {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: Spacing.elementNormal) {
                            SkeletonBlock(height: 20, width: 20)
                            SkeletonBlock(height: 14)
                            SkeletonBlock(height: 14, width: 64)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.elementSection)
        }
        .accessibilityLabel(Text(String(localized: "Reading the system…", comment: "Monitor first tick")))
    }
}

/// The process-inspector placeholder while probes (signature, argv, open files,
/// listening ports, and outbound connections) are fetched for the selection.
struct InspectorSkeletonView: View {
    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.elementNormal) {
                HStack {
                    SkeletonBlock(height: 16, width: 72)
                    Spacer()
                    SkeletonBlock(height: 24, width: 52)
                    SkeletonBlock(height: 24, width: 82)
                }
                SkeletonBlock(height: 44)
                ForEach(0..<5, id: \.self) { _ in
                    HStack {
                        SkeletonBlock(height: 12, width: 90)
                        Spacer()
                        SkeletonBlock(height: 12, width: 130)
                    }
                }
                Divider()
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonBlock(height: 12)
                }
                Divider()
                SkeletonBlock(height: 76)
            }
            .padding(Spacing.elementNormal)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel(Text(String(localized: "Loading process details…", comment: "Inspector loading")))
    }
}

private struct MetricTileGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.elementNormal)], spacing: Spacing.elementNormal) {
            content
        }
    }
}
