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
//     `globalThis.oaaRenderReady` once the mock programme has frozen and the
//     final frame is painted. `--virtual-time-budget` looks like the answer and
//     is not: it does not drive Flutter's ticker, so 8, 16 and 24 second budgets
//     all produced the same 56 frames and a spectrogram with no history in it.
//   - **Clip precisely.** `Page.captureScreenshot` takes a rectangle and a
//     scale, so there is no cropping step and no dependence on Chrome's refusal
//     to open a window narrower than 500 px.
//   - **Let Chrome shut down before deleting its profile.** It writes as it
//     exits, so removing the directory straight after kill() throws ENOTEMPTY.

import { createServer } from 'node:http';
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
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
};

/// Serve `root` on `port`. `mount` strips a leading path, so a build made with
/// `--base-href /analyzer/` can be served from the root of this server.
export async function serve(root, port, mount = '/') {
  const server = createServer((req, res) => {
    let path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (mount !== '/' && path.startsWith(mount)) path = path.slice(mount.length - 1);
    const file = join(root, path === '/' || path === '' ? 'index.html' : path);
    if (!file.startsWith(root)) return void res.writeHead(403).end();
    try {
      const body = readFileSync(file);
      res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' });
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
    /// of `clip` at `scale` device pixels per logical pixel.
    /// `clip` omitted (or `clipViewport`) captures exactly the layout viewport,
    /// which is not the window size: headless Chrome reports a viewport some
    /// tens of pixels shorter, and clipping the window size instead pads the
    /// difference with white.
    async shoot({ url, clip, clipViewport = false, scale = 3, timeoutMs = 120_000 }) {
      const { targetId } = await cdp.send('Target.createTarget', { url });
      const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
      try {
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
        const { data } = await cdp.send(
          'Page.captureScreenshot',
          { format: 'png', clip: { ...rect, scale }, captureBeyondViewport: true },
          sessionId,
        );
        return Buffer.from(data, 'base64');
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
