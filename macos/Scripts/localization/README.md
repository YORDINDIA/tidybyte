# macOS Localization Pipeline

Tidybyte for Mac ships 21 languages (`en` plus 20 localized languages matching iOS: `hi`, `bn`, `ta`, `te`, `mr`, `gu`, `kn`, `ml`, `pa`, `es`, `fr`, `de`, `pt-BR`, `it`, `ja`, `ko`, `zh-Hans`, `ru`, `ar`, `he`).

## Catalogs

Because Tidybyte for Mac is a multi-target SwiftPM package, localization spans three catalogs:

| Catalog | Source | Output |
|---|---|---|
| Core | `Sources/MacOSCleanerCore` (+ MCP targets) | `Sources/MacOSCleanerCore/Resources/Localizable.xcstrings` |
| AppKit | `Sources/MacOSCleanerAppKit` (+ `MacOSCleaner`) | `Sources/MacOSCleanerAppKit/Resources/Localizable.xcstrings` |
| Info.plist | `Scripts/build-app.sh` usage descriptions | `Configuration/InfoPlist.xcstrings` |

Both SPM resource bundles (`Tidybyte_MacOSCleanerCore.bundle` and `Tidybyte_MacOSCleanerAppKit.bundle`) are embedded in `Tidybyte.app/Contents/Resources/` by `Scripts/build-app.sh`, and their `.lproj` tables are also merged into `Contents/Resources/<lang>.lproj/` alongside compiled `InfoPlist.strings`.

At runtime, `L10n` (`Sources/MacOSCleanerCore/Localization/MacL10n.swift`) searches `Bundle.main`, `Tidybyte_MacOSCleanerCore.bundle`, and `Tidybyte_MacOSCleanerAppKit.bundle` so lookups work identically across `.app`, `swift run`, `swift test`, and `xcodebuild test`.

## Commands

Run from `macos/`:

```sh
# Regenerate catalogs, seed shared translations from ios/, and validate
./Scripts/localization/refresh.sh

# Strict audit (after all Swift UI/Core strings are localized and translated)
node Scripts/localization/extract.mjs --check
node Scripts/localization/check.mjs --strict

# Prune obsolete catalog keys no longer referenced by Swift sources
./Scripts/localization/refresh.sh --prune
```

## Files

| Script / File | Purpose |
|---|---|
| `extract.mjs` | Scans Swift sources (`String(localized:)`, SwiftUI `Text`/`Label`/`Button`/..., `L10n.*`) and `Scripts/build-app.sh`, flags `(s)`, `L10n.*(rawValue)`, nested literals, and bare display properties |
| `build-catalog.mjs` | Seeds matching translations from `../ios/scripts/localization/translations/*.json`, builds Core, AppKit, and InfoPlist `.xcstrings` catalogs |
| `check.mjs` | Verifies 21-language coverage, placeholder parity, ICU CLDR plural rules, and `InfoPlist.xcstrings` parity |
| `plural-categories.mjs` | Derives CLDR plural categories per language from `Intl.PluralRules` |
| `format-placeholders.mjs` | Positional placeholder validator and rewriter |
| `translations/<lang>.json` | Per-language translation dictionaries (`strings` and `plurals`) |
| `translations/_glossary.json` | Terminology rules and keep-literal tokens |
| `translations/_plural-keys.json` | English `one`/`other` pairs for counted plural keys |
