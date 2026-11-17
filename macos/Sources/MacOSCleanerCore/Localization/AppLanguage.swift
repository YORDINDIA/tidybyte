import Foundation

/// Every language Tidybyte ships UI for, plus `.system`.
///
/// `.system` is the default and means "follow macOS": the app renders in
/// whatever language macOS resolves for it, which is the system or per-app
/// language from System Settings. Every other case is an explicit override
/// chosen in Tidybyte's own Settings screen.
///
/// The raw values are BCP-47 language identifiers and must match the
/// localization identifiers declared in `Localizable.xcstrings` (`hi`,
/// `pt-BR`, `zh-Hans`, …).
public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case english = "en"
    case hindi = "hi"
    case bengali = "bn"
    case tamil = "ta"
    case telugu = "te"
    case marathi = "mr"
    case gujarati = "gu"
    case kannada = "kn"
    case malayalam = "ml"
    case punjabi = "pa"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portugueseBrazil = "pt-BR"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"
    case russian = "ru"
    case arabic = "ar"
    case hebrew = "he"

    public var id: String { rawValue }

    /// The concrete language code, or `nil` for `.system`.
    public var code: String? { self == .system ? nil : rawValue }

    /// The languages that actually have translations. `.system` is excluded
    /// because it is a mode, not a language.
    public static var concreteLanguages: [AppLanguage] {
        allCases.filter { $0 != .system }
    }

    /// The language's name in its own script.
    ///
    /// Deliberately never translated so a user can always recognize their own
    /// language regardless of the active UI language.
    public var endonym: String {
        switch self {
        case .system: "Automatic"
        case .english: "English"
        case .hindi: "हिन्दी"
        case .bengali: "বাংলা"
        case .tamil: "தமிழ்"
        case .telugu: "తెలుగు"
        case .marathi: "मराठी"
        case .gujarati: "ગુજરાતી"
        case .kannada: "ಕನ್ನಡ"
        case .malayalam: "മലയാളം"
        case .punjabi: "ਪੰਜਾਬੀ"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .portugueseBrazil: "Português (Brasil)"
        case .italian: "Italiano"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .chineseSimplified: "简体中文"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .hebrew: "עברית"
        }
    }

    /// The English name of the language (for diagnostics and accessibility).
    public var englishName: String {
        switch self {
        case .system: "Automatic"
        case .english: "English"
        case .hindi: "Hindi"
        case .bengali: "Bengali"
        case .tamil: "Tamil"
        case .telugu: "Telugu"
        case .marathi: "Marathi"
        case .gujarati: "Gujarati"
        case .kannada: "Kannada"
        case .malayalam: "Malayalam"
        case .punjabi: "Punjabi"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .portugueseBrazil: "Portuguese (Brazil)"
        case .italian: "Italian"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .chineseSimplified: "Chinese (Simplified)"
        case .russian: "Russian"
        case .arabic: "Arabic"
        case .hebrew: "Hebrew"
        }
    }

    /// Languages written right to left. Drives the layout direction the app
    /// injects at the root.
    public var isRightToLeft: Bool {
        switch self {
        case .arabic, .hebrew: true
        default: false
        }
    }

    /// Alias for `isRightToLeft`.
    public var isRTL: Bool { isRightToLeft }

    /// The device's language as one of ours, or `nil` when macOS is set to a
    /// language Tidybyte does not ship.
    public static func matchingDeviceLanguage(preferred: [String] = Locale.preferredLanguages) -> AppLanguage? {
        for identifier in preferred {
            if let match = match(identifier: identifier) { return match }
        }
        return nil
    }

    /// Maps a single BCP-47 identifier onto a shipped language, ignoring region
    /// and script subtags that we do not differentiate on.
    public static func match(identifier: String) -> AppLanguage? {
        let tag = identifier.replacingOccurrences(of: "_", with: "-")
        let parts = tag.split(separator: "-").map(String.init)
        guard let base = parts.first?.lowercased() else { return nil }

        if base == "zh" {
            return matchChinese(subtags: parts.dropFirst().map { $0.lowercased() })
        }
        if base == "pt" {
            return .portugueseBrazil
        }
        guard let matched = AppLanguage(rawValue: base), matched != .system else {
            return nil
        }
        return matched
    }

    private static func matchChinese(subtags: [String]) -> AppLanguage? {
        if subtags.contains("hant") { return nil }
        if subtags.contains("hans") { return .chineseSimplified }
        let traditionalRegions: Set<String> = ["tw", "hk", "mo"]
        if subtags.contains(where: { traditionalRegions.contains($0) }) { return nil }
        return .chineseSimplified
    }
}
