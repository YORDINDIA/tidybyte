import SwiftUI

/// Reusable square photo/video cell for multi-select cleanup grids and batch review sheets.
struct SelectableMediaGridCell<MenuContent: View>: View {
    let asset: AssetSummary
    let photoService: PhotoLibraryService
    let isSelected: Bool
    let itemName: String
    let previewAccessibilityLabel: LocalizedStringKey
    var showsSelectionToggle: Bool = true
    var showsFavoriteMark: Bool = true
    var bottomBadgeText: String? = nil
    var scoreBar: (value: Float, color: Color, label: LocalizedStringKey)? = nil
    var selectionColor: Color = .blue
    var isSelectionDisabled: Bool = false
    let onPreview: () -> Void
    let onToggleSelection: () -> Void
    @ViewBuilder let menuContent: () -> MenuContent

    init(
        asset: AssetSummary,
        photoService: PhotoLibraryService = .shared,
        isSelected: Bool,
        itemName: String = "photo",
        previewAccessibilityLabel: LocalizedStringKey? = nil,
        showsSelectionToggle: Bool = true,
        showsFavoriteMark: Bool = true,
        bottomBadgeText: String? = nil,
        scoreBar: (value: Float, color: Color, label: LocalizedStringKey)? = nil,
        selectionColor: Color = .blue,
        isSelectionDisabled: Bool = false,
        onPreview: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void,
        @ViewBuilder menuContent: @escaping () -> MenuContent = { EmptyView() }
    ) {
        self.asset = asset
        self.photoService = photoService
        self.isSelected = isSelected
        self.itemName = itemName
        self.previewAccessibilityLabel = previewAccessibilityLabel ?? "Preview photo, \(asset.displaySize)"
        self.showsSelectionToggle = showsSelectionToggle
        self.showsFavoriteMark = showsFavoriteMark
        self.bottomBadgeText = bottomBadgeText
        self.scoreBar = scoreBar
        self.selectionColor = selectionColor
        self.isSelectionDisabled = isSelectionDisabled
        self.onPreview = onPreview
        self.onToggleSelection = onToggleSelection
        self.menuContent = menuContent
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AsyncThumbnailView(assetId: asset.id, photoService: photoService)
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Spacing.xs))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(previewAccessibilityLabel)
                .accessibilityAction(.default) { onPreview() }

            if showsFavoriteMark, asset.isFavorite {
                VStack {
                    HStack {
                        FavoriteMark()
                            .padding(Spacing.xs + 2)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if let bottomBadgeText {
                VStack {
                    Spacer()
                    HStack {
                        Text(verbatim: bottomBadgeText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.xs + 2)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.68), in: Capsule())
                            .padding(Spacing.xs)
                        Spacer()
                    }
                }
                .allowsHitTesting(false)
            }

            if let scoreBar {
                VStack {
                    Spacer()
                    HStack {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.3))
                                Rectangle()
                                    .fill(scoreBar.color)
                                    .frame(width: geo.size.width * CGFloat(min(1, max(0, scoreBar.value))))
                            }
                        }
                        .frame(width: 40, height: 4)
                        .clipShape(Capsule())
                        .padding(Spacing.sm)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(scoreBar.label)
                        .accessibilityValue("\(Int((scoreBar.value * 100).rounded())) percent")
                        Spacer()
                    }
                }
                .allowsHitTesting(false)
            }

            if showsSelectionToggle {
                SelectToggle(isSelected: isSelected, itemName: itemName) {
                    onToggleSelection()
                }
                .disabled(isSelectionDisabled)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Spacing.xs)
                    .strokeBorder(selectionColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onPreview()
        }
        .contextMenu {
            menuContent()
        }
    }
}

