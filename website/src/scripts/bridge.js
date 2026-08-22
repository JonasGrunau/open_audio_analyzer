/*
  One clock.

  The application drives all fourteen of its modules from a single MeterClock,
  because independent tickers drift and two meters showing the same quantity
  could then disagree inside one frame. On a measurement tool that is a
  correctness bug, not a cosmetic one. The same rule holds here: there is one
  requestAnimationFrame loop on this page, every surface reads the same frame
  index from it, and text is rewritten only when the formatted string actually
  changes — a value moves continuously, but the string rounded to one decimal
  changes about ten times a second, and laying out the other fifty is waste.
*/

import { decode, makeSurface, C } from './painters.js';

const raw = JSON.parse(document.getElementById('bridge-data').textContent);
const D = decode(raw);
const FPS = D.meta.fps;
const FRAMES = D.meta.frames;

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');

/* A frame the programme is loud and interesting, for anyone who has asked the
   browser not to animate things. Not the last frame — the outro is quiet, and
   a still of a decayed meter says less than a still of a working one. */
const STILL = Math.round(13.4 * FPS);

/* --- readouts ------------------------------------------------------------ */

const fmt = {
  lufs: (v) => (v === null ? '—' : v.toFixed(1)),
  db: (v) => (v === null ? '—' : v.toFixed(1)),
  lu: (v) => (v === null ? '—' : v.toFixed(1)),
  corr: (v) => (v === null ? '—' : (v >= 0 ? '+' : '') + v.toFixed(2)),
  time: (f) => {
    const t = f / FPS;
    return `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(Math.floor(t % 60)).padStart(2, '0')}`;
  },
};

const T = D.target;
const verdict = {
  i: (v) => (v === null ? null : Math.abs(v - T.lufs) <= T.tolerance),
  tpmax: (v) => (v === null ? null : v <= T.truePeakMax),
  lra: (v) => (v === null ? null : v <= T.lraMax),
};

const readouts = [...document.querySelectorAll('[data-readout]')].map((el) => ({
  el,
  key: el.dataset.readout,
  judge: el.dataset.judge === 'true',
  last: null,
}));

function paintReadouts(f) {
  for (const r of readouts) {
    let text;
    let v = null;
    switch (r.key) {
      case 'time':
        text = fmt.time(f);
        break;
      case 'i':
      case 'm':
      case 's':
        v = D[r.key][f];
        text = fmt.lufs(v);
        break;
      case 'lra':
        v = D.lra[f];
        text = fmt.lu(v);
        break;
      case 'tp':
      case 'tpmax':
        v = D[r.key][f];
        text = fmt.db(v);
        break;
      case 'corr':
        v = D.corr[f];
        text = fmt.corr(v);
        break;
      case 'crest':
        v = D.crest[f];
        text = fmt.db(v);
        break;
      default:
        continue;
    }
    // Only touch the DOM when the string has actually changed.
    if (text === r.last) continue;
    r.last = text;
    r.el.textContent = text;
    if (r.judge) {
      const pass = verdict[r.key] ? verdict[r.key](v) : null;
      r.el.style.color = v === null ? C.faint : pass ? C.signal : C.over;
    }
  }
}

/* --- surfaces ------------------------------------------------------------ */

const live = [...document.querySelectorAll('[data-meter]')].map((canvas) => ({
  canvas,
  name: canvas.dataset.meter,
  surface: makeSurface(canvas),
}));

for (const s of live) s.surface.size();

let dirty = true;
const ro = new ResizeObserver(() => {
  dirty = true;
});
for (const s of live) ro.observe(s.canvas);

/* --- the clock ----------------------------------------------------------- */

const statusEl = document.querySelector('[data-status]');
let running = false;
let origin = 0;
/* Milliseconds into the programme when the clock was last stopped. Scrolling
   past the bridge pauses it; coming back resumes it rather than restarting,
   because a meter you looked away from did not stop measuring. */
let elapsed = 0;
/* Deliberately not 0: the tick below draws only when the frame changes, and
   frame zero is a real frame that has to be drawn like any other. */
let frame = -1;

function drawAll(f) {
  for (const s of live) {
    if (dirty) s.surface.size();
    s.surface.draw(s.name, D, f);
  }
  dirty = false;
  paintReadouts(f);
}

function tick(now) {
  if (!running) return;
  if (!origin) origin = now - elapsed;
  elapsed = now - origin;
  const f = Math.floor((elapsed / 1000) * FPS) % FRAMES;
  // A wrap is a restart, exactly as ⌘R is: the integration starts again, and
  // the meters go back to a dash until each window has refilled.
  if (f !== frame) {
    frame = f;
    drawAll(f);
  }
  requestAnimationFrame(tick);
}

function start() {
  if (running || reduced.matches) return;
  running = true;
  origin = 0;
  if (statusEl) statusEl.dataset.state = 'measuring';
  requestAnimationFrame(tick);
}

function stop() {
  running = false;
  if (statusEl) statusEl.dataset.state = 'held';
}

function still() {
  frame = STILL;
  dirty = true;
  drawAll(STILL);
  if (statusEl) statusEl.dataset.state = 'paused';
}

/* Off screen, nothing needs measuring. A meter bridge in a background tab
   burning a core is the sort of thing that gets a page closed. */
const hero = document.querySelector('[data-bridge]');
if (hero) {
  new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          if (reduced.matches) still();
          else start();
        } else if (!reduced.matches) stop();
      }
    },
    { threshold: 0.02 },
  ).observe(hero);
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) stop();
  else if (hero && !reduced.matches) start();
});

reduced.addEventListener('change', () => {
  if (reduced.matches) {
    stop();
    still();
  } else start();
});

/* Paint frame zero before the clock starts, so the bridge is never a row of
   empty panels: the scales, the target lines and the dashes are all there to
   read, and the first three seconds of the timeline then fill them in. */
if (reduced.matches) still();
else drawAll(0);

/* --- the catalogue -------------------------------------------------------
   Nothing to do here any more. The fourteen thumbnails used to be these same
   painters drawn at one frame; they are now photographs of the real modules,
   taken from the running application by `npm run modules`. A hand-written
   approximation of a measurement display is the one thing this project should
   not ship — see scripts/render-modules.mjs.
   ------------------------------------------------------------------------ */
