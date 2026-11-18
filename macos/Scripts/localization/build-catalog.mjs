#!/usr/bin/env node
/**
 * Builds:
 *   - `Sources/MacOSCleanerCore/Resources/Localizable.xcstrings`
 *   - `Sources/MacOSCleanerAppKit/Resources/Localizable.xcstrings`
 *   - `Configuration/InfoPlist.xcstrings`
 *
 * Also seeds any matching keys from `../ios/scripts/localization/translations/<lang>.json`
 * into `scripts/localization/translations/<lang>.json` without overwriting existing
 * Mac translations.
 *
 * Preserves existing English `stringUnit.value` (e.g. Xcode's positionalized
 * `%1$@ and %2$lld more`), `comment`, and `extractionState` metadata.
 *
 * Run: node scripts/localization/build-catalog.mjs [--prune]
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LANGUAGES, pluralCategories } from './plural-categories.mjs';
import { positionalize } from './format-placeholders.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const CORE_CATALOG_PATH = join(ROOT, 'Sources/MacOSCleanerCore/Resources/Localizable.xcstrings');
const APPKIT_CATALOG_PATH = join(ROOT, 'Sources/MacOSCleanerAppKit/Resources/Localizable.xcstrings');
const INFO_PLIST_CATALOG_PATH = join(ROOT, 'Configuration/InfoPlist.xcstrings');
const BUILD_APP_PATH = join(ROOT, 'Scripts/build-app.sh');
const TRANSLATIONS_DIR = join(HERE, 'translations');
const IOS_TRANSLATIONS_DIR = join(ROOT, '..', 'ios/scripts/localization/translations');

const PLURAL_CATEGORIES = pluralCategories();
const prune = process.argv.includes('--prune');

function readJSON(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return fallback;
  }
}

function translationFile(dir, language) {
  const path = join(dir, `${language}.json`);
  if (!existsSync(path)) return {};
  const file = readJSON(path, undefined);
  if (file === undefined) {
    throw new Error(
      `${relative(ROOT, path)} exists but is not valid JSON; fix it before building the catalog`,
    );
  }
  return file;
}

function loadPlurals() {
  return readJSON(join(TRANSLATIONS_DIR, '_plural-keys.json'), {});
}

function readInfoPlistDescriptions() {
  if (!existsSync(BUILD_APP_PATH)) return [];
  const script = readFileSync(BUILD_APP_PATH, 'utf8');
  const found = [];
  const pattern = /<key>(\w*UsageDescription)<\/key>\s*<string>([^<]+)<\/string>/g;
  let match;
  while ((match = pattern.exec(script)) !== null) {
    found.push({ key: match[1], english: match[2] });
  }
  return found;
}

/**
 * Seeds matching translations from `../ios/scripts/localization/translations/`
 * for any key present in Mac sources/catalogs, without overwriting existing
 * Mac translations.
 */
function loadAndSeedTranslations(allMacKeys, pluralKeys) {
  mkdirSync(TRANSLATIONS_DIR, { recursive: true });
  const byLanguage = new Map();

  for (const language of LANGUAGES) {
    if (language === 'en') continue;
    const macFile = translationFile(TRANSLATIONS_DIR, language);
    const macStrings = { ...(macFile.strings ?? {}) };
    const macPlurals = { ...(macFile.plurals ?? {}) };

    let seededCount = 0;
    const iosPath = join(IOS_TRANSLATIONS_DIR, `${language}.json`);
    if (existsSync(iosPath)) {
      const iosFile = readJSON(iosPath, {});
      const iosStrings = iosFile.strings ?? {};
      const iosPlurals = iosFile.plurals ?? {};

      for (const key of allMacKeys) {
        if (!macStrings[key] && typeof iosStrings[key] === 'string' && iosStrings[key].length > 0) {
          macStrings[key] = iosStrings[key];
          seededCount += 1;
        }
        if (pluralKeys.has(key) && !macPlurals[key] && iosPlurals[key]) {
          macPlurals[key] = iosPlurals[key];
          seededCount += 1;
        }
      }
    }

    const sortedStrings = Object.fromEntries(
      Object.entries(macStrings).sort(([a], [b]) => a.localeCompare(b)),
    );
    const sortedPlurals = Object.fromEntries(
      Object.entries(macPlurals).sort(([a], [b]) => a.localeCompare(b)),
    );

    const nextFile = { strings: sortedStrings };
    if (Object.keys(sortedPlurals).length > 0) {
      nextFile.plurals = sortedPlurals;
    }

    const outPath = join(TRANSLATIONS_DIR, `${language}.json`);
    const nextJSON = JSON.stringify(nextFile, null, 2) + '\n';
    const prevJSON = existsSync(outPath) ? readFileSync(outPath, 'utf8') : null;
    if (prevJSON !== nextJSON || seededCount > 0) {
      writeFileSync(outPath, nextJSON);
    }

    byLanguage.set(language, {
      strings: sortedStrings,
      plurals: sortedPlurals,
    });
  }

  return byLanguage;
}

function stringUnit(value, state = 'translated') {
  return { stringUnit: { state, value } };
}

function localizationsFor(key, existingEntry, pluralForms, translations) {
  const localizations = {};
  const englishPlural = pluralForms?.[key];
  const isPlural = Boolean(englishPlural);

  const existingEnglishValue = existingEntry?.localizations?.en?.stringUnit?.value;
  const englishSource = isPlural ? key : (existingEnglishValue || key);

  for (const language of LANGUAGES) {
    if (language === 'en') {
      if (isPlural) {
        const categories = {};
        for (const category of PLURAL_CATEGORIES.en) {
          const value = englishPlural[category] ?? englishPlural.other;
          if (value) categories[category] = stringUnit(value);
        }
        localizations.en = { variations: { plural: categories } };
      } else {
        const enState = existingEntry?.localizations?.en?.stringUnit?.state ?? 'translated';
        localizations.en = stringUnit(englishSource, enState);
      }
      continue;
    }

    const translation = translations.get(language) ?? { strings: {}, plurals: {} };

    if (isPlural) {
      const forms = translation.plurals?.[key];
      const categories = {};
      for (const category of PLURAL_CATEGORIES[language]) {
        const value = forms?.[category];
        if (value) {
          const englishForm = englishPlural[category] ?? englishPlural.other ?? key;
          categories[category] = stringUnit(positionalize(englishForm, value));
        }
      }
      if (Object.keys(categories).length > 0) {
        localizations[language] = { variations: { plural: categories } };
        continue;
      }
    }

    const translated = translation.strings?.[key];
    if (typeof translated === 'string' && translated.length > 0) {
      localizations[language] = isPlural
        ? { variations: { plural: { other: stringUnit(positionalize(key, translated)) } } }
        : stringUnit(positionalize(englishSource, translated));
    } else {
      // Preserve an existing already-translated entry in the catalog if present
      // and not marked needs_review.
      const existingLang = existingEntry?.localizations?.[language];
      if (!isPlural && existingLang?.stringUnit?.state === 'translated' && existingLang.stringUnit.value) {
        localizations[language] = stringUnit(positionalize(englishSource, existingLang.stringUnit.value));
      } else {
        localizations[language] = stringUnit(englishSource, 'needs_review');
      }
    }
  }

  return localizations;
}

function buildTargetCatalog(catalogPath, label, targetKeys, plurals, translations) {
  const existing = readJSON(catalogPath, { sourceLanguage: 'en', strings: {}, version: '1.0' });
  const existingStrings = existing.strings ?? {};

  const live = new Set(targetKeys);
  const keys = new Set();
  const pruned = [];

  for (const key of Object.keys(existingStrings)) {
    if (!key.trim()) continue;
    if (prune && !live.has(key)) {
      pruned.push(key);
      continue;
    }
    keys.add(key);
  }
  for (const key of targetKeys) {
    if (key.trim()) keys.add(key);
  }

  const strings = {};
  for (const key of [...keys].sort()) {
    const existingEntry = existingStrings[key];
    const entry = {};
    if (existingEntry?.comment) entry.comment = existingEntry.comment;
    if (existingEntry?.extractionState) entry.extractionState = existingEntry.extractionState;
    if (typeof existingEntry?.generatesSymbol === 'boolean') entry.generatesSymbol = existingEntry.generatesSymbol;
    entry.localizations = localizationsFor(key, existingEntry, plurals, translations);
    strings[key] = entry;
  }

  mkdirSync(dirname(catalogPath), { recursive: true });
  writeFileSync(
    catalogPath,
    JSON.stringify({ sourceLanguage: 'en', strings, version: '1.0' }, null, 2) + '\n',
  );

  const totalKeys = Object.keys(strings).length;
  console.log(`${label} catalog written: ${totalKeys} keys`);
  if (pruned.length > 0) {
    console.log(`  Pruned ${pruned.length} unused key(s) from ${label}`);
  }
  return strings;
}

function buildInfoPlistCatalog(infoPlistItems, translations) {
  const existing = readJSON(INFO_PLIST_CATALOG_PATH, { sourceLanguage: 'en', strings: {}, version: '1.0' });
  const existingStrings = existing.strings ?? {};
  const strings = {};

  // Keep CFBundleDisplayName as literal brand name across all 21 languages.
  const displayNameLocalizations = {};
  for (const language of LANGUAGES) {
    displayNameLocalizations[language] = stringUnit('Tidybyte');
  }
  strings.CFBundleDisplayName = {
    comment: existingStrings.CFBundleDisplayName?.comment ?? 'CFBundleDisplayName. Kept as the brand name in every language.',
    extractionState: 'manual',
    localizations: displayNameLocalizations,
  };

  for (const item of infoPlistItems) {
    const existingEntry = existingStrings[item.key];
    const existingEn = existingEntry?.localizations?.en?.stringUnit?.value;
    const englishUnchanged = existingEn === item.english;
    const localizations = {
      en: stringUnit(item.english),
    };

    for (const language of LANGUAGES) {
      if (language === 'en') continue;
      const translation = translations.get(language)?.strings?.[item.english];
      const existingLang = englishUnchanged ? existingEntry?.localizations?.[language] : null;
      if (typeof translation === 'string' && translation.length > 0) {
        localizations[language] = stringUnit(translation);
      } else if (existingLang?.stringUnit?.state === 'translated' && existingLang.stringUnit.value) {
        localizations[language] = stringUnit(existingLang.stringUnit.value);
      } else {
        localizations[language] = stringUnit(item.english, 'needs_review');
      }
    }

    strings[item.key] = {
      comment: existingEntry?.comment ?? `${item.key} — macOS permission prompt.`,
      extractionState: 'manual',
      localizations,
    };
  }

  mkdirSync(dirname(INFO_PLIST_CATALOG_PATH), { recursive: true });
  writeFileSync(
    INFO_PLIST_CATALOG_PATH,
    JSON.stringify({ sourceLanguage: 'en', strings, version: '1.0' }, null, 2) + '\n',
  );
  console.log(`InfoPlist catalog written: ${Object.keys(strings).length} keys`);
}

function main() {
  const found = readJSON(join(HERE, 'strings.found.json'), {
    keys: [],
    coreKeys: [],
    appKitKeys: [],
    infoPlist: [],
  });
  const plurals = loadPlurals();
  const pluralKeys = new Set(Object.keys(plurals));

  const coreExisting = readJSON(CORE_CATALOG_PATH, { strings: {} });
  const appKitExisting = readJSON(APPKIT_CATALOG_PATH, { strings: {} });
  const infoPlistItems = found.infoPlist?.length ? found.infoPlist : readInfoPlistDescriptions();

  const allMacKeys = new Set([
    ...(found.coreKeys ?? []),
    ...(found.appKitKeys ?? []),
    ...Object.keys(coreExisting.strings ?? {}),
    ...Object.keys(appKitExisting.strings ?? {}),
    ...Object.keys(plurals),
    ...infoPlistItems.map((item) => item.english),
  ]);

  const translations = loadAndSeedTranslations(allMacKeys, pluralKeys);

  const coreTargetKeys = new Set(found.coreKeys ?? []);
  const appKitTargetKeys = new Set(found.appKitKeys ?? []);
  // Ensure plural keys land in the catalog(s) that reference them (defaulting to AppKit if unreferenced yet).
  for (const pKey of pluralKeys) {
    if (!coreTargetKeys.has(pKey) && !appKitTargetKeys.has(pKey)) {
      appKitTargetKeys.add(pKey);
    }
  }

  buildTargetCatalog(CORE_CATALOG_PATH, 'Core', coreTargetKeys, plurals, translations);
  buildTargetCatalog(APPKIT_CATALOG_PATH, 'AppKit', appKitTargetKeys, plurals, translations);
  buildInfoPlistCatalog(infoPlistItems, translations);
}

main();
