import Foundation

/// String lookup resolving across `Bundle.main` and Core/AppKit SwiftPM resource
/// bundles for live `.lproj` language switching and testing.
///
/// Inside SwiftUI views, `Text("key")` resolves against `\.locale`, so switching
/// language updates views immediately without a relaunch. Core services, CLI
/// output, error messages, and dynamically formatted strings have no SwiftUI
/// environment, so they resolve through `L10n` against the chosen language's
/// `.lproj` bundle.
public enum L10n {
    private static let missingSentinel = "\u{0007}__TIDYBYTE_L10N_MISSING__\u{0007}"
    private static let cache = BundleCache()

    /// The user's active override, or `nil` when following macOS.
    public static var currentOverride: AppLanguage? { LanguagePreferenceStore.stored() }

    /// Registers an additional SPM resource bundle (such as AppKit's
    /// `Bundle.module`) so `L10n` checks its `.lproj` tables as well.
    public static func registerBundle(_ bundle: Bundle) {
        cache.register(bundle)
    }

    /// Primary `.lproj` bundle for `language`, or `.main` when following macOS.
    public static func bundle(for language: AppLanguage?) -> Bundle {
        guard let language, language != .system else { return .main }
        return cache.candidateBundles(for: language).first ?? .main
    }

    /// Ordered candidate bundles searched when resolving strings for `language`.
    public static func bundles(for language: AppLanguage?) -> [Bundle] {
        cache.candidateBundles(for: language)
    }

    /// Marks a literal as a catalog key without resolving it immediately.
    public static func key(_ key: String) -> String { key }

    /// Looks up `key` in the chosen language's `.lproj` tables across
    /// `Bundle.main`, `MacOSCleanerCore`, and `MacOSCleanerAppKit`.
    public static func string(_ key: String, language: AppLanguage? = nil, fallback: String? = nil) -> String {
        let resolvedLanguage = language ?? currentOverride
        for candidate in cache.candidateBundles(for: resolvedLanguage) {
            let value = candidate.localizedString(forKey: key, value: missingSentinel, table: nil)
            if value != missingSentinel {
                return value
            }
        }
        return fallback ?? key
    }

    /// Looks up a localized format template (including `.stringsdict` plural
    /// rules) and formats `arguments` with the resolved locale.
    public static func format(
        _ key: String,
        language: AppLanguage? = nil,
        fallback: String? = nil,
        _ arguments: CVarArg...
    ) -> String {
        format(key, language: language, fallback: fallback, arguments: arguments)
    }

    /// Array-based variant of `format(_:language:fallback:_:)`.
    public static func format(
        _ key: String,
        language: AppLanguage? = nil,
        fallback: String? = nil,
        arguments: [CVarArg]
    ) -> String {
        let resolvedLanguage = language ?? currentOverride
        let template = string(key, language: resolvedLanguage, fallback: fallback)
        return String(format: template, locale: formattingLocale(for: resolvedLanguage), arguments: arguments)
    }

    /// Locale used for plural selection and number formatting.
    public static func formattingLocale(for language: AppLanguage?) -> Locale {
        guard let code = language?.code else { return .current }
        return Locale(identifier: code)
    }
}

/// Thread-safe cache of discovered base bundles and per-language `.lproj`
/// sub-bundles.
private final class BundleCache: @unchecked Sendable {
    private static let knownBundleNames = [
        "Tidybyte_MacOSCleanerCore.bundle",
        "Tidybyte_MacOSCleanerAppKit.bundle"
    ]

    private let lock = NSLock()
    private var lprojBundles: [String: [Bundle]] = [:]
    private var registeredBundles: [Bundle] = []

    func register(_ bundle: Bundle) {
        lock.lock()
        defer { lock.unlock() }
        if !registeredBundles.contains(where: { $0.bundleURL == bundle.bundleURL }) {
            registeredBundles.append(bundle)
            lprojBundles.removeAll()
        }
    }

    func candidateBundles(for language: AppLanguage?) -> [Bundle] {
        guard let language, language != .system else {
            return unlocalizedSearchBundles()
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached = lprojBundles[language.rawValue] {
            return cached
        }
        var resolved: [Bundle] = []
        var seenURLs: Set<URL> = []
        for base in discoveredBaseBundlesLocked() {
            guard let path = base.path(forResource: language.rawValue, ofType: "lproj"),
                  let localized = Bundle(path: path),
                  seenURLs.insert(localized.bundleURL).inserted else {
                continue
            }
            resolved.append(localized)
        }
        if resolved.isEmpty {
            resolved = [.main]
        }
        lprojBundles[language.rawValue] = resolved
        return resolved
    }

    private func unlocalizedSearchBundles() -> [Bundle] {
        lock.lock()
        defer { lock.unlock() }
        return discoveredBaseBundlesLocked()
    }

    private func discoveredBaseBundlesLocked() -> [Bundle] {
        var bases: [Bundle] = []
        var seenURLs: Set<URL> = []

        func appendUnique(_ bundle: Bundle?) {
            guard let bundle else { return }
            if seenURLs.insert(bundle.bundleURL).inserted {
                bases.append(bundle)
            }
        }

        appendUnique(.main)

        let anchorBundle = Bundle(for: BundleCache.self)
        let searchDirectories: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            anchorBundle.resourceURL,
            anchorBundle.bundleURL.deletingLastPathComponent(),
            anchorBundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        ]

        var foundCore = false
        for directory in searchDirectories.compactMap({ $0 }) {
            for bundleName in Self.knownBundleNames {
                let candidateURL = directory.appendingPathComponent(bundleName, isDirectory: true)
                if FileManager.default.fileExists(atPath: candidateURL.path),
                   let bundle = Bundle(url: candidateURL) {
                    appendUnique(bundle)
                    if bundleName == "Tidybyte_MacOSCleanerCore.bundle" {
                        foundCore = true
                    }
                }
            }
        }

        // Only evaluate SwiftPM's `Bundle.module` when disk discovery didn't find
        // Core's bundle (avoids `Bundle.module`'s buildPath fatalError if a signed
        // app bundle is moved off the build host).
        if !foundCore {
            appendUnique(.module)
        }

        for extra in registeredBundles {
            appendUnique(extra)
        }

        return bases
    }
}
