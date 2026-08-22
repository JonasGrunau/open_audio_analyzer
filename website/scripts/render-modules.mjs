// Photographs the application's fourteen modules for the module catalogue.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The website used to draw its own approximations of these meters in
// JavaScript. That is the one thing this project should not ship: a picture of a
// meter that disagrees with the meter is worse than no picture, and two
// implementations of one display drift apart silently — which is the argument
// made on `MeterSource` in packages/oaa_core/lib/src/meter_source.dart, and the
// reason the application itself refuses to write its meters twice.
//
// So these are photographs of the real widgets. `tools/module-renderer` is a
// Flutter web target that depends on `package:oaa` and renders one module per
// page load against a mock MeterSource; this drives Chrome over the list.
//
//     npm run modules
//     npm run modules -- --no-build
//     npm run modules -- --only spectrogram,histogram
//     npm run modules -- --keep-png
//
// It talks to Chrome over the DevTools protocol rather than using
// `--headless --screenshot`, for two reasons that both showed up in practice:
//
//   - **It can wait for the picture instead of for a stopwatch.** The page sets
//     `globalThis.oaaRenderReady` when the programme has frozen and the final
//     frame is painted. `--virtual-time-budget` looked like the answer and is
//     not: it does not drive Flutter's ticker, so 8, 16 and 24 second budgets
//     all produced the same 56 frames and a spectrogram with no history in it.
//   - **It can clip exactly.** `Page.captureScreenshot` takes a rectangle and a
//     scale, so the module is captured at 2x with no cropping step and no
//     dependence on Chrome's 500 px minimum window width.
//
// Needs Flutter, Google Chrome and cwebp (brew install webp) on the machine
// doing it — which is why the output is committed, exactly as public/og.png is,
// rather than being regenerated in CI.

import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, statSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

import { browser, serve } from './lib/headless.mjs';
import { syncFonts } from './lib/fonts.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const REPO = resolve(ROOT, '..');
const RENDERER = join(ROOT, 'tools/module-renderer');
const SERVE = join(RENDERER, 'build/web');
const OUT = join(ROOT, 'public/modules');
const PORT = 4402;
const CDP_PORT = 9333;

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

/// The frame every module is photographed into, so the catalogue is a grid of
/// identically sized pictures rather than fourteen different shapes.
const FRAME_W = 390;
const FRAME_H = 256;

/// Device pixels per logical pixel.
///
/// **Two, and the frame sized to match where it lands.** More is not sharper
/// here, which took a while to see: at 4x these came out 1,440 px wide and the
/// browser resampled them down to the ~390 px the catalogue gives them, which
/// is a 3.5x downscale that averages three and a half source pixels into every
/// destination one. Hairlines and six-pixel labels do not survive that — the
/// pictures got *softer* the more resolution they were given.
///
/// A module drawn at FRAME_W logical pixels and captured at two device pixels
/// each lands 1:1 on a retina display at the size the grid actually gives it,
/// and the browser resamples nothing. Change the column count or the padding
/// and FRAME_W has to move with it.
const SCALE = 2;

/// Give up on a module rather than hanging the whole run.
const READY_TIMEOUT_MS = 90_000;

// The catalogue, in the order the page shows it.
//
// `id` is a ModuleKind id from packages/oaa_core/lib/src/layout.dart. `seconds`
// is how much programme to play first, and only the modules with a time axis
// need more than the default — a VU meter reads the same at four seconds as at
// forty, and waiting is the slow part of this script.
const MODULES = [
  // Every photograph is FRAME_W x FRAME_H. Most modules simply fill it: they are
  // resizable on the real canvas and this is a shape they are drawn well at.
  //
  // `w`/`h` override the size of the module *inside* the frame, and only the two
  // bar meters need it — stretched to 360 px, a pair of vertical bars becomes a
  // pair of squat slabs with nothing to read. They keep their own width and sit
  // centred, which is the whole reason there is a frame rather than a crop.
  { id: 'number_box', file: 'number-box' },
  { id: 'lufs_meter', file: 'lufs-meter', w: 190 },
  { id: 'super_meter', file: 'super-meter' },
  { id: 'digital_meter', file: 'digital-meter', w: 190 },
  { id: 'vu_meter', file: 'vu-meter' },
  { id: 'alert_meter', file: 'alert-meter' },
  { id: 'validator', file: 'validator' },
  { id: 'histogram', file: 'histogram', seconds: 32 },
  { id: 'distribution', file: 'loudness-distribution', seconds: 32 },
  { id: 'spectrum', file: 'spectrum-analyzer' },
  { id: 'spectrogram', file: 'spectrogram', seconds: 24, dt: 0.03 },
  // 1,024 stereo pairs is 21 ms at 48 kHz, so the default one-second base would
  // draw that sliver stretched across the whole width. 20 ms is the base this
  // much audio actually fills.
  { id: 'oscilloscope', file: 'oscilloscope', options: 'timeBase=20ms' },
  { id: 'phase_scope', file: 'phase-scope' },
  { id: 'stereo_cloud', file: 'stereo-cloud', seconds: 32 },
];

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const value = (name) => {
  const i = argv.indexOf(name);
  return i === -1 ? null : argv[i + 1];
};

const only = value('--only')?.split(',').map((s) => s.trim());
const wanted = only ? MODULES.filter((m) => only.includes(m.id)) : MODULES;
if (!wanted.length) {
  console.error(`No module matched --only. Known ids:\n  ${MODULES.map((m) => m.id).join('\n  ')}`);
  process.exit(1);
}

if (!existsSync(CHROME)) {
  console.error(`Missing ${CHROME}\n  Install Google Chrome, or edit CHROME in this file.`);
  process.exit(1);
}

// --- Build ------------------------------------------------------------------

if (!flag('--no-build')) {
  syncFonts(REPO, RENDERER);
  console.log('Building the renderer…');
  try {
    execFileSync('flutter', ['build', 'web', '--release', '--no-wasm-dry-run'], {
      cwd: RENDERER,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    console.error(error.stdout?.toString() ?? '', error.stderr?.toString() ?? '');
    process.exit(1);
  }
}
if (!existsSync(SERVE)) {
  console.error(`The renderer has not been built (${SERVE}). Run without --no-build.`);
  process.exit(1);
}

// --- Serve, and a browser to point at it ------------------------------------

const server = await serve(SERVE, PORT);
const chrome = await browser({ window: '900,700' });

function urlFor(module) {
  return (
    `http://127.0.0.1:${PORT}/index.html` +
    `?module=${module.id}&fw=${FRAME_W}&fh=${FRAME_H}` +
    (module.w ? `&w=${module.w}` : '') +
    (module.h ? `&h=${module.h}` : '') +
    (module.seconds ? `&seconds=${module.seconds}` : '') +
    (module.dt ? `&dt=${module.dt}` : '') +
    (module.options ? `&${module.options}` : '')
  );
}

/// The frame is pinned to the top-left corner at exactly this size, so the clip
/// is known rather than measured.
const shoot = (module) =>
  chrome.shoot({
    url: urlFor(module),
    clip: { x: 0, y: 0, width: FRAME_W, height: FRAME_H },
    scale: SCALE,
  });

// --- Shoot ------------------------------------------------------------------

mkdirSync(OUT, { recursive: true });

let failed = 0;
let total = 0;
const started = Date.now();

for (const module of wanted) {
  const png = join(OUT, `${module.file}.png`);
  const webp = join(OUT, `${module.file}.webp`);

  let size;
  try {
    writeFileSync(png, await shoot(module));
    // q95, and `-sharp_yuv` because these are coloured hairlines on a dark
    // ground: WebP's default chroma subsampling is what softens a teal 1 px
    // rule against near-black, and that flag is the fix for exactly that.
    //
    // Lossless is not worth it here — it costs 214 kB for the spectrogram alone,
    // which is a field of noise, against 78 for this. What made the first set
    // look soft was pixel density rather than the encoder: at 2x they landed at
    // exactly 1:1 on a retina display, with no headroom for a wider column or a
    // reader zoomed in one notch.
    execFileSync('cwebp', ['-quiet', '-q', '95', '-sharp_yuv', '-m', '6', png, '-o', webp]);
    size = Number((statSync(webp).size / 1024).toFixed(1));
  } catch (error) {
    console.log(`  ${module.file.padEnd(22)}  failed: ${error.message}`);
    failed++;
    continue;
  }

  total += size;
  // A module that refused to draw, or drew nothing, compresses to almost
  // nothing. Cheaper to catch here than by opening fourteen pictures.
  const suspect = size < 1.5;
  if (suspect) failed++;
  console.log(
    `  ${module.file.padEnd(22)} ${String(size).padStart(6)} kB` +
      (suspect ? '   <- suspiciously small, check it' : ''),
  );

  if (!flag('--keep-png')) rmSync(png);
}

await chrome.close();
server.close();

console.log(
  `\n${wanted.length} module${wanted.length === 1 ? '' : 's'} → ${OUT}\n` +
    `${total.toFixed(1)} kB total, ${FRAME_W * SCALE}x${FRAME_H * SCALE} each, ` +
    `in ${((Date.now() - started) / 1000).toFixed(0)}s`,
);
if (failed) {
  console.error(`\n${failed} did not come out. Run with --keep-png and look at them.`);
  process.exit(1);
}
