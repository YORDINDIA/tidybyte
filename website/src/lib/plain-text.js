// Plain text for a title or description. The data files store copy with HTML
// character references, and Astro escapes attribute and <title> text, so
// passing the raw string would print `&amp;mdash;` in the tab, in search results
// and in link previews. Each reference is decoded in one pass, so the output is
// always one decode away from the source: `&amp;mdash;` becomes `&mdash;`,
// never `—`.

// Named references the site uses, plus the common ones copy tends to reach for.
// Any other named reference is left as written, not guessed.
const NAMED = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  mdash: "—", ndash: "–", lsquo: "‘", rsquo: "’", sbquo: "‚",
  ldquo: "“", rdquo: "”", bdquo: "„", laquo: "«", raquo: "»",
  lsaquo: "‹", rsaquo: "›", middot: "·", bull: "•", hellip: "…",
  larr: "←", rarr: "→", uarr: "↑", darr: "↓", harr: "↔",
  copy: "©", reg: "®", trade: "™", times: "×", divide: "÷",
  deg: "°", plusmn: "±", frac12: "½", frac14: "¼", frac34: "¾",
  cent: "¢", pound: "£", yen: "¥", euro: "€", sect: "§", para: "¶",
  check: "✓", hearts: "♥", star: "☆",
};

// Every numeric reference (decimal or hex) decodes. Surrogates, zero and code
// points past U+10FFFF are not characters, so they stay as written.
function fromNumeric(body) {
  const code = body[1] === "x" || body[1] === "X" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
  if (!Number.isFinite(code) || code <= 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return null;
  return String.fromCodePoint(code);
}

export function plainText(s) {
  return s
    .replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/g, (match, body) => {
      if (body[0] === "#") return fromNumeric(body) ?? match;
      return Object.prototype.hasOwnProperty.call(NAMED, body) ? NAMED[body] : match;
    })
    .replace(/\s+/g, " ")
    .trim();
}
