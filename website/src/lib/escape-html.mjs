const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;' };

export function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (character) => HTML_ESCAPES[character]);
}
