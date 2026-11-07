#!/usr/bin/env node
// Extracts the translatable strings from the English landing page.
//
// The landing page body is the Astro component
// src/components/HomeMain.astro, so most of the file is markup: Tailwind
// classes, SVG paths, data attributes. Only text nodes and a handful of
// text-bearing attributes change between languages. Translating by
// hand-editing 20 copies of a component this size invites structural drift,
// so this script pulls out the strings that actually need translating and
// `build-site-translations.mjs` puts them back into one generated copy of
// the component per language.
//
// Run: node scripts/localization/site/extract-site-strings.mjs
// Out: scripts/localization/site/site-strings.json  { source, strings: [...] }

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { KEEP_LITERAL } from "./keep-literal.mjs";
import { isTranslatable, mapMarkupStrings } from "./markup-strings.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const SOURCE = join(root, "src", "components", "HomeMain.astro");

const html = readFileSync(SOURCE, "utf8");
const found = new Set();

// Every inline tag is a hard boundary: `>([^<>]+)<` cannot see across an `<a>`,
// a `<strong>` or a `<span>`. A sentence that wraps a link therefore reaches a
// translator as fragments ("Open an issue on", "or use the contact form on the",
// "page."), and that is deliberate: keeping the markup out of the string is what
// lets the builder put translations back into the English page without parsing
// HTML, and it keeps a mistranslated href out of the map entirely.
//
// The cost is real and is not fixable here: fragments cannot be reordered, so an
// SOV language (Tamil, Telugu, Kannada, Malayalam) glues them back in English
// order and the sentence reads as translated English. Where word order matters,
// write the sentence as one full sentence inside a single text node instead of
// splitting it around a link.
mapMarkupStrings(html, (value) => {
  const text = value.trim();
  if (isTranslatable(text)) found.add(text);
  return value;
});

const strings = [...found].filter((text) => !KEEP_LITERAL.has(text)).sort();

mkdirSync(here, { recursive: true });
writeFileSync(
  join(here, "site-strings.json"),
  `${JSON.stringify({ source: "src/components/HomeMain.astro", strings }, null, 2)}\n`,
);

console.log(`site-strings.json: ${strings.length} strings`);
console.log(`  skipped ${KEEP_LITERAL.size} keep-literal entries`);

// --- Head metadata -------------------------------------------------------
//
// The landing page and this extractor read the same plain-text metadata.
const metaPath = join(root, "src", "data", "home-meta.json");
const meta = JSON.parse(readFileSync(metaPath, "utf8"));
if (typeof meta.title !== "string" || typeof meta.description !== "string") {
  throw new Error(`${metaPath}: title and description must be strings`);
}

writeFileSync(
  join(here, "site-meta.json"),
  `${JSON.stringify(
    {
      source: "src/data/home-meta.json",
      limits: { title: 65, description: 165 },
      meta,
    },
    null,
    2,
  )}\n`,
);

console.log(`site-meta.json: title ${meta.title.length}/65, description ${meta.description.length}/165`);
