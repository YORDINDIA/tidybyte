import SwiftUI

/// A row that stacks its children vertically at accessibility sizes. Beside a
/// button, a text column got a sliver of width and wrapped one word or one
/// character per line. Stacked, each child gets the full row width.
struct AdaptiveRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let spacing: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
    }
}

/// The flexible gap of an `AdaptiveRow`. Nothing at accessibility sizes, where
/// the row is a column and a Spacer would take vertical space.
struct AdaptiveSpacer: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            EmptyView()
        } else {
            Spacer()
        }
    }
}

/// The shared action bar, with its controls in an `AdaptiveRow`.
struct CleanupActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ActionBarView {
            AdaptiveRow(spacing: nil) { content }
        }
    }
}
