import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { withGeneratedPageRewrites } from './lib/netlify-routes.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');
const configPath = join(root, '..', 'netlify.toml');
const home = join(dist, 'index.html');
if (!existsSync(home)) throw new Error('Build the site before syncing Netlify routes');

const html = readFileSync(home, 'utf8');
const languages = [...html.matchAll(/<link rel="alternate" hreflang="[^"]+" href="([^"]+)"/g)]
  .map((match) => new URL(match[1]).pathname).filter((path) => path !== '/');
if (!languages.length || languages.some((path) => !existsSync(join(dist, `${path.slice(1)}.html`)))) {
  throw new Error('Built home page is missing valid language alternates');
}
const tools = readdirSync(dist).filter((file) => file.endsWith('.html'))
  .filter((file) => /\/assets\/img\/og\//.test(readFileSync(join(dist, file), 'utf8')))
  .map((file) => `/${file.slice(0, -5)}`);
const current = readFileSync(configPath, 'utf8');
const generated = withGeneratedPageRewrites(current, [...languages, ...tools]);
if (process.argv.includes('--check')) {
  if (generated !== current) {
    console.error('Netlify landing rewrites are stale; run npm run sync:netlify after building.');
    process.exit(1);
  }
  console.log(`Netlify landing rewrites match ${new Set([...languages, ...tools]).size} built routes`);
} else {
  writeFileSync(configPath, generated);
  console.log('Updated Netlify landing rewrites');
}
