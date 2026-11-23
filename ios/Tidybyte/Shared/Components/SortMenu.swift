import SwiftUI

/// The sort control shared by the Cleanup tools: a menu that holds one
/// checkmarked choice per order. Callers own the placement.
struct SortMenu<Order: Hashable>: View {
    @Binding var selection: Order
    let options: [Order]
    /// Already-localized name of an order (`displayName`).
    let title: (Order) -> String

    /// Read so the option names resolve again after an in-app language change.
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        Menu {
            Picker("Sort", selection: $selection) {
                ForEach(options, id: \.self) { order in
                    Text(title(order)).tag(order)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("sortMenu")
    }
}
