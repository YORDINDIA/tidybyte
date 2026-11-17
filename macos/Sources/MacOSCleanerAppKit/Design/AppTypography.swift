import SwiftUI

/// Native macOS 26 text styles; monospaced text is reserved for paths and commands.
public enum AppFont: Sendable {
    case display, h3, h4, bodyMedium, labelMedium, caption, filePath

    public func font() -> Font {
        switch self {
        case .display: .system(.largeTitle, design: .rounded).weight(.semibold)
        case .h3: .system(.headline, design: .rounded)
        case .h4: .subheadline.weight(.semibold)
        case .bodyMedium: .body
        case .labelMedium: .callout
        case .caption: .caption
        case .filePath: .system(.caption, design: .monospaced)
        }
    }
}

extension Font {
    public static func app(_ style: AppFont) -> Font { style.font() }
}

extension View {
    public func appFont(_ style: AppFont) -> some View { font(style.font()) }
    public func appFont(_ style: AppFont, color: Color) -> some View { font(style.font()).foregroundStyle(color) }
}
