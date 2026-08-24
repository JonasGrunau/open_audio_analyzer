// The three typefaces, fetched once and served from this origin.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
//     npm run fonts
//
// The site used to link `fonts.googleapis.com/css2` from every page. That is one
// render-blocking stylesheet on a second origin, which then names font files on
// a *third*, so nothing typographic paints until two cross-origin round trips
// have finished — and `global.css` sets `font-synthesis: none` and varies
// Archivo's `wdth` axis, so the fallback does not merely differ in weight, it
// re-wraps. Self-hosted, the `@font-face` rules arrive inside the HTML (every
// stylesheet here is inlined) and the files come off a connection that is
// already open.
//
// This writes both halves: the woff2 files into `public/fonts/`, and
// `src/styles/fonts.css` with the rules that name them. Both are committed —
// the same bargain `public/modules/*.webp` strikes, for the same reason, and
// running this needs the network where a build must not.
//
// Three things worth knowing before editing it:
//
//   - **The `unicode-range` values are Google's, copied verbatim.** They are
//     what makes a subset free until it is needed: a browser downloads
//     `symbols` only on a page that actually contains one, so the keyboard
//     document pulls it and the front page never does.
//
//   - **`math` and `symbols` are kept for Google Sans Code and are not
//     optional.** `⌘ ⇧ ⌃ ⇥ ⌦ ⌫` on the keyboard page and the `→` and `↗` in
//     every documentation page are in those two subsets and in neither `latin`
//     nor `latin-ext`. Ship latin alone and all of them fall to a system font —
//     which is not an error, does not fail a build, and quietly redraws the one
//     page whose whole subject is which key to press.
//
//   - **`latin-ext` is kept although nothing currently needs it.** Every glyph
//     the site publishes today is inside `latin`; the moment somebody writes a
//     name with a diacritic it would not be, and the failure is a silent
//     fallback rather than a missing file. `unicode-range` means the file is
//     never fetched until that day, so it costs repository bytes and no
//     request.
//
// The filenames carry the family's version (`archivo-v25-latin.woff2`), which is
// what lets `public/_headers` cache them for a year as immutable: a refresh that
// changes a file changes its name.

import { mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const FONT_DIR = join(ROOT, 'public/fonts');
const CSS_OUT = join(ROOT, 'src/styles/fonts.css');

/// The families and axis ranges the site asks for. One string, so it cannot
/// drift from what the stylesheet declares.
const CSS2 =
  'https://fonts.googleapis.com/css2' +
  '?family=Archivo:wdth,wght@62..125,400..700' +
  '&family=Google+Sans+Code:wght@400..600' +
  // Source Serif 4 without its `opsz` axis, which is a deliberate trade and the
  // only place these ranges differ from what the old stylesheet asked for.
  // Carrying it costs 71,244 bytes — 58% of the file, and this was the single
  // heaviest request on every page, ahead of the hero image whose arrival is
  // what Largest Contentful Paint measures. What it buys is optical sizing
  // between the 15px of the footer and the 19px of body prose, which is the
  // narrowest range a serif's optical axis has anything to say about. Archivo's
  // `wdth` is not the same case and stays: the site sets it explicitly at 94,
  // 98, 108, 110 and 112, so dropping that axis would silently flatten every
  // heading and label to one width.
  '&family=Source+Serif+4:wght@400..600' +
  '&display=swap';

/// Which subsets of each family to keep. See the header for why these and not
/// only `latin`.
const KEEP = {
  Archivo: ['latin', 'latin-ext'],
  'Source Serif 4': ['latin', 'latin-ext'],
  'Google Sans Code': ['latin', 'latin-ext', 'math', 'symbols'],
};

/// A modern desktop Chrome, because the response depends on it: an older or
/// absent User-Agent gets `ttf` with no `unicode-range` at all, and the whole
/// design of this script rests on those ranges.
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

const slug = (family) => family.toLowerCase().replace(/[^a-z0-9]+/g, '-');

async function main() {
  const response = await fetch(CSS2, { headers: { 'user-agent': UA } });
  if (!response.ok) throw new Error(`${CSS2} answered ${response.status}`);
  const css = await response.text();

  // Google emits one `/* subset */ @font-face { … }` pair per subset per family.
  const blocks = [...css.matchAll(/\/\*\s*(\S+)\s*\*\/\s*@font-face\s*\{([^}]*)\}/g)];
  if (!blocks.length) throw new Error('No @font-face blocks in the response — did the UA change?');

  mkdirSync(FONT_DIR, { recursive: true });
  const wanted = new Set();
  const rules = [];

  for (const [, subset, body] of blocks) {
    const family = /font-family:\s*'([^']+)'/.exec(body)?.[1];
    if (!family || !KEEP[family]?.includes(subset)) continue;

    const url = /url\((\S+?)\)/.exec(body)[1];
    // `/s/archivo/v25/k3kQ….woff2` — the version is the third segment, and it is
    // the only part of the name that has to change when a font does.
    const version = /\/s\/[^/]+\/(v\d+)\//.exec(url)?.[1] ?? 'v0';
    const name = `${slug(family)}-${version}-${subset}.woff2`;
    wanted.add(name);

    // Always fetched, never skipped when the file is already there. The name
    // carries the family's *version*, not the axis ranges asked for above — so
    // narrowing an axis produces a different file under the same name, and a
    // "download only if missing" check would keep the old one, report success
    // and leave the site a change behind with nothing to show for it. This is
    // the same trap scripts/clean-content-cache.mjs exists to close, and it
    // caught this script once already: dropping Source Serif 4's `opsz` changed
    // nothing until the check came out.
    const target = join(FONT_DIR, name);
    const file = await fetch(url, { headers: { 'user-agent': UA } });
    if (!file.ok) throw new Error(`${url} answered ${file.status}`);
    writeFileSync(target, Buffer.from(await file.arrayBuffer()));

    // Keep every descriptor Google wrote — the weight and stretch ranges are
    // what make these variable rather than one instance — and swap only the src.
    const keepDescriptor = (property) => {
      const found = new RegExp(`${property}:\\s*([^;]+);`).exec(body);
      return found ? `  ${property}: ${found[1].trim()};\n` : '';
    };
    rules.push(
      `/* ${family} — ${subset} */\n@font-face {\n` +
        `  font-family: '${family}';\n` +
        keepDescriptor('font-style') +
        keepDescriptor('font-weight') +
        keepDescriptor('font-stretch') +
        `  font-display: swap;\n` +
        `  src: url('/fonts/${name}') format('woff2');\n` +
        keepDescriptor('unicode-range') +
        `}`,
    );
  }

  // A refresh that moves a version leaves the old file behind otherwise, and a
  // font nothing references is a font nobody will ever notice is stale.
  for (const found of readdirSync(FONT_DIR)) {
    if (found.endsWith('.woff2') && !wanted.has(found)) {
      rmSync(join(FONT_DIR, found));
      console.log(`  removed ${found} (no longer referenced)`);
    }
  }

  writeFileSync(
    CSS_OUT,
    `/* Generated by scripts/fetch-fonts.mjs — do not edit. Run \`npm run fonts\`.\n` +
      `   SPDX-License-Identifier: GPL-3.0-or-later\n\n` +
      `   The typefaces themselves are SIL OFL 1.1; see public/fonts/OFL.txt.\n` +
      `   Every value below except the src URL is Google's own, so these render\n` +
      `   what fonts.googleapis.com rendered. The header of the script says why\n` +
      `   the math and symbols subsets are here. */\n\n` +
      rules.join('\n\n') +
      '\n',
  );

  let total = 0;
  console.log(`\n  ${'file'.padEnd(44)}bytes`);
  for (const name of [...wanted].sort()) {
    const size = statSync(join(FONT_DIR, name)).size;
    total += size;
    console.log(`  ${name.padEnd(44)}${size.toLocaleString().padStart(9)}`);
  }
  console.log(`  ${'total'.padEnd(44)}${total.toLocaleString().padStart(9)}`);
  console.log(`\n  ${rules.length} @font-face rules → src/styles/fonts.css`);
}

await main();
