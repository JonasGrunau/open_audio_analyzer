// Does any page scroll sideways on a phone?
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
//     npm run build && npm run check
//     npm run check -- --port 4411        # against a preview already running
//
// The one responsive bug that is invisible in every screenshot and obvious on
// every phone: something two pixels too wide — a table, a code block, a line of
// readout set `nowrap` — pushes the whole document sideways, and from then on
// the header is short of the right edge and every heading is slightly off. It
// does not look broken in a desktop browser at any width, because the desktop
// layout has room; it needs an actual narrow viewport, which a browser window
// cannot be dragged to.
//
// So this serves `dist/`, opens each page at three widths with the viewport
// overridden, and compares `documentElement.scrollWidth` with `innerWidth`. It
// names the widest element when they disagree, because "it overflows by 40 px"
// sends somebody hunting and "the table in the install page does" does not.
//
// Not part of `npm run build`: it needs Chrome, and a build should not.

import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

import { browser, serve } from './lib/headless.mjs';
import { PAGES, href } from '../src/lib/docs.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const DIST = join(ROOT, 'dist');

/// Three widths, and the reasons for each: the narrowest phone still sold, the
/// most common one, and the tablet portrait width where the docs rail drops to
/// two columns and the module catalogue to two across.
const WIDTHS = [360, 390, 768];

const argv = process.argv.slice(2);
const at = argv.indexOf('--port');
const external = at >= 0 ? Number(argv[at + 1]) : null;
const PORT = external ?? 4412;

if (!external && !existsSync(join(DIST, 'index.html'))) {
  console.error('No dist/. Run `npm run build` first.');
  process.exit(1);
}

/// Every page the site publishes. The documentation is derived from the same
/// manifest the pages are built from, so a new document is checked without this
/// list being edited. `/privacy` is named because it is the one published page
/// outside that manifest — see src/pages/privacy.astro — and it is the page
/// most worth checking here, being almost entirely tables.
const paths = ['/', '/404', '/privacy', ...PAGES.map((page) => href(page.slug))];

const server = external ? null : await serve(DIST, PORT);
const chrome = await browser({ port: 9402, window: '1200,1000' });

let failures = 0;
try {
  for (const width of WIDTHS) {
    for (const path of paths) {
      // `build.format: 'file'`, so a route is a file. The server here does not
      // rewrite, and asking it for `/docs/install` would be a 404 that looked
      // like a layout pass.
      const file = path === '/' ? '/index.html' : `${path}.html`;
      const report = await chrome.probe({
        url: `http://127.0.0.1:${PORT}${file}`,
        width,
        height: 900,
      });
      const over = report.scrollWidth - report.innerWidth;
      if (over > 1) {
        failures++;
        console.error(
          `  ${String(width).padStart(4)}px  ${path} overflows by ${over}px — widest is ${report.widest}`,
        );
      }
    }
  }
} finally {
  await chrome.close();
  server?.close();
}

if (failures > 0) {
  console.error(`\n${failures} page/width combination(s) scroll sideways.`);
  process.exit(1);
}
console.log(`${paths.length} pages at ${WIDTHS.join(', ')} px — none scroll sideways.`);
