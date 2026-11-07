import { test } from 'node:test';
import assert from 'node:assert/strict';
import { escapeHtml } from '../../src/lib/escape-html.mjs';
import { blogArticleScript } from '../../src/lib/blog-article.mjs';

test('escapes metadata for HTML and keeps JSON inside its script', () => {
  const heading = `A & <B> "quoted" 'text'`;
  assert.equal(escapeHtml(heading), 'A &amp; &lt;B&gt; &quot;quoted&quot; &#x27;text&#x27;');
  const meta = {
    route: '/blog/example', canonical: 'https://example.test/blog/example', ogImage: 'https://example.test/image.jpg',
    datePublished: '2026-06-13T00:00:00Z', dateModified: '2026-06-13',
    description: 'A </script> description', blog: { heading },
  };
  const script = blogArticleScript(meta);
  assert.equal((script.match(/<\/script>/g) ?? []).length, 1);
  const article = JSON.parse(script.match(/<script type="application\/ld\+json">([\s\S]*)<\/script>/)[1]);
  assert.equal(article.headline, heading);
  assert.equal(article.description, meta.description);
  assert.equal(article.mainEntityOfPage.url, meta.canonical);
  assert.equal(article.image, meta.ogImage);
  const override = JSON.parse(blogArticleScript({ ...meta, blog: { ...meta.blog, schemaHeadline: 'Editorial title' } })
    .match(/<script type="application\/ld\+json">([\s\S]*)<\/script>/)[1]);
  assert.equal(override.headline, 'Editorial title');
  assert.throws(() => blogArticleScript({ route: '/blog/incomplete' }));
});
