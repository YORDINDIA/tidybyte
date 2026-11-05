// Content-file loading and the visible "Quick answer" box.
//
// Page bodies (other than the home page, which is the HomeMain.astro
// component) live in src/content/pages/*.html. This module is the one
// loader for them; routes import it and inject the result with
// <Fragment set:html> inside src/layouts/SiteLayout.astro.
import type { PageMeta } from "../data/page-meta";

const contentFiles = import.meta.glob("../content/pages/*.html", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

/** The authored body of a page, exactly as the content file holds it. */
export function bodyFor(contentFile: string): string {
  const key = `../content/pages/${contentFile}.html`;
  const raw = contentFiles[key];
  if (!raw) throw new Error(`missing content file ${key}`);
  return raw;
}

/**
 * The visible "Quick answer" box. Featured snippets, voice assistants, and
 * AI citations all prefer a short direct answer near the top; the meta
 * description already is one, so it is reused verbatim.
 */
export function quickAnswerBox(description: string): string {
  return (
    `  <aside class="clay-card mt-8 p-5 sm:p-6" data-quick-answer>\n` +
    `    <h2 class="font-display text-sm font-semibold uppercase tracking-[0.12em] text-muted">Quick answer</h2>\n` +
    `    <p class="mt-2 text-base leading-relaxed text-body sm:text-lg">${description}</p>\n` +
    `  </aside>\n`
  );
}

/**
 * Places the quick-answer box in an authored body. Placement is decided by
 * an explicit marker, in this order:
 *   1. `<!-- quick-answer -->` in the content file, if the author placed one
 *   2. `</figure>`  — blog posts (under the hero image)
 *   3. `</header>`  — pages with a header block (support, privacy, changelog)
 * If none is present the box is skipped; scripts/seo-audit.mjs fails the
 * check when an indexable page ends up without one.
 */
export function withQuickAnswer(mainHtml: string, m: PageMeta): string {
  if (m.route === "/404") return mainHtml;
  if (mainHtml.includes("data-quick-answer")) return mainHtml;
  const box = quickAnswerBox(m.description);
  const MARKER = "<!-- quick-answer -->";
  if (mainHtml.includes(MARKER)) {
    return mainHtml.replace(MARKER, box.trimEnd());
  }
  const fallback = m.route.startsWith("/blog/") ? "</figure>" : "</header>";
  const i = mainHtml.indexOf(fallback);
  if (i < 0) return mainHtml;
  return (
    mainHtml.slice(0, i + fallback.length) +
    "\n\n" +
    box +
    mainHtml.slice(i + fallback.length)
  );
}
