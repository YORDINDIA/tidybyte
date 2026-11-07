// Content-file loading and the visible "Quick answer" box.
//
// Page bodies (other than the home page, which is the HomeMain.astro
// component) live in src/content/pages/*.html. This module is the one
// loader for them; routes import it and inject the result with
// <Fragment set:html> inside src/layouts/SiteLayout.astro.
import type { PageMeta } from "../data/page-meta";
import { PAGES } from "../data/pages";
import { IOS_VERSION, MAC_DOWNLOAD_URL, MAC_VERSION } from "../data/releases";
import { blogCards, blogFilters, blogPosts, categoryLabel, dateLabel } from "./blog-index";
import { escapeHtml } from "./escape-html.mjs";

const contentFiles = import.meta.glob("../content/pages/*.html", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

/**
 * The authored body of a page, with release and blog placeholders filled in
 * from the page metadata before it is returned.
 */
export function bodyFor(contentFile: string): string {
  const key = `../content/pages/${contentFile}.html`;
  const raw = contentFiles[key];
  if (!raw) throw new Error(`missing content file ${key}`);
  let body = raw.replaceAll("{{MAC_DOWNLOAD_URL}}", MAC_DOWNLOAD_URL).replaceAll("{{MAC_VERSION}}", MAC_VERSION)
    .replaceAll("{iosVersion}", IOS_VERSION);
  const meta = PAGES.find((page) => page.contentFile === contentFile);
  if (meta?.blog) {
    if (!meta.datePublished) throw new Error(`missing publication date for ${meta.route}`);
    const date = meta.datePublished.slice(0, 10);
    const category = meta.blog.categories[0];
    // Function replacers keep "$&", "$'" and "$$" in metadata literal.
    body = body.replaceAll("{{BLOG_HEADING}}", () => escapeHtml(meta.blog.heading))
      .replaceAll("{{BLOG_IMAGE_ALT}}", () => escapeHtml(meta.blog.imageAlt))
      .replaceAll("{{BLOG_DATE}}", () => date)
      .replaceAll("{{BLOG_DATE_LABEL}}", () => dateLabel(date))
      .replaceAll("{{BLOG_READING_MINUTES}}", () => String(meta.blog.readingMinutes))
      .replaceAll("{{BLOG_PRIMARY_CATEGORY}}", () => category)
      .replaceAll("{{BLOG_PRIMARY_LABEL}}", () => categoryLabel(category));
  }
  if (contentFile === "blog-index") {
    body = body.replaceAll("{{BLOG_COUNT}}", String(blogPosts(PAGES).length))
      .replace("<!-- BLOG_FILTERS -->", () => blogFilters(PAGES))
      .replace("<!-- BLOG_CARDS -->", () => blogCards(PAGES));
  }
  return body;
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
    `    <p class="mt-2 text-base leading-relaxed text-body sm:text-lg">${escapeHtml(description)}</p>\n` +
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
