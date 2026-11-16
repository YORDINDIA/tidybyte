import { test } from 'node:test';
import assert from 'node:assert/strict';
import { plainText } from '../../src/lib/plain-text.js';

test('maps each quote entity to its own character', () => {
  assert.equal(plainText('&ldquo;x&rdquo;'), '“x”');
  assert.equal(plainText('&lsquo;x&rsquo;'), '‘x’');
  assert.equal(plainText("you&rsquo;re"), 'you’re');
});

test('decodes dashes, ampersands and spaces once', () => {
  assert.equal(plainText('TidyByte &mdash; Free &amp; Clean'), 'TidyByte — Free & Clean');
  assert.equal(plainText('a&nbsp;&nbsp;b'), 'a b');
});

test('leaves an already double-encoded entity visible as text, not decoded twice', () => {
  assert.equal(plainText('&amp;mdash;'), '&mdash;');
});
