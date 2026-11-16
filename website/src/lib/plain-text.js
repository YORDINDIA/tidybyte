// Plain text for a title or description. The data files store copy with HTML
// entities, and Astro escapes attribute and <title> text, so passing the raw
// string would print `&amp;mdash;` in the tab, in search results and in link
// previews. Decode each entity to its own character, then let Astro escape.
const ENTITIES = {
  "&mdash;": "—",
  "&ndash;": "–",
  "&lsquo;": "‘",
  "&rsquo;": "’",
  "&ldquo;": "“",
  "&rdquo;": "”",
  "&quot;": '"',
  "&#x27;": "'",
  "&#39;": "'",
  "&middot;": "·",
  "&hellip;": "…",
  "&nbsp;": " ",
};

export function plainText(s) {
  return s
    .replace(/&[a-z]+;|&#x?[0-9a-f]+;/gi, (e) => ENTITIES[e] ?? e)
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
}
