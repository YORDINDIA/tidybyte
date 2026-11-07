import { readdirSync } from "node:fs";
import { join } from "node:path";

// Astro may place pages at any depth under the output directory.
export function findHtmlFiles(root) {
  const files = [];
  function visit(dir) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile() && entry.name.endsWith(".html")) files.push(path);
    }
  }
  visit(root);
  return files.sort();
}
