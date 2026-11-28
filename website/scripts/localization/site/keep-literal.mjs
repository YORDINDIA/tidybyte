// Text that stays English on the localized landing pages.
//
// Shared by the extractor and the builder on purpose. The extractor leaves these
// out of `site-strings.json` so no translator is ever asked about them, and the
// builder has to know they were deliberately excluded — otherwise it finds a
// Latin-script string on the page with no translation, calls it untranslated,
// and fails the build for all 20 languages.
//
// Product names, Apple framework names, keycaps, sample filenames, and version
// strings. Translating any of them would be wrong in every language.

export const KEEP_LITERAL = new Set([
  "TidyByte",
  "TidyByte Free",
  "TidyByte for Mac",
  "iOS 17+",
  "iPhone",
  "iPad",
  "Mac",
  "MIT",
  "App Store",
  "GitHub",
  "Vision",
  "SHA-256",
  "WhatsApp",
  "Telegram",
  "1.0.5",
  "{iosVersion}",
  // Unit symbols, disk/file names, durations, and HTML entities
  "GB",
  "MB",
  "KB",
  "1.4 GB",
  "2.8 MB",
  "3.1 MB",
  "3.4 MB",
  "4.1 MB",
  "4.2 MB",
  "60s",
  "12:05",
  "2012-08-09",
  "2024-10-14",
  "2025-06-22",
  "2025-11-03",
  "1080p HD",
  "macOS 26",
  "APFS",
  "Finder",
  "File",
  "Edit",
  "View",
  "Macintosh HD",
  "IMG_4032.jpg",
  "IMG_4032 2.jpg",
  "IMG_2208 (blur).jpg",
  "IMG_4471 copy.jpg",
  "IMG_8920.heic",
  "Old-App-1.2.dmg",
  "Screenshot 13.19.52.png",
  "Burst_0042",
  "4K Clip.mov",
  "holiday-clip.mov",
  "holiday-video.mp4",
  "/Applications",
  "~/Downloads",
  "~/Pictures",
  "~/Library/Developer",
  "~/Pictures/IMG_4032.jpg",
  "~/Downloads/IMG_4032 2.jpg",
  "~/Movies/holiday-video.mp4",
  "~/Pictures/IMG_4032.jpg &middot; Keep",
  "~/Downloads/IMG_4032 2.jpg &rarr; APFS Clone",
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
  "&#x2318; F",
  // Hardware keyboard keycap legends (ANSI Mac layout)
  "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
  "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
  "esc", "tab", "caps", "shift", "return", "fn", "ctrl", "opt", "space", "up", "Space",
]);

/// True when a page string is deliberately not translated.
export function isKeepLiteral(text) {
  return KEEP_LITERAL.has(text.trim());
}
