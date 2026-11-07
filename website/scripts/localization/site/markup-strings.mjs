const TEXT_ATTRIBUTES = ["alt", "title", "aria-label", "placeholder"];
const OPAQUE = /(^---[\s\S]*?---\r?\n|<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<!--[\s\S]*?-->)/gi;

export function isTranslatable(text) {
  // HTML entity names such as &middot; contain letters but no words.
  return /[A-Za-z]/.test(text.replace(/&[#\w]+;/g, ""));
}

export function mapMarkupStrings(source, transform) {
  return source.split(OPAQUE).map((chunk, index) => {
    if (index % 2 === 1) return chunk;
    const text = chunk.replace(/(^|>)([^<]+)(?=<|$)/g, (_, prefix, value) => `${prefix}${transform(value, "text")}`);
    const attributes = new RegExp(`\\b(${TEXT_ATTRIBUTES.join("|")})="([^"]*)"`, "g");
    return text.replace(attributes, (_, name, value) => `${name}="${transform(value, "attribute")}"`);
  }).join("");
}
