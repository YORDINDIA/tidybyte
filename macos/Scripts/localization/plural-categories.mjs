/**
 * The CLDR plural categories each shipped language actually uses.
 *
 * Derived from ICU through `Intl.PluralRules` rather than hand-maintained so
 * `build-catalog.mjs` and `check.mjs` cannot disagree.
 */

/** The shipped languages, in the order the Settings picker shows them. */
export const LANGUAGES = [
  'en', 'hi', 'bn', 'ta', 'te', 'mr', 'gu', 'kn', 'ml', 'pa',
  'es', 'fr', 'de', 'pt-BR', 'it', 'ja', 'ko', 'zh-Hans', 'ru', 'ar', 'he',
];

/**
 * Order matters: the catalog writes variations in this order so `git diff`
 * remains deterministic and readable.
 */
const CATEGORY_ORDER = ['zero', 'one', 'two', 'few', 'many', 'other'];

/** Categories ICU reports for a language, in `CATEGORY_ORDER`. */
export function pluralCategoriesFor(language) {
  const resolved = new Intl.PluralRules(language).resolvedOptions().pluralCategories;
  const set = new Set(resolved);
  return CATEGORY_ORDER.filter((category) => set.has(category));
}

/** Every shipped language mapped to its categories. */
export function pluralCategories() {
  return Object.fromEntries(LANGUAGES.map((language) => [language, pluralCategoriesFor(language)]));
}

/**
 * `true` when ICU's answer differs from the expected baseline for a language.
 */
export function pluralCategoriesDisagree(a, b) {
  if (!a || !b) return true;
  return a.length !== b.length || a.some((category, index) => category !== b[index]);
}
