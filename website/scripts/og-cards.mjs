#!/usr/bin/env node
/**
 * og-cards.mjs — render 1200x630 Open Graph cards for the tool landing pages.
 *
 * Uses the Snaptitle crayon-and-paper palette (#fffdf8 paper, #121214 ink,
 * #ff5a14 orange, Gaegu bold display font) to match the redesigned site.
 */
import { chromium } from "playwright";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(ROOT, "dist");
const OUT = join(ROOT, "public/assets/img/og");
const FONT = pathToFileURL(join(ROOT, "public/assets/fonts/gaegu-700-latin.woff2")).href;
const CHECK = process.argv.includes("--check");
const MANIFEST = join(OUT, "manifest.json");
const RENDER_OPTIONS = { type: "jpeg", quality: 84 };
const VIEWPORT = { width: 1200, height: 630 };
const RENDER_CONTEXT = { viewport: VIEWPORT, deviceScaleFactor: 1 };

if (!existsSync(DIST)) {
  console.error("dist/ not found — run `npm run build` first.");
  process.exit(1);
}

/** Tool pages = top-level HTML files that reference an og card. */
function toolPages() {
  const pages = [];
  for (const f of readdirSync(DIST)) {
    if (!f.endsWith(".html")) continue;
    if (["index.html", "404.html"].includes(f)) continue;
    const html = readFileSync(join(DIST, f), "utf8");
    const og = html.match(/<meta property="og:image" content="[^"]*\/assets\/img\/og\/([^"]+)"/);
    if (!og) continue;
    const title = html.match(/<title>([\s\S]*?)<\/title>/)?.[1]?.trim() ?? "";
    const h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/)?.[1]?.replace(/<[^>]+>/g, "").trim() ?? "";
    const badge = html.match(/<p class="badge">([\s\S]*?)<\/p>/)?.[1]?.replace(/<[^>]+>/g, "").trim() ?? "";
    pages.push({ slug: og[1].replace(/\.jpg$/, ""), title, h1, badge });
  }
  return pages.sort((a, b) => a.slug.localeCompare(b.slug));
}

const pages = toolPages();

mkdirSync(OUT, { recursive: true });

const card = (p) => `<!doctype html>
<html><head><meta charset="utf-8"><style>
  @font-face { font-family: 'Gaegu'; src: url('${FONT}') format('woff2'); font-weight: 700; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    width: 1200px; height: 630px; overflow: hidden;
    background: #fffdf8; color: #121214;
    font-family: 'Gaegu', system-ui, sans-serif;
    display: flex; flex-direction: column; justify-content: center; gap: 28px;
    align-items: flex-start;
    padding: 64px 76px 132px;
    position: relative;
    border: 14px solid #ffe27a;
  }
  .frame {
    position: absolute; inset: 14px; border: 4px solid #121214; border-radius: 24px; pointer-events: none;
  }
  .badge {
    display: inline-flex; align-items: center; gap: 10px;
    background: #ffe1bf; color: #121214; border-radius: 999px;
    border: 3px solid #121214;
    box-shadow: 3px 4px 0 #121214;
    padding: 8px 22px; font-size: 24px; font-weight: 700;
  }
  h1 {
    font-size: 80px; line-height: 0.94; font-weight: 700; letter-spacing: -0.04em; max-width: 980px;
  }
  .brand { display: flex; align-items: center; gap: 12px; font-size: 38px; font-weight: 700; }
  .dot { width: 14px; height: 14px; border-radius: 999px; background: #ff5a14; border: 2px solid #121214; }
  .foot {
    position: absolute; left: 76px; right: 76px; bottom: 52px;
    display: flex; align-items: flex-end; justify-content: space-between; gap: 24px;
  }
  .facts {
    font-family: system-ui, -apple-system, sans-serif;
    font-size: 21px; font-weight: 600; color: #3d3d44; max-width: 680px; line-height: 1.35;
  }
</style></head>
<body>
  <div class="frame"></div>
  <span class="badge">${p.badge}</span>
  <h1>${p.h1}</h1>
  <div class="foot">
    <div class="facts">Free forever &middot; iPhone cleanup on-device &middot; No ads or subscription</div>
    <div class="brand"><span>TidyByte</span><span class="dot"></span></div>
  </div>
</body></html>`;

const digest = (value) => createHash("sha256").update(value).digest("hex");
const fontHash = digest(readFileSync(join(ROOT, "public/assets/fonts/gaegu-700-latin.woff2")));
const sourceHash = (p) => digest(card(p).replaceAll(FONT, "<font>") + fontHash + JSON.stringify({ RENDER_OPTIONS, RENDER_CONTEXT }));

function jpegSize(data) {
  if (data.length < 4 || data.readUInt16BE(0) !== 0xffd8) return null;
  for (let i = 2; i + 3 < data.length;) {
    if (data[i++] !== 0xff) return null;
    while (i < data.length && data[i] === 0xff) i++;
    const marker = data[i++];
    if (marker === 0xd9 || marker === 0xda || i + 1 >= data.length) return null;
    const length = data.readUInt16BE(i);
    if (length < 2 || i + length > data.length) return null;
    if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
      if (length < 7) return null;
      return [data.readUInt16BE(i + 5), data.readUInt16BE(i + 3)];
    }
    i += length;
  }
  return null;
}

if (CHECK) {
  const manifest = existsSync(MANIFEST) ? JSON.parse(readFileSync(MANIFEST, "utf8")) : {};
  let failed = false;
  if (Object.keys(manifest).length !== pages.length) failed = true;
  for (const p of pages) {
    const path = join(OUT, `${p.slug}.jpg`);
    const data = existsSync(path) ? readFileSync(path) : null;
    const entry = manifest[p.slug];
    if (!data || String(jpegSize(data)) !== "1200,630" || !entry ||
        entry.source !== sourceHash(p) || entry.image !== digest(data)) {
      console.error(`invalid or stale og card: ${p.slug}.jpg`);
      failed = true;
    }
  }
  if (failed) {
    console.error("Run `npm run og` after building the site.");
    process.exit(1);
  }
  console.log(`✓ ${pages.length} og cards current and 1200x630`);
  process.exit(0);
}

let browser;
try {
  browser = await chromium.launch();
} catch (err) {
  console.error(
    "Playwright cannot launch Chromium. Install it once with:\n" +
      "  npx playwright install chromium\n" +
      "then re-run this script."
  );
  process.exit(1);
}
const page = await browser.newPage(RENDER_CONTEXT);

let written = 0;
const manifest = {};
for (const p of pages) {
  await page.setContent(card(p), { waitUntil: "load" });
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(OUT, `${p.slug}.jpg`), ...RENDER_OPTIONS });
  manifest[p.slug] = { source: sourceHash(p), image: digest(readFileSync(join(OUT, `${p.slug}.jpg`))) };
  written++;
  console.log(`  ${p.slug}.jpg`);
}
await browser.close();
writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + "\n");
console.log(`\n✓ wrote ${written} og cards to public/assets/img/og/`);
