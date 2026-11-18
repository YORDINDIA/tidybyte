/** Every format specifier in a string, in order, as `{ token, positional, raw, index }`. */
export function scanPlaceholders(text) {
  const pattern = /%(?:(\d+)\$)?[-+ #0\x27]*(?:\d+)?(?:\.(\d+))?(?:ll|hh|l|h|z|q|j|t|L)?([@diufsxXoOeEgGcCpaA]|%)/g;
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
 */
export function positionalize(english, translated) {
  const englishTokens = scanPlaceholders(english);
  const translatedTokens = scanPlaceholders(translated);

  if (englishTokens.length !== translatedTokens.length) return translated;
  if (argumentsMatch(english, translated)) {
    return translated;
  }

  const englishArguments = positionalPlaceholders(english);
  const englishTypes = englishArguments.map((token) => token.type);
  if (new Set(englishTypes).size !== englishTypes.length) return translated;

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
      result += `%${englishArguments[englishIndex].position}$${bare}`;
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
 */
export function argumentsMatch(english, translated) {
  const englishTokens = positionalPlaceholders(english);
  const translatedTokens = positionalPlaceholders(translated);

  if (englishTokens.length !== translatedTokens.length) return false;

  const signature = (tokens) => tokens.map((token) => `${token.position}:${token.type}`).sort();
  const expected = signature(englishTokens);
  const actual = signature(translatedTokens);
  return expected.every((token, index) => token === actual[index]);
}
