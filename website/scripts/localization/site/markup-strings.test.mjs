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
  assert.equal(isTranslatable("42 &middot;"), true);
  assert.equal(isTranslatable("42 ·"), false);
});
