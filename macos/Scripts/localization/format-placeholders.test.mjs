import { test } from 'node:test';
import assert from 'node:assert/strict';
import { scanPlaceholders, positionalize, argumentsMatch } from './format-placeholders.mjs';

test('tracks positions, precision and literal percent offsets', () => {
  const text = '100%%: %@ / %2$.2f';
  assert.deepEqual(scanPlaceholders(text), [
    { token: '%%', positional: undefined, raw: '%%', index: 3 },
    { token: '@', positional: undefined, raw: '%@', index: 7 },
    { token: 'f', positional: '2', raw: '%2$.2f', index: 12 },
  ]);
});

test('reorders distinct arguments without counting literal percent', () => {
  assert.equal(positionalize('100%% %@ %lld', '100%% %lld %@'), '100%% %2$lld %1$@');
  assert.equal(positionalize('%@ %.2f', '%2$.2f %1$@'), '%2$.2f %1$@');
  assert.equal(positionalize('%@ %lld', '%f %@'), '%f %@');
  assert.equal(positionalize('%@ %@', '%@ %@'), '%@ %@');
  assert.equal(argumentsMatch('%@ %lld', '%2$lld %1$@'), true);
  assert.equal(argumentsMatch('%@ %lld', '%2$@ %1$lld'), false);
});

test('maps explicit English positions and formatted widths', () => {
  assert.equal(positionalize('%2$@ %1$lld', '%@ %lld'), '%2$@ %1$lld');
  assert.equal(argumentsMatch('%2$@ %1$lld', '%@ %lld'), false);
  assert.equal(argumentsMatch('%2$@ %1$lld', '%lld %@'), true);
  assert.equal(argumentsMatch('%02d %5.1f %-10s %+d', '%02d %5.1f %-10s'), false);
  assert.deepEqual(scanPlaceholders('%02d %5.1f %-10s %+d').map((x) => x.token), ['d', 'f', 's', 'd']);
});
