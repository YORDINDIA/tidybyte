import SwiftUI

// Phase 3 (PRD 9.3): every Monitor surface that loads shows skeleton
// placeholders mirroring the real layout instead of fake zeros or empty
// flashes. Pure shape placeholders — no pulse, so Reduce Motion needs no
// special casing.

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

/// The warm-up placeholder shown before the monitor's first snapshot lands:
/// the Overview layout (metric tiles, chart frame, busiest apps, process
/// rows) rendered as blocks.
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

/// The process-inspector placeholder while the probes (signature, argv, open
/// files, ports) are being fetched for the selection.
struct InspectorSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.elementSection) {
            HStack(spacing: Spacing.elementNormal) {
                SkeletonBlock(height: 40, width: 40)
                VStack(alignment: .leading, spacing: Spacing.elementTight) {
                    SkeletonBlock(height: 16, width: 180)
                    SkeletonBlock(height: 12, width: 90)
                }
            }
            SkeletonBlock(height: 60)
            ForEach(0..<6, id: \.self) { _ in
                HStack {
                    SkeletonBlock(height: 12, width: 110)
                    SkeletonBlock(height: 12)
                }
            }
            SkeletonBlock(height: 90)
            Spacer(minLength: 0)
        }
        .padding(Spacing.screenEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel(Text(String(localized: "Loading process details…", comment: "Inspector loading")))
    }
}

/// A four-column tile grid wrapper matching the Overview metric tiles.
private struct MetricTileGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.elementNormal)], spacing: Spacing.elementNormal) {
            content
        }
    }
}
