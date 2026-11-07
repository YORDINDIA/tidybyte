// Netlify reads its config before the site build, so these rewrites stay in
// netlify.toml. Check them against the generated pages to prevent drift.
export function missingPageRewrites(config, paths) {
  const rules = config.split(/^\[\[redirects\]\]\s*$/m).slice(1).map((block) => {
    const from = block.match(/^\s*from\s*=\s*"([^"]+)"/m)?.[1];
    const to = block.match(/^\s*to\s*=\s*"([^"]+)"/m)?.[1];
    const status = Number(block.match(/^\s*status\s*=\s*(\d+)/m)?.[1]);
    return { from, to, status };
  });
  return [...new Set(paths)].filter((path) =>
    !rules.some((rule) => rule.from === path && rule.to === `${path}.html` && rule.status === 200),
  ).sort();
}

const BEGIN = '# BEGIN GENERATED LANDING REWRITES';
const END = '# END GENERATED LANDING REWRITES';

// Netlify consumes this committed block before it runs the site build.
// Generate it from built pages after a tool or language is added or removed.
export function withGeneratedPageRewrites(config, paths) {
  const start = config.indexOf(BEGIN);
  const end = config.indexOf(END, start + BEGIN.length);
  if (start < 0 || end < 0 || config.indexOf(BEGIN, start + BEGIN.length) >= 0 || config.indexOf(END, end + END.length) >= 0) {
    throw new Error('Expected exactly one generated landing rewrite block in netlify.toml');
  }
  const sorted = [...new Set(paths)].sort();
  if (!sorted.length || sorted.some((path) => !/^\/[a-z0-9-]+$/.test(path))) {
    throw new Error('Generated landing paths are empty or invalid');
  }
  const rules = sorted.map((path) => `[[redirects]]\n  from = "${path}"\n  to = "${path}.html"\n  status = 200`).join('\n\n');
  return config.slice(0, start) + `${BEGIN}\n# Run npm run sync:netlify after building when tool or language routes change.\n${rules}\n${END}` + config.slice(end + END.length);
}
