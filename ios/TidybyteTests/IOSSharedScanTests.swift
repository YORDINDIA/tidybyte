import SwiftUI
import XCTest
@testable import Tidybyte

/// Regression tests for the shared-layer audit: WCAG contrast of the colour
/// tokens that carry text in both appearances, and the once-only resume contract
/// of `ContinuationResumer`.
final class IOSSharedScanTests: XCTestCase {

    // MARK: - Contrast helpers

    private typealias RGB = (r: Double, g: Double, b: Double)

    /// The colour a token resolves to in one appearance, in sRGB components.
    private func resolved(_ color: Color, dark: Bool) -> RGB {
        var environment = EnvironmentValues()
        environment.colorScheme = dark ? .dark : .light
        let value = color.resolve(in: environment)
        return (Double(value.red), Double(value.green), Double(value.blue))
    }

    private func background(dark: Bool) -> RGB {
        dark ? (0, 0, 0) : (1, 1, 1)
    }

    /// `tint` at `alpha` laid over `base`, the way a `.opacity` fill composites.
    private func blend(_ tint: RGB, alpha: Double, over base: RGB) -> RGB {
        (
            tint.r * alpha + base.r * (1 - alpha),
            tint.g * alpha + base.g * (1 - alpha),
            tint.b * alpha + base.b * (1 - alpha)
        )
    }

    private func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG 2.x contrast ratio, 1...21.
    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private let aaText = 4.5

    // MARK: - White-label fills

    /// A filled control with a white label must clear AA in both appearances.
    /// The system tint, green, red and gray fail this (2.3 to 4.0:1).
    func testWhiteLabelFillsReachAAInBothAppearances() {
        let fills: [(String, Color)] = [
            ("actionFill", .actionFill),
            ("successFill", .successFill),
            ("destructiveFill", .destructiveFill),
            ("neutralFill", .neutralFill)
        ]
        for (name, fill) in fills {
            for dark in [false, true] {
                let ratio = contrast((1, 1, 1), resolved(fill, dark: dark))
                XCTAssertGreaterThanOrEqual(
                    ratio, aaText,
                    "\(name) with a white label is \(ratio):1 in \(dark ? "dark" : "light")"
                )
            }
        }
    }

    // MARK: - Text tokens

    /// Text tokens are drawn on the page background in both appearances.
    func testTextTokensReachAAOnPageInBothAppearances() {
        let texts: [(String, Color)] = [
            ("actionText", .actionText),
            ("successText", .successText),
            ("destructiveText", .destructiveText),
            ("warningText", .warningText)
        ]
        for (name, text) in texts {
            for dark in [false, true] {
                let ratio = contrast(resolved(text, dark: dark), background(dark: dark))
                XCTAssertGreaterThanOrEqual(
                    ratio, aaText,
                    "\(name) on the page is \(ratio):1 in \(dark ? "dark" : "light")"
                )
            }
        }
    }

    /// The Cancel button in `ToolScanningView` draws `destructiveText` on a 12%
    /// destructive wash. The system red text it replaced measured 3.0:1 in light.
    func testDestructiveCancelTextReachesAAOnItsWash() {
        for dark in [false, true] {
            let page = background(dark: dark)
            let wash = blend(resolved(.destructive, dark: dark), alpha: 0.12, over: page)
            let ratio = contrast(resolved(.destructiveText, dark: dark), wash)
            XCTAssertGreaterThanOrEqual(ratio, aaText, "Cancel text is \(ratio):1 in \(dark ? "dark" : "light")")
        }
    }

    /// `LimitedLibraryBanner` and `ToolErrorBanner` draw `actionText` on the
    /// warning wash. System blue on that wash measured about 3.1:1 in light.
    func testActionTextReachesAAOnWarningWash() {
        for dark in [false, true] {
            let page = background(dark: dark)
            let wash = blend(resolved(.warning, dark: dark), alpha: 0.12, over: page)
            let ratio = contrast(resolved(.actionText, dark: dark), wash)
            XCTAssertGreaterThanOrEqual(ratio, aaText, "Banner link is \(ratio):1 in \(dark ? "dark" : "light")")
        }
    }
}

// MARK: - ContinuationResumer

final class ContinuationResumerTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        var cleanups = 0
    }

    /// PHImageManager can deliver a degraded result and then a final result, and
    /// a timeout can race both. Only the first resume may land, and the cleanup
    /// hook (which cancels the request and the timeout) must run exactly once.
    func testResumesOnceAndRunsCleanupOnce() async {
        let counter = Counter()
        let value: Int = await withCheckedContinuation { continuation in
            let resumer = ContinuationResumer<Int>(continuation)
            resumer.onResume = { counter.cleanups += 1 }
            resumer.resume(1)
            resumer.resume(2)
            resumer.resume(3)
        }
        XCTAssertEqual(value, 1)
        XCTAssertEqual(counter.cleanups, 1)
    }
}

