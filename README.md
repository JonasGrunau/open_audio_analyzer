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

> **Status: Phase 2 complete.** Bel measures real audio from a real device, and
> the canvas is arrangeable: add, move, resize, duplicate, delete, tabs, undo.
> Loudness — momentary, short-term, integrated, LRA and true peak — is verified
> against the EBU Tech 3341/3342 cases on Linux, macOS and Windows on every
> push. **One of the twelve modules exists so far**; the other eleven can be
> placed and say `NOT BUILT YET` where their meter will go. That is next. See
> [Roadmap](#roadmap), and [docs/PLAN.md](docs/PLAN.md) for the full plan.
>
> Layouts are not saved yet — a rearranged canvas is gone when the app closes.
> Persistence is Phase 4, and a half-written autosave now would only produce a
> file format Phase 4 has to migrate.

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
| LRA | Gated at −20 LU relative, 10th–95th percentile, via a 0.01 LU-bin histogram storing exact energy sums (O(1) per update, constant memory) |
| True peak | BS.1770-4 Annex 2, 4× oversampling with the specified 48-tap polyphase FIR, at every sample rate |
| Spectrum | Hann window, 1024–8192 points, log-frequency mapping with **peak-per-bin** so narrow peaks survive |
| Correlation | Running Pearson over a sliding window |

Every one of these is measured today and checked in CI. The spectrum is not —
those bands stay at the floor behind a flag, and the analyser module that draws
them lands with the FFT.

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
UI renders it as an em dash. Today that means the spectrum, and it also means
any reading that is not yet *defined*: momentary loudness needs 400 ms of
signal, short-term needs 3 s, and integrated needs one gating block above the
absolute gate. Each shows a dash until it means something.

### The correctness gate

CI runs the **EBU Tech 3341 and 3342** cases on Linux, macOS and Windows on
every push, and fails the build if any reading is outside the standard's stated
tolerance. A loudness meter that has never been run against the reference cases
is a number generator.

The signals are **generated, not downloaded** — every case is a sine at a stated
level or a sequence of them, so the suite needs no fixtures, no network and no
WAV decoder, and each expected value is derived from the standard in a comment
rather than copied from somebody's output. Two extra properties are asserted
that the standard does not state but no correct implementation can violate:

- **Sample rate independence** — the same tone reads the same at 44.1, 48, 88.2,
  96 and 192 kHz. This catches the tempting shortcut of using the 48 kHz
  coefficient table BS.1770-4 prints instead of designing the filter at the
  stream's rate: it passes every 48 kHz test there is, and is wrong by a
  fraction of a dB on the most common delivery rate in music.
- **Block size independence** — ten seconds pushed in one call, in 512-frame
  device blocks, and in 377-frame chunks agree to 0.001 LU.

Phase 5 adds the official BS.2217 WAV vectors as an independent second check.

---

## Layout

Bel's canvas is a **24-column snapping grid** rather than Decibel's free pixel
positioning. 24 divides by 2, 3, 4, 6, 8 and 12, so halves, thirds and quarters
are all exact — a 12-column grid cannot express thirds and quarters at once,
which is the first thing anybody wants when arranging meters.

**The row count is fixed too, at 16.** The obvious alternative — square cells
and a canvas that scrolls — keeps module aspect ratios identical everywhere, and
is wrong: on a 32" display a cell becomes 160 px, a six-row meter becomes 960 px
tall, and a layout built on a laptop now needs scrolling. A meter bridge you
have to scroll is not a meter bridge. So both axes are fixed and cells are
whatever shape the window makes them, which costs nothing because every painter
has to handle arbitrary aspect anyway — nothing stops you resizing a phase scope
to 8×2.

The practical win is that a preset stores grid cells, so it is
screen-independent by construction. Decibel stores fractions of the window and
reconstitutes them per display; Bel opens the same layout on a 32" monitor and
an 11" tablet with nobody writing responsive code.

The interactions: **drag the title bar** to move, **drag the corner grip** to
resize, **alt-drag** to duplicate, **right-click or double-click empty canvas**
to add a module there, **right-click a module** for its options, `⌫` to delete,
`⌘Z` / `⌘⇧Z` to undo and redo, and `1`–`9` to switch tabs. Buttons for add, undo
and redo sit in the tab strip as well, because tablets have neither a right
mouse button nor `⌘Z`.

**Modules do not overlap, and a drop that would overlap is refused.** The two
alternatives are worse: allowing overlap turns a meter bridge into a stack of
half-hidden panels and needs a z-order, and pushing neighbours aside — what most
dashboard grids do — means a drag near an edge can rearrange a layout you spent
ten minutes on, irreversibly. Bel shows the target cells while the pointer is
down, in the accent colour when the drop is legal and in red when it is not, and
an illegal drop simply does not happen. Nothing moves that you did not move.

A module resized below its minimum shows `TOO SMALL` instead of an unreadable
smear — a spectrum analyser in two cells is not a small spectrum analyser. A
module kind that has no painter yet says `NOT BUILT YET` rather than showing an
empty panel, which would read as a meter that is broken.

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

**Inter** (labels and prose) and **JetBrains Mono** (every number) are bundled
rather than requested from the system, in the three and two weights the type
scale actually names. Falling through to the platform's own faces means digit
width, tracking and cap height all differ between macOS, Windows and Linux, and
a layout tuned on one is subtly wrong on the other two. Both are SIL OFL 1.1 and
their licences ship in `assets/fonts/`.

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
assets/fonts/      Inter and JetBrains Mono, with their licences.        SIL OFL
cli/               `bel analyze file.wav --json`            (Phase 5)        GPL
plugin/            Headless VST3 + AU plugin                (Phase 7)        GPL
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
| 1 | K-weighting, M/S/I, LRA, true peak, **EBU conformance in CI**, device capture | ✅ done |
| 2 | The 24×16 canvas: add, move, resize, duplicate, tabs, undo; bundled type | ✅ done |
| 3 | The twelve modules | next |
| 4 | Presets, calibrations, skins, audio settings, persistence | |
| 5 | Offline file analysis, report panel, exports, `bel` CLI | |
| 6 | Remote display: mDNS discovery, wire protocol, tablet mode | |
| 7 | VST3 and Audio Unit plugin, DAW transport and timecode | |
| 8 | Keyboard shortcuts, docs, packaging (dmg / msix / AppImage / flatpak) | |

### Known gaps, stated plainly

- **Capturing your own system's output needs a virtual device on macOS and
  Linux.** This is the biggest gap versus Decibel, which ships a signed
  monitoring driver.
  - **Windows** — nothing to do. WASAPI loopback captures whatever is playing.
  - **macOS** — install [BlackHole](https://existential.audio/blackhole/) (free)
    or Loopback, route your output through it, and it appears in Bel's source
    menu like any other input. ScreenCaptureKit is a later evaluation.
  - **Linux** — a PulseAudio or PipeWire monitor source already appears in the
    list.

  Metering a hardware input needs none of this — any interface shows up
  directly.
- **Tablets are display-first.** FFI works fine on iPadOS and Android, but audio
  *input* selection differs sharply per platform. The tablet build's primary
  role is the Phase 6 remote display.
- **Flutter cannot be a VST3/AU plugin GUI.** The plugin is a headless C++
  wrapper around the same `libbel`, streaming measurements and DAW transport to
  the app over a local socket. It ships as **VST3 and Audio Unit** — the two
  formats that reach every DAW people actually master in, Ableton Live
  included. AAX is out of scope: it needs Avid's SDK and a registered developer
  account, neither of which a free project can promise.
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
