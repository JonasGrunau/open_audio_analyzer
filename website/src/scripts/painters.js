/*
  The painters.

  Each one is a pure function of (context, size, measurements, frame). None of
  them owns a timer, none of them holds state that the driver cannot throw
  away, and none of them knows whether it is drawing the live bridge at the top
  of the page or a single still frame in the module catalogue below it. That is
  the same split the application makes — one clock, fourteen painters — and it
  is why a thumbnail and the hero cannot drift apart.
*/

export const C = {
  ink: '#0b0c0e',
  panel: '#121417',
  raised: '#171a1e',
  hair: '#1f2328',
  hairStrong: '#2a2f36',
  text: '#e6e8eb',
  muted: '#8a9199',
  faint: '#565e67',
  signal: '#35e0c4',
  signalDim: '#1d7a6b',
  warn: '#f2b01e',
  over: '#ff4d4d',
};

const LO = -40; // LUFS floor the loudness painters draw to
const HI = 0;

export function decode(payload) {
  const bin = (b64) => {
    const s = atob(b64);
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
  };
  const spectra = bin(payload.spectra);
  const scopeU = bin(payload.scope);
  return { ...payload, spectra, scope: new Int8Array(scopeU.buffer) };
}

/* --- shared helpers ------------------------------------------------------ */

const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const lerp = (a, b, t) => a + (b - a) * t;

/** LUFS to y, over the painter's own height. */
const lufsY = (v, h, pad = 0) => {
  const t = clamp((v - LO) / (HI - LO), 0, 1);
  return h - pad - t * (h - pad * 2);
};

/** dBFS to y over a stated floor. */
const dbY = (v, h, floor, pad = 0) => {
  const t = clamp((v - floor) / (0 - floor), 0, 1);
  return h - pad - t * (h - pad * 2);
};

function rule(g, x1, y1, x2, y2, colour) {
  g.strokeStyle = colour;
  g.lineWidth = 1;
  g.beginPath();
  g.moveTo(Math.round(x1) + 0.5, Math.round(y1) + 0.5);
  g.lineTo(Math.round(x2) + 0.5, Math.round(y2) + 0.5);
  g.stroke();
}

function tick(g, text, x, y, colour, align = 'left', size = 8) {
  g.fillStyle = colour;
  g.font = `${size}px "Google Sans Code", ui-monospace, monospace`;
  g.textAlign = align;
  g.textBaseline = 'middle';
  g.fillText(text, x, y);
}

/** A value that is not yet defined is a dash, never a zero. */
const has = (v) => v !== null && v !== undefined && Number.isFinite(v);

/** Spectrum byte back to dBFS. */
const bandDb = (b) => (b / 255) * 96 - 96;

/* --- a compact FFT, for the three painters that need the waveform -------- */

function fftMag(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang);
    const wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1;
      let ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur = re[i + k];
        const ui = im[i + k];
        const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr;
        im[i + k + len / 2] = ui - vi;
        const nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
}

/* --- painters ------------------------------------------------------------ */

/**
 * LUFS Meter — momentary and short-term as bars, integrated as a line.
 * The bar changes colour where it crosses the delivery target, because a
 * loudness bar that is one colour all the way up tells you nothing about
 * whether you have made the target.
 */
function lufs(g, w, h, D, f) {
  const pad = 10;
  const gutter = 26;
  const target = D.target.lufs;
  const trackTop = pad;
  const trackBot = h - pad;
  const inner = w - gutter - pad;
  // Capped, because a loudness bar as wide as it is tall stops reading as a
  // bar and starts reading as a filled panel.
  const barW = Math.min(28, Math.floor((inner - 8) / 2));

  for (const v of [0, -10, -14, -20, -30, -40]) {
    const y = lufsY(v, h, pad);
    rule(g, gutter, y, w - pad, y, v === target ? C.hairStrong : C.hair);
    tick(g, v === 0 ? '0' : String(v), gutter - 5, y, v === target ? C.muted : C.faint, 'right');
  }

  const bars = [
    { v: D.m[f], x: gutter },
    { v: D.s[f], x: gutter + barW + 8 },
  ];
  for (const b of bars) {
    g.fillStyle = C.raised;
    g.fillRect(b.x, trackTop, barW, trackBot - trackTop);
    if (!has(b.v)) continue;
    const y = lufsY(b.v, h, pad);
    const yTarget = lufsY(target, h, pad);
    g.fillStyle = C.signal;
    g.fillRect(b.x, Math.max(y, yTarget), barW, trackBot - Math.max(y, yTarget));
    if (y < yTarget) {
      // Above the delivery target: the same bar, in the colour that means over.
      g.fillStyle = C.warn;
      g.fillRect(b.x, y, barW, yTarget - y);
    }
  }

  if (has(D.i[f])) {
    const y = lufsY(D.i[f], h, pad);
    g.strokeStyle = C.text;
    g.lineWidth = 1;
    g.setLineDash([]);
    g.beginPath();
    g.moveTo(gutter, Math.round(y) + 0.5);
    g.lineTo(w - pad, Math.round(y) + 0.5);
    g.stroke();
  }

  tick(g, 'M', gutter + barW / 2, h - 3, C.faint, 'center', 8);
  tick(g, 'S', gutter + barW + 8 + barW / 2, h - 3, C.faint, 'center', 8);
}

/**
 * Super Meter — momentary, short-term and integrated as three concentric arcs.
 */
function superMeter(g, w, h, D, f) {
  const cx = w / 2;
  const cy = h * 0.58;
  const r0 = Math.min(w, h) * 0.5;
  const start = Math.PI * 0.75;
  const sweep = Math.PI * 1.5;
  const target = (clamp((D.target.lufs - LO) / (HI - LO), 0, 1));

  const rings = [
    { v: D.m[f], r: r0, wdt: Math.max(3, r0 * 0.11) },
    { v: D.s[f], r: r0 * 0.76, wdt: Math.max(3, r0 * 0.11) },
    { v: D.i[f], r: r0 * 0.52, wdt: Math.max(3, r0 * 0.11) },
  ];

  for (const ring of rings) {
    g.lineCap = 'butt';
    g.lineWidth = ring.wdt;
    g.strokeStyle = C.raised;
    g.beginPath();
    g.arc(cx, cy, ring.r, start, start + sweep);
    g.stroke();

    // The target, marked on every ring so the three are read against one line.
    g.strokeStyle = C.hairStrong;
    g.lineWidth = 1;
    const ta = start + sweep * target;
    g.beginPath();
    g.moveTo(cx + Math.cos(ta) * (ring.r - ring.wdt / 2 - 1), cy + Math.sin(ta) * (ring.r - ring.wdt / 2 - 1));
    g.lineTo(cx + Math.cos(ta) * (ring.r + ring.wdt / 2 + 1), cy + Math.sin(ta) * (ring.r + ring.wdt / 2 + 1));
    g.stroke();

    if (!has(ring.v)) continue;
    const t = clamp((ring.v - LO) / (HI - LO), 0, 1);
    g.lineWidth = ring.wdt;
    g.strokeStyle = C.signal;
    g.beginPath();
    g.arc(cx, cy, ring.r, start, start + sweep * Math.min(t, target));
    g.stroke();
    if (t > target) {
      g.strokeStyle = C.warn;
      g.beginPath();
      g.arc(cx, cy, ring.r, start + sweep * target, start + sweep * t);
      g.stroke();
    }
  }
}

/**
 * Spectrum Analyzer — level against frequency, log-spaced, with a peak hold
 * that never smooths. The drawn level is a one-pole average of the published
 * bands; the peak line above it is not.
 */
function spectrum(g, w, h, D, f, st) {
  const padL = 24;
  const padB = 13;
  const padT = 8;
  const n = D.meta.bands;
  const floor = -90;
  const plotW = w - padL - 6;
  const plotH = h - padT - padB;

  if (!st.avg) {
    st.avg = new Float32Array(n).fill(floor);
    st.hold = new Float32Array(n).fill(floor);
  }

  for (const db of [-20, -40, -60, -80]) {
    const y = padT + (1 - (db - floor) / (0 - floor)) * plotH;
    rule(g, padL, y, w - 6, y, C.hair);
    tick(g, String(db), padL - 5, y, C.faint, 'right');
  }
  const fLo = D.meta.fLo;
  const ratio = Math.log(D.meta.fHi / fLo);
  for (const [hz, lab] of [[100, '100'], [1000, '1k'], [10000, '10k']]) {
    const x = padL + (Math.log(hz / fLo) / ratio) * plotW;
    rule(g, x, padT, x, padT + plotH, C.hair);
    tick(g, lab, x, h - 5, C.faint, 'center');
  }

  const base = f * n;
  const pt = (i, v) => [padL + (i / (n - 1)) * plotW, padT + (1 - (v - floor) / (0 - floor)) * plotH];

  for (let i = 0; i < n; i++) {
    const db = Math.max(floor, bandDb(D.spectra[base + i]));
    st.avg[i] = st.avg[i] * 0.62 + db * 0.38;
    st.hold[i] = db > st.hold[i] ? db : st.hold[i] - 0.55;
    if (st.hold[i] < floor) st.hold[i] = floor;
  }

  g.beginPath();
  g.moveTo(padL, padT + plotH);
  for (let i = 0; i < n; i++) {
    const [x, y] = pt(i, st.avg[i]);
    g.lineTo(x, y);
  }
  g.lineTo(padL + plotW, padT + plotH);
  g.closePath();
  g.fillStyle = 'rgba(53, 224, 196, 0.14)';
  g.fill();

  g.beginPath();
  for (let i = 0; i < n; i++) {
    const [x, y] = pt(i, st.avg[i]);
    if (i === 0) g.moveTo(x, y);
    else g.lineTo(x, y);
  }
  g.strokeStyle = C.signal;
  g.lineWidth = 1.5;
  g.lineJoin = 'round';
  g.stroke();

  g.beginPath();
  for (let i = 0; i < n; i++) {
    const [x, y] = pt(i, st.hold[i]);
    if (i === 0) g.moveTo(x, y);
    else g.lineTo(x, y);
  }
  g.strokeStyle = C.faint;
  g.lineWidth = 1;
  g.stroke();
}

/**
 * Spectrogram — frequency against time, level as brightness. Kept as a
 * scrolled bitmap because the columns behind the newest one never change.
 */
function spectrogram(g, w, h, D, f, st) {
  const n = D.meta.bands;
  const ramp = (v) => {
    // ink -> dim signal -> signal -> warn. Five steps, so a level reads as a
    // step rather than as a shade nobody can name.
    const stops = [
      [11, 12, 14],
      [18, 58, 54],
      [29, 122, 107],
      [53, 224, 196],
      [242, 176, 30],
    ];
    const t = clamp(v, 0, 0.9999) * (stops.length - 1);
    const i = Math.floor(t);
    const k = t - i;
    const a = stops[i];
    const b = stops[Math.min(i + 1, stops.length - 1)];
    return `rgb(${lerp(a[0], b[0], k) | 0},${lerp(a[1], b[1], k) | 0},${lerp(a[2], b[2], k) | 0})`;
  };

  if (!st.buf || st.buf.width !== Math.round(w) || st.buf.height !== Math.round(h)) {
    st.buf = document.createElement('canvas');
    st.buf.width = Math.max(1, Math.round(w));
    st.buf.height = Math.max(1, Math.round(h));
    st.bg = st.buf.getContext('2d');
    st.bg.fillStyle = C.ink;
    st.bg.fillRect(0, 0, st.buf.width, st.buf.height);
    st.last = -1;
  }
  const bw = st.buf.width;
  const bh = st.buf.height;

  /** One column of bands at x, for the frame it belongs to. */
  const column = (x, frame) => {
    if (frame < 0) return;
    const base = frame * n;
    for (let i = 0; i < n; i++) {
      const db = bandDb(D.spectra[base + i]);
      const lvl = clamp((db + 78) / 78, 0, 1);
      const y0 = Math.floor((1 - (i + 1) / n) * bh);
      const y1 = Math.ceil((1 - i / n) * bh);
      st.bg.fillStyle = ramp(lvl);
      st.bg.fillRect(x, y0, 1, Math.max(1, y1 - y0));
    }
  };

  if (st.last === -1) {
    // A first paint has no history to scroll, and a spectrogram with one
    // column in it looks broken rather than new. Fill the whole width from
    // the frames that precede this one — which is what the display would be
    // showing if it had been running.
    for (let x = 0; x < bw; x++) column(x, f - (bw - 1 - x));
    st.last = f;
  } else if (f !== st.last) {
    if (f < st.last) {
      // The timeline wrapped: a restart clears the axis rather than splicing
      // the end of the programme onto its beginning.
      st.bg.fillStyle = C.ink;
      st.bg.fillRect(0, 0, bw, bh);
      for (let x = 0; x < bw; x++) column(x, f - (bw - 1 - x));
    } else {
      const steps = Math.min(f - st.last, 8);
      for (let sIdx = steps - 1; sIdx >= 0; sIdx--) {
        st.bg.globalCompositeOperation = 'copy';
        st.bg.drawImage(st.buf, -1, 0);
        st.bg.globalCompositeOperation = 'source-over';
        column(bw - 1, f - sIdx);
      }
    }
    st.last = f;
  }
  g.drawImage(st.buf, 0, 0, w, h);
}

/**
 * Histogram — loudness against time: how the programme moved, and when it was
 * over target. Kept as measurements rather than as pixels, so it survives a
 * resize with nothing lost.
 */
function histogram(g, w, h, D, f) {
  const pad = 8;
  const padL = 24;
  const total = D.meta.frames;
  const target = D.target.lufs;
  const x = (i) => padL + (i / (total - 1)) * (w - padL - pad);

  for (const v of [0, -14, -30]) {
    const y = lufsY(v, h, pad);
    rule(g, padL, y, w - pad, y, v === target ? C.hairStrong : C.hair);
    tick(g, String(v), padL - 5, y, C.faint, 'right');
  }

  const yTarget = lufsY(target, h, pad);
  const upTo = Math.min(f, total - 1);

  // Below target and above target are two fills, clipped against the target
  // line, so the eye reads the excursion rather than a single silhouette.
  for (const [colour, region] of [
    [C.signalDim, 'below'],
    [C.warn, 'above'],
  ]) {
    g.save();
    g.beginPath();
    if (region === 'below') g.rect(padL, yTarget, w - padL - pad, h - yTarget);
    else g.rect(padL, 0, w - padL - pad, yTarget);
    g.clip();
    g.beginPath();
    g.moveTo(x(0), h - pad);
    let started = false;
    for (let i = 0; i <= upTo; i++) {
      const v = D.s[i];
      if (!has(v)) continue;
      const px = x(i);
      const py = lufsY(v, h, pad);
      if (!started) {
        g.lineTo(px, h - pad);
        started = true;
      }
      g.lineTo(px, py);
    }
    if (started) {
      g.lineTo(x(upTo), h - pad);
      g.closePath();
      g.fillStyle = colour;
      g.fill();
    }
    g.restore();
  }

  g.beginPath();
  let started = false;
  for (let i = 0; i <= upTo; i++) {
    const v = D.s[i];
    if (!has(v)) continue;
    const px = x(i);
    const py = lufsY(v, h, pad);
    if (!started) {
      g.moveTo(px, py);
      started = true;
    } else g.lineTo(px, py);
  }
  if (started) {
    g.strokeStyle = C.signal;
    g.lineWidth = 1.25;
    g.stroke();
  }

  if (has(D.i[upTo])) {
    // Only as far as the playhead: an integrated loudness is a statement about
    // the programme so far, and drawing it across time nobody has measured yet
    // would be the one dishonest mark on the page.
    const y = lufsY(D.i[upTo], h, pad);
    g.strokeStyle = C.text;
    g.lineWidth = 1;
    g.setLineDash([2, 3]);
    g.beginPath();
    g.moveTo(padL, Math.round(y) + 0.5);
    g.lineTo(x(upTo), Math.round(y) + 0.5);
    g.stroke();
    g.setLineDash([]);
  }

  if (upTo < total - 1) rule(g, x(upTo), pad, x(upTo), h - pad, C.hairStrong);
}

/** Digital Meter — sample peak and RMS, per channel. */
function digital(g, w, h, D, f) {
  const pad = 8;
  const padB = 13;
  const floor = -60;
  const chans = [
    { pk: D.pkL[f], rms: D.rmsL[f], lab: 'L' },
    { pk: D.pkR[f], rms: D.rmsR[f], lab: 'R' },
  ];
  const barW = Math.min(26, Math.floor((w - pad * 2 - 6) / 2));
  const x0 = (w - (barW * 2 + 6)) / 2;

  chans.forEach((c, idx) => {
    const x = x0 + idx * (barW + 6);
    g.fillStyle = C.raised;
    g.fillRect(x, pad, barW, h - pad - padB);

    if (has(c.rms)) {
      const y = dbY(c.rms, h - padB + pad, floor, pad);
      g.fillStyle = C.signal;
      g.fillRect(x, y, barW, h - padB - y);
    }
    // Graduations, drawn over the fill. Without them a hot channel is a solid
    // block and there is no reading it against anything.
    for (const db of [-6, -12, -20, -30, -40]) {
      const y = dbY(db, h - padB + pad, floor, pad);
      g.fillStyle = 'rgba(11, 12, 14, 0.55)';
      g.fillRect(x, Math.round(y), barW, 1);
    }
    if (has(c.pk)) {
      const y = dbY(c.pk, h - padB + pad, floor, pad);
      g.fillStyle = c.pk >= -1 ? C.over : C.text;
      g.fillRect(x, Math.max(pad, y - 1), barW, 2);
    }
    tick(g, c.lab, x + barW / 2, h - 4, C.faint, 'center');
  });
}

/** VU Meter — a needle, on the movement the engine models. */
function vu(g, w, h, D, f) {
  const cx = w / 2;
  const cy = h * 0.95;
  const r = Math.min(w * 0.46, h * 0.8);
  const a0 = Math.PI * 1.18;
  const a1 = Math.PI * 1.82;

  g.strokeStyle = C.hairStrong;
  g.lineWidth = 1;
  g.beginPath();
  g.arc(cx, cy, r, a0, a1);
  g.stroke();

  for (let i = 0; i <= 8; i++) {
    const t = i / 8;
    const a = lerp(a0, a1, t);
    const over = t > 0.78;
    g.strokeStyle = over ? C.over : C.faint;
    g.lineWidth = 1;
    g.beginPath();
    g.moveTo(cx + Math.cos(a) * r, cy + Math.sin(a) * r);
    g.lineTo(cx + Math.cos(a) * (r - (i % 2 ? 3 : 6)), cy + Math.sin(a) * (r - (i % 2 ? 3 : 6)));
    g.stroke();
  }

  // The needle follows an averaging movement, not the sample peak.
  const v = has(D.rmsL[f]) ? (D.rmsL[f] + D.rmsR[f]) / 2 : -60;
  const t = clamp((v + 26) / 26, 0, 1);
  const a = lerp(a0, a1, t);
  g.strokeStyle = C.text;
  g.lineWidth = 1.5;
  g.beginPath();
  g.moveTo(cx, cy);
  g.lineTo(cx + Math.cos(a) * (r - 4), cy + Math.sin(a) * (r - 4));
  g.stroke();
  g.fillStyle = C.text;
  g.beginPath();
  g.arc(cx, cy, 2.5, 0, Math.PI * 2);
  g.fill();
}

/** Alert Meter — one measurement, watched, with the worst it has been latched. */
function alert(g, w, h, D, f) {
  const pad = 10;
  const floor = -24;
  const now = has(D.tp[f]) ? D.tp[f] : floor;
  const worst = has(D.tpmax[f]) ? D.tpmax[f] : floor;
  const limit = D.target.truePeakMax;
  const x = (v) => pad + clamp((v - floor) / (0 - floor), 0, 1) * (w - pad * 2);

  const trackY = h * 0.62;
  g.fillStyle = C.raised;
  g.fillRect(pad, trackY, w - pad * 2, 8);
  g.fillStyle = now > limit ? C.over : C.signal;
  g.fillRect(pad, trackY, x(now) - pad, 8);

  rule(g, x(limit), trackY - 4, x(limit), trackY + 12, C.hairStrong);
  // The latch: a clip that lasted three samples is still visible when you
  // look back at it.
  g.fillStyle = worst > limit ? C.over : C.text;
  g.fillRect(x(worst) - 1, trackY - 3, 2, 14);

  tick(g, `${worst.toFixed(1)}`, pad, h * 0.3, worst > limit ? C.over : C.text, 'left', 13);
  tick(g, 'dBTP MAX', pad, h * 0.88, C.faint, 'left', 8);
}

/** Loudness Distribution — how much of the programme sat at each loudness. */
function distribution(g, w, h, D) {
  const pad = 8;
  const bins = D.dist;
  const n = bins.length;
  const max = D.meta.distMax;
  const bw = (w - pad * 2) / n;
  const targetBin = (D.target.lufs - D.meta.distLo) / D.meta.distStep;

  for (let i = 0; i < n; i++) {
    if (!bins[i]) continue;
    const bh = (bins[i] / max) * (h - pad * 2);
    g.fillStyle = i > targetBin ? C.warn : C.signal;
    g.fillRect(pad + i * bw, h - pad - bh, Math.max(1, bw - 0.5), bh);
  }
  rule(g, pad + targetBin * bw, pad, pad + targetBin * bw, h - pad, C.hairStrong);
}

/** Oscilloscope — the waveform itself, one lane per channel. */
function oscilloscope(g, w, h, D) {
  const s = D.scope;
  const count = s.length / 2;
  const laneH = h / 2;
  for (let ch = 0; ch < 2; ch++) {
    const mid = laneH * ch + laneH / 2;
    rule(g, 0, mid, w, mid, C.hair);
    g.beginPath();
    for (let i = 0; i < count; i++) {
      const x = (i / (count - 1)) * w;
      const y = mid - (s[i * 2 + ch] / 127) * (laneH * 0.44);
      if (i === 0) g.moveTo(x, y);
      else g.lineTo(x, y);
    }
    g.strokeStyle = C.signal;
    g.lineWidth = 1;
    g.stroke();
  }
}

/** Phase Scope — left against right, rotated so mono stands upright. */
function phase(g, w, h, D) {
  const s = D.scope;
  const count = s.length / 2;
  const cx = w / 2;
  const cy = h / 2;
  const r = Math.min(w, h) * 0.44;

  g.strokeStyle = C.hair;
  g.lineWidth = 1;
  g.beginPath();
  g.moveTo(cx - r, cy - r);
  g.lineTo(cx + r, cy + r);
  g.moveTo(cx + r, cy - r);
  g.lineTo(cx - r, cy + r);
  g.stroke();

  g.fillStyle = C.signal;
  for (let i = 0; i < count; i++) {
    const l = s[i * 2] / 127;
    const rr = s[i * 2 + 1] / 127;
    // Rotate 45°: a mono signal becomes a vertical line.
    const x = cx + ((l - rr) / Math.SQRT2) * r;
    const y = cy - ((l + rr) / Math.SQRT2) * r;
    g.globalAlpha = 0.55;
    g.fillRect(x, y, 1, 1);
  }
  g.globalAlpha = 1;
}

/** Stereo Cloud — where each frequency sits in the stereo image. */
function cloud(g, w, h, D, _f, st) {
  if (!st.points) {
    const N = 1024;
    const s = D.scope;
    const reL = new Float64Array(N);
    const imL = new Float64Array(N);
    const reR = new Float64Array(N);
    const imR = new Float64Array(N);
    for (let i = 0; i < N; i++) {
      const win = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / N);
      reL[i] = (s[i * 2] / 127) * win;
      reR[i] = (s[i * 2 + 1] / 127) * win;
    }
    fftMag(reL, imL);
    fftMag(reR, imR);
    const pts = [];
    for (let k = 2; k < N / 2; k++) {
      const ml = Math.hypot(reL[k], imL[k]);
      const mr = Math.hypot(reR[k], imR[k]);
      const mag = ml + mr;
      if (mag < 1e-3) continue;
      const pan = (mr - ml) / mag; // −1 hard left, +1 hard right
      const hz = (k * 48000) / N;
      const fy = Math.log(clamp(hz, 20, 20000) / 20) / Math.log(1000);
      pts.push([pan, fy, clamp(20 * Math.log10(mag) / 40 + 1.2, 0.08, 1)]);
    }
    st.points = pts;
  }
  rule(g, w / 2, 0, w / 2, h, C.hair);
  for (const [pan, fy, lvl] of st.points) {
    const x = w / 2 + pan * (w * 0.46);
    const y = h - fy * h;
    g.globalAlpha = lvl;
    g.fillStyle = lvl > 0.72 ? C.warn : C.signal;
    g.fillRect(x - 1, y - 1, 2.5, 2.5);
  }
  g.globalAlpha = 1;
}

/** Number Box — any single measurement, as a number. */
function numberbox(g, w, h, D, f) {
  const v = D.i[f];
  const over = has(v) && v > D.target.lufs + D.target.tolerance;
  g.fillStyle = has(v) ? (over ? C.warn : C.text) : C.faint;
  const size = Math.min(h * 0.42, w * 0.3);
  g.font = `500 ${size}px "Google Sans Code", ui-monospace, monospace`;
  g.textAlign = 'center';
  g.textBaseline = 'alphabetic';
  g.fillText(has(v) ? v.toFixed(1) : '—', w / 2, h * 0.62);
  tick(g, 'LUFS INTEGRATED', w / 2, h * 0.82, C.faint, 'center', 8);
}

/** Validator — the delivery decision, as a table. */
function validator(g, w, h, D, f) {
  const rows = [
    { k: 'LUFS-I', v: D.i[f], ok: (x) => Math.abs(x - D.target.lufs) <= D.target.tolerance, fmt: (x) => x.toFixed(1) },
    { k: 'dBTP', v: D.tpmax[f], ok: (x) => x <= D.target.truePeakMax, fmt: (x) => x.toFixed(1) },
    { k: 'LRA', v: D.lra[f], ok: (x) => x <= D.target.lraMax, fmt: (x) => x.toFixed(1) },
  ];
  const rowH = h / (rows.length + 0.6);
  g.textBaseline = 'middle';
  rows.forEach((r, i) => {
    const y = rowH * (i + 0.8);
    tick(g, r.k, 8, y, C.muted, 'left', 9);
    const defined = has(r.v);
    const pass = defined && r.ok(r.v);
    g.fillStyle = !defined ? C.faint : pass ? C.signal : C.over;
    g.font = '500 11px "Google Sans Code", ui-monospace, monospace';
    g.textAlign = 'right';
    g.fillText(defined ? r.fmt(r.v) : '—', w - 22, y);
    g.fillText(!defined ? '' : pass ? '✓' : '✕', w - 6, y);
  });
}

export const PAINTERS = {
  numberbox,
  lufs,
  super: superMeter,
  digital,
  vu,
  alert,
  validator,
  histogram,
  distribution,
  spectrum,
  spectrogram,
  oscilloscope,
  phase,
  cloud,
};

/* --- mounting ------------------------------------------------------------
   One resize path and one clear path for every painter, so no painter has to
   think about device pixel ratio and none of them can get it differently.
   ------------------------------------------------------------------------ */

export function makeSurface(canvas) {
  const st = {};
  let w = 0;
  let h = 0;
  const g = canvas.getContext('2d', { alpha: false });

  function size() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const r = canvas.getBoundingClientRect();
    const nw = Math.max(1, Math.round(r.width));
    const nh = Math.max(1, Math.round(r.height));
    if (nw === w && nh === h && canvas.width === nw * dpr) return false;
    w = nw;
    h = nh;
    canvas.width = nw * dpr;
    canvas.height = nh * dpr;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    return true;
  }

  return {
    st,
    get w() {
      return w;
    },
    get h() {
      return h;
    },
    size,
    draw(name, D, f) {
      if (!w || !h) return;
      g.setTransform(Math.min(window.devicePixelRatio || 1, 2), 0, 0, Math.min(window.devicePixelRatio || 1, 2), 0, 0);
      g.fillStyle = C.panel;
      g.fillRect(0, 0, w, h);
      PAINTERS[name](g, w, h, D, f, st);
    },
  };
}
