// Text that stays English on the localized landing pages.
//
// Shared by the extractor and the builder on purpose. The extractor leaves these
// out of `site-strings.json` so no translator is ever asked about them, and the
// builder has to know they were deliberately excluded — otherwise it finds a
// Latin-script string on the page with no translation, calls it untranslated,
// and fails the build for all 20 languages.
//
// Product names, Apple framework names and a version string. Translating any of
// them would be wrong in every language, which is what earns them a place here
// rather than a translation.

export const KEEP_LITERAL = new Set([
  "TidyByte",
  "TidyByte Free",
  "TidyByte for Mac",
  "iOS 17+",
  "iPhone",
  "iPad",
  "App Store",
  "GitHub",
  "Vision",
  "SHA-256",
  "WhatsApp",
  "Telegram",
  "1.0.5",
  "{iosVersion}",
  // The landing page's app replicas: unit symbols, a disk and file names,
  // a duration, and HTML entities that render as glyphs. Every language
  // sees the same characters on screen, so there is nothing to translate.
  "GB",
  "MB",
  "KB",
  "60s",
  "12:05",
  "2012-08-09",
  "2024-10-14",
  "2025-06-22",
  "2025-11-03",
  "1080p HD",
  "macOS 26",
  "APFS",
  "Macintosh HD",
  "IMG_4032.jpg",
  "IMG_4032 2.jpg",
  "holiday-video.mp4",
  "/Applications",
  "~/Downloads",
  "~/Pictures",
  "~/Library/Developer",
  "~/Pictures/IMG_4032.jpg",
  "~/Downloads/IMG_4032 2.jpg",
  "~/Movies/holiday-video.mp4",
  "Xcode DerivedData",
  "node_modules",
  "Homebrew Cache",
  "Docker Build Cache",
  "~/Library/Developer/Xcode/DerivedData",
  "~/Projects/node_modules",
  "~/Library/Caches/Homebrew",
  "~/Library/Containers/com.docker.docker",
  "sha256:9f8a4c12",
  "sha256:3e1b8d09",
  "&middot;",
  "&#x2039;",
]);

/// True when a page string is deliberately not translated.
///
/// Matches the trimmed string exactly. A partial match would be wrong: the
/// string "Macintosh HD is almost full" contains "Macintosh HD" and must be
/// translated, while the bare disk label "Macintosh HD" must not.
export function isKeepLiteral(text) {
  return KEEP_LITERAL.has(text.trim());
}
