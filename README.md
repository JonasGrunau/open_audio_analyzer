<div align="center">

<img src="assets/brand/oaa-icon.png" alt="Open Audio Analyzer" width="128" height="128">

<h1>Open Audio Analyzer</h1>

<p><strong>A free and open-source loudness and spectrum analyzer, for desktop and tablets.</strong></p>

<h3><a href="https://open-audio-analyzer.com">🌐&nbsp; open-audio-analyzer.com</a></h3>

<p><sub>Real meters running in your browser, what each module looks like, and where to download it.</sub></p>

<p>
  <a href="https://github.com/JonasGrunau/open_audio_analyzer/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/JonasGrunau/open_audio_analyzer/ci.yml?branch=main&label=CI&style=flat-square"></a>
  <a href="https://open-audio-analyzer.com/docs"><img alt="Documentation" src="https://img.shields.io/badge/%F0%9F%93%96_docs-open%20audio%20analyzer-1F2328?style=flat-square"></a>
  <a href="#-the-correctness-gate"><img alt="EBU R128 verified in CI" src="https://img.shields.io/badge/EBU_R128-verified_in_CI-1F2328?style=flat-square"></a>
</p>

<p>
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20iPadOS%20%7C%20Android-1F2328?style=flat-square">
  <a href="#-licensing"><img alt="Licence" src="https://img.shields.io/badge/licence-GPL--3.0--or--later-1F2328?style=flat-square"></a>
</p>

<p>
  <a href="https://open-audio-analyzer.com/docs"><strong>Documentation</strong></a>
  ·
  <a href="https://github.com/JonasGrunau/open_audio_analyzer/releases">Download</a>
  ·
  <a href="https://open-audio-analyzer.com/docs/keyboard">Keyboard</a>
  ·
  <a href="https://open-audio-analyzer.com/docs/metrics">Metrics</a>
  ·
  <a href="https://open-audio-analyzer.com/docs/odr">Open Dynamic Range</a>
  ·
  <a href="#-known-gaps-stated-plainly">Known gaps</a>
</p>

</div>

Open Audio Analyzer is a modular metering suite: a canvas of resizable meter
modules — loudness, true peak, VU, spectrum, spectrogram, phase scope, histogram
— organised into tabs, driven by presets, delivery targets and skins, with
offline file analysis and a companion display that mirrors a tab to a tablet
over Wi-Fi.

It is a free reimplementation of the ideas in
[Decibel](https://process.audio/products/decibel) by Process.Audio, whose
modular canvas is the best interaction model anybody has found for this problem.
The measurement work, the architecture and the visual language are our own, and
where Open Audio Analyzer cannot honestly match Decibel it says so rather than
approximating. The
[side-by-side](https://open-audio-analyzer.com/alternatives/decibel) is on the
website: what the two share, the four differences there is published evidence
for, and [Known gaps](#-known-gaps-stated-plainly) unsoftened.

---

## 📑 Contents

1. [Status](#-status)
2. [The fourteen modules](#-the-fourteen-modules)
3. [Why it is built this way](#-why-it-is-built-this-way)
   - [The per-frame path](#-the-per-frame-path)
   - [Rendering, per module](#-rendering-per-module)
4. [Measurement](#-measurement)
   - [Open Dynamic Range](#-open-dynamic-range)
   - [The correctness gate](#-the-correctness-gate)
5. [Layout](#-layout)
   - [Keyboard](#-keyboard)
   - [Presets, targets and skins](#-presets-targets-and-skins)
6. [Configuration](#-configuration)
   - [Skins](#-skins)
7. [Design](#-design)
8. [Repository layout](#-repository-layout)
   - [Licensing](#-licensing)
9. [Installing](#-installing)
10. [Building](#-building)
    - [Tests](#-tests)
11. [Analysing files](#-analysing-files)
12. [In a DAW](#-in-a-daw)
    - [Building and installing it by hand](#-building-and-installing-it-by-hand)
    - [What the DAW adds that a live input cannot](#-what-the-daw-adds-that-a-live-input-cannot)
    - [Testing the plugin without a DAW](#-testing-the-plugin-without-a-daw)
13. [Known gaps, stated plainly](#-known-gaps-stated-plainly)
14. [Contributing](#-contributing)
15. [License](#-license)

---

## ✅ Status

What ships today:

- **All fourteen modules measure something.** The app opens on a working meter
  bridge — loudness, super, digital, VU, validator, histogram, alert — with the
  analyser, oscilloscope, spectrogram, phase scope and stereo cloud on a second
  tab.
- **The canvas is arrangeable**: add, move, resize, duplicate, delete, tabs,
  undo.
- **Loudness and true peak are verified** against the EBU Tech 3341/3342 cases,
  and the spectrum against a sine of known amplitude, on Linux, macOS and
  Windows on every push.
- **What you set up is remembered** — layout, delivery target, skin and capture
  device — as plain JSON in a documented directory. See
  [Configuration](#-configuration).
- **Files are analysed offline** by the app and by the
  [`oaa` CLI](#-analysing-files).
- **A tablet mirrors the canvas** over Wi-Fi. Flip **PUBLISH** in the menu bar;
  the tablet finds it by itself, reads a pairing code off the screen, or takes
  an address typed by hand. Three routes, because the first one is what a
  venue's Wi-Fi blocks.
- **A headless [VST3 / AU / AAX plugin](#-in-a-daw)** meters what your DAW is
  playing.
- **Your system's own output is metered with nothing to install** — WASAPI
  loopback on Windows, a Core Audio process tap on macOS 14.2+, a monitor source
  on Linux. No driver, and on macOS the audio still reaches your speakers while
  it is measured.
- **The installers carry the plugin**, behind a checkbox that starts ticked: a
  macOS pkg, a Windows installer and a Linux tarball, plus an AppImage and a
  flatpak for the app alone. See [Installing](#-installing).
- **What is *not* built** is under
  [Known gaps](#-known-gaps-stated-plainly), and the list is honest rather than
  short.

---

## 📊 The fourteen modules

Every one of them is [`ModuleFrame`](packages/oaa_ui/lib/src/module_frame.dart)
plus a painter, reads the same `MeterSource`, and repaints from the same clock.
A module that also owned its border and title treatment would drift from the
other thirteen.

| Module | What it shows |
|---|---|
| **Number Box** | Any single measurement, as a number. |
| **LUFS Meter** | Momentary, short-term and integrated loudness as three bars against a target band, each with its value printed beneath. |
| **Super Meter** | One half-gauge: short-term and integrated loudness filling from the left, ODR-S and ODR-I continuing from each loudness tip to the true peak, so the dark rest of a ring is its true-peak headroom. Names ride the outer tips, and the centre stacks the short-term pair above the delivered three — LUFS-I, ODR-I and true peak — each of the five with its unit beside it. |
| **Digital Meter** | Sample peak and RMS, per channel, up to 7.1 — as segmented bars and as numbers. |
| **VU Meter** | A needle, on the movement the engine models. |
| **Alert Meter** | One measurement, watched, printed as **the worst it has been**. That one number is the module — the live value is a Number Box's job — and the panel's own light is that same verdict at a hundred times the area: a wash off the left edge in the latched state's colour, held until the engine is reset and dark until something has been measured. `Metric` picks what it watches; any of the fourteen works. A quantity the engine already accumulates over the programme — LUFS-I, LRA, TP Max, Peak Max, ODR-I — is **read rather than latched**: the engine is doing the holding, and the extremum of a converging estimator is a property of how it converged rather than of the audio. `Delta` prints that worst case as its signed distance from the line the target draws instead of as itself — `+0.6 dB` rather than `−0.4 dBTP` against a −1.0 ceiling, in the unit of the *difference* — and is offered only where the active target actually draws that line: loudness, true peak and LRA always, the two ODR floors only under a target that states them, because a distance from a floor nobody stated is a number nobody measured. |
| **Validator** | The delivery decision, as a table. `Checks` picks which criteria this one judges — LUFS-I, true peak, LRA and each dynamics floor the target sets — ticked in a menu that stays open, because choosing four of five through a menu that closes on every tap is four trips through it. A criterion switched off leaves the verdict as well as the table; a module with nothing left to check says so rather than passing. |
| **Histogram** | Loudness against time: how the programme moved, and when it was over target. Both bands averaged over a window its menu names, and the whole recording in an overview strip along the floor — which is also the control: drag the frame on it to scroll back through the programme, scroll, pinch or wheel over it to change how much of the programme the plot shows. The time axis is elapsed time, so a scrolled plot still says where you are. |
| **Loudness Distribution** | How much of the programme was spent at each loudness, bracketed between the two percentiles LRA is the distance between. The axis fits the programme, so a distribution occupying eight decibels is drawn across the module instead of into a fifth of it; `Scale` gives the whole −60 to 0 range back. |
| **Spectrum Analyzer** | Level against frequency, log-spaced, tilted so a mix reads roughly flat, with a peak hold. `Source` picks which signal the bands are measured on: all channels, or the front pair's left, right, mid or side. `Range` sets how far below full scale the axis reaches — 60, 90 or 120 dB, 90 by default. Click or tap the plot for a **cursor**: a line at that frequency with a tag reading the frequency, the level there, its peak hold and the level A-weighted — dB(A), the IEC 61672-1 curve at the band's centre. Drag it to move it; tap the line, or click anywhere away from the module, to dismiss it. The tag prints the *measured* level, untilted, which under a tilt is not where the curve is drawn. |
| **Spectrogram** | Frequency against time, level as colour. `Source` is the analyser's, and changing it clears the record. `Colour` picks the ramp: the skin's own, its ground rising through the accent into the warning colour, or `Full RGB`, the spectrogram rainbow, which separates far more steps of level than two hues can. |
| **Oscilloscope** | The waveform, one lane per channel or both overlaid: triggered at scope speeds, rolling from half a second up, locked to the DAW's bar grid when a plugin is attached, or swept from a transient. Height and threshold are sliders on the module, because both are chosen by watching the picture move; `AUTO` takes the threshold six decibels under the loudest transient, so the sweep starts inside the attack rather than on top of it. Overlaid, the `L R` legend beside them is a control too: clicking it swaps which channel is drawn in front of the other. `Colour: Full RGB` draws each column in its own balance of bass, mids and highs, so a kick is red, a hat is blue and a full-spectrum hit is white. |
| **Phase Scope** | A goniometer: left against right, rotated so mono stands upright, `L`, `R` and `M` engraved at the axis ends, with balance and correlation riding the frame's edges as markers — correlation in the warning colour below zero. Needs two channels; on a mono source it says **MONO SOURCE** rather than drawing the straight line one produces. |
| **Stereo Cloud** | Where each frequency sits in the stereo image over the last two seconds: one mark per band per frame, brighter and larger the louder, fading with age, placed at the pan pot's angle. |

Every module that draws against the delivery target splits its bar, arc or area
at the target and draws the part above in `over`. The split is a clip rather
than a verdict on the whole shape: what carries the meaning is how much of the
reading is over.

---

## ⚡ Why it is built this way

Everything below follows from one rule, because a meter that stutters is not a
meter:

> [!IMPORTANT]
> **Measurements never cross an isolate boundary, never allocate per frame, and
> never rebuild a widget.**

| Tier | Thread | Job |
|---|---|---|
| **Capture** | audio callback, realtime-safe | Copy input into a lock-free ring. No malloc, no locks, no syscalls. |
| **Analysis** | dedicated, high priority | Run the DSP graph. Publish results into a seqlock-protected snapshot. |
| **Display** | Flutter UI thread | One FFI call per frame, then paint. |

### ⏩ The per-frame path

Once per frame, [`MeterClock`](lib/src/clock/meter_clock.dart) makes a single
`@Native(isLeaf: true)` call to `oaa_snapshot_acquire` — an atomic load, a
memcpy, and a second atomic load, with no VM state transition. Painters then
read `Float32List` views built once at startup over native memory that never
moves, and are constructed with `CustomPainter(repaint: clock)`, which re-rasters
them *without rebuilding the widget*. A frame costs one FFI call plus N `paint()`
calls, and allocates nothing.

Four consequences worth naming, because they are what usually goes wrong:

- **One clock, not fourteen.** Independent tickers drift, and two meters showing
  the same quantity could then disagree within a single frame. On a measurement
  tool that is a correctness bug, not a cosmetic one.
- **Measurements are consumed at the rate they are published; pixels are drawn
  at the rate you asked for.** Dropping to 30 fps halves the rasterising and
  changes nothing about what the meters have seen. The engine's snapshot has one
  slot, so a measurement nobody reads in time is gone, and a display whose axis
  is time would have holes rather than a coarser picture.
- **Text is cached by formatted string.** A value changes continuously; the
  string rounded to one decimal changes about ten times a second, so
  [`ReadoutPainter`](packages/oaa_ui/lib/src/readout.dart) lays out a
  `ui.Paragraph` only when the string actually differs.
- **The reader retries, never the writer.** A seqlock is wait-free for the
  analysis thread. A mutex would let a descheduled UI thread stall the thread
  that must never stall, and when that thread falls behind the ring overruns and
  signal is lost for good.

### 🖌️ Rendering, per module

| Module | Technique |
|---|---|
| Number box, LUFS, Alert, Validator | Cached `ui.Paragraph`, rebuilt on string change only |
| Digital meter | Batched `drawRect` under one cached gradient shader; the segment gaps are one `drawRawPoints` from a buffer rebuilt only on resize |
| VU meter | The whole face redrawn each frame — a handful of `drawArc`s and `drawLine`s, cheaper than caching it and keeping it in step with a resize. The needle is one `Path`, reset and refilled; the scale labels are cached paragraphs, each placed where it clears the boxes already placed |
| Spectrum analyzer | `drawRawPoints` over the native `Float32List` — C writes screen-space x,y directly. The drawn level is a one-pole average at the time constant `Response` names, plus the offset `Tilt` names; the line above it is that curve's envelope on the same pole. The cursor reads those two buffers at one band and repaints from its own notifier, because the clock fires only on a new frame and a cursor placed on a stopped signal still has to appear |
| Phase scope | The last forty frames of samples in a ring, each drawn as one `drawRawPoints` of 1.4 px dots at its age's brightness, the dimmest from an eighth of their samples. The trail is the frames, not a faded picture |
| Stereo cloud | A ring of the last 96 frames' hits — band, position, weight — re-emitted every published frame as square-capped points under a 45° rotation, which draws them as diamonds, sorted into brightness buckets whose paints also size them |
| Spectrogram | One byte of palette step per cell as the record, plus an RGBA buffer shifted a column per published frame and uploaded as a pixel-backed `ui.Image` for a single `drawImageRect`. Bounded by the module's area, whatever the signal does. A skin or `Colour` change re-renders the buffer from the record, moving no cell |
| Histogram | Twenty columns a second into a fixed ring of loudness values, redrawn whole as a handful of `drawRawPoints` — the momentary band bucketed by how far over target each column stands. Kept as measurements rather than pixels, so it survives a resize and so the plot's window over it is an index rather than a scroll offset in pixels; raw, with `Smoothing` applied on the way out, so the setting redraws the whole programme. A pixel covering several columns takes their mean for short-term and their loudest for momentary |
| Loudness distribution | The engine's 120 bins as one-pixel columns that tile exactly, over an axis fitted to every occupied bin, the gated range and the target, rounded to whole ticks and left alone until the distribution outgrows it, so the scale never slides while it is being read. One `drawRawPoints` for the fill and one for the top edge, each clipped twice so either side of the target takes its own colour |

---

## 📐 Measurement

Correctness is the entire product, so every metric is pinned to a published spec
rather than to intuition — and where no standards body has published one, as
for dynamics, the project publishes its own: **Open Dynamic Range**,
[docs/ODR.md](docs/ODR.md), with conformance cases held to in CI like the EBU
ones.

| Quantity | Definition |
|---|---|
| **K-weighting** | ITU-R BS.1770-4 stage-1 shelf + stage-2 RLB, coefficients computed from the analog prototype **at the actual sample rate** — not hardcoded 48 kHz tables |
| **Gating** | EBU R128: 400 ms blocks at 75% overlap, absolute gate −70 LUFS, relative gate −10 LU |
| **Momentary / Short-term** | 400 ms / 3 s |
| **LRA** | Gated at −20 LU relative, 10th–95th percentile, via a 0.01 LU-bin histogram storing exact energy sums (O(1) per update, constant memory) |
| **True peak** | BS.1770-4 Annex 2, 4× oversampling with the specified 48-tap polyphase FIR, at every sample rate |
| **Spectrum** | 4096-point Hann window at a 1024-sample hop, zero-padded to a 16384-point transform and mapped onto 512 log-spaced bands with **peak-per-bin** so narrow peaks survive; bands too narrow to hold a bin read between two. Window-compensated: a full-scale sine reads 0.0 dBFS on a bin centre and within 0.3 dB off it |
| **Correlation** | Pearson over the block, then a 200 ms one-pole. Gated at −70 LUFS per channel, R128's absolute gate: under it the quotient is `0/0` and the reading is a dash rather than a `0` nobody took. A gate and not an underflow guard — a live input's noise floor is not exactly zero, and the correlation of two channels of noise is a random number whose sign falls whichever way the block did |
| **Crest** | Sample peak minus RMS over the same block — the block's own values, not the held peak and smoothed RMS the meters draw, which settle at different rates. Exactly 3.0103 dB for a sine, 0 for DC |
| **ODR-S / ODR-I** | Open Dynamic Range: true peak minus loudness over the same window, the last 3 s for ODR-S and the programme for ODR-I. Defined [below](#-open-dynamic-range). A stereo 1 kHz sine reads exactly 0 LU on both, in mono 3.01 |
| **Clip** | Longest run of consecutive samples at or above 0.999 since the reset, per channel. Latched, so a clip that lasted three samples is still visible when you look back |

All of these are measured today and checked in CI, the spectrum included.
`OAA_FLAG_SPECTRUM_UNAVAILABLE` stays in the ABI and consumers must keep checking
it: every reset raises the flag and it clears once a full window has been
transformed, about 85 ms in.

### 🎯 Open Dynamic Range

There is no standard that says what "dynamic range" is, so Open Audio Analyzer
defines one — **Open Dynamic Range**, `ODR-S` and `ODR-I` — says exactly which
subtraction it means, and holds it in CI the way it holds loudness. The
arithmetic is that of the peak-to-loudness ratios in AES TD1004; what the
standard adds is every operand that note leaves open, so that two
implementations of it cannot disagree. **The specification is
[docs/ODR.md](docs/ODR.md)** — normative, versioned, CC BY 4.0 so it can be
reproduced, with the conformance cases an implementation is held to. What
follows is the summary; nothing is tuned, weighted or smoothed on top of it.

| | Is | Over | Undefined while |
|---|---|---|---|
| **ODR-S** | `TruePeak − LUFS-S` | the last 3 s | `LUFS-S` is at or below −70 LUFS |
| **ODR-I** | `TruePeakMax − LUFS-I` | the programme since Reset | `LUFS-I` is |

- **The peak is true peak** — BS.1770-4 Annex 2, 4× oversampled — never sample
  peak, which understates a limited master by up to 3 dB and is precisely the
  error a dynamics reading exists to catch. It is the loudest channel's peak;
  the loudness is the standard's channel-weighted sum. So a stereo 1 kHz sine
  reads exactly **0.0 LU** on both — its 3.01 dB crest, the second channel's
  +3.01 and the K filter's +0.691 against the −0.691 offset cancel to nothing —
  and the same tone in mono reads **3.01**.
- **Both operands cover the same window.** ODR-S's peak is the highest true peak
  in the *same* three seconds `LUFS-S` averages, not the meter's held reading;
  ODR-I's is the highest since Reset, against the gated integrated loudness that
  BS.1770 defines for the programme. The unit is LU and the resolution 0.1,
  like every loudness reading.
- **Silence has no dynamics.** Every dB quantity floors at −144 rather than
  −∞ internally — a level standing there is *printed* `-∞`, and the floor is
  kept a number so that differences of dB stay arithmetic — and a subtraction
  of two floors is 0.0 — which read as "completely
  squashed" for a passage nobody could hear, and about 8 LU of "dynamics" for a
  noise floor at −90 dBFS. ODR-S is therefore undefined below the −70 LUFS
  absolute gate, which is the line BS.1770 already draws for what counts as
  programme, and ODR-I is undefined for exactly as long as `LUFS-I` is. Both
  read as a dash.
- **Neither moves when a platform turns the track down.** Peak and loudness
  shift together, so ODR-S and ODR-I describe the master and not the playback
  level — which is what makes them the dynamics numbers for the normalised
  era, and what LRA is not: LRA is how far the programme *moves*, and a track
  can be crushed flat with a wide LRA or breathe with a narrow one.
- **ODR-I is the delivery number, and its peak is gated by nothing.** `TP Max`
  is the highest true peak since Reset wherever it fell, including in a block
  the loudness gate threw out — a transient in a quiet intro is a peak a
  converter will see. The consequence is that one such transient rescues a
  flattened chorus, so ODR-I alone cannot say how hard a master was limited.
- **The lowest ODR-S can.** ODR-S is the live one — watch it fall in the chorus
  as a limiter is pushed and you are watching the squeeze happen — and a file
  report keeps its minimum over the programme, taken where it was defined: the
  most squeezed three seconds. A target may set a floor on either (`odr_i_min`,
  `odr_s_min`), and each floor is a line of the Validator, the report and the
  `oaa` verdict; the ODR-S line is judged against the minimum, which the
  Validator keeps since the last Reset.

What it is not: the `DR` of the TT Dynamic Range Meter — a different statistic
with a different algorithm, sample peak over the loudest fifth of the
programme's 3 s RMS blocks, rounded to an integer — which Open Audio Analyzer
does not report under any name, and the reason the pair is not called `DR-S`
and `DR-I`, which it was through 0.14.0 alongside `PSR` and `PLR`. Nor is it
*TrueDyn*: Decibel's dynamics figure is "the equivalent of peak over average,
but in the LUFS world", shown beside `LUFS-S` and true peak on one rim of its
Super Meter and beside `LUFS-I` and true peak max on the other, which is, by
Process.Audio's own description, this pair. It is not documented as one, so
nothing here claims to match its ballistics or its rounding; the numbers are
published under their own name and checked against arithmetic instead.

And what a reading *means*. Normalise a master to a target and its true peak
lands at the target plus its ODR-I — exactly — so under −14 LUFS and a −1 dBTP
ceiling, **13 LU** is the most a platform can play at its own level: below it
the master was limited harder than anyone asked and gets turned down, above it
the platform cannot lift it without clipping and it plays quieter by the
excess, transients intact. The bands are the specification's
[Annex A](docs/ODR.md#annex-a--reading-the-numbers-informative), informative
and kept apart from the definition on purpose. The anchors are arithmetic on
published delivery levels; the names are editorial, and genre-dependent in a
way no number can be — 7 LU is a choice in a techno track and a casualty in a
string quartet.

| ODR-I | Reads as | Anchor |
|---|---|---|
| 0 – 5 LU | **Flat.** The limiter's ceiling is the loudness. | 0.0 LU is a full-scale stereo sine |
| 5 – 8 LU | **Crushed.** The late loudness war. | −6 LUFS at −0.1 dBTP → 5.9 LU |
| 8 – 10 LU | **Loud.** | −9 LUFS at −0.3 dBTP, a loud CD → 8.7 LU |
| 10 – 13 LU | **Balanced.** Nothing is lost at −14 LUFS. | −14 LUFS at −1 dBTP → 13.0 LU, the streaming line |
| 13 – 16 LU | **Dynamic.** Plays below target on −14 platforms, transients intact. | −16 LUFS at −1 dBTP → 15.0 LU |
| over 16 LU | **Wide.** Ordinary for classical, jazz, film and broadcast. | −23 LUFS at −1 dBTP (EBU R 128) → 22.0 LU |

The text report prints the band's name after ODR-I. Overcompression lives in
the *minimum* ODR-S rather than in ODR-I, and the one published floor for it is
8 LU in the loudest passage, any genre — the number the **Dynamic master**
target carries.

A quantity this build does not measure is **NaN**, never zero — zero is a
legitimate reading for correlation, balance and several dB quantities, so it
cannot double as "no data" — and the UI renders it as an em dash, in the muted
ink and never in the colour a measurement is printed in. Nothing in the
table above is unmeasured, so in practice a dash means a reading that is not yet
*defined*: momentary loudness needs 400 ms of signal, short-term 3 s, integrated
one gating block above the absolute gate. A remote display that has lost its host
shows dashes too, since a frozen meter is indistinguishable from a quiet passage.

### ✅ The correctness gate

CI runs the **EBU Tech 3341 and 3342** cases on Linux, macOS and Windows on every
push, and fails the build if any reading is outside the standard's stated
tolerance. The **ODR § 7** cases run beside them, the same way: seven generated
signals with stated tolerances, because the dynamics readings have no reference
cases from anybody else. A loudness meter that has never been run against the
reference cases is a number generator.

The signals are **generated, not downloaded** — every case is a sine at a stated
level, or a sequence of them — so the suite needs no fixtures, no network and no
WAV decoder, and each expected value is derived from the standard in a comment
instead of copied from somebody's output. Three further properties are asserted
that the standard does not state but no correct implementation can violate:

- **Sample rate independence.** The same tone reads the same at 44.1, 48, 88.2,
  96 and 192 kHz. This catches the tempting shortcut of reusing the 48 kHz
  coefficient table BS.1770-4 prints instead of designing the filter at the
  stream's rate: it passes every 48 kHz test there is, and is wrong by a
  fraction of a dB on the most common delivery rate in music.
- **Block size independence.** Ten seconds pushed in one call, in 512-frame
  device blocks, and in 377-frame chunks agree to 0.001 LU.
- **Decoding does not change a reading.** A generated signal analysed directly,
  and the same signal written to a WAV, decoded and analysed again, agree to the
  bit. Offline analysis rests on that, so it is asserted rather than assumed.

**The official vectors are run too, and they are not a gate.** Neither the EBU
nor the ITU licenses its material for redistribution here, and fetching 811 MB
in CI would put a network dependency in front of the one suite that must never
be flaky, so `packages/oaa_engine/test/vectors_test.dart` skips unless told
where an unzipped copy is:

```sh
cd packages/oaa_engine
OAA_VECTORS=~/ebu-loudness-test-set OAA_VECTORS_ITU=~/bs2217 \
  dart test test/vectors_test.dart
```

**All 112 cases pass** — Table 1 of EBU Tech 3341 entire, Table 1 of Tech 3342,
and the compliance material of Report ITU-R BS.2217.

> [!NOTE]
> Running them found two real defects, which is the argument for material
> somebody else made. Tech 3341's tests 13 and 14 slide a 400 ms tone through
> twenty files in 20 ms steps; momentary loudness advanced only every 100 ms, so
> sixteen of the twenty read up to 0.45 LU low. And the ITU's two 7.1 files read
> 0.35 LU high, because the +1.5 dB surround weight was reaching the rear pair as
> well as the side pair. Both are fixed, and neither is expressible as a signal a
> generated suite would think to write. See [CHANGELOG.md](CHANGELOG.md) for what
> moved and by how much.

---

## 🧩 Layout

**The window is two bars and a canvas.** Across the top: the File menu where a
platform draws one, ANALYSE FILE, the open preset's name centred in the row, and
the pairing code, PUBLISH, ATTACH, settings, restart and `?` against the right
edge. Across the bottom: what is being measured and in what format on the left,
the DAW's playhead, the elapsed clock and the delivery target on the right.
Everything you *read* is in one row and everything you *press* is in the other,
and on macOS the top row is the window's title bar as well, which is why the
document's name is centred in it. They were one row for eight phases and could
not hold both jobs — the document's name had the highest width gate in the bar
and vanished on any window under 1266 px, and PUBLISH, whose absence takes a
capability away rather than hiding it, was dropped next.

The canvas is a **24-column snapping grid** rather than Decibel's free pixel
positioning. 24 divides by 2, 3, 4, 6, 8 and 12, so halves, thirds and quarters
are all exact; a 12-column grid cannot express thirds and quarters at once,
which is the first thing anybody wants when arranging meters.

**The row count is fixed too, at 16.** Square cells and a scrolling canvas keep
module aspect ratios identical everywhere and are wrong: on a 32" display a cell
becomes 160 px, a six-row meter becomes 960 px tall, and a layout built on a
laptop now needs scrolling. So both axes are fixed and cells are whatever shape
the window makes them, which costs nothing because every painter handles
arbitrary aspect anyway. A preset therefore stores grid cells and is
screen-independent by construction: Decibel stores fractions of the window and
reconstitutes them per display, while Open Audio Analyzer opens the same layout
on a 32" monitor and an 11" tablet with nobody writing responsive code.

**Drag a module's title bar** to move it, **drag the corner grip** to resize,
**alt-drag** to duplicate, **right-click or long-press empty canvas** to add a
module there, **right-click a module** for its options, and **right-click or
long-press a tab** to rename, duplicate or delete it. **Click anywhere else** —
empty canvas, the menu bar, the tab strip, another module — and the selection
clears, on the press; a module's own menu is not "anywhere else", so choosing an
option for it leaves it selected. Buttons for add, undo and redo sit in the tab
strip as well, because tablets have neither a right mouse button nor `⌘Z`.

A finger gets a larger target than the one that is drawn: 40 px of title bar
rather than the 24 px it paints, a 32 px corner grip rather than 16 px. Both are
invisible and both are admitted to touch and stylus alone, so a mouse still
moves and resizes exactly what it can see. A cursor has a hotspot one pixel
across and says what it is over; a fingertip has neither.

Nothing on the canvas is a double click. A double-tap recogniser holds Flutter's
gesture arena for 300 ms before giving up, and every button underneath one waits
that long to fire — a third of a second of an application that feels broken, in
exchange for a gesture a long press does better on both a mouse and a tablet.
The one exception is the window's top edge on macOS, where the menu bar *is* the
title bar: double-clicking it does whatever the Mac's "double-click a window's
title bar to" setting says, because a window that ignores that gesture ignores
the system. Flutter recognises nothing but a single click there; AppKit pairs
them in the runner, which is the only side that knows the interval this user set.

**Modules do not overlap, and a drop that would overlap is refused.** Allowing
overlap turns a meter bridge into a stack of half-hidden panels and needs a
z-order; pushing neighbours aside, as most dashboard grids do, means a drag near
an edge can irreversibly rearrange a layout you spent ten minutes on. While the
pointer is down the canvas becomes the placement grid — cells ruled inside a
border one gutter outside the modules, every other module dimmed, the target
cells bright when the drop is legal and red when it is not. The meters do not
stop, because dimming is a wash painted over them rather than a pause, and a
wash rather than a blur because a full-screen blur would be recomputed every
frame over exactly the readings that are still arriving.

A module resized below its minimum shows `TOO SMALL` instead of an unreadable
smear, and a module kind with no painter yet says `NOT BUILT YET` instead of
showing an empty panel that would read as a broken meter.

### ⌨️ Keyboard

Press `?` or `F1`, or the `?` at the end of the menu bar. Open Audio Analyzer
draws its own chrome, so apart from the File menu there is no menu bar to read a
shortcut off, and without that sheet most of them would be undiscoverable by
design.

`⌫` deletes the selection, arrow keys nudge it a cell and `⇧`+arrows resize it,
`⌘Z` / `⌘⇧Z` undo and redo, `⌘D` duplicates, `1`–`9` switch tabs, `⌘R` restarts
the measurement, `⌘O` opens a preset and `⌘S` saves it, `⌘I` analyses an audio
file. The full list is on the
[documentation site](https://open-audio-analyzer.com/docs/keyboard), and it is
not written twice: the page, the in-app sheet, the bindings and the key
equivalents in the macOS File menu all come from one table in
`lib/src/app/shortcuts.dart`, and a test fails if the page has drifted from it.

Three details that are decisions rather than defaults:

- **`Ctrl` and `⌘` are both accepted on every platform.** Asking the OS which
  one was meant is how a Mac driving an external PC keyboard ends up with no
  undo. Only the printed label is platform-specific.
- **A chord with no `Ctrl` or `⌘` stands aside while a text field has focus**,
  so a tab named `Mix 2` does not jump you to the second tab halfway through.
- **A nudge with nowhere to go does nothing**, rather than clamping. Clamping
  means the tenth press of `→` moves the module and the eleventh does not, with
  no way to feel where the edge was. It is the same rule a drag follows.

### 🗂️ Presets, targets and skins

Three independent axes, as in Decibel, including the `from preset` indirection.
Null means *follow the preset*; a concrete id means the user pinned that choice
and opening a preset must leave it alone. Without that distinction, either
presets cannot carry a target or an explicit choice gets silently overwritten.

**A preset is a document, and the File menu treats it like one.** `Open…` picks
one through the platform's own dialog, starting in the presets folder and
reaching anywhere else you point it; `Save` writes back to the file it came
from, without asking, on the next launch as well as this one — the session
remembers which file that is, and drops it only if the file has gone; `Save
as…` places a copy anywhere and takes the preset's name from the filename,
which is why there is no name field. An unsaved layout is called
**Unnamed**, and that is the word the save dialog opens with. The open preset's
name is centred in the menu bar, with a dot beside it when the canvas differs
from the file. On macOS the menu is in the system menu bar; on Windows and Linux
it is the FILE button at the far left of that same row.

Whether a preset carries the delivery target and the skin is a property of the
preset, set by two ticked rows in that menu. They cannot go in the platform's
save dialog — `file_selector`'s macOS panel has no accessory view, Windows would
need a plugin of its own, and Linux's `GtkFileChooserNative` has no extra-widget
API left — and as properties of the document they also survive a save, which the
switches they replaced did not.

Delivery targets ship as **data**, not code, so the set can be corrected and
extended without a release. Seven are built in: **Streaming (−14 LUFS)** — Spotify,
Apple Music, YouTube, Amazon and Tidal all normalise to about the same place, so
one target with their names in its note beats five identical entries — plus
**Spotify Loud**, **Podcast (−16 LUFS)**, **EBU R 128**, **ATSC A/85**,
**CD / no normalisation**, and **Dynamic master**, the one built-in that is a
recommendation rather than a platform: the streaming target's loudness and peak
lines with a floor of 8 LU on the minimum ODR-S, Ian Shepherd's published
number for the loudest passage in any genre
([ODR Annex A](docs/ODR.md#annex-a--reading-the-numbers-informative)).
Anything else is a JSON file you write; see
[Configuration](#-configuration). A target names a loudness with a tolerance,
a true peak ceiling and an LRA ceiling, and may name an **ODR-I floor** and an
**ODR-S floor** — the two limits that run the other way, and the ones no platform
publishes: of the built-ins only Dynamic master carries one, and a house
standard that wants its own writes `odr_i_min` or `odr_s_min` into its file.
**Reset**, beside Edit in Settings, deletes
every target you wrote and puts those seven back, which is also how a correction
to a built-in is undone, since a correction *is* a file shadowing it. It asks
first, and says how many files went.

---

## 📂 Configuration

Everything Open Audio Analyzer remembers is a JSON file you can open, edit, copy
between machines or keep in version control.

| Platform | Directory |
|---|---|
| **macOS** | `~/Library/Application Support/Open Audio Analyzer` |
| **Windows** | `%APPDATA%\Open Audio Analyzer` |
| **Linux** | `$XDG_CONFIG_HOME/oaa`, or `~/.config/oaa` |
| **iPadOS** | `Library/Application Support/Open Audio Analyzer` inside the app's own container |
| **Android** | `oaa` inside the app's own `files` directory |

```
settings.json          the frame rate, source, target, skin
session.json           the canvas as you left it and the preset file it is
                       open on, saved as you work
presets/*.json         one file per saved layout
calibrations/*.json    one file per delivery target you wrote
skins/*.json           one file per skin
```

`OAA_CONFIG_DIR` overrides the three desktop rows, and `--config-dir=<path>`
beats the variable in turn — which is what works on macOS, where an environment
cannot be handed to an application bundle. Settings → Session prints the
directory actually in use and lets you select it.

The two tablet rows are the ones you cannot open in a file manager, because both
systems give an app a private directory and no way out of it. Android's comes
from `getFilesDir()` over a platform channel, because nothing in the environment
there names a directory the app may write to, and it goes when the app is
uninstalled, as a tablet's copy of a layout should.

**The macOS app is deliberately not sandboxed**, which is what makes the first
row true: a sandboxed app's `HOME` is redirected into `~/Library/Containers`,
which would put your presets somewhere you would never find them and stop either
override from pointing outside it. The trade is that Open Audio Analyzer cannot
ship on the Mac App Store, which it was never going to. See
`macos/Runner/Release.entitlements`, which says so at the top.

**One file per preset rather than one library file**, deliberately: a preset can
be sent to somebody or dropped in from a forum post, and one corrupt file costs
one preset instead of all of them. `presets/` is where the File menu's dialogs
open, and it is not a boundary — a preset can be saved and opened anywhere,
which is what makes the sending work. It is also the list, since there is no
preset browser, so deleting one is a file manager's job. Every write goes to a
temporary file and is renamed over the target, so an interrupted save leaves the
previous version intact. A file that fails to parse is named in the interface
and left alone; Open Audio Analyzer never rewrites something it could not read.

The path this does *not* take is `path_provider`. It needs a Flutter binding, so
it throws in the two places these paths are most needed — the `oaa` CLI and a
unit test — and on macOS it returns a sandbox container keyed by bundle
identifier, which moves your entire configuration the first time a build is
signed differently.

### 🎨 Skins

**Settings → Appearance → Edit skin** opens the editor. Every role is a swatch
that opens a colour picker, the canvas behind the panel follows the pointer as
you drag — as does any tablet mirroring the session — and each role prints its
contrast ratio against the surface it has to be read on, with the ones below its
floor marked. Nothing is written until you save.

**Precision Instrument and Daylight cannot be changed or deleted.** They are the
pair that proves the roles are semantic: Daylight inverts the entire lightness
ordering, so a painter that had reached for "the dark one" instead of a role
would be obvious immediately, and a reference point a file on disk can quietly
redefine is not one. Editing either previews normally; **Save as new** keeps it.

A skin is a JSON file, and the editor changes nothing about that. It names as
many of thirteen colour **roles** as it likes and inherits the rest, so changing
one colour is a three-line file:

```json
{
  "id": "my-skin",
  "name": "My Skin",
  "colors": { "accent": "#FF9E00" }
}
```

The roles are `background`, `panel`, `panel_raised`, `hairline`,
`hairline_strong`, `text_primary`, `text_muted`, `text_faint`, `accent`, `warn`,
`over`, `meter_track` and `meter_fill`. Values take `#RGB`, `#RRGGBB` or
`#AARRGGBB`. Add `"light": true` for dark ink on a light ground.

They are *semantic* roles rather than literal colours — `over` is "the colour
that means over a limit", used for nothing else — which is what lets a skin
apply to a module written after it. A file named after a built-in is ignored
instead of shadowing it. **New skin** writes the current palette out in full as
a starting point, and **Reload from disk** picks up hand edits without a
restart.

A delivery target is the same idea:

```json
{
  "id": "house-standard",
  "name": "House standard",
  "lufs_target": -12.0,
  "lufs_tolerance": 0.5,
  "true_peak_max": -1.0,
  "lra_max": 14.0,
  "odr_i_min": 8.0,
  "odr_s_min": 6.0,
  "vu_reference": -18.0
}
```

`odr_i_min` and `odr_s_min` are the two lines that may be left out: a target
without them sets no dynamics floor, and its Validator has three rows rather
than five. The second is judged against the lowest ODR-S of the programme, not
the current one. That is the target's half of what a Validator checks; the
module's half is its `Checks` menu, which can leave out any of the rows the
target does state.

A file whose `id` matches one Open Audio Analyzer ships with **replaces** it
everywhere, including in presets that already name it, so if you disagree with
our reading of a published spec, your number wins. Delete the file and the
original comes back.

---

## 🎨 Design

**Precision Instrument.** Graphite black, one signal hue, hairline borders, no
shadows. Depth comes from background steps, because measurement gear is
machined panels sitting flush, not floating cards — and a gradient appears only
where it describes light on such a surface: every module's panel is lit from its
top-left corner, as Decibel's are; a level meter's bar is shaded as a solid; the
Number Box and the Alert Meter glow in their verdict. Never as decoration.

```
bg      #0B0C0E     accent  #35E0C4   readings, and in spec
panel   #121417     warn    #F2B01E   close to a limit
hairline#1F2328     over    #FF4D4D   past the target
text    #E6E8EB / #8A9199 / #565E67   chrome, labels, ticks
```

Two rules are enforced rather than merely encouraged:

1. **Every spatial value comes from `Space`** — `2, 4, 8, 12, 16, 24, 32, 48,
   64`. No widget writes a raw number for padding, margin or gap. Modules built
   over many weeks drift apart one `EdgeInsets.all(11)` at a time, and the
   result reads as amateur long before anybody can say which value is wrong.
2. **Every number is monospaced with tabular figures.** With proportional digits
   a readout's width changes as its digits change, so it jitters while you watch
   it. It is the most obvious tell of a meter written by somebody who does not
   use meters.

**Inter** (labels and prose) and **Google Sans Code** (every number) are bundled
rather than requested from the system, in the weights the type scale names.
Falling through to the platform's own faces means digit width, tracking and cap
height all differ between macOS, Windows and Linux, and a layout tuned on one is
subtly wrong on the other two. Both are SIL OFL 1.1 and their licences ship in
`assets/fonts/`.

---

## 📦 Repository layout

```
engine/            C11 DSP core. Knows nothing about Dart or Flutter.        GPL
packages/
  oaa_engine/      FFI bindings + the build hook that compiles engine/.      GPL
  oaa_core/        Domain model. Pure Dart — no Flutter, no dart:ffi.        GPL
  oaa_wire/        The remote-display protocol. Pure Dart, no I/O.           GPL
  oaa_ui/          Design tokens and the primitives modules are built from.  GPL
lib/               The application.                                          GPL
assets/fonts/      Inter and Google Sans Code, with their licences.      SIL OFL
cli/               The `oaa` command-line analyser.                          GPL
plugin/            Headless VST3 + AU + AAX plugin.                        AGPL
  host/            A fake DAW that plays a file through it. Ships nowhere.  AGPL
docs/              METRICS.md, ODR.md, WIRE.md.
```

Two boundaries carry weight:

- **`engine/` knows nothing about Flutter, and `oaa_core` knows nothing about
  `dart:ffi`.** Four things need the domain vocabulary — the app, the tablet
  display, the CLI and the plugin — and three of them have no engine of their
  own. The tablet reads measurements off a socket. The moment `oaa_core` imports
  `oaa_engine`, all three drag in a native library they never call.
- **One `liboaa` serves all three tiers.** That is what makes standalone, remote
  display and plugin tractable as one project rather than three.

### 📜 Licensing

Copyleft throughout. Copyright © 2026 Jonas Grunau.

- **`engine/`, `packages/oaa_engine`, `packages/oaa_core`, `packages/oaa_wire`,
  `packages/oaa_ui`, `lib/`, `cli/` — GPL-3.0-or-later.** A free clone of a paid
  product should not be re-closable, and that argument does not stop at the
  application: an engine anybody may embed in a closed product is an engine
  somebody can sell back to you.
- **`plugin/` — AGPL-3.0-or-later**, because it links JUCE. JUCE 7 and 8 are
  AGPLv3-or-commercial (only JUCE 6 offered GPLv3), and Open Audio Analyzer
  takes the AGPLv3 option. It changes the licence of the plugin binary alone:
  the app talks to the plugin over a socket, which is not linking, and GPLv3
  section 13 expressly permits the combination. Neither plugin SDK changes that
  answer and neither needs a checkout: Steinberg's VST3 SDK is MIT, and Avid's
  AAX SDK is offered under GPLv3 beside their commercial agreement — copyleft,
  but the same section 13 case. Both are vendored inside JUCE.
- **`docs/ODR.md` — CC BY 4.0.** The one document that is not GPL, because a
  specification is only open if another product's manual may reproduce it.
  The reference implementation stays GPL; the licence binds the code and not
  the measurement, which anybody may implement without asking.

The engine, the domain model and the wire protocol were MIT through 0.13.0, on
the argument that a measurement engine's value is that anyone can embed and
audit it. Auditing never needed MIT, since the source is published either way,
and embedding was the half that let the work be closed again. The trade, stated
plainly: a third-party display now has to be GPL-3.0-or-later to reuse
`packages/oaa_wire`. What it does *not* have to do is use that package at all —
the protocol is specified normatively in [docs/WIRE.md](docs/WIRE.md), a
specification is not a program, and three independent implementations of it
already exist.

**This is not a licence against commercial use, and no free-software licence
is.** GPL permits selling copies, charging for support and shipping Open Audio
Analyzer inside something you sell. What it forbids is a *proprietary* fork:
anyone distributing a modified version has to ship its source under the same
terms, which is the part MIT left open.

---

## 📥 Installing

Every release publishes five desktop downloads and the CLI on the [releases
page](https://github.com/JonasGrunau/open_audio_analyzer/releases). Full
instructions, including how to meter your own system's output on each platform,
are on the [documentation site](https://open-audio-analyzer.com/docs/install).

| Platform | Artefact | Plugin | |
|---|---|:-:|---|
| macOS 14.2+ | `Open.Audio.Analyzer-<version>-macos.pkg` | VST3 + AU | Universal — Apple silicon and Intel. |
| Windows 10 1809+ | `Open.Audio.Analyzer-<version>-windows-x64.exe` | VST3 | Uninstaller in Installed apps. |
| Linux | `Open.Audio.Analyzer-<version>-linux-<arch>.tar.gz` | VST3 | `./install.sh`, no root. |
| Linux | `Open.Audio.Analyzer-<version>-<arch>.AppImage` | — | One file, no root, GTK from the host. |
| Linux | `Open.Audio.Analyzer-<version>-<arch>.flatpak` | — | Sandboxed, carries its own runtime. |
| Any | `oaa-cli-<platform>.tar.gz` / `.zip` | — | `bin/oaa` beside the engine. No Flutter runtime. |
| Any | `oaa-plugin-<platform>.tar.gz` / `.zip` | the bundles | For installing by hand, and the only place the **AAX** is. See [In a DAW](#-in-a-daw). |

> [!TIP]
> **The first three install the plugin as well, and the checkbox starts
> ticked.** Untick it and you get the application on its own. The AppImage and
> the flatpak cannot offer the choice: an AppImage never installs anything, and
> a flatpak's plugin would be built against the sandbox's libraries while the
> DAW that must load it runs against the host's.

> [!NOTE]
> **There is no Mac App Store build and there will not be one.** The store
> requires the app sandbox, which redirects the home directory into
> `~/Library/Containers` and would put every preset, skin and delivery target
> somewhere no user goes looking and no override could escape. The pkg is
> distributed directly instead, signed with a Developer ID **Installer**
> certificate — a different one from the Developer ID Application certificate
> that signs the code, and not interchangeable with it — and notarised when a
> release is built with the credentials for both.
> `packaging/macos/make_pkg.sh` prints which of its three states it was in,
> because "signed" and "a user can double-click it" are not the same thing.

> [!NOTE]
> **The iPad build goes to TestFlight and the Android build to Google Play**,
> and neither is on the releases page. Both are built and uploaded by a tagged
> release, after the release is published, so a store build always belongs to a
> release that exists. Neither is attachable as an asset: an App Store signature
> provisions no devices, so a downloaded IPA could not be installed by anyone,
> and an `.aab` is a publishing format from which Play generates and signs each
> device's download. Play carries it as a **closed test**, which grants access
> by list rather than by link, so
> [ask on the repository](https://github.com/JonasGrunau/open_audio_analyzer/issues)
> before opting in — [Installing](docs/site/install.md#android) has both steps.
> Play offers it to **tablets** only, via a 600dp shortest-edge filter in the
> manifest, which is the store's filter and not a runtime one. Building the IPA
> yourself is two lines in [Building](#-building) and needs no credentials.

The scripts live in [`packaging/`](packaging/AGENTS.md), one per artefact, and
`ci.yml` runs all five installers, the iPad build and the Android bundle on a
tag and on demand. Each produces an unsigned artefact and says so rather than
failing when the signing secrets are absent, since a fork has none.

---

## 🔨 Building

Requires Flutter `3.44.5-stable` (pinned in `.tool-versions`) and a C toolchain
— Xcode command line tools, MSVC, or gcc/clang.

```sh
flutter pub get
flutter run -d macos          # or windows, linux
flutter run -d <ipad>         # the display build; `flutter devices` names it
```

The app needs **no podspec, no `build.gradle` and no per-platform
`CMakeLists.txt`**. `packages/oaa_engine/hook/build.dart` compiles the C through
`native_toolchain_c` and bundles it as a code asset, the recommended way to ship
native code with Flutter since 3.38. One build description that works on five
platforms beats five that each work on one. On iOS it compiles the engine as
**Objective-C**, because miniaudio's Core Audio backend configures an
`AVAudioSession` and iOS offers no C way to do that; undo it and you get several
hundred errors inside Apple's own `Foundation` headers, not one of which names a
file in this repository.

`engine/CMakeLists.txt` describes the *same* compile for consumers that are not
Dart — the plugin, and a CI runner with no Flutter SDK. Two descriptions of one
compile is a real cost, paid deliberately: `plugin/test/sources_match.sh` fails
the build if the source lists drift, so **a new file in `engine/src` goes in
both.**

Four Flutter plugins are pulled in: `desktop_drop` and `file_selector` to get a
path from a user, `flutter_riverpod` for configuration, and `mobile_scanner`
(MIT) for the host picker's QR scanner. The last is the one dependency with a
native half that is not vendored, and the one that does not ship everywhere:
Android, iOS and macOS only. It integrates through Swift Package Manager, so
there is still no `Podfile` here. The QR *encoder* on the other side of that
feature is written here rather than depended on, in
`packages/oaa_ui/lib/src/qr.dart`, held against ZXing by `test/qr_test.dart`.

### 🧪 Tests

```sh
flutter analyze                       # lints, whole workspace
dart format --output=none --set-exit-if-changed .
                                      # formatting; nothing else objects to it
flutter test                          # widget and golden tests
dart test packages/oaa_core           # domain layer, no toolchain needed
dart test packages/oaa_wire           # the wire protocol, incl. the C++ golden
cd packages/oaa_engine && dart test   # engine, through FFI
cd packages/oaa_engine && dart run test/reclaim_orphans.dart
                                      # the process-global reset, in a process
                                      # of its own. After the suite, never
                                      # inside it — see the file's header
cd cli && dart test                   # the `oaa` binary, as a subprocess
cd cli && dart build cli -o build     # and it still builds the way a release does
sh plugin/test/sources_match.sh       # the engine's two build lists agree
cmake -B plugin/build-nojuce -S plugin -DOAA_BUILD_PLUGIN=OFF && \
  cmake --build plugin/build-nojuce && \
  ctest --test-dir plugin/build-nojuce  # the plugin's C++ that needs no JUCE
cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release && \
  cmake --build plugin/build && \
  ctest --test-dir plugin/build       # the VST3, the AU, the AAX and the fake
                                      # DAW compile, each macOS bundle verifies
                                      # against its own signature, and the
                                      # plugin answers a host that says nothing
dart test packages/oaa_wire           # again: with a built fake DAW the
                                      # end-to-end cases run instead of skipping
flutter test test/plugin_to_display_e2e_test.dart
                                      # and on to a display: DAW → plugin →
                                      # app → tablet
cd website && npm ci && npm run build  # the website still builds
```

`dart test packages/oaa_wire` appears twice on purpose. Its end-to-end cases
spawn the [fake DAW](#-testing-the-plugin-without-a-daw) and decode what the
plugin sends over a real socket; without a build they skip, so the second run is
where they actually happen. The line after it is the same run with the
application in the middle — plugin ingest, display host, display client — so a
DAW's meters are shown to reach a second screen field by field rather than each
half being shown to work on its own. Both want port 47822, so neither runs while
Open Audio Analyzer is open.

`-DOAA_BUILD_PLUGIN=OFF` is the framework-free configure: no JUCE fetch, no
plugin, no fake DAW, and five seconds for the C++ tests that need none of them.
It runs on every push; the full plugin build does not.

Two things are deliberately not on that list, for the same reason: neither's
material may live in this repository.

`packages/oaa_engine/test/vectors_test.dart` runs the
[official EBU and ITU vectors](#-the-correctness-gate) and skips unless
`OAA_VECTORS` and `OAA_VECTORS_ITU` say where they are, because 811 MB of
material nobody may redistribute cannot be a gate. Run it after touching
`engine/src/oaa_loudness.*`, `oaa_kweight.*` or `oaa_truepeak.*`.

Avid's **AAX Validator** is the plugin's equivalent — this format's `auval`,
and the only thing short of Pro Tools that will say the `.aaxplugin` is sound.
The tools are a separate download under Avid's developer agreement and cannot be
vendored here, so nothing in CI runs them. Run it after touching anything the
AAX bundle is made of; `plugin/AGENTS.md` has the invocation.

The engine tests are worth a look even if you never touch the C. A sine of
amplitude *A* has a peak of *A* and an RMS of *A*/√2, exactly 3.0103 dB lower.
That is arithmetic rather than convention, so the built-in test tone doubles as
a reference the meters can be held against on a headless CI runner with no sound
hardware anywhere near it.

---

## 🔍 Analysing files

Drop a file on the analysis panel, or run the CLI. Both push blocks through the
*same* `oaa_analyse` a capture device drives — there is no second DSP path — so
an offline reading and a live reading of the same audio are identical rather
than merely close, and a test asserts exactly that on the same samples analysed
both ways.

Nothing resamples or remixes: a file is measured at its own sample rate and
channel count, because a converter in front of a measurement changes the
measurement. WAV, AIFF, RF64, Wave64, FLAC and MP3.

```sh
oaa master.wav                                 # human-readable report
oaa --target streaming-14 master.wav           # …and a delivery verdict
oaa --format json --timeline master.wav        # every measurement, for scripts
oaa --format csv -o loudness.csv master.wav    # the loudness timeline
oaa --list-targets                             # what you can measure against
```

**`--target` reads your own targets too.** A `calibrations/*.json` file in the
[configuration directory](#-configuration) is available to the CLI exactly as it
is to the app, and one whose `id` matches a built-in replaces it, so a
correction to our reading of a published spec reaches the exit code and not only
the window. `--config-dir` points somewhere other than the default.

**The exit code is the point.** With `--target`, a file that misses its delivery
spec exits `2`, an unreadable file exits `1`, and all-clear exits `0`, so a
release pipeline can fail a build on a master that is 2 LU too loud instead of
shipping it:

```sh
oaa --target streaming-14 master.wav || exit 1
```

Reports export as text, JSON and CSV, where an unmeasured quantity is an em
dash, a `null` and an empty cell respectively, never a zero. The app adds a
fourth: **a PNG report card**, for the message where somebody asks whether the
master is ready. It is drawn as a fixed layout rather than captured from the
panel, so two people exporting the same report get the same picture.

---

## 🎹 In a DAW

Open Audio Analyzer installs as a **VST3** and an **Audio Unit** that draws
nothing — and builds an **AAX** for Pro Tools, with the caveat below. Insert it
on a track, a bus or the master, and the desktop app meters what your DAW is
playing, through the same engine, on the same canvas, with the same painters as
a live input. The plugin measures and streams; the app
displays. That split is what stops there being two implementations of every
meter drifting apart from each other.

**A connected plugin is a source in the picker**, beside the test tone and the
machine's own inputs — `DAW plugin — Logic Pro`, with the host it is running in
— so it is chosen and left the same way an interface is, and the selection is
remembered between launches. The first plugin to connect selects itself, because
inserting it is the act of choosing it and nobody who has just put a meter on a
bus wants to go and find a menu; a second insert does not, so a plugin left in a
session cannot take the canvas back off somebody who has switched to their
interface. Several inserts can be connected at once and each is its own row.
Choosing a DAW releases the capture device — nothing local is being metered, and
a microphone held open behind a canvas showing a DAW is a recording light with
nothing behind it — and choosing it with none connected reads as dashes rather
than as silence, with a line at the top of the window saying so. It connects on
`127.0.0.1:47822` and keeps retrying, so it does not matter which of the two you
start first. Its window is a status
panel: a diagram of the three places the path can break — the host's audio, the
host's playhead, the socket to the app — with each run lit or dark and the
socket's dashes travelling while frames are actually being sent, and under it
what the host is handing over, for how long, the integrated loudness, and one
line saying what to do about whatever is wrong.

**RESET is the one control that cannot follow.** Protocol version 3 opened the
app → plugin direction, but it defines one frame and RESET is not it, so
pressing it while a plugin is on screen says so rather than quietly resetting a
local engine nobody is looking at.

### 🔧 Building and installing it by hand

```sh
cmake -B plugin/build -S plugin -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build plugin/build
```

Products land in `plugin/build/OaaPlugin_artefacts/Release/`. Nothing is copied
into a system plugin folder unless you copy it, because a build that installed
itself would mean the DAW you have open is now running a binary you did not
knowingly install. JUCE is fetched and pinned, not vendored, so a fresh clone
builds without checking out a framework by hand.

The installers do the rest of this for you. By hand, copy the *bundle*, not the
directory holding it, into the folder your DAW scans — on a machine that has
never had a plugin installed, it does not exist yet:

```sh
# macOS
mkdir -p ~/Library/Audio/Plug-Ins/VST3 ~/Library/Audio/Plug-Ins/Components
cp -R "plugin/build/OaaPlugin_artefacts/Release/VST3/Open Audio Analyzer.vst3" \
      ~/Library/Audio/Plug-Ins/VST3/
cp -R "plugin/build/OaaPlugin_artefacts/Release/AU/Open Audio Analyzer.component" \
      ~/Library/Audio/Plug-Ins/Components/

# Linux
mkdir -p ~/.vst3
cp -R plugin/build/OaaPlugin_artefacts/Release/VST3/*.vst3 ~/.vst3/
```

On Windows the folder is `%CommonProgramFiles%\VST3`. **Ableton Live also has to
be told to look there** — Preferences → Plug-Ins → *Use VST3 Plug-In System
Folders*.

**The AAX is built and is not signed, so Pro Tools will not load it.** An AAX
bundle needs a signature from PACE's `wraptool`, made against an Avid developer
account holding a signing certificate, and that is a different thing from the
code signature every bundle here already carries. Unsigned, it loads in a
*Developer* build of Pro Tools and in Avid's own developer tools, and nowhere
else — and a released Pro Tools does not explain itself, it simply does not list
the plugin. So the `.aaxplugin` is in the release archive and in none of the
installers, because a checkbox that installs something no DAW will show is worse
than no checkbox. Its folder, for when that changes, is
`/Library/Application Support/Avid/Audio/Plug-Ins` on macOS and
`%CommonProgramFiles%\Avid\Audio\Plug-Ins` on Windows.

**If you unpacked a release archive on macOS, strip the quarantine flag.** A
browser marks every file it downloads, the mark survives extraction, and
Gatekeeper then refuses the load. On macOS 15 and later that refusal is a modal
with no way to override it in System Settings, because "Open Anyway" is only
ever offered for a blocked *launch* and loading a plugin is a library load; on
earlier versions it is silent, and the plugin is simply absent from the DAW's
browser with nothing logged anywhere.

```sh
xattr -dr com.apple.quarantine ~/Library/Audio/Plug-Ins/VST3/"Open Audio Analyzer.vst3"
```

The build signs each macOS bundle *after* every step that writes into it and
then verifies the result, so `codesign --verify --strict` and `auval` are both
clean. Signing is ad-hoc by default, and ad-hoc is not a Developer ID: only the
flag above gets an ad-hoc copy past Gatekeeper, and a bundle you built yourself
has no flag to remove. `-DOAA_CODESIGN_IDENTITY=<id>` signs with a real
identity, and `packaging/macos/notarize.sh` is what then gets a *download* past
Gatekeeper, which is the step people skip.

The bundles are universal and load on **macOS 14.2 and later**, the
application's floor too. 14.2 is where `CATapDescription` arrived, and a strong
reference to a class that does not exist is a library dyld cannot load at all.
Releases up to 0.5.0 were neither universal nor portable, because CMake defaults
both the architecture and the deployment target to the machine that built them —
and a bundle whose slice does not match is, to a DAW, the same event as a bundle
that is not there.

### 🎚️ What the DAW adds that a live input cannot

The host's transport comes across with the audio: play and record state, the
playhead in seconds, samples and quarter-notes, tempo, time signature, loop
points, and SMPTE timecode with its frame rate, plus a flag when the playhead
*jumps*, because an integrated reading taken across a relocate is the average of
two passes of the same music and looks entirely reasonable.

The status bar reads it back in the most precise unit the host gave — timecode,
else bar and beat, else the host's own clock — with tempo and time signature
beside it where the window is wide enough. It is brighter while the transport is
rolling than while it is parked, because two readings of the same frame
otherwise print the same string. The desktop relays the playhead to every
attached remote display, so an iPad across the room shows the DAW's position
beside the DAW's meters, sent when it changes rather than with every measurement
— so a parked session costs nothing, and a display that attaches to one is given
the position it is parked at instead of waiting for somebody to press play.

Hosts differ enormously in what they actually report, and Open Audio Analyzer
does not paper over it: every transport value carries a flag saying whether the
host supplied it, and a value that did not arrive is not drawn. A tempo that
arrives as zero is indistinguishable from a real one, and "bar 1, beat 1,
00:00:00:00" is a perfectly plausible thing to show somebody whose session is
parked at bar 57. A host that reports nothing at all gets dashes rather than a
plausible zero — a case **no DAW can actually produce**, because neither format
has a way to say "not saying": JUCE's VST3 host sends a zeroed process context
and the Audio Unit scopes a playhead around every render, so a host that
withholds its transport arrives as one *parked at zero with nothing else valid*.
The dashes belong to the branch behind that, held by
[`plugin/test/transport_capture_test.cpp`](plugin/test/transport_capture_test.cpp),
which hosts the processor as the C++ object it is.

The **Elapsed** and **Timecode** LUFS modes are what that measurement is for,
and **no module offers them yet**; see [Known gaps](#-known-gaps-stated-plainly).

### 🧪 Testing the plugin without a DAW

`plugin/host/` builds a **fake DAW**: a host that plays an audio file through
the plugin and gives it a transport, built by the same CMake run.

```sh
open plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw.app  # macOS
plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw           # Linux
```

It finds the VST3 in the build tree beside it, so with the app already running
the only thing left is to open a track and press space. Tempo, time signature,
timecode frame rate, a loop region and the record flag are controllable in the
window, and the plugin's own status panel opens in a second one. Three gestures
are command-line switches instead, because they have to happen on cue rather
than when somebody remembers: `--no-playhead` reports no transport at all, and
in `--headless` runs `--parked` renders with the transport stopped, while
`--relocate-at=<s>` plays, stops, jumps back to the start and plays again — the
gesture [`docs/WIRE.md`](docs/WIRE.md) names as the reason the discontinuity
flag exists.

`dart run tool/fetch_test_audio.dart` downloads music worth looking at: two
CC BY 3.0 post-rock tracks, picked by measuring candidates rather than by reading
titles. The default is a loud master with a real 10.3 LU range, a true peak
*above* its sample peak, and a stereo field that moves. A sine has none of those
— correlation pinned at 1.00, one spectrum bin, and an LRA of zero.

The same binary runs with `--headless`: no window, no sound card, blocks pushed
from a background thread. That is what
[`packages/oaa_wire/test/plugin_e2e_test.dart`](packages/oaa_wire/test/plugin_e2e_test.dart)
drives, and it is the only test that covers the live path — `prepareToPlay`, the
FIFO, the playhead, the engine, the streaming thread and the socket — rather
than the codec alone.

It earned its keep immediately: **seven** findings that nothing else could see,
listed under **What it found** in
[`plugin/host/AGENTS.md`](plugin/host/AGENTS.md). Six were defects and all six
are fixed — three in the plugin's transport handling, one that only became
visible with the fake DAW and the application running as a pair, one in the
plugin's streaming thread that a 2048-frame host buffer exposed as a waveform
with gaps in it, and one in the fake DAW itself, which was inventing the very
thing it exists to measure. The seventh is the unreachable "host supplies no
position" branch described above.

---

## 🚧 Known gaps, stated plainly

- **No module offers the Elapsed or Timecode LUFS modes yet.** What used to
  block them is gone: protocol version 3 defines `0x0020 SET_LUFS_MODE` on the
  ingest port, which is loopback where whatever connects is already running as
  you, and the engine's half is built. What is left is the part you would see —
  a mode menu on the LUFS modules and a region editor for Timecode. The plugin
  applies a mode against the transport it captures per audio block rather than
  being told when to reset, because the app only sees the playhead at the
  publish rate and a reset arriving a frame late has already let the wrong audio
  into the reading. **Continuous is what every module measures today**, and it
  is the mode a producer with no playhead can honour anyway.

  **RESET still cannot reach a connected plugin**: version 3 defines only the
  mode frame, so `0x0021`–`0x002F` are undefined. The remote display neither
  needs one nor will get one, since that port is on the LAN and stays read-only
  until somebody designs authentication for it. Silently restarting an
  integration mid-programme is wrong in a way nothing on screen reveals.
- **Capturing your own system's output takes all of it, and on macOS it takes
  permission.** No driver on any platform, and no per-application selection on
  any of them. Windows needs nothing: WASAPI loopback captures whatever is
  playing. Linux already lists a PulseAudio or PipeWire monitor source. On
  macOS, **System Output** is the first entry in the source menu, a Core Audio
  process tap that reads what is being sent to your speakers without rerouting
  it, so you keep hearing your audio; the first time you choose it macOS asks
  for permission, and a refusal is silent by Apple's design, so the meters read
  digital black rather than saying no. Metering a hardware input needs none of
  this.

  Two rough edges on the tap, both stated rather than hidden. It follows the
  default output device when you change it, but only when the new device has the
  same sample rate and channel count: the engine's DSP is sized once and cannot
  be resized underneath a running measurement, so when the format moves the tap
  stops, says so, and the application opens a new engine at the new format a
  couple of seconds later — which starts the integration again, because it is a
  different measurement of a different stream. Bluetooth headsets trigger this
  whenever something opens their microphone. And a tap only receives audio while
  something is actually playing: an output device with nothing going to it has
  an idle clock, so the meters hold their last reading rather than falling to
  the floor. That is not a fault, and a source that has *stopped* is a different
  fact that is reported.
- **Offline analysis does not read Ogg Vorbis, Opus, AAC or ALAC.** WAV,
  AIFF, RF64, Wave64, FLAC and MP3 cover the formats a master is delivered *as*,
  which is what a delivery check is for. The missing ones are what a master is
  distributed as after transcoding — worth having eventually, and the decoder is
  one function per format, but nothing is silently wrong in the meantime: an
  unsupported file is refused rather than half-read.
- ⏱️ **A file is measured whole, from the start.** There is no region selection
  and no seeking during analysis, because an integrated loudness taken over a
  file that was seeked through is a measurement of a programme nobody played.
- **The remote display has no authentication and no encryption.** Anyone who
  can reach the port can read the measurements and the layout, though not the
  audio, which never goes on the wire. That is why publishing is **off until you
  switch it on**, and why the link is one-directional: a display cannot reset,
  retarget or reconfigure the machine it is watching. Do not switch it on at a
  venue whose Wi-Fi you do not control.
- **Publishing is never remembered, on purpose.** The display's name, port and
  update rate persist like every other setting; whether to publish does not, and
  starts off at every launch. The switch is **PUBLISH** in the menu bar rather
  than in the panel, because an unauthenticated open port needs to be visible
  without opening anything, and a remembered "yes" means a laptop carried to a
  café starts advertising itself without anybody deciding to.
- **Neither tablet's discovery can be proved by a test.** All five platforms
  find hosts by themselves now — the desktops and Android over a multicast
  socket Open Audio Analyzer owns, iPadOS through the system's Bonjour
  responder, because Apple does not let an app hold that socket without an
  entitlement it grants per developer on request. Android holds a
  `WifiManager.MulticastLock` while it searches, without which its Wi-Fi driver
  discards every answer below the socket and says nothing about it. What no
  suite can cover is whether the packets arrive: an Android emulator sits behind
  NAT that does not carry the LAN's multicast, an iOS simulator is exempt from
  the restriction the device enforces, and a `flutter test` on macOS is refused
  the local network for reasons that have nothing to do with the code. Both
  tablet paths are checked by hand on hardware. What each end can do is say when
  it is not working, which is the whole difference between a feature that is off
  and one that is broken. Typing an address is supported everywhere and always
  will be, because multicast is also the first thing a guest network blocks —
  and so, now, is pointing the tablet's camera at a code on the desktop's
  screen. That route needs a camera: Android, iPadOS and macOS have one through
  `mobile_scanner`, and on Windows and Linux the row is absent rather than
  present and refusing.
- **A remote display shows every tab, not a chosen one.** `TabSpec` carries a
  `displayTargetId` and nothing honours it yet: assigning tabs to a screen means
  the host has to tell two displays apart, and in a protocol where the display
  says nothing at all, it cannot. Either the display identifies itself — a
  client→host frame, which the display port lacks by policy rather than by
  limitation — or the host keys assignments by address, which breaks on DHCP.
  Until then the display shows the whole preset and the viewer picks the tab.
- **Tablets are display-first.** FFI works fine on iPadOS and Android, but
  audio *input* selection differs sharply per platform. The tablet build's
  primary role is the remote display.
- **Flutter cannot be a plugin GUI.** The plugin is a headless C++ wrapper
  around the same `liboaa`, streaming measurements and DAW transport to the app
  over a local socket. It ships as **VST3 and Audio Unit**, the two formats that
  reach every DAW people actually master in.
- **The AAX is built but not PACE-signed**, so a released Pro Tools will not
  load it. The SDK stopped being the obstacle — Avid offers it under GPLv3 and
  JUCE vendors it — but a bundle still needs a signature made against an Avid
  developer account holding a signing certificate, and until there is one the
  `.aaxplugin` ships in the release archive rather than in an installer. See
  **In a DAW** above.
- **A light skin does not lighten the window frame on Windows or Linux.**
  Everything Open Audio Analyzer paints follows the skin; the window frame
  belongs to the operating system, and Flutter has no supported desktop API for
  it. macOS no longer has a title bar at all, but that took platform code in the
  runner, and the other two each need their own.
- **Native assets are young.** Recommended since Flutter 3.38, but the
  fallback if a platform misbehaves is the legacy `plugin_ffi` template plus
  CMake.

---

## 🤝 Contributing

Read [CLAUDE.md](CLAUDE.md) first — it is short, and it is where the rules that
are not obvious from the code live. Each directory has an `AGENTS.md` explaining
what belongs in it and why.

The house style for comments is *why, not what*, usually naming the failure mode
that forced the design. If a comment could be deleted without losing
information, delete it.

## 📜 License

GPL-3.0-or-later, except `plugin/`, which is AGPL-3.0-or-later because it links
JUCE. Copyright © 2026 Jonas Grunau. See [Licensing](#-licensing) above and the
`LICENSE` file in each tier.

---

<div align="center">

<img src="assets/brand/oaa-icon.png" alt="" width="44" height="44">

<p><sub><a href="https://open-audio-analyzer.com/docs">open-audio-analyzer.com/docs</a></sub></p>

</div>
