import SwiftUI

/// Standard primary full-width (or intrinsic-width) call-to-action label used across
/// onboarding, permission gates, empty states, tool idle screens, and session completion.
struct PrimaryActionLabel: View {
    let title: LocalizedStringKey
    var icon: String?
    var fill: Color?
    var isLoading: Bool = false
    var fullWidth: Bool = true
    var cornerRadius: CGFloat = CornerRadius.medium

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let icon {
                Image(systemName: icon)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.headline)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .padding(.horizontal, fullWidth ? Spacing.lg : Spacing.xxxl)
        .padding(.vertical, Spacing.md + 2)
        .frame(minHeight: 48)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fill ?? Color.actionFill)
        }
        .foregroundStyle(.white)
    }
}

/// Secondary tonal/outlined action label paired below or beside a primary CTA.
struct SecondaryActionLabel: View {
    let title: LocalizedStringKey
    var icon: String?
    var tint: Color = .accentColor
    var fullWidth: Bool = true
    var cornerRadius: CGFloat = CornerRadius.medium

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm + 2)
        .frame(minHeight: 44)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }
}

/// Shared header summary card used at the top of cleanup result screens.
struct CleanupSummaryCard<Trailing: View>: View {
    let icon: String?
    let tint: Color
    let headline: Text
    var subtitle: Text?
    @ViewBuilder let trailing: () -> Trailing

    init(
        icon: String? = nil,
        tint: Color = .accentColor,
        headline: Text,
        subtitle: Text? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.tint = tint
        self.headline = headline
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            if let icon {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .scaledSquare(32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: CornerRadius.small))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                headline
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let subtitle {
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            trailing()
        }
        .glassCard(padding: Spacing.md)
        .accessibilityElement(children: .contain)
    }
}
