import { test } from 'node:test';
import assert from 'node:assert/strict';
import { plainText } from '../../src/lib/plain-text.js';

test('maps each quote entity to its own character', () => {
  assert.equal(plainText('&ldquo;x&rdquo;'), '“x”');
  assert.equal(plainText('&lsquo;x&rsquo;'), '‘x’');
  assert.equal(plainText("you&rsquo;re"), 'you’re');
});

test('decodes dashes, ampersands and spaces', () => {
  assert.equal(plainText('TidyByte &mdash; Free &amp; Clean'), 'TidyByte — Free & Clean');
  assert.equal(plainText('a&nbsp;&nbsp;b'), 'a b');
});

test('decodes the named references copy uses beyond the original table', () => {
  assert.equal(plainText('Save &rarr; Open'), 'Save → Open');
  assert.equal(plainText('&copy; 2026 TidyByte'), '© 2026 TidyByte');
  assert.equal(plainText('3 &times; 4'), '3 × 4');
  assert.equal(plainText('&apos;quoted&apos; &lt;b&gt;'), "'quoted' <b>");
});

test('decodes numeric references in decimal and hex', () => {
  assert.equal(plainText('A &#8212; B'), 'A — B');
  assert.equal(plainText('A &#x2014; B'), 'A — B');
  assert.equal(plainText('&#X2014;'), '—');
  assert.equal(plainText('&#x2039;Back'), '‹Back');
  assert.equal(plainText('&#38; more'), '& more');
});

test('leaves unknown names and invalid code points as written', () => {
  assert.equal(plainText('&notarealentity; ok'), '&notarealentity; ok');
  assert.equal(plainText('&#0; &#xD800; &#x110000;'), '&#0; &#xD800; &#x110000;');
});

test('decodes exactly once: an encoded reference stays visible as text', () => {
  assert.equal(plainText('&amp;mdash;'), '&mdash;');
  assert.equal(plainText('&amp;amp;'), '&amp;');
  assert.equal(plainText('&#38;mdash;'), '&mdash;');
  assert.equal(plainText('&amp;#8212;'), '&#8212;');
});
