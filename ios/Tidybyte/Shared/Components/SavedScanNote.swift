import SwiftUI

/// "Last scan: <date>" above results that came back from a saved scan, so the
/// user knows they may be out of date and can scan again.
struct SavedScanNote: View {
    let date: Date
    /// Side inset. Inside a list row, which has its own, pass a small one.
    var inset: CGFloat = Spacing.lg
    /// Read so the date re-renders after an in-app language change.
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        Text(L10n.format("Last scan: %@", Formatters.dateTime(date)))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.top, Spacing.xs)
    }
}
