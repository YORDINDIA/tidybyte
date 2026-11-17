import SwiftUI
import UIKit

// MARK: - Spacing System

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

// MARK: - Corner Radius System

enum CornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
}

// MARK: - Colors

extension Color {
    static let appBackground = Color(.systemBackground)
    static let destructive = Color.red
    static let success = Color.green
    static let warning = Color.orange
    static let otherCategory = Color.gray

    // Glass card surface colors — adaptive so the glass look works in both light
    // and dark mode (a translucent light fill on dark, a translucent dark fill on light).
    static let cardSurface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.06)
            : UIColor.black.withAlphaComponent(0.035)
    })
    static let cardBorder = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.10)
    })

    // Opaque counterparts to the translucent card tokens above. `GlassCard`
    // swaps to these when Reduce Transparency is enabled: a translucent wash
    // over an unknown backdrop is exactly what those users turned off, so the
    // card needs a real surface color instead of alpha.
    static let opaqueCardSurface = Color(.secondarySystemBackground)
    static let opaqueCardBorder = Color(.separator)

    /// Opaque fill for controls that normally sit on a material (action bars,
    /// capsule buttons) so they stay legible without a blur backdrop.
    static let controlSurface = Color(.tertiarySystemFill)

    // Fills for controls whose label is white. Each holds at least 4.5:1 against
    // white in both appearances (WCAG AA). The system tint, green, red and gray
    // do not: white on them measures 2.3:1 to 4.0:1. Values are sRGB hex.
    static let actionFill = Color(red: 0.000, green: 0.376, blue: 0.784)       // #0060C8
    static let successFill = Color(red: 0.118, green: 0.482, blue: 0.204)      // #1E7B34
    static let destructiveFill = Color(red: 0.769, green: 0.188, blue: 0.169)  // #C4302B
    static let neutralFill = Color(red: 0.431, green: 0.431, blue: 0.451)      // #6E6E73

    // Text tokens for copy drawn on the page or on a 12% tint. Each is adaptive
    // and clears 4.5:1 in both appearances. Use these where a system colour would
    // be text: system green, orange, blue and red text fall below 4.5:1 on white.
    static let actionText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.039, green: 0.518, blue: 1.000, alpha: 1)   // #0A84FF
            : UIColor(red: 0.000, green: 0.376, blue: 0.784, alpha: 1)   // #0060C8
    })
    static let successText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)   // #30D158
            : UIColor(red: 0.118, green: 0.482, blue: 0.204, alpha: 1)   // #1E7B34
    })
    static let destructiveText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1.000, green: 0.412, blue: 0.380, alpha: 1)   // #FF6961
            : UIColor(red: 0.702, green: 0.149, blue: 0.118, alpha: 1)   // #B3261E
    })
    static let warningText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1.000, green: 0.702, blue: 0.251, alpha: 1)   // #FFB340
            : UIColor(red: 0.561, green: 0.337, blue: 0.000, alpha: 1)   // #8F5600
    })

    /// Footnote copy on the page. Clears 4.5:1 against white and black in both
    /// appearances, unlike `.secondary` (about 3.4:1 in light mode).
    static let footnoteText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.682, green: 0.682, blue: 0.698, alpha: 1)   // #AEAEB2
            : UIColor(red: 0.353, green: 0.353, blue: 0.380, alpha: 1)   // #5A5A61
    })

    /// Accessible warm gold/amber for Screenshots iconography and badges in light & dark mode.
    static let screenshotTint = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.systemYellow
            : UIColor(red: 0.710, green: 0.475, blue: 0.000, alpha: 1)   // #B57900
    })
}


// MARK: - Shadows

extension View {
    func cardShadow() -> some View {
        self.shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    func subtleShadow() -> some View {
        self.shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}
