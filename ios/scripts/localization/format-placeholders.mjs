/** Every format specifier in a string, in order, as `{ token, index }`. */
export function scanPlaceholders(text) {
  const pattern = /%(?:(\d+)\$)?(?:\.(\d+))?(?:ll|l|h|hh|z|q)?([@difsuxXeEgGcCpaA]|%)/g;
  const found = [];
  let match;
  while ((match = pattern.exec(text)) !== null) {
    found.push({ token: match[3] === '%' ? '%%' : match[3], positional: match[1], raw: match[0], index: match.index });
  }
  return found;
}

/**
 * Rewrites a translation's placeholders as positional specifiers when the
 * translator reordered them.
 *
 * This is not cosmetic. `String.localizedStringWithFormat` substitutes
 * arguments *positionally*, so a Chinese string that puts the count before the
 * text ("%lld 中的 %@") would feed the count into `%@` and the text into
 * `%lld` — a crash or garbage output. Writing `%2$lld 中的 %1$@` pins each
 * specifier to the argument the English source intended, which is exactly what
 * Xcode does when you reorder specifiers in the String Catalog editor.
 *
 * Reordering is only resolvable when the types are distinguishable. With two
 * `%@`s in one string there is no way to tell which moved, so the translation
 * is returned unchanged; no checker can infer which identical argument moved.
 */
export function positionalize(english, translated) {
  const englishTokens = scanPlaceholders(english);
  const translatedTokens = scanPlaceholders(translated);

  // Nothing to do when the order already matches, or the shapes differ (the
  // validator reports shape mismatches separately).
  if (englishTokens.length !== translatedTokens.length) return translated;
  if (englishTokens.every((token, index) => token.token === translatedTokens[index].token)) {
    return translated;
  }
  // Ambiguous when a type repeats: cannot map one occurrence onto another.
  //
  // `%%` is a literal percent, not an argument, so it is excluded from the base
  // the index is looked up in. Leaving it in shifted every placeholder after a
  // `%%` by one: "100%% of %@ saved by %lld MB" gave `%3$lld` and `%2$@` for a
  // translation that had swapped only the two real arguments.
  const englishTypes = englishTokens
    .filter((token) => token.token !== '%%')
    .map((token) => token.token);
  if (new Set(englishTypes).size !== englishTypes.length) return translated;

  // Walk the translated string, replacing each placeholder with the positional
  // form of the English argument it corresponds to.
  let result = '';
  let cursor = 0;
  for (const match of translatedTokens) {
    const type = match.token;
    result += translated.slice(cursor, match.index);
    if (type === '%%') {
      result += '%%';
    } else {
      const englishIndex = englishTypes.indexOf(type);
      if (englishIndex < 0) return translated;
      const bare = match.raw.replace(/^%(?:\d+\$)?/, '');
      result += `%${englishIndex + 1}$${bare}`;
    }
    cursor = match.index + match.raw.length;
  }
  result += translated.slice(cursor);
  return result;
}

/**
 * `{ position, type }` for each specifier, where `position` is the explicit
 * `%N$` index when the string uses positional specifiers, and the specifier's
 * own ordinal otherwise.
 */
function positionalPlaceholders(text) {
  let ordinal = 0;
  return scanPlaceholders(text).filter((token) => token.token !== '%%').map((token) => {
    ordinal += 1;
    return { position: token.positional ? Number(token.positional) : ordinal, type: token.token };
  });
}

/**
 * Whether a translation consumes the English source's arguments correctly.
 *
 * Two shapes pass:
 *
 * 1. Same specifiers in the same order — the ordinary case.
 * 2. Positional specifiers (`%2$lld … %1$@`) that map each English argument to
 *    a specifier of the matching type. This is how a language that naturally
 *    orders a count before a noun stays correct, and it is what
 *    `build-catalog.mjs` emits for reordered translations.
 */
export function argumentsMatch(english, translated) {
  const englishTokens = positionalPlaceholders(english);
  const translatedTokens = positionalPlaceholders(translated);

  if (englishTokens.length !== translatedTokens.length) return false;

  const englishByPosition = new Map(englishTokens.map((token) => [token.position, token.type]));
  const usesPositional = translatedTokens.some((token, index) => token.position !== index + 1);

  if (!usesPositional) {
    return englishTokens.every((token, index) => token.type === translatedTokens[index].type);
  }

  // Every English argument must be consumed exactly once, with its own type.
  const seen = new Set();
  for (const token of translatedTokens) {
    if (seen.has(token.position)) return false;
    seen.add(token.position);
    if (englishByPosition.get(token.position) !== token.type) return false;
  }
  return seen.size === englishTokens.length;
}
