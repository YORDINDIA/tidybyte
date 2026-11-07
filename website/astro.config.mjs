// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import { TOOLS } from './src/data/tools.ts';
import { SITE_LANGUAGES } from './src/data/languages.ts';

// Static marketing site. HTML is minified at build time; pretty URLs use
// build.format 'preserve' (blog/index.astro -> blog/index.html,
// [slug].astro -> blog/<slug>.html) plus Netlify redirects.
//
// Sitemap priority follows the same route data used to build the pages.
const TOOL_ROUTES = new Set(TOOLS.map((tool) => `/${tool.slug}`));
const LANG_ROUTES = new Set(SITE_LANGUAGES.map((language) => `/${language.slug}`));

export default defineConfig({
  site: 'https://tidybyte.yord.si',
  output: 'static',
  compressHTML: true,
  trailingSlash: 'never',
  build: { format: 'preserve' },
  integrations: [
    sitemap({
      // Machine-readable alternates and the 404 page are not search content.
      filter: (page) => !/\/404\/?$/.test(page) && !/\.(txt|md)\/?$/.test(page),
      serialize(item) {
        const path = new URL(item.url).pathname;
        // Localized landing pages are the same page as "/" in another
        // language: same priority, and the hreflang block in the HTML is
        // what tells a crawler they are alternates rather than 21 pages
        // fighting for one query.
        if (path === '/' || LANG_ROUTES.has(path)) {
          item.changefreq = 'weekly';
          item.priority = 1.0;
        } else if (TOOL_ROUTES.has(path)) {
          item.changefreq = 'monthly';
          item.priority = 0.9;
        } else if (path === '/blog') {
          item.changefreq = 'weekly';
          item.priority = 0.8;
        } else if (path.startsWith('/blog/')) {
          item.changefreq = 'monthly';
          item.priority = 0.7;
        } else if (path === '/mac' || path === '/activity-monitor-alternative') {
          // Both Mac pages carry the same commercial intent as a tool
          // landing page; the monitor page uses the same icon OG pattern
          // as /mac, and /mac sits at 0.9, so the two match.
          item.changefreq = 'monthly';
          item.priority = 0.9;
        } else if (path === '/support') {
          item.changefreq = 'monthly';
          item.priority = 0.6;
        } else if (path === '/changelog') {
          item.changefreq = 'monthly';
          item.priority = 0.5;
        } else {
          item.changefreq = 'yearly';
          item.priority = 0.3;
        }
        return item;
      },
    }),
  ],
});
