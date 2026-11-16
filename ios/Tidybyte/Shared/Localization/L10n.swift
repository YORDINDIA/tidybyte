import Foundation

/// String lookup for code that runs outside a SwiftUI view.
///
/// Inside a view, `Text("key")` is the right call: SwiftUI resolves it against
/// the `\.locale` environment value, so the language can change while the app
/// is running (verified in the simulator — an injected `de` locale renders the
/// German string immediately, no relaunch). Services, notification bodies,
/// widget copy, and App Intents have no such environment, so they come here.
///
/// **Navigation titles are the exception, and they go through
/// `localizedNavigationTitle`.** A `.navigationTitle("key")` takes the same
/// `LocalizedStringKey`, but the bar is UIKit-backed and only re-applies a title
/// whose *value* changed — and that key is identical in every language. A
/// screen that was hidden while the language changed therefore kept the old
/// title: its body rendered in the new language while the bar above it still
/// read the old one. Resolving the key here fixes the value; the modifier also
/// reads the live language, because a title is computed when the body runs and a
/// hidden screen's body does not run again. Keep `.navigationTitle` literals out
/// of the app.
///
/// This type resolves against the *specific language's* bundle rather than
/// `Bundle.main`. That matters for the same reason: `Bundle.main` resolves once
/// per process launch, so it keeps serving the launch-time language after the
/// user switches. Building a `Bundle` from the chosen `.lproj` directory is the
/// only way to get the new language without a relaunch.
enum L10n {
    /// The language to resolve against: the user's override if they set one,
    /// otherwise `nil` meaning "whatever iOS already resolved for this
    /// process" (`Bundle.main` is correct in that case, including per-app
    /// language set in iOS Settings).
    static var currentOverride: AppLanguage? { LanguagePreferenceStore.stored() }

    /// The bundle for a language, or `Bundle.main` when there is no override.
    ///
    /// Caches per language because this is called on hot paths (every size
    /// string in a list of thousands of assets). `Bundle(path:)` is not free
    /// and the answer never changes within a process for a given language.
    private static let cache = BundleCache()

    static func bundle(for language: AppLanguage?) -> Bundle {
        guard let language, language != .system else { return .main }
        return cache.bundle(for: language)
    }

    /// A catalog key, unresolved.
    ///
    /// For a call site that must resolve the key *later* rather than now — a
    /// navigation title, which has to be re-resolved on a language change
    /// instead of handed a value computed once. Returning the key unchanged is
    /// the whole implementation; the call exists so the literal is recognisably
    /// a catalog key, both to a reader and to `extract.mjs`, which collects keys
    /// from `L10n.key` calls.
    ///
    /// Use `string(_:)` instead when the text is drawn where it stands.
    static func key(_ key: String) -> String { key }

    /// Looks up `key` in the language's bundle.
    ///
    /// `value` is the English fallback. Passing the English text here (rather
    /// than an empty string) is deliberate: it keeps a missing translation
    /// readable instead of showing a raw key to the user, and it matches what
    /// the String Catalog would have produced anyway.
    static func string(_ key: String, language: AppLanguage? = nil, fallback: String? = nil) -> String {
        let bundle = bundle(for: language ?? currentOverride)
        let resolved = bundle.localizedString(forKey: key, value: fallback ?? key, table: nil)
        // `localizedString` returns the key itself when the table has no entry.
        // Falling back to the key is fine for the base language (where the key
        // IS the English text) but useless for anything else, so let the caller
        // supply the English text when the key is not itself English.
        return resolved
    }

    /// A localized template with `%` arguments applied, for counted strings.
    ///
    /// `String(format:locale:)` applies the plural variations the String Catalog
    /// compiles into the `.stringsdict`, using the locale passed in.
    ///
    /// The counted form is chosen by the locale it is formatted with. That is the
    /// app language when one is set, so Russian `5` picks the `many` form even on
    /// an English device. `String.localizedStringWithFormat` would use the device
    /// locale instead, and gave the wrong category for a non-device language.
    ///
    /// The digits in `%lld` stay ASCII, as they did before; only the plural form
    /// follows the locale.
    static func format(_ key: String, language: AppLanguage? = nil, fallback: String? = nil, _ arguments: CVarArg...) -> String {
        let resolved = language ?? currentOverride
        let template = string(key, language: resolved, fallback: fallback)
        return String(format: template, locale: formattingLocale(for: resolved), arguments: arguments)
    }

    /// The locale counted strings are formatted with: the chosen app language, or
    /// the device locale when the app follows the device.
    static func formattingLocale(for language: AppLanguage?) -> Locale {
        guard let code = language?.code else { return .current }
        return Locale(identifier: code)
    }
}

/// Thread-safe bundle cache. `Bundle` is immutable once created, so the only
/// shared state is the dictionary itself; a lock keeps it correct without
/// pulling the whole type onto an actor (it is read from services on background
/// executors and from `@MainActor` views alike).
private final class BundleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var bundles: [String: Bundle] = [:]

    func bundle(for language: AppLanguage) -> Bundle {
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[language.rawValue] { return cached }
        // `Bundle(path:)` fails only if the .lproj directory is missing, which
        // means the catalog has no translations for this language — a build
        // misconfiguration that `LanguageCoverageTests` catches. Degrading to
        // the main bundle keeps the app usable rather than crashing.
        let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:)) ?? .main
        bundles[language.rawValue] = bundle
        return bundle
    }
}
