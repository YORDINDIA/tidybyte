import MacOSCleanerCore
import SwiftUI

extension View {
    public func accessibleRiskLabel(_ risk: RiskLevel) -> some View {
        accessibilityLabel(String(localized: "Risk: \(risk.displayName)"))
    }

    /// PRD 9.3: gray placeholder bars while a surface loads, instead of an
    /// empty or half-populated list. Surfaces pass their own busy flag.
    public func skeletonLoading(_ isLoading: Bool) -> some View {
        redacted(reason: isLoading ? .placeholder : [])
    }
}
