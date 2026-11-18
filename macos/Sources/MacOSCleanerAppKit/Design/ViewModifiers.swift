import MacOSCleanerCore
import SwiftUI

extension View {
    public func accessibleRiskLabel(_ risk: RiskLevel) -> some View {
        accessibilityLabel(L10n.format("Risk: %@", risk.displayName))
    }

    /// PRD 9.3: gray placeholder bars while a surface loads, instead of an
    /// empty or half-populated list. Surfaces pass their own busy flag.
    public func skeletonLoading(_ isLoading: Bool) -> some View {
        redacted(reason: isLoading ? .placeholder : [])
    }

    /// Translucent semantic card chrome with subtle selection ring.
    func softCardSurface(
        cornerRadius: CGFloat = Radius.card,
        isSelected: Bool = false,
        tint: Color = .accentColor
    ) -> some View {
        background(.background.secondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? tint : SemanticScale.subtleBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
    }

    /// Floating Liquid Glass pill/bar chrome reserved exclusively for overlay
    /// navigation and action bars (never applied to rows, cards, or forms).
    func floatingGlassOverlay<S: InsettableShape>(in shape: S) -> some View {
        glassEffect(in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}
