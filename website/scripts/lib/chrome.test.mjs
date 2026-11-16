import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const dir = join(root, 'scripts', 'localization', 'site', 'site-translations');
const en = JSON.parse(readFileSync(join(dir, 'en.chrome.json'), 'utf8'));
const enKeys = Object.keys(en).sort();
const langFiles = readdirSync(dir).filter((f) => f.endsWith('.chrome.json') && f !== 'en.chrome.json');

// The published languages, from the same list the site builds from.
const languagesSource = readFileSync(join(root, 'src', 'data', 'languages.ts'), 'utf8');
const siteBlock = languagesSource.slice(languagesSource.indexOf('export const SITE_LANGUAGES'));
const siteCodes = [...siteBlock.slice(0, siteBlock.indexOf('];')).matchAll(/code: "([^"]+)"/g)].map((m) => m[1]);
const fileCodes = langFiles.map((f) => f.slice(0, -'.chrome.json'.length));

test('there is one chrome file per published language, with matching names', () => {
  assert.ok(siteCodes.length > 0, 'found the SITE_LANGUAGES codes');
  assert.deepEqual([...fileCodes].sort(), [...siteCodes].sort(), 'file stems equal SITE_LANGUAGES codes');
});

test('every language file has exactly the English chrome keys, each non-empty', () => {
  for (const f of langFiles) {
    const map = JSON.parse(readFileSync(join(dir, f), 'utf8'));
    assert.deepEqual(Object.keys(map).sort(), enKeys, `${f} keys`);
    for (const [k, v] of Object.entries(map)) {
      assert.ok(typeof v === 'string' && v.trim().length > 0, `${f}: empty value for "${k}"`);
    }
  }
});

test('every chrome string used in the components is a key of en.chrome.json', () => {
  const sources = [
    'src/components/chrome/Header.astro',
    'src/components/chrome/Footer.astro',
    'src/layouts/SiteLayout.astro',
  ];
  for (const rel of sources) {
    const text = readFileSync(join(root, rel), 'utf8');
    const used = [...text.matchAll(/\bt\("([^"]+)"\)|chrome\([^,]+,\s*"([^"]+)"\)/g)].map((m) => m[1] ?? m[2]);
    assert.ok(used.length > 0, `${rel} uses the chrome lookup`);
    for (const key of used) assert.ok(key in en, `${rel}: "${key}" has no entry in en.chrome.json`);
  }
});

test('a placeholder string keeps its placeholder exactly once in every language', () => {
  for (const key of enKeys.filter((k) => k.includes('{'))) {
    for (const f of langFiles) {
      const map = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      const count = map[key].split(key.match(/\{[a-z]+\}/)[0]).length - 1;
      assert.equal(count, 1, `${f}: "${key}" must contain its placeholder once`);
    }
  }
});
