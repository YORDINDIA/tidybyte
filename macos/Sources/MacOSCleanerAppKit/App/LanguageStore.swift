import Foundation
import MacOSCleanerCore
import SwiftUI

/// Live UI language and layout-direction state for Tidybyte on macOS.
///
/// Registers both SwiftPM resource bundles (`MacOSCleanerAppKit` and
/// `MacOSCleanerCore`) with `L10n`, persists overrides in `UserDefaults`, and
/// exposes reactive `locale` and `layoutDirection` values for SwiftUI scenes
/// so language and RTL switches apply immediately without relaunch.
@Observable
@MainActor
final class LanguageStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// Stored language preference. `.system` follows macOS settings.
    private(set) var language: AppLanguage

    /// Two-way binding target for Settings pickers.
    var selectedLanguage: AppLanguage {
        get { language }
        set { setLanguage(newValue) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        L10n.registerBundle(Bundle.module)
        L10n.registerBundle(Bundle(for: ScanOrchestrator.self))
        language = LanguagePreferenceStore.stored(in: defaults) ?? .system
    }

    /// Concrete language the UI renders in, or `nil` when following an
    /// unsupported macOS system language.
    var resolvedLanguage: AppLanguage? {
        language == .system ? AppLanguage.matchingDeviceLanguage() : language
    }

    /// Concrete language to render against (`en` fallback when macOS uses an
    /// unsupported language).
    var effectiveLanguage: AppLanguage {
        resolvedLanguage ?? .english
    }

    /// Explicit override for `L10n` lookups, or `nil` when following macOS.
    /// Reading this property inside SwiftUI views subscribes them to live
    /// language updates.
    var activeOverride: AppLanguage? {
        language == .system ? nil : language
    }

    /// True when following macOS and macOS is set to a language without
    /// translations yet.
    var systemLanguageIsUnsupported: Bool {
        language == .system && AppLanguage.matchingDeviceLanguage() == nil
    }

    /// SwiftUI `\.locale` injected at every scene root.
    var locale: Locale {
        L10n.formattingLocale(for: activeOverride)
    }

    /// Mirrors layout automatically for RTL languages (Arabic, Hebrew).
    var layoutDirection: LayoutDirection {
        effectiveLanguage.isRightToLeft ? .rightToLeft : .leftToRight
    }

    func setLanguage(_ newValue: AppLanguage) {
        guard newValue != language else { return }
        language = newValue
        LanguagePreferenceStore.save(newValue, to: defaults)
        LanguagePreferenceStore.applyToSystem(newValue, to: defaults)
    }

    func reset() {
        language = .system
        LanguagePreferenceStore.save(.system, to: defaults)
        LanguagePreferenceStore.applyToSystem(.system, to: defaults)
    }
}
