#!/usr/bin/env node
/**
 * Validates the macOS String Catalogs (Core, AppKit, and InfoPlist).
 *
 * Run in CI: `node scripts/localization/check.mjs [--strict]`
 *
 * Four checks:
 *   1. Coverage — every key has an entry for every one of the 21 shipped languages.
 *   2. Placeholder parity — translated strings match English format specifiers.
 *   3. Plural categories — every plural entry has exact ICU CLDR categories.
 *   4. InfoPlist parity — every `*UsageDescription` in `Scripts/build-app.sh`
 *      exists in `Configuration/InfoPlist.xcstrings` with matching English source.
 */

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LANGUAGES, pluralCategories, pluralCategoriesDisagree } from './plural-categories.mjs';
import { argumentsMatch } from './format-placeholders.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const CORE_CATALOG_PATH = join(ROOT, 'Sources/MacOSCleanerCore/Resources/Localizable.xcstrings');
const APPKIT_CATALOG_PATH = join(ROOT, 'Sources/MacOSCleanerAppKit/Resources/Localizable.xcstrings');
const PLURAL_KEYS_PATH = join(HERE, 'translations/_plural-keys.json');
const INFO_PLIST_CATALOG_PATH = join(ROOT, 'Configuration/InfoPlist.xcstrings');
const BUILD_APP_PATH = join(ROOT, 'Scripts/build-app.sh');

const PLURAL_CATEGORIES = pluralCategories();

const EXPECTED_CATEGORIES = {
  en: ['one', 'other'], hi: ['one', 'other'], bn: ['one', 'other'],
  ta: ['one', 'other'], te: ['one', 'other'], mr: ['one', 'other'],
  gu: ['one', 'other'], kn: ['one', 'other'], ml: ['one', 'other'],
  pa: ['one', 'other'], es: ['one', 'many', 'other'], fr: ['one', 'many', 'other'],
  de: ['one', 'other'], 'pt-BR': ['one', 'many', 'other'], it: ['one', 'many', 'other'],
  ja: ['other'], ko: ['other'], 'zh-Hans': ['other'],
  ru: ['one', 'few', 'many', 'other'],
  ar: ['zero', 'one', 'two', 'few', 'many', 'other'],
  he: ['one', 'two', 'other'],
};

const strict = process.argv.includes('--strict');
let failures = 0;

function fail(message) {
  console.error(`FAIL: ${message}`);
  failures += 1;
}

function entryValues(entry, language) {
  const localization = entry.localizations?.[language];
  if (!localization) return null;
  if (localization.stringUnit) return { plain: localization.stringUnit };
  if (localization.variations?.plural) return { plural: localization.variations.plural };
  return null;
}

function checkCatalog(path, label) {
  if (!existsSync(path)) {
    fail(`${label} catalog not found at ${path}`);
    return;
  }
  const catalog = JSON.parse(readFileSync(path, 'utf8'));
  const strings = catalog.strings ?? {};
  const keys = Object.keys(strings);
  const pluralKeys = new Set(
    existsSync(PLURAL_KEYS_PATH) ? Object.keys(JSON.parse(readFileSync(PLURAL_KEYS_PATH, 'utf8'))) : [],
  );

  console.log(`\n${label}: ${keys.length} keys`);

  const untranslated = new Map();

  for (const key of keys) {
    const entry = strings[key];
    const english = entryValues(entry, 'en');
    if (!english) {
      fail(`${label}: "${key}" has no English source value`);
      continue;
    }

    for (const language of LANGUAGES) {
      if (language === 'en') continue;
      const value = entryValues(entry, language);
      if (!value) {
        fail(`${label}: "${key}" is missing language ${language}`);
        continue;
      }

      const englishForms = english.plural
        ? Object.values(english.plural).map((unit) => unit.stringUnit?.value ?? '')
        : [english.plain.value ?? ''];

      if (value.plural) {
        const expected = PLURAL_CATEGORIES[language] ?? [];
        const actual = Object.keys(value.plural).sort();
        const wanted = [...expected].sort();
        if (actual.join(',') !== wanted.join(',')) {
          fail(
            `${label}: "${key}" [${language}] plural categories are [${actual.join(', ')}], expected [${wanted.join(', ')}]`,
          );
        }
      }

      const translatedForms = value.plural
        ? Object.values(value.plural).map((unit) => unit.stringUnit?.value ?? '')
        : [value.plain.value ?? ''];

      for (const form of translatedForms) {
        if (!englishForms.some((source) => argumentsMatch(source, form))) {
          fail(
            `${label}: "${key}" [${language}] placeholder mismatch\n      en: ${JSON.stringify(englishForms[0])}\n      ${language}: ${JSON.stringify(form)}`,
          );
        }
      }

      const isMarked = value.plain
        ? value.plain.state === 'needs_review'
        : Object.values(value.plural).every((unit) => unit.stringUnit?.state === 'needs_review');
      if (isMarked) {
        untranslated.set(language, (untranslated.get(language) ?? 0) + 1);
      }
    }
  }

  for (const key of pluralKeys) {
    if (!strings[key]) continue;
    if (!entryValues(strings[key], 'en')?.plural) {
      fail(`${label}: "${key}" is listed as a plural key but has no English plural variations`);
    }
  }

  const total = keys.length;
  for (const language of LANGUAGES) {
    if (language === 'en') continue;
    const missingCount = untranslated.get(language) ?? 0;
    const done = total - missingCount;
    const pct = total > 0 ? ((done / total) * 100).toFixed(0) : '100';
    const flag = missingCount === 0 ? 'ok' : 'needs work';
    console.log(`  ${language.padEnd(8)} ${String(done).padStart(4)}/${total}  ${pct.padStart(3)}%  ${flag}`);
    if (strict && missingCount > 0) {
      fail(`${label}: ${language} has ${missingCount} untranslated keys`);
    }
  }
}

function checkInfoPlistCatalog() {
  const label = 'Info.plist';

  if (!existsSync(INFO_PLIST_CATALOG_PATH)) {
    fail(`${label} catalog not found at ${INFO_PLIST_CATALOG_PATH}`);
    return;
  }
  if (!existsSync(BUILD_APP_PATH)) {
    fail(`${label}: Scripts/build-app.sh not found at ${BUILD_APP_PATH}`);
    return;
  }

  const catalog = JSON.parse(readFileSync(INFO_PLIST_CATALOG_PATH, 'utf8'));
  const strings = catalog.strings ?? {};
  const keys = Object.keys(strings);

  const buildScript = readFileSync(BUILD_APP_PATH, 'utf8');
  const required = new Map();
  for (const match of buildScript.matchAll(/<key>(\w*UsageDescription)<\/key>\s*<string>([^<]+)<\/string>/g)) {
    required.set(match[1], match[2]);
  }

  console.log(`\n${label}: ${keys.length} keys`);

  if (required.size === 0) {
    fail(`${label}: no *UsageDescription keys found in Scripts/build-app.sh`);
  }

  for (const [key, englishText] of required) {
    if (!strings[key]) {
      fail(
        `${label}: "${key}" is set in Scripts/build-app.sh but has no catalog entry — ` +
        'macOS permission prompt will stay English in every language',
      );
      continue;
    }
    const enValue = entryValues(strings[key], 'en')?.plain?.value;
    if (enValue !== englishText) {
      fail(`${label}: "${key}" English value in catalog does not match Scripts/build-app.sh`);
    }
  }

  for (const key of keys) {
    if (key.endsWith('UsageDescription') && !required.has(key)) {
      fail(`${label}: "${key}" is in the catalog but not set in Scripts/build-app.sh`);
    }
  }

  let incomplete = 0;
  for (const key of keys) {
    const entry = strings[key];
    const english = entryValues(entry, 'en');
    if (!english) {
      fail(`${label}: "${key}" has no English source value`);
      continue;
    }

    for (const language of LANGUAGES) {
      if (language === 'en') continue;
      const value = entryValues(entry, language);
      if (!value) {
        fail(`${label}: "${key}" is missing language ${language}`);
        incomplete += 1;
        continue;
      }
      if (value.plain?.state === 'needs_review') {
        incomplete += 1;
      }
    }
  }

  const total = keys.length * (LANGUAGES.length - 1);
  const done = total - incomplete;
  const pct = total > 0 ? ((done / total) * 100).toFixed(0) : '100';
  console.log(`  coverage   ${String(done).padStart(4)}/${total}  ${pct.padStart(3)}%  ${incomplete === 0 ? 'ok' : 'needs work'}`);
  // InfoPlist permission strings must always be translated in all 21 languages.
  if (incomplete > 0) {
    fail(`${label}: ${incomplete} untranslated value(s)`);
  }
}

function checkPluralRulesMatchICU() {
  let drifted = 0;
  for (const language of LANGUAGES) {
    if (pluralCategoriesDisagree(PLURAL_CATEGORIES[language], EXPECTED_CATEGORIES[language])) {
      fail(
        `${language}: ICU reports plural categories [${(PLURAL_CATEGORIES[language] ?? []).join(', ')}] `
        + `but this repo expects [${(EXPECTED_CATEGORIES[language] ?? []).join(', ')}].`,
      );
      drifted += 1;
    }
  }
  if (drifted === 0) {
    console.log(`Plural rules: ICU matches the expected category set for all ${LANGUAGES.length} languages.`);
  }
}

checkPluralRulesMatchICU();
checkCatalog(CORE_CATALOG_PATH, 'Core');
checkCatalog(APPKIT_CATALOG_PATH, 'AppKit');
checkInfoPlistCatalog();

console.log('');
if (failures > 0) {
  console.error(`${failures} problem(s) found.`);
  process.exit(1);
}
console.log('Localization checks passed.');
