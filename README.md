# Bel

A free and open-source loudness and spectrum analyzer, for desktop and tablets.

Bel is a modular metering suite: a canvas of resizable meter modules — loudness,
true peak, VU, spectrum, spectrogram, phase scope, histogram — organised into
tabs, driven by presets, delivery targets and skins, with offline file analysis
and a companion display that mirrors a tab to a tablet over Wi-Fi.

It is a free reimplementation of the ideas in
[Decibel](https://process.audio/products/decibel) by process.audio, whose
modular canvas is the best interaction model anybody has found for this problem.
The measurement work, the architecture and the visual language are our own, and
where Bel cannot honestly match Decibel it says so rather than approximating.

> **Status: Phase 0.** The architecture is proven end to end — native engine,
> zero-copy snapshot, ticker-driven painting — and the app runs. Loudness is
> **not measured yet**; those readouts show a dash. See
> [Roadmap](#roadmap) for what lands when, and [docs/PLAN.md](docs/PLAN.md) for
> the full plan.

---

## Why it is built this way

A meter that stutters is not a meter. Everything below follows from one rule:

> **Measurements never cross an isolate boundary, never allocate per frame, and
> never rebuild a widget.**

Three tiers, and the boundary between each is deliberate:

| Tier | Thread | Job |
|---|---|---|
| **Capture** | audio callback, realtime-safe | Copy input into a lock-free ring. No malloc, no locks, no syscalls. |
| **Analysis** | dedicated, high priority | Run the DSP graph. Publish results into a seqlock-protected snapshot. |
| **Display** | Flutter UI thread | One FFI call per frame, then paint. |

### The per-frame path

Once per frame, [`MeterClock`](lib/src/clock/meter_clock.dart) makes a single
`@Native(isLeaf: true)` call to `bel_snapshot_acquire` — an atomic load, a
memcpy, and a second atomic load, with no VM state transition. Then every
painter reads `Float32List` views that were **built once at startup** over
native memory that never moves.

The widget tree is not involved at any point. Painters are constructed with
`CustomPainter(repaint: clock)`, which re-rasters them *without rebuilding the
widget*. A frame costs one FFI call plus N `paint()` calls, and allocates
nothing.

Three consequences worth naming, because they are what usually goes wrong:

- **One clock, not twelve.** Independent tickers drift, and two meters showing
  the same quantity could then disagree within a single frame. On a measurement
  tool that is a correctness bug, not a cosmetic one.
- **Text is cached by formatted string.** A value changes continuously; the
  string rounded to one decimal changes about ten times a second. Laying out a
  `ui.Paragraph` on the other fifty frames is pure waste, so
  [`ReadoutPainter`](packages/bel_ui/lib/src/readout.dart) rebuilds only when
  the string actually differs.
- **The reader retries, never the writer.** The snapshot is a seqlock precisely
  because it is wait-free for the analysis thread. A mutex would let a
  descheduled UI thread stall the thread that must never stall — and when that
  thread falls behind, the ring overruns and signal is lost for good.

### Rendering, per module

| Module | Technique |
|---|---|
| Number box, LUFS, Alert, Validator | Cached `ui.Paragraph`, rebuilt on string change only |
| Digital meter | Batched `drawRect`, one reused `Paint` |
| VU meter | Dial face pre-rendered once to a `ui.Image`; only the needle repaints |
| Spectrum analyzer | `drawRawPoints` over the native `Float32List` — C writes screen-space x,y directly |
| Phase scope | `drawRawPoints` onto a `toImageSync()` afterglow layer, GPU-side, no readback |
| Stereo cloud | `drawVertices(Vertices.raw(...))` — positions and colors pass straight through |
| Spectrogram | Persistent scroll target: blit the previous image offset by N px, add one column |
| Histogram | Committed `ui.Image` for the tail + live head. 4 h at 10 Hz is 144k points; never re-path them all |

---

## Measurement

Correctness is the entire product, so every metric is pinned to a published
spec rather than to intuition.

| Quantity | Definition |
|---|---|
| K-weighting | ITU-R BS.1770-4 stage-1 shelf + stage-2 RLB, coefficients computed from the analog prototype **at the actual sample rate** — not hardcoded 48 kHz tables |
| Gating | EBU R128: 400 ms blocks at 75% overlap, absolute gate −70 LUFS, relative gate −10 LU |
| Momentary / Short-term | 400 ms / 3 s |
| LRA | Gated at −20 LU relative, 10th–95th percentile, via a 0.1 LU-bin histogram (O(1) per update) |
| True peak | BS.1770-4 Annex 2, 4× oversampling with the specified 48-tap polyphase FIR; 2× at ≥96 kHz |
| Spectrum | Hann window, 1024–8192 points, log-frequency mapping with **peak-per-bin** so narrow peaks survive |
| Correlation | Running Pearson over a sliding window |

### On dynamics, and on honesty

Decibel reports a dynamics figure called *TrueDyn*. It is proprietary and
undocumented, so any claim to match it would be a guess presented as a
measurement. Bel does not implement it.

Instead Bel reports `DR-S` and `DR-I`, defined as `TruePeak − LUFS-S` and
`TruePeakMax − LUFS-I`, published in [docs/METRICS.md](docs/METRICS.md) and
reproducible from the definition by anybody who wants to check.

The same principle runs through the code. A quantity this build does not
measure is **NaN**, never zero — zero is a legitimate reading for correlation,
balance and several dB quantities, so it cannot double as "no data" — and the
UI renders it as an em dash. Today that means every loudness readout, and the
app says so on screen.

### The correctness gate

CI runs the engine against the **EBU R128 / ITU BS.2217 conformance vectors**
and asserts agreement within ±0.1 LU, cross-checked against `libebur128` as an
oracle. This lands in Phase 1, in the same change as the loudness code it
proves — not after it.

A loudness meter that has never been run against the reference vectors is a
number generator. Shipping one would undermine the only thing this project has
to be good at.

---

## Layout

Bel's canvas is a **24-column snapping grid** rather than Decibel's free pixel
positioning. 24 divides by 2, 3, 4, 6, 8 and 12, so halves, thirds and quarters
are all exact — a 12-column grid cannot express thirds and quarters at once,
which is the first thing anybody wants when arranging meters.

The practical win is that a preset stores grid cells, so it is
screen-independent by construction. Decibel stores fractions of the window and
reconstitutes them per display; Bel opens the same layout on a 32" monitor and
an 11" tablet with nobody writing responsive code.

The interactions worth keeping are kept: click empty space to add, shift-click
to fill, alt-drag to duplicate, right-click for options, drag the corner to
resize. A module resized below its minimum shows `TOO SMALL` instead of an
unreadable smear — a spectrum analyser in two cells is not a small spectrum
analyser.

**Presets, Calibrations and Skins** are three independent axes, as in Decibel,
including the `from preset` indirection. Null means *follow the preset*; a
concrete id means the user pinned that choice and browsing presets must leave it
alone. Without that distinction, either presets cannot carry a target or an
explicit choice gets silently overwritten.

Delivery targets ship as **data**, not code — Spotify, Apple Music, YouTube,
Tidal, Amazon, EBU R128, ATSC A/85, podcast, CD — so the set can be corrected
and extended without a release.

---

## Design

**Precision Instrument.** Graphite black, one signal hue, hairline borders, no
shadows and no gradients. Depth comes from background steps, because
measurement gear is machined panels sitting flush, not floating cards.

```
bg      #0B0C0E     accent  #35E0C4   in spec
panel   #121417     warn    #F2B01E
hairline#1F2328     over    #FF4D4D
text    #E6E8EB / #8A9199 / #565E67
```

Two rules are enforced rather than merely encouraged:

1. **Every spatial value comes from `Space`** — `2, 4, 8, 12, 16, 24, 32, 48,
   64`. No widget writes a raw number for padding, margin or gap. Twelve
   modules built over as many weeks drift apart one `EdgeInsets.all(11)` at a
   time, and the result reads as amateur long before anybody can say which
   value is wrong.
2. **Every number is monospaced with tabular figures.** With proportional
   digits a readout's width changes as its digits change, so it jitters while
   you watch it. It is the single most obvious tell of a meter written by
   somebody who does not use meters.

Every one of the twelve modules is [`ModuleFrame`](packages/bel_ui/lib/src/module_frame.dart)
plus a painter. That is the whole reuse strategy: a module that also owns its
own border and title treatment is a module that will drift from the other
eleven.

---

## Repository layout

```
engine/            C11 DSP core. Knows nothing about Dart or Flutter.        MIT
packages/
  bel_engine/      FFI bindings + the build hook that compiles engine/.      MIT
  bel_core/        Domain model. Pure Dart — no Flutter, no dart:ffi.        MIT
  bel_ui/          Design tokens and the primitives modules are built from.  GPL
lib/               The application.                                          GPL
cli/               `bel analyze file.wav --json`            (Phase 5)        GPL
plugin/            Headless CLAP plugin                     (Phase 7)        GPL
```

Two boundaries carry weight:

- **`engine/` knows nothing about Flutter, and `bel_core` knows nothing about
  `dart:ffi`.** Four things need the domain vocabulary — the app, the tablet
  display, the CLI and the plugin — and three of them have no engine of their
  own. The tablet reads measurements off a socket. The moment `bel_core`
  imports `bel_engine`, all three drag in a native library they never call.
- **One `libbel` serves all three tiers.** That is what makes standalone,
  remote display and plugin tractable as one project rather than three.

### Licensing

Deliberately split, and set on day one because it is nearly free now and
expensive once outside contributors arrive:

- **`engine/`, `packages/bel_engine`, `packages/bel_core` — MIT.** A metering
  engine's value is that anyone can embed and audit it, and a measurement tool
  needs that scrutiny more than most software.
- **Everything else — GPL-3.0-or-later.** A free clone of a paid product should
  not be trivially re-closable.

MIT is one-way compatible with GPL, so the combination composes cleanly.

---

## Building

Requires Flutter `3.44.5-stable` (pinned in `.tool-versions`) and a C toolchain
— Xcode command line tools, MSVC, or gcc/clang.

```sh
flutter pub get
flutter run -d macos          # or windows, linux
```

There is **no `CMakeLists.txt`, no podspec and no `build.gradle`** for the
native code. `packages/bel_engine/hook/build.dart` compiles the C through
`native_toolchain_c` and bundles it as a code asset, which has been the
recommended way to ship native code with Flutter since 3.38. One build
description that works on five platforms beats five that each work on one.

### Tests

```sh
flutter analyze                       # lints, whole workspace
flutter test                          # widget and golden tests
dart test packages/bel_core           # domain layer, no toolchain needed
cd packages/bel_engine && dart test   # engine, through FFI
```

The engine tests are worth a look even if you never touch the C. A sine of
amplitude *A* has a peak of *A* and an RMS of *A*/√2 — exactly 3.0103 dB lower.
That is arithmetic, not convention, so the built-in test tone doubles as a
reference the meters can be held against on a headless CI runner with no sound
hardware anywhere near it.

---

## Roadmap

| Phase | | Status |
|---|---|---|
| 0 | Skeleton, engine spike, the render path, design tokens | ✅ done |
| 1 | miniaudio capture, K-weighting, M/S/I, LRA, true peak, **EBU conformance in CI** | next |
| 2 | The 24-column canvas: add, move, resize, duplicate, tabs | |
| 3 | The twelve modules | |
| 4 | Presets, calibrations, skins, audio settings, persistence | |
| 5 | Offline file analysis, report panel, exports, `bel` CLI | |
| 6 | Remote display: mDNS discovery, wire protocol, tablet mode | |
| 7 | CLAP plugin (+ VST3/AU via `clap-wrapper`), DAW transport and timecode | |
| 8 | Keyboard shortcuts, docs, packaging (dmg / msix / AppImage / flatpak) | |

### Known gaps, stated plainly

- **macOS system-audio capture is the biggest gap versus Decibel.** Decibel
  ships its own signed monitoring driver; we realistically cannot early on. v1
  documents BlackHole and similar loopback devices, and ScreenCaptureKit
  (macOS 13+) is evaluated later.
- **Tablets are display-first.** FFI works fine on iPadOS and Android, but audio
  *input* selection differs sharply per platform. The tablet build's primary
  role is the Phase 6 remote display.
- **Flutter cannot be a VST3/AU plugin GUI.** The plugin is a headless C++ CLAP
  wrapper around the same `libbel`, streaming measurements and DAW transport to
  the app. CLAP's SDK is MIT, which is also why it is the primary format rather
  than VST3.
- **Native assets are young.** Recommended since Flutter 3.38, but the fallback
  if a platform misbehaves is the legacy `plugin_ffi` template plus CMake.

---

## Contributing

Read [CLAUDE.md](CLAUDE.md) first — it is short, and it is where the rules that
are not obvious from the code live. Each directory has an `AGENTS.md`
explaining what belongs in it and why.

The house style for comments is *why, not what*, usually naming the failure mode
that forced the design. If a comment could be deleted without losing
information, delete it.

## License

GPL-3.0-or-later for the application; MIT for the engine and domain model. See
[Licensing](#licensing) above and the `LICENSE` file in each tier.
