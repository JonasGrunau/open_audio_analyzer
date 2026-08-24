// Builds the live analyzer demo, and photographs it for the facade in front of it.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// `tools/analyzer-demo` is a Flutter web target that depends on `package:oaa` and
// runs a canvas of the real meter modules against a recording of the real engine
// measuring a real track — see scripts/record.mjs. The front page does not load
// it on arrival: it shows the still this script takes, and fetches the analyzer
// when a reader asks for it. See the note on the facade in src/pages/index.astro.
//
//     npm run analyzer                 # build the demo, then shoot the still
//     npm run analyzer -- --no-build
//     npm run analyzer -- --still-only
//
// Two outputs, treated differently on purpose:
//
//   - `public/analyzer/` is about 3 MB of compiled Flutter and is **git-ignored**.
//     `npm run deploy` builds it; `npm run build` on its own does not, so working
//     on the site needs no Flutter toolchain. The front page checks whether it is
//     there and simply does not offer the button when it is not, so a site built
//     without it is complete rather than broken.
//   - `public/analyzer-still.webp` is 40-odd kB and **is committed**, like
//     public/og.png and the module thumbnails, because the facade needs it on
//     every build.
//
// CanvasKit is not vendored here. Flutter fetches it from www.gstatic.com at
// runtime, which is the default and keeps 12 MB of WebAssembly out of the
// repository — at the cost of one third-party request, and only for readers who
// press the button. To self-host it instead, copy `canvaskit/` out of the build
// and set `canvasKitBaseUrl` in the bootstrap.

import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, rmSync, writeFileSync, statSync, existsSync } from 'node:fs';
import { execFileSync as run } from 'node:child_process';
import { join, resolve } from 'node:path';

import { browser, serve } from './lib/headless.mjs';
import { syncFonts } from './lib/fonts.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const REPO = resolve(ROOT, '..');
const DEMO = join(ROOT, 'tools/analyzer-demo');
const BUILT = join(DEMO, 'build/web');
const PUBLIC = join(ROOT, 'public/analyzer');
const STILL = join(ROOT, 'public/analyzer-still.webp');
/// The still's pixel size, written out so the page can size the facade from the
/// picture it actually has rather than from a number typed into the markup. The
/// capture is the viewport, which is not a size this script chooses.
const STILL_META = join(ROOT, 'src/data/analyzer-still.json');
const PORT = 4403;

/// The still is shot at the shape the facade reserves on the page, and at the
/// window size a reader would actually open the demo at — the canvas is 24x16
/// cells whatever the window, but how much room each module gets is not.
const W = 1280;
const H = 800;
/// Device pixels per CSS pixel, set on the page rather than applied to the
/// screenshot afterwards — see the note on DPR in scripts/render-modules.mjs
/// and `shoot` in scripts/lib/headless.mjs.
const DPR = 2;

/// The widths the still is published at, and why each one exists. The facade is
/// as wide as `.shell` allows, which is `min(100vw, 1440px)` less a gutter of
/// 32, 24 or 16 px depending on the width — so the picture is asked for at
/// anything from about 370 CSS px on a phone to 1376 on a wide desktop, and the
/// device pixel ratio multiplies all of it.
///
/// One 2560 px file served to every one of them was 124 kB arriving on a phone
/// to be drawn into a box a seventh of its width, and this is the element that
/// decides the page's Largest Contentful Paint.
///
///    768  a mid-range Android: 380 CSS px at a ratio of 1.75 wants 665
///   1024  a small phone at ratio 2.5 to 2.75
///   1440  a laptop at ratio 1, where the box is 1286–1376 px, and an iPhone
///         at ratio 3, which wants about 1074
///   1920  a laptop at ratio 1.5, and a tablet
///   2560  the full-width retina case, and the file the `src` attribute names
///
/// The largest keeps the bare name so that `<img src>` and anything else
/// pointing at `/analyzer-still.webp` still resolves.
const WIDTHS = [768, 1024, 1440, 1920, 2560];

/// Programme to play before freezing.
///
/// The histogram's axis is a minute wide at this size, and a trace that stops a
/// third of the way across reads as a demo caught mid-load rather than as a
/// measurement. Long enough to fill it, and far longer than the integrated
/// reading needs to settle.
const SECONDS = 72;

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);

// --- Build ------------------------------------------------------------------

/* The recording, and the audio it was measured from.
 *
 * They live in the demo's `web/` directory so that `flutter build web` copies
 * them into the build, and they are git-ignored because they are derived from a
 * track this repository does not carry. Checked here rather than left to fail in
 * a browser: without them the demo compiles, deploys, loads, and shows one line
 * of text where the canvas should be — which is a broken site that built
 * successfully, and nobody would look at the build log for it. */
const NEEDED = ['programme.oaaz', 'programme.m4a'];
const missing = NEEDED.filter((name) => !existsSync(join(DEMO, 'web', name)));
if (missing.length > 0) {
  console.error(
    `The demo has no programme to replay (missing ${missing.join(', ')}).\n\n` +
      `  Record it first:\n\n      npm run record\n\n` +
      `  That needs the CC BY track, which is not in this repository:\n\n` +
      `      cd .. && dart run tool/fetch_test_audio.dart\n`,
  );
  process.exit(1);
}

if (!flag('--no-build') && !flag('--still-only')) {
  syncFonts(REPO, DEMO);
  console.log('Building the analyzer demo…');
  try {
    execFileSync(
      'flutter',
      ['build', 'web', '--release', '--no-wasm-dry-run', '--base-href', '/analyzer/'],
      { cwd: DEMO, stdio: ['ignore', 'pipe', 'pipe'] },
    );
  } catch (error) {
    console.error(error.stdout?.toString() ?? '', error.stderr?.toString() ?? '');
    process.exit(1);
  }

  rmSync(PUBLIC, { recursive: true, force: true });
  mkdirSync(PUBLIC, { recursive: true });
  cpSync(BUILT, PUBLIC, { recursive: true });
  // Every CanvasKit variant Flutter can pick between, which is 41 MB and which
  // the browser fetches from gstatic anyway. See the note at the top.
  rmSync(join(PUBLIC, 'canvaskit'), { recursive: true, force: true });

  const bytes = execFileSync('du', ['-sk', PUBLIC]).toString().split('\t')[0];
  console.log(`  public/analyzer/  ${(Number(bytes) / 1024).toFixed(1)} MB (git-ignored)`);
}

if (!existsSync(BUILT)) {
  console.error(`The demo has not been built (${BUILT}). Run without --no-build.`);
  process.exit(1);
}

// --- The still --------------------------------------------------------------

// Served from the build directory rather than from public/, so `--still-only`
// works whether or not the copy has been made. The build has `--base-href
// /analyzer/`, so the server mounts it there.
const server = await serve(BUILT, PORT, '/analyzer/');
// Exactly the size of the still: the canvas fills its window, so a taller one
// would push the bottom row of modules outside the clip.
const chrome = await browser({ window: `${W},${H}` });

const png = STILL.replace(/\.webp$/, '.png');
try {
  writeFileSync(
    png,
    await chrome.shoot({
      url: `http://127.0.0.1:${PORT}/analyzer/index.html?seconds=${SECONDS}`,
      // The viewport, not the window: see the note on clipViewport.
      clipViewport: true,
      dpr: DPR,
    }),
  );
  execFileSync('cwebp', ['-quiet', '-q', '88', '-sharp_yuv', '-m', '6', png, '-o', STILL]);

  // `webpinfo -summary` prints "Width: N" and "Height: N".
  const info = run('webpinfo', ['-summary', STILL]).toString();
  const size = {
    width: Number(/Width:\s*(\d+)/.exec(info)?.[1]),
    height: Number(/Height:\s*(\d+)/.exec(info)?.[1]),
  };

  // The narrower variants, each resampled from the same capture rather than
  // from each other — `-resize W 0` keeps the aspect ratio, and going through
  // an intermediate would compress an already-compressed picture.
  const sources = [];
  for (const width of WIDTHS) {
    if (width >= size.width) continue;
    const file = STILL.replace(/\.webp$/, `-${width}.webp`);
    execFileSync('cwebp', [
      '-quiet', '-q', '88', '-sharp_yuv', '-m', '6',
      '-resize', String(width), '0',
      png, '-o', file,
    ]);
    sources.push({ width, file: `/analyzer-still-${width}.webp` });
  }
  sources.push({ width: size.width, file: '/analyzer-still.webp' });

  mkdirSync(join(ROOT, 'src/data'), { recursive: true });
  // `width`/`height` stay the intrinsic size of the largest, because that is
  // what the `<img>` attributes have to declare for the box to have a shape
  // before anything is fetched. `sources` is what the srcset is built from, so
  // the markup names no width this script did not actually write.
  writeFileSync(STILL_META, `${JSON.stringify({ ...size, sources }, null, 2)}\n`);
  for (const { file } of sources) {
    const path = join(ROOT, 'public', file.slice(1));
    console.log(`  public${file}  ${(statSync(path).size / 1024).toFixed(1)} kB (committed)`);
  }
} catch (error) {
  console.error(`  the still failed: ${error.message}`);
  await chrome.close();
  server.close();
  process.exit(1);
} finally {
  if (!flag('--keep-png')) rmSync(png, { force: true });
}

await chrome.close();
server.close();
