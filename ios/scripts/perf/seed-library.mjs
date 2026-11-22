#!/usr/bin/env node
// Adds a number of small, distinct photos to a simulator's photo library, so the
// large-library behaviour in docs/large-library-performance.md can be measured.
//
//   node scripts/perf/seed-library.mjs --count 27000            # booted simulator
//   node scripts/perf/seed-library.mjs --count 27000 --udid <id>
//   node scripts/perf/seed-library.mjs --count 10 --dry-run     # write files only
//
// The photos stay in the simulator's library. 27,000 take about 10 minutes.
// Every file has different bytes, but most share a byte size, so the exact
// duplicate scan hashes almost all of them: real libraries prune far better.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { crc32, deflateSync } from 'node:zlib';

function option(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? fallback : process.argv[index + 1];
}

const count = Number(option('count', '0'));
const udid = option('udid', 'booted');
const dryRun = process.argv.includes('--dry-run');
const batchSize = 1000;
if (!Number.isInteger(count) || count < 1) {
  console.error('Usage: node scripts/perf/seed-library.mjs --count <n> [--udid <id>] [--dry-run]');
  process.exit(1);
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

/** A 16x16 RGB PNG whose last pixel holds `index`, so no two files are equal. */
function png(index) {
  const side = 16;
  const rows = [];
  for (let y = 0; y < side; y += 1) {
    const row = [0];
    for (let x = 0; x < side; x += 1) row.push((index * 37) % 256, (index * 91) % 256, (index >> 8) % 256);
    rows.push(...row);
  }
  rows.splice(rows.length - 3, 3, index % 256, (index >> 8) % 256, (index >> 16) % 256);
  const header = Buffer.alloc(13);
  header.writeUInt32BE(side, 0);
  header.writeUInt32BE(side, 4);
  header.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(Buffer.from(rows))),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const folder = mkdtempSync(join(tmpdir(), 'tidybyte-seed-'));
const started = Date.now();
try {
  const files = [];
  for (let index = 0; index < count; index += 1) {
    const file = join(folder, `seed-${String(index).padStart(6, '0')}.png`);
    writeFileSync(file, png(index));
    files.push(file);
  }
  if (dryRun) {
    console.log(`Wrote ${count} files to ${folder}; added nothing (--dry-run).`);
  } else {
    for (let start = 0; start < files.length; start += batchSize) {
      execFileSync('xcrun', ['simctl', 'addmedia', udid, ...files.slice(start, start + batchSize)], { stdio: 'inherit' });
      console.log(`Added ${Math.min(start + batchSize, files.length)} of ${count}`);
    }
    console.log(`Added ${count} photos to ${udid} in ${Math.round((Date.now() - started) / 1000)} s.`);
  }
} finally {
  if (!dryRun) rmSync(folder, { recursive: true, force: true });
}
