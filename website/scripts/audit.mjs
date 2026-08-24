// What Lighthouse makes of every page this site publishes.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
//     npm run build && npm run audit
//     npm run audit -- --only /docs/install     # one page
//     npm run audit -- --mobile                 # one form factor
//     npm run audit -- --min 95                 # fail under this score
//
// There is no gate on this directory in `ci.yml` — `npm run deploy` is the whole
// release process — so a score is only as durable as something that re-measures
// it. This is that thing, and it is built the way `check-layout.mjs` is built,
// for the same reason: the page list comes out of the documentation manifest, so
// a new document is audited without this file being edited.
//
// Two things about it that are not obvious:
//
//   - **It serves `dist/` through the same `serve()` the renderers use**, which
//     reads `public/_headers` and gzips text. Both matter, and for the same
//     reason: a local server with no `Cache-Control` reports every asset as
//     uncacheable, and one that does not compress serves a page nobody is
//     served — Cloudflare does both, and an audit that reproduces neither is
//     measuring the harness. Compression is worth 3.4x across these eleven
//     pages, because every stylesheet is inlined and the HTML *is* the payload.
//     What is still not reproduced is the edge itself: one origin on localhost
//     against a CDN close to the reader. Lighthouse simulates the network from
//     observed transfer sizes rather than from the wall clock, so that gap is
//     smaller than it sounds, but these numbers are a floor rather than a
//     forecast.
//
//   - **It checks the JSON-LD parses.** A structured-data block that is invalid
//     JSON is dropped silently by every consumer, and no Lighthouse audit reads
//     it — `structured-data` is a manual audit that does nothing. One
//     `JSON.parse` per block is the whole check.

import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

import lighthouse from 'lighthouse';
import desktopConfig from 'lighthouse/core/config/desktop-config.js';

import { serve, browser } from './lib/headless.mjs';
import { PAGES, href } from '../src/lib/docs.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const DIST = join(ROOT, 'dist');

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const value = (name, fallback) => {
  const at = argv.indexOf(`--${name}`);
  return at >= 0 ? argv[at + 1] : fallback;
};

const MIN = Number(value('min', 0));
const PORT = 4413;

if (!existsSync(join(DIST, 'index.html'))) {
  console.error('No dist/. Run `npm run build` first.');
  process.exit(1);
}

/// The same list `check-layout.mjs` walks, and for the same reason.
const only = value('only', null);
const paths = only
  ? [only]
  : ['/', '/404', '/privacy', ...PAGES.map((page) => href(page.slug))];

const forms = flag('mobile') ? ['mobile'] : flag('desktop') ? ['desktop'] : ['mobile', 'desktop'];

const CATEGORIES = ['performance', 'accessibility', 'best-practices', 'seo'];

/// Audits that are *meant* to fail, and where.
///
/// Only one so far. `is-crawlable` asks whether a page is blocked from
/// indexing, and `/404` is blocked on purpose: `not_found_handling: "404-page"`
/// serves that one document at every address the site does not have, so without
/// it a crawler is told that a thousand URLs are all really `/404`. Lighthouse
/// has no way to know the difference between a page that is accidentally
/// hidden and one whose whole content is that there is nothing here.
///
/// This suppresses the entry in the report and the page's category score from
/// the floor. It is not a way to quiet an audit that is inconvenient: an
/// exception belongs here only with a reason written down, and the raw score is
/// still printed in the table.
const EXPECTED = {
  'is-crawlable': ['/404'],
};

const expected = (id, path) => (EXPECTED[id] ?? []).includes(path);

// `build.format: 'file'`, so a route is a file and the server does not rewrite —
// asking it for `/docs/install` would be a 404 that looked like a bad score.
const fileFor = (path) => (path === '/' ? '/index.html' : `${path}.html`);

const server = await serve(DIST, PORT);
// Reuse the renderers' Chrome rather than chrome-launcher's, so this script
// needs the same one browser the rest of the directory already requires.
const chrome = await browser({ port: 9403, window: '1400,1000' });

const rows = [];
const failing = new Map(); // audit id -> Set of "form page"
let badJson = 0;

try {
  for (const path of paths) {
    // The JSON-LD check is per page, not per form factor — it is the same bytes.
    const html = readFileSync(join(DIST, fileFor(path)), 'utf8');
    for (const [, block] of html.matchAll(
      /<script[^>]+type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g,
    )) {
      try {
        JSON.parse(block);
      } catch (error) {
        badJson++;
        console.error(`  ${path}: JSON-LD does not parse — ${error.message}`);
      }
    }

    for (const form of forms) {
      const url = `http://127.0.0.1:${PORT}${fileFor(path)}`;
      const result = await lighthouse(
        url,
        { port: 9403, output: 'json', logLevel: 'error', onlyCategories: CATEGORIES },
        form === 'desktop' ? desktopConfig : undefined,
      );
      const lhr = result.lhr;
      const scores = {};
      for (const id of CATEGORIES) scores[id] = Math.round((lhr.categories[id].score ?? 0) * 100);
      // Which categories this page has an intended failure in. Its score is
      // still printed; it is only kept out of the floor, so one deliberate
      // `noindex` does not read as a regression every time the suite runs.
      const waived = new Set();
      for (const [id, paths] of Object.entries(EXPECTED)) {
        if (!paths.includes(path)) continue;
        for (const category of CATEGORIES) {
          if (lhr.categories[category].auditRefs.some((ref) => ref.id === id)) waived.add(category);
        }
      }
      rows.push({ path, form, scores, waived });

      for (const id of CATEGORIES) {
        for (const ref of lhr.categories[id].auditRefs) {
          const audit = lhr.audits[ref.id];
          // Weight 0 is informative — it is reported and does not move a score,
          // so listing it here would bury the ones that do.
          if (!ref.weight || audit.score === null || audit.score >= 0.9) continue;
          if (expected(ref.id, path)) continue;
          if (!failing.has(ref.id)) failing.set(ref.id, new Set());
          failing.get(ref.id).add(`${form} ${path}`);
        }
      }
    }
  }
} finally {
  await chrome.close();
  server.close();
}

const pad = (s, n) => String(s).padEnd(n);
const head = ['performance', 'accessibility', 'best-practices', 'seo'];
console.log(`\n${pad('page', 24)}${pad('form', 9)}${head.map((h) => pad(h.slice(0, 12), 14)).join('')}`);
console.log('-'.repeat(24 + 9 + 14 * 4));
for (const row of rows) {
  console.log(
    pad(row.path, 24) + pad(row.form, 9) + head.map((h) => pad(row.scores[h], 14)).join(''),
  );
}

const worst = {};
for (const id of CATEGORIES) {
  const eligible = rows.filter((r) => !r.waived?.has(id));
  worst[id] = Math.min(...(eligible.length ? eligible : rows).map((r) => r.scores[id]));
}
console.log('-'.repeat(24 + 9 + 14 * 4));
console.log(pad('worst', 24) + pad('', 9) + head.map((h) => pad(worst[h], 14)).join(''));

if (failing.size) {
  console.log('\nScored audits below 90, and where:');
  for (const [id, where] of [...failing].sort()) {
    const list = [...where];
    console.log(`  ${pad(id, 34)} ${list.length > 4 ? `${list.length} pages` : list.join(', ')}`);
  }
}

const floor = Math.min(...Object.values(worst));
if (badJson) {
  console.error(`\n${badJson} JSON-LD block(s) do not parse.`);
  process.exit(1);
}
if (MIN && floor < MIN) {
  console.error(`\nWorst category score ${floor} is below the ${MIN} floor.`);
  process.exit(1);
}
console.log(`\n${rows.length} run(s). Worst category score: ${floor}.`);
