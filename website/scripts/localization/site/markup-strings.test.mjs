import test from "node:test";
import assert from "node:assert/strict";
import { isTranslatable, mapMarkupStrings } from "./markup-strings.mjs";

test("visits visible text and accessible attributes without changing code or comments", () => {
  const source = '---\nconst title = "Hello";\n---\n<p title="Hello"> Hello </p><!-- Hello --><script>"Hello"</script><style>p{content:"Hello"}</style>';
  const seen = [];
  const result = mapMarkupStrings(source, (value, kind) => {
    seen.push([value.trim(), kind]);
    return value.replace("Hello", "Hola");
  });
  assert.deepEqual(seen.sort(), [["Hello", "attribute"], ["Hello", "text"]]);
  assert.ok(result.includes('<p title="Hola"> Hola </p>'));
  assert.ok(result.includes('const title = "Hello"'));
  assert.ok(result.includes('<!-- Hello --><script>"Hello"</script>'));
});

test("visits text that directly follows a comment or starts a chunk", () => {
  const seen = [];
  mapMarkupStrings("<!-- note -->Hello<p>World</p>", (value) => {
    seen.push(value);
    return value;
  });
  assert.deepEqual(seen.sort(), ["Hello", "World"]);
});

test("matches opaque blocks regardless of tag case and CRLF frontmatter", () => {
  const seen = [];
  mapMarkupStrings("<SCRIPT>const a = 'Hi';</SCRIPT><p>Shown</p>", (value) => {
    seen.push(value);
    return value;
  });
  assert.deepEqual(seen, ["Shown"]);

  const crlf = [];
  mapMarkupStrings("---\r\nconst t = 'Hidden';\r\n---\r\n<p>Shown</p>", (value) => {
    crlf.push(value);
    return value;
  });
  assert.deepEqual(crlf, ["Shown"]);
});

test("does not treat entity-only text as translatable", () => {
  assert.equal(isTranslatable("42 &middot;"), false);
  assert.equal(isTranslatable("42 ·"), false);
  assert.equal(isTranslatable("Hello &middot; world"), true);
});
