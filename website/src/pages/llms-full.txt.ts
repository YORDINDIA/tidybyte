import type { APIRoute } from "astro";
import { PAGES } from "../data/pages";
import { MAC_DOWNLOAD_URL, MAC_VERSION } from "../data/releases";
import { TOOLS } from "../data/tools";
import {
  blogPosts,
  contentFor,
  htmlToMarkdown,
  plainDescription,
  plainTitle,
  urlFor,
} from "../lib/llms";
import { renderToolMarkdown } from "../lib/tool-page";

// Complete machine-readable site text. Content only — no header/footer
// chrome — regenerated every build from the same files the HTML renders.
export const GET: APIRoute = () => {
  const sections: string[] = [
    "# TidyByte — Full Site Content",
    "",
    "Free, MIT-licensed storage cleaner for iPhone, iPad, iPhone Duo (iOS 17+) and Mac (macOS 26+ Apple silicon), localized in 21 languages including RTL Arabic and Hebrew. No ads, no accounts, and no subscriptions.",
    "",
    "On iPhone and iPad, core library cleanup runs on-device (with optional direct Google Photos requests in enabled builds). On Mac, TidyByte cleans system junk, developer clutter, large/old files, SHA-256 duplicates (APFS clones or Trash), Photos & Media (similar, blurry, burst, screenshots, Live Photos to stills, and iCloud-aware compression with Keep Both or Replace & Trash Original, Max File Size targets, Check Result Sizes, HEIC/HEVC), login items, and bundle-ID/code-signature leftovers with running-app protection, plus 8-mode Space Explorer.",
    "",
    "Mac distribution: Direct DMG releases include Sparkle auto-updates, the 13-dashboard system-wide Monitor, optional LaunchAgent APFS clone-folding, the `tidybyte` CLI (`status|top|ports|agents|limits|history`), and `tidybyte-mcp` inside `Tidybyte.app/Contents/MacOS/` (read-only/preview-first by default; `execute` and `undo` require `confirm: true`, with `execute` limited to APFS clone folding and SQLite undo history). Sandboxed Mac App Store builds focus safely on user-selected folders and your Photos library without system-wide Monitor, Sparkle, CLI/MCP, external AI gateway calls, or LaunchAgent automation.",
    "",
    "Download for iPhone & iPad (App Store): https://apps.apple.com/app/id6775769763",
    `Download for Mac Direct v${MAC_VERSION}: ${MAC_DOWNLOAD_URL}`,
    "",
  ];
  const core = PAGES.filter(
    (p) =>
      !p.route.startsWith("/blog/") &&
      p.route !== "/404" &&
      !TOOLS.some((t) => p.route === `/${t.slug}`),
  );
  for (const p of core) {
    sections.push(
      `## ${plainTitle(p)}`,
      `URL: ${urlFor(p.route)}`,
      "",
      htmlToMarkdown(contentFor(p.route)),
      "",
      "---",
      "",
    );
  }
  // Tool landing pages: structured blocks (quick answer, comparison, FAQ)
  // first, then the authored prose, so an extractor gets the direct answer
  // before the long copy.
  for (const t of TOOLS) {
    const route = `/${t.slug}`;
    sections.push(
      `## ${t.name} — ${urlFor(route)}`,
      "",
      renderToolMarkdown(t.slug),
      "",
      "### Full page text",
      "",
      htmlToMarkdown(contentFor(route)),
      "",
      "---",
      "",
    );
  }
  for (const p of blogPosts()) {
    sections.push(
      `## ${plainTitle(p)}`,
      `URL: ${urlFor(p.route)}`,
      `Markdown: ${urlFor(p.route)}.md`,
      "",
      plainDescription(p),
      "",
      htmlToMarkdown(contentFor(p.route)),
      "",
      "---",
      "",
    );
  }
  return new Response(sections.join("\n"), {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};
