import { test } from 'node:test';
import assert from 'node:assert/strict';
import { missingPageRewrites } from './netlify-routes.mjs';

test('requires an exact 200 rewrite for each published route', () => {
  const config = `[[redirects]]
  from = "/hi"
  to = "/hi.html"
  status = 200
[[redirects]]
  from = "/photo-cleaner"
  to = "/photo-cleaner.html"
  status = 301
`;
  assert.deepEqual(missingPageRewrites(config, ['/hi', '/photo-cleaner', '/fr', '/hi']), ['/fr', '/photo-cleaner']);
});

test('generates a stable block and rejects unsafe paths', async () => {
  const { withGeneratedPageRewrites } = await import('./netlify-routes.mjs');
  const config = 'before\n# BEGIN GENERATED LANDING REWRITES\nold\n# END GENERATED LANDING REWRITES\nafter\n';
  const generated = withGeneratedPageRewrites(config, ['/fr', '/hi', '/fr']);
  assert.equal(withGeneratedPageRewrites(generated, ['/hi', '/fr']), generated);
  assert.match(generated, /from = "\/fr"\n  to = "\/fr\.html"\n  status = 200/);
  assert.ok(generated.indexOf('"/fr"') < generated.indexOf('"/hi"'));
  assert.throws(() => withGeneratedPageRewrites(config, ['/bad"path']));
  assert.throws(() => withGeneratedPageRewrites('no markers', ['/fr']));
});
