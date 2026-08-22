// Builds the data the hero meter bridge plays back.
//
// This is the honest part of the website: the numbers on the front page are
// measurements, not an animation. A twenty-second stereo programme is
// synthesised here, then pushed through K-weighting, EBU R128 gating, an
// oversampled true-peak detector and an FFT, and the resulting timeline is
// what the canvas painters draw. Everything is deterministic — a seeded PRNG,
// no wall-clock, no input files — so `npm run measure` produces the same
// bridge.json on any machine and anybody can check the front page against the
// spec by reading this file.
//
// Where this differs from the shipping engine is stated rather than hidden:
// the engine designs the K-weighting filter from the analog prototype at the
// stream's own sample rate, because a hardcoded 48 kHz table is wrong on
// 44.1 kHz material. This script only ever runs at 48 kHz, which is the one
// rate the standard prints coefficients for, so the table is exact here.

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, '..', 'src', 'data', 'bridge.json');

const SR = 48000;
const DURATION = 20; // seconds
const FPS = 30; // published frame rate of the timeline
const HOP = SR / FPS; // 1600 samples
const FRAMES = DURATION * FPS;
const BANDS = 64; // log-spaced spectrum bands the web painter draws
const FFT_N = 2048;

// ---------------------------------------------------------------------------
// Deterministic noise. Reproducibility is the point of the whole file.
// ---------------------------------------------------------------------------

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(0x0aa1770);
const noise = () => rnd() * 2 - 1;

// ---------------------------------------------------------------------------
// The programme.
//
// A quiet intro, a verse, a build, a loud chorus and a decay — arranged so the
// front page shows a meter doing the thing meters are for. It is mastered
// deliberately hot: the chorus lands about 2.8 LU over the −14 LUFS streaming
// target and clips a true peak past −1 dBTP, so the validator on the front
// page returns a real failure. A demo that always passes teaches nothing.
// ---------------------------------------------------------------------------

const N = SR * DURATION;
const L = new Float64Array(N);
const R = new Float64Array(N);

const BPM = 120;
const BEAT = 60 / BPM; // 0.5 s
const BAR = BEAT * 4; // 2 s

// i – VI – III – VII in A minor, two seconds each.
const PROGRESSION = [
  { root: 110.0, third: 130.81, fifth: 164.81 }, // Am
  { root: 87.31, third: 110.0, fifth: 130.81 }, // F
  { root: 130.81, third: 164.81, fifth: 196.0 }, // C
  { root: 98.0, third: 123.47, fifth: 146.83 }, // G
];

/** Section gain envelope: intro, verse, build, chorus, outro. */
function arrangement(t) {
  if (t < 2) return { level: 0.18, drums: 0, lead: 0 };
  if (t < 8) return { level: 0.5, drums: 1, lead: 0 };
  if (t < 10) return { level: 0.5 + 0.5 * ((t - 8) / 2), drums: 1, lead: 0 };
  if (t < 16) return { level: 1.0, drums: 1, lead: 1 };
  const k = Math.max(0, 1 - (t - 16) / 4);
  return { level: 0.28 + 0.72 * k * k, drums: k > 0.35 ? 1 : 0, lead: 0 };
}

function addStereo(at, l, r) {
  if (at < 0 || at >= N) return;
  L[at] += l;
  R[at] += r;
}

// -- Percussion, rendered as one-shots at their hit positions ---------------

function kick(startSec, gain) {
  const start = Math.round(startSec * SR);
  const len = Math.round(0.3 * SR);
  let phase = 0;
  for (let n = 0; n < len; n++) {
    const t = n / SR;
    const f = 45 + 90 * Math.exp(-t * 42); // pitch drop into the fundamental
    phase += (2 * Math.PI * f) / SR;
    const env = Math.exp(-t * 9.5);
    const click = Math.exp(-t * 420) * 0.45 * noise();
    const s = (Math.sin(phase) * env + click) * gain;
    addStereo(start + n, s, s);
  }
}

function snare(startSec, gain) {
  const start = Math.round(startSec * SR);
  const len = Math.round(0.22 * SR);
  let lp = 0;
  let phase = 0;
  for (let n = 0; n < len; n++) {
    const t = n / SR;
    const env = Math.exp(-t * 24);
    lp += 0.42 * (noise() - lp); // shaped noise, not white
    phase += (2 * Math.PI * 185) / SR;
    const body = Math.sin(phase) * Math.exp(-t * 40) * 0.5;
    const s = (lp * 0.9 + body) * env * gain;
    // A snare sits centre but its room does not.
    addStereo(start + n, s * 1.0, s * 0.94);
  }
}

function hat(startSec, gain, open) {
  const start = Math.round(startSec * SR);
  const decay = open ? 0.16 : 0.035;
  const len = Math.round((decay * 4 + 0.01) * SR);
  let hp = 0;
  let prev = 0;
  for (let n = 0; n < len; n++) {
    const t = n / SR;
    const x = noise();
    hp = 0.86 * (hp + x - prev); // one-pole high pass
    prev = x;
    const env = Math.exp(-t / decay);
    const s = hp * env * gain;
    // Hats offset in the image; the phase scope in the app shows this.
    addStereo(start + n, s * 0.78, s * 1.0);
  }
}

// -- Sustained parts, rendered sample by sample ------------------------------

let bassPhase = 0;
let bassLp = 0;
const padPhase = [0, 0, 0, 0, 0, 0];
let leadPhase = 0;
let leadLp = 0;

/** Band-limited-ish saw: cheap, and its harmonics are what the FFT is for. */
function saw(phase) {
  return 2 * (phase / (2 * Math.PI) - Math.floor(phase / (2 * Math.PI) + 0.5));
}

for (let n = 0; n < N; n++) {
  const t = n / SR;
  const { level, lead } = arrangement(t);
  const chord = PROGRESSION[Math.floor(t / BAR) % PROGRESSION.length];

  // Bass — root, an octave down, low-passed hard.
  bassPhase += (2 * Math.PI * (chord.root / 2)) / SR;
  const bassEnv = 0.55 + 0.45 * Math.sin(2 * Math.PI * (t / BEAT) - Math.PI / 2) ** 2;
  bassLp += 0.045 * (saw(bassPhase) - bassLp);
  const bass = bassLp * bassEnv * 0.85 * level;

  // Pad — three notes, each detuned in opposite directions per channel, which
  // is what puts width on the phase scope without decorrelating the bass.
  let padL = 0;
  let padR = 0;
  const notes = [chord.root, chord.third, chord.fifth];
  for (let v = 0; v < 3; v++) {
    const det = 1 + (v - 1) * 0.0016;
    padPhase[v * 2] += (2 * Math.PI * notes[v] * 2 * det) / SR;
    padPhase[v * 2 + 1] += (2 * Math.PI * notes[v] * 2) / (SR * det);
    padL += saw(padPhase[v * 2]) * 0.09;
    padR += saw(padPhase[v * 2 + 1]) * 0.09;
  }
  const padOpen = 0.25 + 0.75 * Math.min(1, Math.max(0, (t - 2) / 8));
  padL *= level * padOpen;
  padR *= level * padOpen;

  // Lead — chorus only, an octave above the third.
  let leadS = 0;
  if (lead > 0) {
    leadPhase += (2 * Math.PI * chord.third * 4) / SR;
    leadLp += 0.28 * (saw(leadPhase) - leadLp);
    const gate = Math.exp(-((t / BEAT) % 1) * 3.2);
    leadS = leadLp * gate * 0.22 * lead;
  }

  L[n] += bass + padL + leadS * 0.92;
  R[n] += bass + padR + leadS;
}

// Drum grid.
for (let bar = 0; bar * BAR < DURATION; bar++) {
  const t0 = bar * BAR;
  const { drums, level } = arrangement(t0);
  if (!drums) continue;
  const g = 0.9 * level;
  kick(t0, g);
  kick(t0 + BEAT * 1.5, g * 0.82);
  kick(t0 + BEAT * 2, g * 0.95);
  snare(t0 + BEAT, g * 0.7);
  snare(t0 + BEAT * 3, g * 0.7);
  for (let h = 0; h < 8; h++) {
    hat(t0 + h * (BEAT / 2), g * (h % 2 ? 0.16 : 0.26), h === 7);
  }
}

// -- Mastering ---------------------------------------------------------------
// Drive into a soft clipper, then trim. The overshoot past −1 dBTP the
// validator reports comes from here, and it comes from inter-sample peaks the
// sample-peak meter cannot see — which is the entire reason true peak exists.

{
  let peak = 0;
  for (let n = 0; n < N; n++) peak = Math.max(peak, Math.abs(L[n]), Math.abs(R[n]));
  const norm = 0.72 / peak;
  for (let n = 0; n < N; n++) {
    const t = n / SR;
    const drive = 1 + 2.4 * arrangement(t).level;
    L[n] = Math.tanh(L[n] * norm * drive) * 0.985;
    R[n] = Math.tanh(R[n] * norm * drive) * 0.985;
  }
}

// ---------------------------------------------------------------------------
// K-weighting — ITU-R BS.1770-4. Stage 1 is the head-related high shelf,
// stage 2 the RLB high pass. Coefficients as printed for 48 kHz.
// ---------------------------------------------------------------------------

const STAGE1 = {
  b: [1.53512485958697, -2.69169618940638, 1.19839281085285],
  a: [1.0, -1.69065929318241, 0.73248077421585],
};
const STAGE2 = {
  b: [1.0, -2.0, 1.0],
  a: [1.0, -1.99004745483398, 0.99007225036621],
};

function biquad(x, { b, a }) {
  const y = new Float64Array(x.length);
  let x1 = 0;
  let x2 = 0;
  let y1 = 0;
  let y2 = 0;
  for (let n = 0; n < x.length; n++) {
    const x0 = x[n];
    const y0 = b[0] * x0 + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2;
    x2 = x1;
    x1 = x0;
    y2 = y1;
    y1 = y0;
    y[n] = y0;
  }
  return y;
}

const kL = biquad(biquad(L, STAGE1), STAGE2);
const kR = biquad(biquad(R, STAGE1), STAGE2);

/** Cumulative sum of squares, so any block's mean square is O(1) to read. */
function cumulativeSquares(x) {
  const c = new Float64Array(x.length + 1);
  for (let n = 0; n < x.length; n++) c[n + 1] = c[n] + x[n] * x[n];
  return c;
}
const cL = cumulativeSquares(kL);
const cR = cumulativeSquares(kR);

/** BS.1770-4 loudness of one window. G = 1.0 for L and R. */
function loudnessOf(from, to) {
  const len = to - from;
  if (len <= 0) return { lufs: -Infinity, z: 0 };
  const z = (cL[to] - cL[from]) / len + (cR[to] - cR[from]) / len;
  if (z <= 0) return { lufs: -Infinity, z: 0 };
  return { lufs: -0.691 + 10 * Math.log10(z), z };
}

// EBU R128 gating blocks: 400 ms at 75% overlap, so a 100 ms step.
const GATE_BLOCK = Math.round(0.4 * SR);
const GATE_STEP = Math.round(0.1 * SR);
const gateBlocks = [];
for (let start = 0; start + GATE_BLOCK <= N; start += GATE_STEP) {
  const { lufs, z } = loudnessOf(start, start + GATE_BLOCK);
  gateBlocks.push({ endSample: start + GATE_BLOCK, lufs, z });
}

/** Integrated loudness over every gating block that ended by `upTo`. */
function integratedUpTo(upTo) {
  const pool = [];
  for (const b of gateBlocks) {
    if (b.endSample > upTo) break;
    if (b.lufs > -70) pool.push(b); // absolute gate
  }
  if (!pool.length) return NaN;
  const meanZ = pool.reduce((s, b) => s + b.z, 0) / pool.length;
  const relative = -0.691 + 10 * Math.log10(meanZ) - 10; // relative gate, −10 LU
  const kept = pool.filter((b) => b.lufs > relative);
  if (!kept.length) return NaN;
  const z = kept.reduce((s, b) => s + b.z, 0) / kept.length;
  return -0.691 + 10 * Math.log10(z);
}

// LRA — EBU Tech 3342. 3 s windows, absolute gate −70, relative gate −20 LU,
// then the 10th to 95th percentile of what survives.
const LRA_BLOCK = Math.round(3 * SR);
const lraBlocks = [];
for (let start = 0; start + LRA_BLOCK <= N; start += GATE_STEP) {
  const { lufs, z } = loudnessOf(start, start + LRA_BLOCK);
  lraBlocks.push({ endSample: start + LRA_BLOCK, lufs, z });
}

function lraUpTo(upTo) {
  const pool = lraBlocks.filter((b) => b.endSample <= upTo && b.lufs > -70);
  if (pool.length < 6) return NaN;
  const meanZ = pool.reduce((s, b) => s + b.z, 0) / pool.length;
  const relative = -0.691 + 10 * Math.log10(meanZ) - 20;
  const kept = pool.filter((b) => b.lufs > relative).map((b) => b.lufs).sort((x, y) => x - y);
  if (kept.length < 2) return NaN;
  const at = (p) => kept[Math.min(kept.length - 1, Math.max(0, Math.round(p * (kept.length - 1))))];
  return at(0.95) - at(0.1);
}

// ---------------------------------------------------------------------------
// True peak — BS.1770-4 Annex 2 structure: 4× oversampling through a 48-tap
// polyphase FIR. The shipping engine uses the coefficient set the standard
// prints; this script designs the same shape as a Kaiser-windowed sinc, which
// is within a few hundredths of a dB and keeps the file self-contained.
// ---------------------------------------------------------------------------

const OS = 4;
const TAPS_PER_PHASE = 12;

function besselI0(x) {
  let sum = 1;
  let term = 1;
  for (let k = 1; k < 24; k++) {
    term *= (x / (2 * k)) ** 2;
    sum += term;
  }
  return sum;
}

function buildPolyphase() {
  const total = OS * TAPS_PER_PHASE;
  const beta = 8.6;
  const centre = (total - 1) / 2;
  const h = new Float64Array(total);
  for (let n = 0; n < total; n++) {
    const x = n - centre;
    const sinc = x === 0 ? 1 : Math.sin((Math.PI * x) / OS) / ((Math.PI * x) / OS);
    const r = (2 * n) / (total - 1) - 1;
    h[n] = sinc * (besselI0(beta * Math.sqrt(Math.max(0, 1 - r * r))) / besselI0(beta));
  }
  const phases = [];
  for (let p = 0; p < OS; p++) {
    const ph = new Float64Array(TAPS_PER_PHASE);
    let sum = 0;
    for (let k = 0; k < TAPS_PER_PHASE; k++) {
      ph[k] = h[k * OS + p];
      sum += ph[k];
    }
    for (let k = 0; k < TAPS_PER_PHASE; k++) ph[k] /= sum; // unity DC gain per phase
    phases.push(ph);
  }
  return phases;
}

const PHASES = buildPolyphase();

/** Highest reconstructed inter-sample magnitude in [from, to). */
function truePeak(x, from, to) {
  let peak = 0;
  const lo = Math.max(0, from - TAPS_PER_PHASE);
  for (let n = lo; n < to; n++) {
    for (let p = 0; p < OS; p++) {
      const ph = PHASES[p];
      let acc = 0;
      for (let k = 0; k < TAPS_PER_PHASE; k++) {
        const idx = n - k;
        if (idx >= 0) acc += ph[k] * x[idx];
      }
      const mag = Math.abs(acc);
      if (mag > peak && n >= from) peak = mag;
    }
  }
  return peak;
}

// ---------------------------------------------------------------------------
// Spectrum — 2048-point Hann, mapped onto log-spaced bands with peak-per-bin
// so a narrow peak survives the mapping instead of being averaged away.
// ---------------------------------------------------------------------------

const HANN = new Float64Array(FFT_N);
let hannSum = 0;
for (let n = 0; n < FFT_N; n++) {
  HANN[n] = 0.5 - 0.5 * Math.cos((2 * Math.PI * n) / FFT_N);
  hannSum += HANN[n];
}
// Window-compensated, so a full-scale sine on a bin centre reads 0.0 dBFS.
const FFT_SCALE = 2 / hannSum;

function fft(re, im) {
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

// Band edges, 20 Hz to 20 kHz, log-spaced.
const F_LO = 20;
const F_HI = 20000;
const bandEdge = (i) => F_LO * (F_HI / F_LO) ** (i / BANDS);

function spectrumAt(centre) {
  const re = new Float64Array(FFT_N);
  const im = new Float64Array(FFT_N);
  const start = Math.max(0, Math.min(N - FFT_N, centre - FFT_N / 2));
  for (let n = 0; n < FFT_N; n++) {
    re[n] = ((L[start + n] + R[start + n]) * 0.5) * HANN[n];
  }
  fft(re, im);

  const out = new Uint8Array(BANDS);
  const binHz = SR / FFT_N;
  for (let b = 0; b < BANDS; b++) {
    const f0 = bandEdge(b);
    const f1 = bandEdge(b + 1);
    let k0 = Math.round(f0 / binHz);
    let k1 = Math.round(f1 / binHz);
    if (k1 <= k0) k1 = k0 + 1; // a band narrower than one bin still reads one
    k0 = Math.max(1, k0);
    k1 = Math.min(FFT_N / 2, k1);
    let mag = 0;
    for (let k = k0; k < k1; k++) {
      const m = Math.hypot(re[k], im[k]) * FFT_SCALE; // peak-per-bin
      if (m > mag) mag = m;
    }
    const db = 20 * Math.log10(Math.max(mag, 1e-7));
    // −96 dBFS .. 0 dBFS packed into a byte.
    out[b] = Math.max(0, Math.min(255, Math.round(((db + 96) / 96) * 255)));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Walk the timeline.
// ---------------------------------------------------------------------------

const m = [];
const s = [];
const integ = [];
const lra = [];
const tp = [];
const tpmax = [];
const pkL = [];
const pkR = [];
const rmsL = [];
const rmsR = [];
const corr = [];
const crest = [];
const spectra = new Uint8Array(FRAMES * BANDS);

const MOMENTARY = Math.round(0.4 * SR);
const SHORT = Math.round(3 * SR);

const round1 = (v) => (Number.isFinite(v) ? Math.round(v * 10) / 10 : null);
const round2 = (v) => (Number.isFinite(v) ? Math.round(v * 100) / 100 : null);
const dbfs = (v) => (v > 0 ? 20 * Math.log10(v) : -Infinity);

let runningTp = 0;

for (let f = 0; f < FRAMES; f++) {
  const end = (f + 1) * HOP;

  // Momentary and short-term are undefined until their window has filled.
  // The em dash on the front page is this condition, not a loading state.
  m.push(end >= MOMENTARY ? round1(loudnessOf(end - MOMENTARY, end).lufs) : null);
  s.push(end >= SHORT ? round1(loudnessOf(end - SHORT, end).lufs) : null);
  integ.push(round1(integratedUpTo(end)));
  lra.push(round1(lraUpTo(end)));

  const tpFrame = Math.max(truePeak(L, end - HOP, end), truePeak(R, end - HOP, end));
  runningTp = Math.max(runningTp, tpFrame);
  tp.push(round2(dbfs(tpFrame)));
  tpmax.push(round2(dbfs(runningTp)));

  let peakL = 0;
  let peakR = 0;
  let sumL = 0;
  let sumR = 0;
  let sumLR = 0;
  for (let n = end - HOP; n < end; n++) {
    const a = L[n];
    const b = R[n];
    peakL = Math.max(peakL, Math.abs(a));
    peakR = Math.max(peakR, Math.abs(b));
    sumL += a * a;
    sumR += b * b;
    sumLR += a * b;
  }
  const rL = Math.sqrt(sumL / HOP);
  const rR = Math.sqrt(sumR / HOP);
  pkL.push(round2(dbfs(peakL)));
  pkR.push(round2(dbfs(peakR)));
  rmsL.push(round2(dbfs(rL)));
  rmsR.push(round2(dbfs(rR)));

  // Pearson over the frame. Zero is a legitimate reading, so it can never
  // double as "no data" — an undefined correlation is null and draws a dash.
  const denom = Math.sqrt(sumL * sumR);
  corr.push(denom > 1e-12 ? round2(sumLR / denom) : null);

  // Crest from this block's own peak and RMS, never from the held peak and
  // the smoothed RMS the meters draw — those settle at different rates and
  // their difference drifts on its own.
  const blockPeak = Math.max(peakL, peakR);
  const blockRms = Math.sqrt((sumL + sumR) / (2 * HOP));
  crest.push(blockRms > 0 ? round2(dbfs(blockPeak) - dbfs(blockRms)) : null);

  spectra.set(spectrumAt(end - HOP / 2), f * BANDS);
}

// Loudness distribution: how much of the programme sat at each loudness,
// over the same 400 ms gating blocks, in 0.5 LU bins.
const DIST_LO = -40;
const DIST_BINS = 120;
const dist = new Array(DIST_BINS).fill(0);
for (const b of gateBlocks) {
  if (!(b.lufs > -70)) continue;
  const idx = Math.floor((b.lufs - DIST_LO) / 0.5);
  if (idx >= 0 && idx < DIST_BINS) dist[idx]++;
}
const distMax = Math.max(1, ...dist);

// A 2048-sample stereo window from the loudest bar, for the painters that
// need the waveform itself — the oscilloscope, the phase scope, the stereo
// cloud. Int8, which is all a 120 px thumbnail can resolve.
const SCOPE_AT = Math.round(12.5 * SR);
const scope = new Int8Array(2048 * 2);
for (let n = 0; n < 2048; n++) {
  scope[n * 2] = Math.max(-127, Math.min(127, Math.round(L[SCOPE_AT + n] * 127)));
  scope[n * 2 + 1] = Math.max(-127, Math.min(127, Math.round(R[SCOPE_AT + n] * 127)));
}

const b64 = (arr) => Buffer.from(arr.buffer, arr.byteOffset, arr.byteLength).toString('base64');

const payload = {
  meta: {
    sampleRate: SR,
    channels: 2,
    duration: DURATION,
    fps: FPS,
    frames: FRAMES,
    bands: BANDS,
    fLo: F_LO,
    fHi: F_HI,
    fftSize: FFT_N,
    distLo: DIST_LO,
    distStep: 0.5,
    distMax,
  },
  target: {
    id: 'streaming-14',
    name: 'Streaming (−14 LUFS)',
    lufs: -14.0,
    tolerance: 0.5,
    truePeakMax: -1.0,
    lraMax: 20.0,
  },
  m,
  s,
  i: integ,
  lra,
  tp,
  tpmax,
  pkL,
  pkR,
  rmsL,
  rmsR,
  corr,
  crest,
  dist,
  spectra: b64(spectra),
  scope: b64(scope),
};

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, JSON.stringify(payload));

const final = FRAMES - 1;
const kb = (JSON.stringify(payload).length / 1024).toFixed(1);
console.log(`measured ${DURATION}s @ ${SR} Hz -> ${FRAMES} frames, ${kb} kB`);
console.log(`  integrated  ${integ[final]} LUFS   (target ${payload.target.lufs})`);
console.log(`  true peak   ${tpmax[final]} dBTP   (max ${payload.target.truePeakMax})`);
console.log(`  LRA         ${lra[final]} LU`);
console.log(`  M defined from frame ${m.findIndex((v) => v !== null)}, S from ${s.findIndex((v) => v !== null)}`);
