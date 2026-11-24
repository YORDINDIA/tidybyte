import SwiftUI

// MARK: - Fade Slide In

/// Entrance motion for rows and cards. Content is ALWAYS fully visible: only
/// the vertical offset animates, so a row whose animation never runs (a
/// backgrounded tab, a screenshot pass, a lazy row scrolled into view late)
/// still shows. The delay is capped: callers pass `index * 0.03`, and an
/// uncapped delay left row 500 of a long list waiting 15 s.
struct FadeSlideInModifier: ViewModifier {
    let delay: Double
    @State private var isSettled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maxDelay: Double = 0.3

    func body(content: Content) -> some View {
        content
            .offset(y: isSettled || reduceMotion ? 0 : 12)
            .onAppear {
                guard !isSettled else { return }
                if reduceMotion {
                    isSettled = true
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(min(delay, Self.maxDelay))) {
                        isSettled = true
                    }
                }
            }
    }
}

extension View {
    func fadeSlideIn(delay: Double = 0) -> some View {
        modifier(FadeSlideInModifier(delay: delay))
    }
}

// MARK: - Scale On Press Button Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    func scaleOnPress() -> some View {
        self.buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Reduce Motion

extension Animation {
    /// Returns `base`, or a near-instant animation when Reduce Motion is enabled,
    /// so large motion (card flings, spring scaling) is calmed for users who need it.
    static func reduceMotionAware(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.01) : base
    }
}

// MARK: - Reduce Swipe Motion

extension EnvironmentValues {
    /// Settings > Reduce Swipe Motion. Until the user picks a value it follows
    /// iOS Reduce Motion (`RootView` sets it). When on, a swipe card moves a
    /// quarter of the drag without tilting, and decided cards fade out instead
    /// of flying off.
    @Entry var reduceSwipeMotion = false
}

/// How far a swipe card is drawn from its center for a given drag. The swipe
/// thresholds and the stamps still read the full drag; only the drawing changes.
enum SwipeMotionStyle {
    static let reducedTravel: CGFloat = 0.25

    static func drawn(_ drag: CGSize, reduced: Bool) -> (offset: CGSize, degrees: Double) {
        guard reduced else { return (drag, Double(drag.width / 20)) }
        return (CGSize(width: drag.width * reducedTravel, height: drag.height * reducedTravel), 0)
    }

    /// The fade a decided card uses instead of the fling.
    static let fade = Animation.easeOut(duration: 0.2)
}

// MARK: - State Transition

extension AnyTransition {
    static var stateTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.95)).animation(.spring(response: 0.35, dampingFraction: 0.85))
    }
}

// MARK: - Pull to Refresh

extension View {
    /// App-wide pull-to-refresh: native `.refreshable` plus a subtle completion haptic,
    /// so every screen behaves identically. Attach to the screen's `List`/`ScrollView`/`Form`.
    ///
    /// The `action` should re-fetch data WITHOUT toggling a full-screen loading/skeleton
    /// state, so existing content stays visible under the system refresh spinner.
    ///
    /// The action is `@MainActor`-isolated (which is also implicitly `Sendable`, so SwiftUI's
    /// `refreshable` still accepts it). This lets call sites touch main-actor state — a
    /// `@State` property, a SwiftData `ModelContext`, a `@MainActor` view model — without
    /// the "cannot exit main actor-isolated context" / "Sendable closure" warnings that a
    /// plain `@Sendable` action would trigger.
    func pullToRefresh(_ action: @escaping @MainActor () async -> Void) -> some View {
        refreshable {
            await action()
            // `.refreshable`'s own closure is non-isolated; hop to the main actor for the haptic.
            await MainActor.run { HapticHelper.impact(.light) }
        }
    }
}
