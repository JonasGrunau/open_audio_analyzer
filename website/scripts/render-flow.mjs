// Assembles the three photographs behind the signal-path section on the front page.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The section shows one stream of audio passing through three programs — the
// plugin in a DAW, the desktop application, the tablet beside it — and each
// stage is a picture of the real thing. `website/AGENTS.md` is the reason:
// nothing on this site draws a meter of its own, because a tool that publishes
// real numbers beside invented pictures has no way to notice when the two drift
// apart.
//
//     npm run flow                # every stage that can be made on this machine
//     npm run flow -- --only=desktop
//
// The three come from two different places, and neither is shot here:
//
//   - plugin           `plugin/build/oaa_editor_snapshot`, a JUCE target that
//                      rasterises the real StatusPanel without a window server.
//                      It needs no DAW and no screen-recording grant, and takes
//                      about a second. Built by the full plugin build
//                      (`cmake --build plugin/build`), which is gated behind a
//                      release or a manual run — so it may simply not be there.
//   - desktop, tablet  `packaging/signal_path.sh`, and **both, from one
//                      session**: the fake DAW plays a real track through the
//                      real VST3 into the application on this Mac, an iPad
//                      simulator attaches to it as a remote display, and both
//                      are photographed from one frozen frame. That is the only
//                      arrangement in which the two plates cannot disagree, and
//                      the paragraph they sit under says they do not. Shot by
//                      hand: it needs Xcode, a release build, the fake DAW, both
//                      ports free and the machine to itself for two minutes.
//
// All three outputs are committed, like the module thumbnails and the hero
// still, because making them needs Flutter, Chrome, cwebp, JUCE and Xcode and
// the website job in ci.yml has none of the five.

import { execFileSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const REPO = resolve(ROOT, '..');
const OUT = join(ROOT, 'public/flow');
/// The published width of every plate.
///
/// The section lays the three stages out in equal thirds of `.shell`, which is
/// at most 1376 px — so a plate is about 440 CSS px, or 880 device pixels on a
/// retina screen. 1200 leaves headroom for a wider layout later without asking
/// a phone to fetch anything like the hero still, which these sit well below.
const WIDTH = 1200;

const argv = process.argv.slice(2);
const only = argv.find((a) => a.startsWith('--only='))?.slice('--only='.length);
const wanted = (name) => !only || only.split(',').includes(name);

mkdirSync(OUT, { recursive: true });

/// PNG in, committed webp out, at the published width.
///
/// The same encoder settings as the hero still and the module thumbnails, so the
/// whole site's photographs are one decision rather than three.
function encode(png, name) {
  const webp = join(OUT, `${name}.webp`);
  execFileSync('cwebp', [
    '-quiet', '-q', '88', '-sharp_yuv', '-m', '6',
    '-resize', String(WIDTH), '0',
    png, '-o', webp,
  ]);
  const info = execFileSync('webpinfo', ['-summary', webp]).toString();
  const w = Number(/Width:\s*(\d+)/.exec(info)?.[1]);
  const h = Number(/Height:\s*(\d+)/.exec(info)?.[1]);
  console.log(
    `  public/flow/${name}.webp  ${w}x${h}  ` +
      `${(statSync(webp).size / 1024).toFixed(1)} kB (committed)`,
  );
  return { width: w, height: h };
}

const made = {};
const skipped = [];

// --- The plugin -------------------------------------------------------------

if (wanted('plugin')) {
  const snapshot = join(REPO, 'plugin/build/oaa_editor_snapshot');
  if (!existsSync(snapshot)) {
    skipped.push(
      'plugin   — plugin/build/oaa_editor_snapshot is not built.\n' +
        '             cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release && \\\n' +
        '               cmake --build plugin/build',
    );
  } else {
    const dir = mkdtempSync(join(tmpdir(), 'oaa-flow-'));
    try {
      execFileSync(snapshot, [dir], { stdio: ['ignore', 'pipe', 'pipe'] });
      // `connected` of the five states it writes: the panel with a live link to
      // the application, which is the one the section is describing. `waiting`
      // is the same panel saying nothing has arrived yet.
      made.plugin = encode(join(dir, 'connected.png'), 'plugin');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
}

// --- The desktop and the tablet ---------------------------------------------
//
// One script writes both, and they are picked up as a pair for the same reason:
// the tablet is a display of that desktop, drawing the frame it published, so a
// plate taken from a different run of the same script would be a picture of a
// different instant. Nothing here enforces that beyond taking them together and
// saying so.

for (const name of ['desktop', 'tablet']) {
  if (!wanted(name)) continue;
  const shot = join(REPO, `build/packaging/screenshots/${name}.png`);
  if (!existsSync(shot)) {
    skipped.push(
      `${name.padEnd(8)} — build/packaging/screenshots/${name}.png is not there.\n` +
        '             sh packaging/signal_path.sh\n' +
        '             (A release build, a simulator build, the fake DAW, Screen\n' +
        '              Recording, and both 47821 and 47822 free.)',
    );
  } else {
    made[name] = encode(shot, name);
  }
}

// --- What the page needs to know --------------------------------------------

/* The intrinsic sizes, written beside the pictures.
 *
 * The same arrangement as `src/data/analyzer-still.json` and for the same
 * reason: an `<img>` has to declare a width and a height for its box to have a
 * shape before anything is fetched, and a number typed into the markup is a
 * number that goes quietly wrong the first time a source is reshot. The page
 * reads this instead, so it can only name sizes this script actually wrote. */
const META = join(ROOT, 'src/data/flow-shots.json');
if (Object.keys(made).length > 0) {
  const existing = existsSync(META)
    ? JSON.parse(readFileSync(META, 'utf8'))
    : {};
  writeFileSync(META, `${JSON.stringify({ ...existing, ...made }, null, 2)}\n`);
  console.log(`  src/data/flow-shots.json  ${Object.keys(made).join(', ')}`);
}

if (skipped.length > 0) {
  console.log(`\nNot made on this machine:\n\n  ${skipped.join('\n  ')}\n`);
}
