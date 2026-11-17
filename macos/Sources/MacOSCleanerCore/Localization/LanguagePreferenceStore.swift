import Foundation

/// Persists the user's explicit UI language override in `UserDefaults`.
///
/// An absent value means "follow macOS" (`.system`), so a fresh install and an
/// explicit "Automatic" selection behave identically.
public enum LanguagePreferenceStore {
    public static let key = "appLanguagePreference"

    /// Writes the choice to `defaults`. Passing `nil` or `.system` clears the
    /// stored key so a fresh install and "Automatic" behave identically.
    public static func save(_ language: AppLanguage?, to defaults: UserDefaults = .standard) {
        if let code = language?.code {
            defaults.set(code, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Reads the stored override from `defaults`, returning `nil` for `.system`
    /// or any unrecognized value.
    public static func stored(in defaults: UserDefaults = .standard) -> AppLanguage? {
        decode(defaults.string(forKey: key))
    }

    /// Mirrors the override into `AppleLanguages` in `defaults` so macOS-owned
    /// UI (file panels, permission alerts) follows the chosen language on next
    /// launch.
    public static func applyToSystem(_ language: AppLanguage?, to defaults: UserDefaults = .standard) {
        if let code = language?.code {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    private static func decode(_ raw: String?) -> AppLanguage? {
        guard let raw, let language = AppLanguage(rawValue: raw), language != .system else {
            return nil
        }
        return language
    }
}
