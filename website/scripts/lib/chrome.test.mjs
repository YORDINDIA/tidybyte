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

test('every language file has exactly the English chrome keys, each non-empty', () => {
  assert.equal(langFiles.length, 20, 'one chrome file per localized language');
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
