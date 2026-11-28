import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

test("Header places mobile drawer outside scrolled header element and exposes Close menu label", () => {
  const header = readFileSync(join(root, "src/components/chrome/Header.astro"), "utf8");
  const headerCloseIdx = header.indexOf("</header>");
  const drawerIdx = header.indexOf('id="mobile-menu"');
  assert.ok(headerCloseIdx > 0 && drawerIdx > headerCloseIdx, "#mobile-menu must sit outside </header>");
  assert.ok(header.includes('role="dialog"'), "mobile drawer must expose dialog semantics");
  assert.ok(header.includes('aria-label={t("Close menu")}'), "drawer close button must have Close menu label");
  const css = readFileSync(join(root, "src/input.css"), "utf8");
  assert.ok(css.includes(".header-compact + #mobile-menu:not(.hidden)"), "compact-nav selector matches sibling drawer");
});

test("nav.js restores focus on drawer close and manages inert background", () => {
  const nav = readFileSync(join(root, "public/assets/js/nav.js"), "utf8");
  assert.ok(nav.includes("setBackgroundInert"), "mobile drawer toggles inert on background landmarks");
  assert.ok(nav.includes("if (restoreFocus) toggle.focus()"), "close paths restore focus to menu toggle");
});

test("site.js escapes key lookups safely and handles RTL carousel scroll offsets", () => {
  const site = readFileSync(join(root, "public/assets/js/site.js"), "utf8");
  assert.equal(site.includes("querySelector('[data-key=\"'"), false, "no raw attribute selector interpolation");
  assert.ok(site.includes("Math.abs(track.scrollLeft)"), "carousel handles RTL negative scrollLeft");
  assert.ok(site.includes("dotsWrap.removeAttribute('aria-hidden')"), "carousel dots clear aria-hidden");
});

test("HomeMain keeps H1/H2 as unified sentences and og-cards bundles Inter font", () => {
  const home = readFileSync(join(root, "src/components/HomeMain.astro"), "utf8");
  assert.ok(home.includes("The best free storage cleaner for iPhone and Mac."), "H1 is a single translatable sentence");
  assert.ok(home.includes("Clean your library in minutes."), "bottom CTA H2 is a single translatable sentence");
  const og = readFileSync(join(root, "scripts/og-cards.mjs"), "utf8");
  assert.ok(og.includes("inter-var-latin.woff2"), "og-cards bundles self-hosted Inter font");
  const css = readFileSync(join(root, "src/input.css"), "utf8");
  assert.ok(css.includes("@keyframes answer-in {\n  from { opacity: 0;"), "answer-in fades from opacity 0");
});
