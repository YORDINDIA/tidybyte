// Shared helpers for the machine-readable routes:
//   /llms.txt, /llms-full.txt (src/pages/llms*.txt.ts)
//   /blog/<slug>.md            (src/pages/blog/[slug].md.ts)
//
// Text is derived from the same content files the HTML pages render, so
// it can never go stale. Header/footer chrome is excluded by construction
// (chrome lives outside the content files), keeping AI context clean.
import { PAGES, type PageMeta } from "../data/pages";
import { bodyFor } from "./content";

const SITE = "https://tidybyte.yord.si";

export function contentFor(route: string): string {
  const meta = PAGES.find((p) => p.route === route);
  if (!meta) throw new Error(`no page meta for route ${route}`);
  return bodyFor(meta.contentFile);
}

const NAMED_ENTITIES: Record<string, string> = {
  mdash: "\u2014",
  ndash: "\u2013",
  rsquo: "'",
  lsquo: "'",
  rdquo: '"',
  ldquo: '"',
  quot: '"',
  apos: "'",
  hellip: "…",
  larr: "←",
  rarr: "\u2192",
  gt: ">",
  lt: "<",
  amp: "&",
  nbsp: " ",
  middot: "\u00b7",
  copy: "©",
  reg: "®",
  trade: "™",
  times: "×",
  laquo: "«",
  raquo: "»",
  lsaquo: "‹",
  rsaquo: "›",
  bull: "•",
  uarr: "↑",
  darr: "↓",
  harr: "↔",
};

function decodeNumericEntity(body: string): string | null {
  const code =
    body[1] === "x" || body[1] === "X"
      ? Number.parseInt(body.slice(2), 16)
      : Number.parseInt(body.slice(1), 10);
  if (
    !Number.isFinite(code) ||
    code <= 0 ||
    code > 0x10ffff ||
    (code >= 0xd800 && code <= 0xdfff)
  ) {
    return null;
  }
  return String.fromCodePoint(code);
}

export function decodeEntities(s: string): string {
  return s.replace(
    /&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/g,
    (match, body: string) => {
      if (body[0] === "#") return decodeNumericEntity(body) ?? match;
      return Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, body)
        ? NAMED_ENTITIES[body]
        : match;
    },
  );
}

const VOID_TAGS = new Set([
  "area",
  "base",
  "br",
  "col",
  "embed",
  "hr",
  "img",
  "input",
  "link",
  "meta",
  "param",
  "source",
  "track",
  "wbr",
]);

const HTML_TAG_RE =
  /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)(?:(?=\s|\/?>)((?:[^>"'/]|\/(?!>)|"[^"]*"|'[^']*')*))(\/?)>/g;

function hasAriaHiddenTrue(attrs: string): boolean {
  const attrRe = /\s([a-zA-Z0-9:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g;
  for (const m of attrs.matchAll(attrRe)) {
    if (m[1].toLowerCase() === "aria-hidden") {
      const val = (m[2] ?? m[3] ?? m[4] ?? "").trim().toLowerCase();
      if (val === "true") return true;
    }
  }
  return false;
}

function appendSubtreeBoundary(out: string, html: string, nextIndex: number): string {
  const prevChar = out.slice(-1);
  const nextChar = html.slice(nextIndex, nextIndex + 1);
  if (
    prevChar &&
    nextChar &&
    !/[\s(\["'“‘]/.test(prevChar) &&
    !/[\s.,;:!?)\]"'”’]/.test(nextChar)
  ) {
    return `${out} `;
  }
  return out;
}

/**
 * Removes every element subtree marked with `aria-hidden="true"`, tracking
 * nested tags of the same tag name so decorative mockups and hidden badges do
 * not leak fragments into Markdown exports.
 */
function stripAriaHidden(html: string): string {
  HTML_TAG_RE.lastIndex = 0;
  let out = "";
  let lastIndex = 0;
  let hideTag = "";
  let hideStart = -1;
  let depth = 0;

  let match: RegExpExecArray | null;
  while ((match = HTML_TAG_RE.exec(html)) !== null) {
    const [full, closingSlash, rawName, attrs = "", selfClosingSlash] = match;
    const tag = rawName.toLowerCase();
    const isClosing = closingSlash === "/";
    const isSelfClosing = selfClosingSlash === "/" || VOID_TAGS.has(tag);

    if (depth === 0) {
      if (!isClosing && hasAriaHiddenTrue(attrs)) {
        out += html.slice(lastIndex, match.index);
        if (isSelfClosing) {
          lastIndex = match.index + full.length;
          out = appendSubtreeBoundary(out, html, lastIndex);
        } else {
          hideTag = tag;
          hideStart = match.index;
          depth = 1;
        }
      }
      continue;
    }

    if (tag === hideTag) {
      if (isClosing) {
        depth--;
        if (depth === 0) {
          lastIndex = match.index + full.length;
          out = appendSubtreeBoundary(out, html, lastIndex);
          hideTag = "";
          hideStart = -1;
        }
      } else if (!isSelfClosing) {
        depth++;
      }
    }
  }

  if (depth > 0 && hideStart >= 0) {
    const snippet = html.slice(hideStart, hideStart + 80).replace(/\s+/g, " ");
    throw new Error(`Unclosed <${hideTag} aria-hidden="true"> subtree near: ${snippet}`);
  }
  return out + html.slice(lastIndex);
}

function absolutize(url: string): string {
  if (url.startsWith("http")) return url;
  if (url.startsWith("/")) return SITE + url;
  if (url.startsWith("#")) return url;
  return url;
}

/**
 * Minimal HTML-to-Markdown for article bodies. Keeps headings, paragraphs,
 * list items, and links; drops images, SVGs, scripts, and styling wrappers.
 */
export function htmlToMarkdown(html: string): string {
  let s = html;
  // Drop HTML comments and non-content subtrees: decorative/hidden subtrees
  // (`aria-hidden="true"`), breadcrumbs, in-page TOC, figures/SVGs.
  s = s.replace(/<!--[\s\S]*?-->/g, "");
  s = stripAriaHidden(s);
  s = s.replace(/<nav aria-label="Breadcrumb"[\s\S]*?<\/nav>/g, "");
  s = s.replace(/<nav aria-labelledby="toc-h"[\s\S]*?<\/nav>/g, "");
  s = s.replace(/<figure[\s\S]*?<\/figure>/g, "");
  s = s.replace(/<svg[\s\S]*?<\/svg>/g, "");
  s = s.replace(/<picture[\s\S]*?<\/picture>/g, "");
  // Separate adjacent sibling nodes (e.g. flex label/value pairs) with a
  // space so stripped tags never glue adjacent text together.
  s = s.replace(/(<\/[a-zA-Z0-9-]+>)(?=<[a-zA-Z0-9-]+)/g, "$1 ");
  // Links -> [text](url) before tags are stripped.
  s = s.replace(
    /<a\s[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g,
    (_m, href: string, text: string) => {
      const t = text.replace(/<[^>]+>/g, "").trim();
      if (!t) return "";
      if (href.startsWith("#")) return t;
      return `[${t}](${absolutize(href)})`;
    },
  );
  // Block structure.
  s = s.replace(/<h1[^>]*>([\s\S]*?)<\/h1>/g, "\n# $1\n");
  s = s.replace(/<h2[^>]*>([\s\S]*?)<\/h2>/g, "\n## $1\n");
  s = s.replace(/<h3[^>]*>([\s\S]*?)<\/h3>/g, "\n### $1\n");
  s = s.replace(/<\/p>/g, "\n\n");
  s = s.replace(/<br\s*\/?>/g, "\n");
  s = s.replace(/<li[^>]*>/g, "\n- ");
  // Tables -> pipe rows: `<tr>` opens a row, each cell adds a separator.
  // Source files indent table markup, so join cell boundaries first —
  // otherwise each cell lands on its own line.
  s = s.replace(/<\/(td|th)>\s+<(td|th)([^>]*)>/g, "</$1><$2$3>");
  s = s.replace(/<tr([^>]*)>\s+/g, "<tr$1>");
  s = s.replace(/\s+<\/(tr)>/g, "</$1>");
  s = s.replace(/<tr[^>]*>/g, "\n| ");
  s = s.replace(/<\/(th|td)>/g, " | ");
  s = s.replace(/<\/(li|ul|ol|section|div|article|aside|main|nav|figure|figcaption|details|summary|table|thead|tbody|tfoot|tr)>/g, "\n");
  s = s.replace(/<[^>]+>/g, "");
  s = decodeEntities(s);
  // Collapse runs of blank lines, trim each line, drop trailing pipes.
  s = s
    .split("\n")
    .map((l) =>
      l
        .trim()
        .replace(/ {2,}/g, " ")
        .replace(/\s+\|\s*$/, ""),
    )
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return s;
}

/** Absolute URL for a route (pretty URL form, matching canonical). */
export function urlFor(route: string): string {
  return route === "/" ? `${SITE}/` : `${SITE}${route}`;
}

/**
 * Drops the body's own H1 from a converted Markdown body.
 *
 * The `.md` alternates emit their own H1 from the page title, and the source
 * content files carry an `<h1>` of their own ("Privacy Policy", "The best free
 * iPhone storage cleaner and photo cleaner."), which `htmlToMarkdown` converts
 * too. The body's heading is not always the first line (a home page opens with
 * its announcement bar), so this removes the first `# ` line wherever it
 * appears in the body. Each content file has exactly one `<h1>`
 * (`scripts/seo-audit.mjs` enforces one per HTML page), so at most one line is
 * ever removed, and the synthetic title heading the route emits stays.
 */
export function stripBodyH1(markdown: string): string {
  return markdown
    .replace(/^#[ \t]+[^\n]*\n{0,2}/m, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function blogPosts(): PageMeta[] {
  return PAGES.filter((p) => p.route.startsWith("/blog/")).sort((a, b) =>
    a.route.localeCompare(b.route),
  );
}

export function plainTitle(m: PageMeta): string {
  return decodeEntities(m.title.replace(/<[^>]+>/g, ""))
    .replace(/\s+/g, " ")
    .trim();
}

export function plainDescription(m: PageMeta): string {
  return decodeEntities(m.description.replace(/<[^>]+>/g, ""))
    .replace(/\s+/g, " ")
    .trim();
}
