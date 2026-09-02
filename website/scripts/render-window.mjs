// Encodes the two photographs of the application's own window.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Loudness tab and the Spectrum tab, whole, with the window's chrome around
// them — which is the one thing no other picture on this site shows. The hero
// still is a Flutter *web* build shot through headless Chrome, so it has no
// window at all; the module thumbnails are one module each; and the signal-path
// plates do show the window but show it publishing to a tablet, because that is
// what the paragraph beside them is about. The tab strip, the file name, the
// menu row and the status bar appear in none of them.
//
//     npm run window                # both, from packaging/screenshots/
//     npm run window -- --only=spectrum
//
// The photographs themselves are not taken here. `packaging/app_window_shots.sh`
// takes them, from one session: the fake DAW plays a real track through the real
// VST3 into the application on this Mac, and both tabs are shot from a frozen
// frame of that one run. It needs a release build, the fake DAW, Screen
// Recording, permission to post a key, port 47822 free and the machine to
// itself for two minutes — so like the other photographs on this site the
// outputs are committed, because the `website` job in ci.yml has none of that.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, statSync, writeFileSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const REPO = resolve(ROOT, '..');
const OUT = join(ROOT, 'public/window');

/// The widths each shot is published at.
///
/// A window shot is read differently from a meter thumbnail: what a reader wants
/// from it is the *shape* of the application — where the tabs are, what a canvas
/// of fourteen modules looks like — and only then the readings. So it is
/// published wide enough to be opened full-screen and zoomed into, with the
/// smaller rungs for a layout that gives it a column rather than a page.
///
/// 2560 is the widest because that is a retina laptop showing it edge to edge;
/// beyond it the file grows faster than anything a reader gains.
const WIDTHS = [1024, 1440, 1920, 2560];

const SHOTS = ['loudness', 'spectrum'];

const argv = process.argv.slice(2);
const only = argv.find((a) => a.startsWith('--only='))?.slice('--only='.length);
const wanted = (name) => !only || only.split(',').includes(name);

mkdirSync(OUT, { recursive: true });

/// PNG in, committed webp out.
///
/// The same encoder settings as the hero still, the module thumbnails and the
/// signal-path plates, so the whole site's photographs are one decision rather
/// than four. `-resize W 0` keeps the aspect ratio; every rung is encoded from
/// the original PNG rather than from a larger webp, so no rung carries a
/// previous encode's artefacts.
function encode(png, name, width) {
  const suffix = width === null ? '' : `-${width}`;
  const webp = join(OUT, `${name}${suffix}.webp`);
  execFileSync('cwebp', [
    '-quiet', '-q', '88', '-sharp_yuv', '-m', '6',
    ...(width === null ? [] : ['-resize', String(width), '0']),
    png, '-o', webp,
  ]);
  const info = execFileSync('webpinfo', ['-summary', webp]).toString();
  const size = {
    width: Number(/Width:\s*(\d+)/.exec(info)?.[1]),
    height: Number(/Height:\s*(\d+)/.exec(info)?.[1]),
  };
  console.log(
    `  public/window/${name}${suffix}.webp  ${size.width}x${size.height}  ` +
      `${(statSync(webp).size / 1024).toFixed(1)} kB (committed)`,
  );
  return size;
}

const made = {};
const skipped = [];

for (const name of SHOTS) {
  if (!wanted(name)) continue;
  const shot = join(REPO, `packaging/screenshots/window-${name}.png`);
  if (!existsSync(shot)) {
    skipped.push(
      `${name.padEnd(8)} — packaging/screenshots/window-${name}.png is not there.\n` +
        '             sh packaging/app_window_shots.sh\n' +
        '             (A release build, the fake DAW, Screen Recording,\n' +
        '              permission to post a key, and 47822 free.)',
    );
    continue;
  }
  // The full-size one keeps the bare name, so a hand-written `src` pointing at
  // `/window/loudness.webp` resolves whatever the rungs are doing.
  const full = encode(shot, name, null);
  const sources = [];
  for (const width of WIDTHS) {
    if (width >= full.width) continue;
    sources.push({ width, file: `/window/${name}-${width}.webp` });
    encode(shot, name, width);
  }
  sources.push({ width: full.width, file: `/window/${name}.webp` });
  made[name] = { ...full, sources };
}

// --- What the page needs to know --------------------------------------------

/* The intrinsic sizes and the rungs, written beside the pictures.
 *
 * The same arrangement as `src/data/flow-shots.json` and for the same reason: an
 * `<img>` has to declare a width and a height for its box to have a shape before
 * anything is fetched, and a number typed into the markup is a number that goes
 * quietly wrong the first time a source is reshot. */
const META = join(ROOT, 'src/data/window-shots.json');
if (Object.keys(made).length > 0) {
  const existing = existsSync(META) ? JSON.parse(readFileSync(META, 'utf8')) : {};
  writeFileSync(META, `${JSON.stringify({ ...existing, ...made }, null, 2)}\n`);
  console.log(`  src/data/window-shots.json  ${Object.keys(made).join(', ')}`);
}

if (skipped.length > 0) {
  console.log(`\nNot made on this machine:\n\n  ${skipped.join('\n  ')}\n`);
}
