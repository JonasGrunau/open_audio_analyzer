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

import { createServer } from 'node:http';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, rmSync, statSync, existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { extname, join, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const RENDERER = join(ROOT, 'tools/module-renderer');
const SERVE = join(RENDERER, 'build/web');
const OUT = join(ROOT, 'public/modules');
const PORT = 4402;
const CDP_PORT = 9333;

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

/// The frame every module is photographed into, so the catalogue is a grid of
/// identically sized pictures rather than fourteen different shapes.
const FRAME_W = 360;
const FRAME_H = 236;

/// Device pixels per logical pixel.
///
/// **Three, not two.** At two the images came out at exactly 1:1 on a retina
/// display — 720 device pixels of picture in a 360 px slot at devicePixelRatio
/// 2 — which is no headroom at all: a slightly wider column, or a reader zoomed
/// in one notch, and the browser is upscaling. On hairlines and six-pixel
/// labels that reads as soft immediately.
const SCALE = 3;

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

// --- Serve ------------------------------------------------------------------

const TYPES = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const file = join(SERVE, path === '/' ? 'index.html' : path);
  if (!file.startsWith(SERVE)) return void res.writeHead(403).end();
  try {
    const body = readFileSync(file);
    res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((ok) => server.listen(PORT, '127.0.0.1', ok));

// --- Chrome, over the DevTools protocol -------------------------------------

const profile = await mkdtemp(join(tmpdir(), 'oaa-render-'));
const chrome = spawn(
  CHROME,
  [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    `--remote-debugging-port=${CDP_PORT}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    // Headless throttles animation in backgrounded pages, and every frame here
    // is one step of the programme.
    '--disable-backgrounding-occluded-windows',
    '--disable-renderer-backgrounding',
    '--window-size=900,700',
    'about:blank',
  ],
  { stdio: 'ignore' },
);

const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

async function browserSocketUrl() {
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`);
      return (await res.json()).webSocketDebuggerUrl;
    } catch {
      await sleep(100);
    }
  }
  throw new Error('Chrome never opened its debugging port.');
}

/// The smallest CDP client that does this job: one socket, numbered commands,
/// promises resolved by id. Node has had a WebSocket of its own since 22, so
/// this needs nothing from npm.
class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.next = 1;
    this.pending = new Map();
    socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      message.error ? entry.reject(new Error(message.error.message)) : entry.resolve(message.result);
    });
  }

  static async open(url) {
    const socket = new WebSocket(url);
    await new Promise((ok, fail) => {
      socket.addEventListener('open', ok, { once: true });
      socket.addEventListener('error', () => fail(new Error(`Cannot open ${url}`)), { once: true });
    });
    return new Cdp(socket);
  }

  send(method, params = {}, sessionId) {
    const id = this.next++;
    const message = { id, method, params };
    if (sessionId) message.sessionId = sessionId;
    this.socket.send(JSON.stringify(message));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  close() {
    this.socket.close();
  }
}

const cdp = await Cdp.open(await browserSocketUrl());

async function shoot(module) {
  const url =
    `http://127.0.0.1:${PORT}/index.html` +
    `?module=${module.id}&fw=${FRAME_W}&fh=${FRAME_H}` +
    (module.w ? `&w=${module.w}` : '') +
    (module.h ? `&h=${module.h}` : '') +
    (module.seconds ? `&seconds=${module.seconds}` : '') +
    (module.dt ? `&dt=${module.dt}` : '') +
    (module.options ? `&${module.options}` : '');

  // A fresh target per module: one page load, one module, nothing carried
  // between shots.
  const { targetId } = await cdp.send('Target.createTarget', { url });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

  try {
    const deadline = Date.now() + READY_TIMEOUT_MS;
    for (;;) {
      const { result } = await cdp.send(
        'Runtime.evaluate',
        { expression: 'globalThis.oaaRenderReady === true', returnByValue: true },
        sessionId,
      );
      if (result.value === true) break;
      if (Date.now() > deadline) {
        throw new Error(`timed out after ${READY_TIMEOUT_MS / 1000}s waiting for the final frame`);
      }
      await sleep(100);
    }

    const { data } = await cdp.send(
      'Page.captureScreenshot',
      {
        format: 'png',
        // The module is pinned to the top-left corner at exactly W x H, so the
        // clip is known rather than measured.
        clip: { x: 0, y: 0, width: FRAME_W, height: FRAME_H, scale: SCALE },
        captureBeyondViewport: true,
      },
      sessionId,
    );
    return Buffer.from(data, 'base64');
  } finally {
    await cdp.send('Target.closeTarget', { targetId });
  }
}

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
    // Lossy at a high quality, and -m 6 for the slowest, smallest search.
    //
    // Lossless was the obvious call for flat panels with hairlines on them, and
    // it cost 720 kB for the fourteen — the spectrogram and the stereo cloud are
    // fields of noise, which is the worst case there is for it. What actually
    // made the old thumbnails look soft was pixel density, not the encoder: they
    // landed at exactly 1:1 on a retina display. At 3x there is enough
    // resolution that q90 has nothing visible left to give away.
    execFileSync('cwebp', ['-quiet', '-q', '90', '-m', '6', png, '-o', webp]);
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

cdp.close();
server.close();

// Chrome writes to its profile as it shuts down, so removing the directory the
// instant after kill() races it and throws ENOTEMPTY. Wait for the process to
// actually go, then tidy up — and never fail the run over a temp directory.
const exited = new Promise((ok) => chrome.once('exit', ok));
chrome.kill();
await Promise.race([exited, sleep(5000)]);
try {
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
} catch {
  console.log(`  (left ${profile} behind)`);
}

console.log(
  `\n${wanted.length} module${wanted.length === 1 ? '' : 's'} → ${OUT}\n` +
    `${total.toFixed(1)} kB total, ${FRAME_W * SCALE}x${FRAME_H * SCALE} each, ` +
    `in ${((Date.now() - started) / 1000).toFixed(0)}s`,
);
if (failed) {
  console.error(`\n${failed} did not come out. Run with --keep-png and look at them.`);
  process.exit(1);
}
