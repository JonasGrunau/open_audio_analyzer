// Serving a directory to a headless Chrome and photographing what it draws.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared by `render-modules.mjs`, which shoots one module at a time for the
// catalogue, and `render-analyzer.mjs`, which shoots the whole canvas for the
// front page. Both need the same three unobvious things, which is why this is a
// module rather than copied twice.
//
//   - **Wait for the picture, not for a stopwatch.** The pages set
//     `globalThis.oaaRenderReady` once the programme has run out and the
//     final frame is painted. `--virtual-time-budget` looks like the answer and
//     is not: it does not drive Flutter's ticker, so 8, 16 and 24 second budgets
//     all produced the same 56 frames and a spectrogram with no history in it.
//   - **Clip precisely.** `Page.captureScreenshot` takes a rectangle and a
//     scale, so there is no cropping step and no dependence on Chrome's refusal
//     to open a window narrower than 500 px.
//   - **Let Chrome shut down before deleting its profile.** It writes as it
//     exits, so removing the directory straight after kill() throws ENOTEMPTY.

import { createServer } from 'node:http';
import { gzipSync } from 'node:zlib';
import { spawn } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { extname, join } from 'node:path';

export const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

export const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

export function requireChrome() {
  if (!existsSync(CHROME)) {
    console.error(`Missing ${CHROME}\n  Install Google Chrome, or edit CHROME in scripts/lib/headless.mjs.`);
    process.exit(1);
  }
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.wasm': 'application/wasm',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  // `font/woff2` and not `application/octet-stream`: a font served as a generic
  // stream still renders, so the omission is invisible until something measures
  // it — `npm run audit` reads the response headers.
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.m4a': 'audio/mp4',
};

/// The cache policy, read from the `_headers` the deploy actually uses.
///
/// Not a second copy of it. A local server that serves `dist/` with no
/// `Cache-Control` reports every asset as uncacheable no matter what the deploy
/// does, so an audit run against it measures the harness rather than the site —
/// and a policy typed here as well would be one more pair of lists to keep in
/// step. `_headers` is the source; this parses it.
///
/// Absent, it returns nothing, which is exactly what the site served before
/// there was a `_headers` at all.
function headerRules(root) {
  const file = join(root, '_headers');
  if (!existsSync(file)) return [];
  const rules = [];
  let current = null;
  for (const raw of readFileSync(file, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('/')) {
      // A path pattern opens a section. `*` is the only wildcard Cloudflare's
      // syntax and this site's file use.
      const rx = new RegExp('^' + line.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
      current = { rx, headers: [] };
      rules.push(current);
      continue;
    }
    const at = line.indexOf(':');
    if (at > 0 && current) current.headers.push([line.slice(0, at).trim(), line.slice(at + 1).trim()]);
  }
  return rules;
}

/// Serve `root` on `port`. `mount` strips a leading path, so a build made with
/// `--base-href /analyzer/` can be served from the root of this server.
/// Which types are worth compressing. Everything else this site serves —
/// woff2, webp, png, wasm — is already a compressed container, and gzipping one
/// costs CPU to make it very slightly larger.
const COMPRESSIBLE = /^(text\/|application\/(json|xml|javascript))/;

export async function serve(root, port, mount = '/') {
  const rules = headerRules(root);
  const server = createServer((req, res) => {
    let path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (mount !== '/' && path.startsWith(mount)) path = path.slice(mount.length - 1);
    const file = join(root, path === '/' || path === '' ? 'index.html' : path);
    if (!file.startsWith(root)) return void res.writeHead(403).end();
    try {
      let body = readFileSync(file);
      const type = TYPES[extname(file)] ?? 'application/octet-stream';
      const headers = { 'content-type': type };
      // Later matches win, which is how Cloudflare resolves overlapping
      // sections and lets a specific path follow a broad one.
      for (const rule of rules) {
        if (!rule.rx.test(path)) continue;
        for (const [name, value] of rule.headers) headers[name] = value;
      }
      // Cloudflare compresses text at the edge, so a local server that does not
      // is measuring a page nobody is served. It matters here more than on most
      // sites: every stylesheet is inlined into the HTML, so the HTML *is* the
      // payload — 739 kB across the eleven pages raw and 215 kB gzipped, and
      // the changelog alone goes from 248 kB to 81 kB. gzip rather than brotli
      // because node has it built in and the difference between them is a few
      // per cent, against the 3.4x that compressing at all is worth.
      if (COMPRESSIBLE.test(type) && /\bgzip\b/.test(req.headers['accept-encoding'] ?? '')) {
        body = gzipSync(body);
        headers['content-encoding'] = 'gzip';
        headers.vary = 'Accept-Encoding';
      }
      res.writeHead(200, headers);
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  await new Promise((ok) => server.listen(port, '127.0.0.1', ok));
  return server;
}

/// The smallest DevTools client that does this job: one socket, numbered
/// commands, promises resolved by id. Node has had a WebSocket of its own since
/// 22, so this needs nothing from npm.
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
}

/// A headless browser, ready to be pointed at pages.
export async function browser({ port = 9333, window = '1600,1000' } = {}) {
  requireChrome();
  const profile = await mkdtemp(join(tmpdir(), 'oaa-render-'));
  const chrome = spawn(
    CHROME,
    [
      '--headless=new',
      '--disable-gpu',
      '--hide-scrollbars',
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profile}`,
      '--no-first-run',
      '--no-default-browser-check',
      // Headless throttles animation in backgrounded pages, and every frame is
      // one step of the programme.
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      `--window-size=${window}`,
      'about:blank',
    ],
    { stdio: 'ignore' },
  );

  let socketUrl;
  for (let i = 0; i < 100 && !socketUrl; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      socketUrl = (await res.json()).webSocketDebuggerUrl;
    } catch {
      await sleep(100);
    }
  }
  if (!socketUrl) throw new Error('Chrome never opened its debugging port.');
  const cdp = await Cdp.open(socketUrl);

  return {
    /// Load `url` in a fresh target, wait for `oaaRenderReady`, and return a PNG
    /// of `clip` at `dpr` device pixels per CSS pixel.
    ///
    /// `dpr` is the *page's* device pixel ratio, set before the page loads —
    /// not a scale applied to the screenshot afterwards, which is a different
    /// thing and was the bug that made every thumbnail soft. Flutter sizes its
    /// canvas backing store from `window.devicePixelRatio`: at 1 it rasterises
    /// a 390x256 module into 390x256 pixels, and asking `captureScreenshot` for
    /// `scale: 2` then resamples that raster up to 780x512. Every hairline and
    /// every six-pixel scale label goes through an upscale, which is why
    /// raising the scale to 3 and to 4 made the files larger and the pictures
    /// no sharper. Telling the page it is on a 2x display instead makes
    /// CanvasKit lay out at 390x256 and rasterise at 780x512, and the type is
    /// drawn at that size rather than blown up to it.
    ///
    /// `clip` omitted (or `clipViewport`) captures exactly the layout viewport,
    /// which is not the window size: headless Chrome reports a viewport some
    /// tens of pixels shorter, and clipping the window size instead pads the
    /// difference with white.
    async shoot({ url, clip, clipViewport = false, dpr = 2, timeoutMs = 120_000 }) {
      // Opened blank so the metrics override lands before anything is laid out.
      // A page that has already booted Flutter at ratio 1 does not re-rasterise
      // when the ratio changes under it — it scales what it has.
      const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
      const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
      try {
        await cdp.send(
          'Emulation.setDeviceMetricsOverride',
          // 0x0 keeps the window's own size and overrides only the ratio.
          { width: 0, height: 0, deviceScaleFactor: dpr, mobile: false },
          sessionId,
        );
        await cdp.send('Page.navigate', { url }, sessionId);
        const deadline = Date.now() + timeoutMs;
        for (;;) {
          const { result } = await cdp.send(
            'Runtime.evaluate',
            { expression: 'globalThis.oaaRenderReady === true', returnByValue: true },
            sessionId,
          );
          if (result.value === true) break;
          if (Date.now() > deadline) {
            throw new Error(`timed out after ${timeoutMs / 1000}s waiting for the final frame`);
          }
          await sleep(100);
        }
        let rect = clip;
        if (clipViewport || !rect) {
          const { result } = await cdp.send(
            'Runtime.evaluate',
            {
              expression: 'JSON.stringify([innerWidth, innerHeight])',
              returnByValue: true,
            },
            sessionId,
          );
          const [width, height] = JSON.parse(result.value);
          rect = { x: 0, y: 0, width, height };
        }
        // `scale: 1` — the pixels are already there. The clip is in CSS pixels
        // and the image comes back at `dpr` device pixels per one.
        const { data } = await cdp.send(
          'Page.captureScreenshot',
          { format: 'png', clip: { ...rect, scale: 1 }, captureBeyondViewport: true },
          sessionId,
        );
        return Buffer.from(data, 'base64');
      } finally {
        await cdp.send('Target.closeTarget', { targetId });
      }
    },

    /// Load a page at a chosen width and ask it a question about its own
    /// layout. Used by the overflow check — a page that scrolls sideways on a
    /// phone looks fine in every screenshot and wrong on every phone.
    async probe({ url, width, height, dpr = 2, timeoutMs = 30_000 }) {
      const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
      const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
      try {
        // `mobile: false`, and that is the whole of the check working or not.
        // Mobile emulation applies the viewport meta *and* Chrome's shrink to
        // fit: a document 128 px wider than the window is laid out at its own
        // width and scaled down to show all of it, so `innerWidth` comes back
        // as 518 on a 390 px phone and equals `scrollWidth` exactly. The
        // comparison below then reports a clean page for every page on the
        // site, which is what it did — the privacy policy pushed itself 128 px
        // sideways for four releases with this check green over it. A real
        // phone does not do that: `initial-scale=1` pins the scale and the page
        // scrolls. Desktop metrics at a chosen width are that layout, because
        // `width=device-width` resolves to the same number the override sets.
        await cdp.send(
          'Emulation.setDeviceMetricsOverride',
          { width, height, deviceScaleFactor: dpr, mobile: false },
          sessionId,
        );
        await cdp.send('Page.navigate', { url }, sessionId);

        const deadline = Date.now() + timeoutMs;
        for (;;) {
          const { result } = await cdp.send(
            'Runtime.evaluate',
            { expression: "document.readyState === 'complete'", returnByValue: true },
            sessionId,
          );
          if (result.value === true) break;
          if (Date.now() > deadline) throw new Error(`${url} never finished loading`);
          await sleep(100);
        }

        // The widest element is named as well as measured: "it overflows by
        // 40 px" sends somebody hunting, "the table in the install page does"
        // does not.
        const expression = `(() => {
          const root = document.documentElement;
          let widest = '', widestRight = 0;
          for (const el of document.body.querySelectorAll('*')) {
            const right = el.getBoundingClientRect().right;
            if (right > widestRight) {
              widestRight = right;
              widest = el.tagName.toLowerCase() +
                (el.className && typeof el.className === 'string'
                  ? '.' + el.className.trim().split(/\\s+/).join('.')
                  : '');
            }
          }
          return JSON.stringify({
            scrollWidth: root.scrollWidth,
            innerWidth: window.innerWidth,
            widest,
          });
        })()`;
        const { result } = await cdp.send(
          'Runtime.evaluate',
          { expression, returnByValue: true },
          sessionId,
        );
        return JSON.parse(result.value);
      } finally {
        await cdp.send('Target.closeTarget', { targetId });
      }
    },

    async close() {
      cdp.socket.close();
      const exited = new Promise((ok) => chrome.once('exit', ok));
      chrome.kill();
      await Promise.race([exited, sleep(5000)]);
      try {
        await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
      } catch {
        console.log(`  (left ${profile} behind)`);
      }
    },
  };
}
