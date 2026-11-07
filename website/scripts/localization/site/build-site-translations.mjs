#!/usr/bin/env node
// Builds the 20 localized landing pages from the English original plus the
// per-language string maps produced by the translation batches.
//
// Translating by hand-editing 20 copies of a component this size invites
// structural drift — a dropped `class`, a mangled SVG path, a stray `</div>`.
// This script takes the English component (src/components/HomeMain.astro) as
// the structural source of truth and replaces only the text that differs, so
// every localized page is guaranteed to have the same markup as the page the
// design was built and reviewed against.
//
// It also rewrites the English snapshot src/content/pages/index.html — the
// component with its frontmatter stripped — because the llms.txt and *.md
// endpoints read that file as plain HTML and it must always match what the
// page renders.
//
// Run: node scripts/localization/site/build-site-translations.mjs
// In:  src/components/HomeMain.astro
//      scripts/localization/site/site-translations/<slug>.json
// Out: src/content/pages/index.<slug>.astro  (one per language)
//      src/content/pages/index.html          (English snapshot)

import { readFileSync, writeFileSync, readdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { isKeepLiteral } from "./keep-literal.mjs";
import { isTranslatable, mapMarkupStrings } from "./markup-strings.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const SOURCE = join(root, "src", "components", "HomeMain.astro");
const SNAPSHOT = join(root, "src", "content", "pages", "index.html");
const TRANSLATIONS = join(here, "site-translations");

const PLACEHOLDER_MARKER = /^<!-- PLACEHOLDER COPY[\s\S]*?-->\s*\n?/m;

function translate(source, map, stats) {
  return mapMarkupStrings(source, (value, kind) => {
    const key = value.trim();
    if (!key || !(key in map)) {
      if (isTranslatable(key) && !isKeepLiteral(key)) stats.unmatched.add(key);
      return value;
    }
    stats.replaced.add(key);
    if (kind === "attribute") return map[key];
    const leading = value.slice(0, value.length - value.trimStart().length);
    const trailing = value.slice(value.trimEnd().length);
    return `${leading}${map[key]}${trailing}`;
  });
}

/// Builds one page from one translation file.
///
/// `file` is the basename exactly as it is on disk (`pt-BR.json`,
/// `zh-Hans.json`), because the read has to survive Linux's case-sensitive
/// filesystem. The OUTPUT name is the lowercased slug, and that is
/// load-bearing rather than cosmetic: every consumer of the generated page is
/// lowercase. `src/data/languages.ts` keys the routes `pt-br` / `zh-hans`,
/// `src/lib/localized-page.ts` imports `index.${lang.slug}.astro`, and the
/// tracked files are lowercase. Writing `index.pt-BR.astro` happens to read
/// correctly on macOS/APFS (case-insensitive, so the write lands on the tracked
/// inode) and silently creates a duplicate on Linux CI, where the tracked page
/// then goes stale. `git diff` cannot see the duplicate because it is untracked.
function buildOne(file) {
  const map = JSON.parse(readFileSync(join(TRANSLATIONS, file), "utf8"));
  const slug = file.replace(/\.json$/, "").toLowerCase();
  const source = readFileSync(SOURCE, "utf8");
  const stats = { replaced: new Set(), unmatched: new Set() };

  const body = translate(source.replace(PLACEHOLDER_MARKER, ""), map, stats);

  // A key the page never uses means the map has drifted from the English file —
  // usually a copy that was reworded on one side only.
  const unused = Object.keys(map).filter((key) => !stats.replaced.has(key));

  writeFileSync(join(root, "src", "content", "pages", `index.${slug}.astro`), body);

  return { slug, replaced: stats.replaced.size, unused, unmatched: [...stats.unmatched] };
}

// The English snapshot: the component with its frontmatter stripped, so the
// llms.txt / *.md endpoints keep reading plain HTML that matches the page.
writeFileSync(SNAPSHOT, readFileSync(SOURCE, "utf8").replace(/^---[\s\S]*?---\s*\n/, ""));

if (!existsSync(TRANSLATIONS)) {
  console.error(`no translations directory: ${TRANSLATIONS}`);
  process.exit(1);
}

const files = readdirSync(TRANSLATIONS)
  // `*.meta.json` holds the title and description for a page, not the body
  // strings. Without excluding it the slug parses as `ar.meta` and the builder
  // writes a bogus `index.ar.meta.html` alongside the real page.
  .filter((name) => name.endsWith(".json") && !name.endsWith(".meta.json"))
  .sort();

if (files.length === 0) {
  console.error("no translation files found");
  process.exit(1);
}

let failed = false;

for (const file of files) {
  const result = buildOne(file);
  const notes = [];
  if (result.unused.length) notes.push(`${result.unused.length} unused key(s)`);
  if (result.unmatched.length) notes.push(`${result.unmatched.length} untranslated string(s)`);

  const status = notes.length ? `  ${notes.join(", ")}` : "";
  console.log(`index.${result.slug}.astro: ${result.replaced} strings replaced${status}`);

  for (const key of result.unused) console.log(`    unused:      ${key.slice(0, 78)}`);
  for (const key of result.unmatched) console.log(`    untranslated: ${key.slice(0, 78)}`);

  // An unmatched English string would ship as English inside a page that
  // declares another language, which is the exact failure this pipeline exists
  // to prevent.
  if (result.unmatched.length) failed = true;
}

console.log(`\n${files.length} localized page(s) written`);
if (failed) {
  console.error("FAIL: some strings had no translation");
  process.exit(1);
}
