import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findHtmlFiles } from "./html-files.mjs";

test("finds HTML at every depth and ignores other files", () => {
  const root = mkdtempSync(join(tmpdir(), "tidybyte-html-"));
  try {
    mkdirSync(join(root, "nested", "deeper"), { recursive: true });
    for (const name of ["index.html", "nested/page.html", "nested/deeper/index.html", "nested/readme.txt"]) {
      writeFileSync(join(root, name), "");
    }
    assert.deepEqual(findHtmlFiles(root), ["index.html", "nested/deeper/index.html", "nested/page.html"].map((name) => join(root, name)));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
