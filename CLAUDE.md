<!-- Generated: 2026-08-15 | Updated: 2026-08-15 -->

# Bel

## Purpose

A free and open-source loudness and spectrum analyzer for desktop and tablets —
a modular canvas of meter modules, driven by presets, delivery targets and
skins. A free reimplementation of the ideas in
[Decibel](https://process.audio/products/decibel) by process.audio.

`README.md` is the real design document: the architecture, the DSP spec table,
the licensing split and the honest list of gaps. Read it before changing
anything non-trivial. `docs/PLAN.md` is the full phased plan.

**Currently Phase 0.** The architecture is proven end to end and the app runs.
Loudness is not measured yet and the UI says so.

## Key Files

| File | Description |
|------|-------------|
| `engine/include/bel/bel.h` | The entire public C ABI. One header, three consumers. If it is not declared here it is not part of the engine. |
| `lib/src/clock/meter_clock.dart` | The only `Ticker` in the app. Everything repaints from it. |
| `packages/bel_engine/hook/build.dart` | Compiles `engine/` and bundles it as a code asset. The only native build description in the repo. |
| `packages/bel_ui/lib/src/tokens.dart` | `Space`, `BelRadius`, `BelStroke`, `BelColors`, `BelType`. Nothing outside this file invents a spatial or colour value. |
| `packages/bel_core/lib/src/layout.dart` | `ModuleSpec` / `TabSpec` / `PresetSpec` — the serialised layout model. |
| `packages/bel_core/lib/src/grid.dart` | Every rule about where a module may go, as pure functions. No pixels. |
| `lib/src/canvas/grid_canvas.dart` | The canvas: drag, resize, selection, the preview overlay. |
| `lib/src/canvas/workspace.dart` | The one path every layout edit takes, and the undo history. |
| `.tool-versions` | Pins Flutter `3.44.5-stable`. CI pins the same; keep them in step. |

## Subdirectories

| Directory | Purpose | License |
|-----------|---------|---------|
| `engine/` | C11 DSP core. No Dart, no Flutter. | MIT |
| `packages/bel_engine/` | FFI bindings and the build hook. | MIT |
| `packages/bel_core/` | Domain model. Pure Dart. | MIT |
| `packages/bel_ui/` | Design tokens and shared primitives. | GPL-3.0-or-later |
| `lib/` | The application. | GPL-3.0-or-later |
| `docs/` | `PLAN.md`, `METRICS.md`. | |

## For AI Agents

### Working In This Directory

- **Never invent a measurement.** A quantity the engine does not compute is
  `NaN` and carries a `BEL_FLAG_*_UNAVAILABLE` flag; the UI renders an em dash.
  Zero is *not* a placeholder — it is a legitimate reading for correlation,
  balance and several dB quantities. If you are tempted to return 0.0 so
  something "looks right", you are about to ship a number nobody measured, and
  a metering tool that does that is worthless.

- **Loudness ships with its conformance test or it does not ship.** K-weighting,
  R128 gating, LRA and true-peak land in the *same change* as the EBU
  R128 / BS.2217 vector suite that proves them. Not the next PR. A loudness
  meter that has never been run against the reference vectors is a number
  generator.

- **Nothing allocates on the frame path.** One FFI call per frame
  (`bel_snapshot_acquire`), then painters read `Float32List` views built once at
  startup. Specifically, do not:
  - create a `Paint`, `Path`, `TextPainter` or list inside `paint()`;
  - route measurements through Riverpod, a `Stream`, or a `ValueNotifier` that
    widgets rebuild from;
  - give a module its own `Ticker` — there is exactly one, and independent
    tickers drift so that two meters can disagree within a frame;
  - lay out a `ui.Paragraph` when the formatted string has not changed.

- **`engine/` must not learn about Flutter, and `bel_core` must not learn about
  `dart:ffi`.** Four consumers need the domain vocabulary and three of them have
  no engine — the tablet display reads measurements off a socket. The moment
  `bel_core` imports `bel_engine`, all three drag in a native library they never
  call. `lib/src/data/metric_reader.dart` is the *only* place the two meet.

- **`bel_engine` is not publishable.** `hook/build.dart` reaches out to
  `../../engine` with relative paths, which no published archive would contain.
  It is a workspace package and must stay one.

- **Every spatial value comes from `Space`.** No `EdgeInsets.all(11)`, no
  `SizedBox(height: 20)`. Twelve modules written over as many weeks drift apart
  one raw number at a time. Same for colour: use `BelColors`, never a literal.

- **Every number on screen is monospaced with tabular figures.** `BelType`
  already does this. A readout whose digits change width jitters while you watch
  it.

- **Painted chrome absorbs pointer events unless you stop it.** A
  `CustomPaint` swallows every hit that lands on it, because
  `CustomPainter.hitTest` returns null and `RenderCustomPaint` reads that as
  true; `RenderDecoratedBox` does the same by asking the decoration, and a
  `BoxDecoration` says yes everywhere inside its shape; `RenderParagraph` says
  yes too. The canvas puts a module's drag and selection layers *behind* the
  module, so any of the three makes meters unclickable and undraggable with no
  error anywhere. Module painters extend `MeterPainter`, and inert chrome is
  painted rather than decorated. This cost real debugging time; see the header
  of `packages/bel_ui/lib/src/module_frame.dart`.

- **A `BoxDecoration` may not combine `borderRadius` with a non-uniform
  `Border`.** Flutter asserts, the decoration paint aborts, and it silently
  takes the child with it — a correctly sized box containing nothing. Use a
  sibling strip inside a `ClipRRect` instead. This cost real debugging time; see
  `_Notice` in `lib/src/app/bel_app.dart`.

- **`toImageSync()` persistence layers hold GPU textures.** The spectrogram,
  phase scope, stereo cloud and histogram all keep one. Dispose on resize and
  teardown or leak VRAM.

- **Bump `BEL_ABI_VERSION` when `bel.h` changes shape,** and regenerate the
  bindings (`cd packages/bel_engine && dart run ffigen --config ffigen.yaml`).
  The Dart side asserts the version at startup, because a stale library does not
  crash — it reads a reordered struct and displays plausible wrong numbers.

### CHANGELOG.md Format

`CHANGELOG.md` is written for the person deciding whether to update, not for
the person who wrote the code. Based on Keep a Changelog with one addition that
matters more here than anywhere else — see 📐 below.

**Structure.** Newest first. `## [Unreleased]` always sits at the top, even when
empty. Versions are `## [0.2.0] — 2026-09-01`, semver, em dash, ISO date. Link
definitions go at the bottom. **A released section is never rewritten** — if it
was wrong, correct it in the next release and say so.

**Sections**, in this exact order. Omit any that is empty; never reorder them,
because readers learn the shape and scan by position.

| | Section | Contents |
|---|---|---|
| 📐 | `Measurement` | Anything that changes a number Bel reports. |
| ✨ | `Added` | New capability that was not there before. |
| ⚡ | `Changed` | Existing behaviour that works differently now. |
| 🐛 | `Fixed` | A defect that is no longer there. |
| 🔥 | `Removed` | Capability that is gone. Deprecations go under `Changed` with the removal version named. |
| 🔒 | `Security` | Anything with a security consequence. |
| 🚧 | `Internal` | Refactors, build, CI, docs. Last, because most readers stop before it. |

**📐 Measurement comes first, and it is not optional.** Users make delivery
decisions from these numbers. If a reading changes — a corrected filter
coefficient, a different gating threshold, a fixed rounding — somebody's
previous master was measured with the old one. Every entry states **the old
behaviour, the new behaviour, and the magnitude**, and says whether a re-measure
is warranted. "Fixed LRA calculation" is not an acceptable entry. This section
also records a metric moving from unavailable to measured.

**Entries.** One line each, starting with a capital and ending with a full stop.
Describe the effect on the user, not the diff. Reference at the end: `(#42)`.
Emoji appear **only in section headings** — never inside an entry, never in a
heading twice, never anywhere else in the file.

```markdown
## [Unreleased]

## [0.2.0] — 2026-09-01

### 📐 Measurement
- LUFS-I, LUFS-M, LUFS-S and LRA are now measured; they previously read as a
  dash. Verified against the EBU R128 conformance vectors to within 0.1 LU. (#31)
- True peak now uses 4× oversampling per BS.1770-4 Annex 2 instead of sample
  peak. Readings rise by up to 1.5 dB on limited material, and a master that
  previously passed a −1 dBTP ceiling may now fail it. Re-measure before
  delivery. (#33)

### ✨ Added
- Audio device capture on macOS, Windows and Linux. (#28)

### ⚡ Changed
- The meter refresh rate defaults to 60 fps and is settable to 30 or 120. (#35)

### 🐛 Fixed
- The elapsed clock no longer resets when a device changes sample rate. (#39)

### 🚧 Internal
- The engine's POSIX feature-test macros are declared in the build hook. (#26)

[unreleased]: https://github.com/JonasGrunau/open_music_analyzer/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/JonasGrunau/open_music_analyzer/compare/v0.1.0...v0.2.0
```

### Testing Requirements

```sh
flutter analyze                       # whole workspace, must be clean
flutter test                          # widget and golden tests
dart test packages/bel_core           # domain, no toolchain needed
cd packages/bel_engine && dart test   # engine, through FFI
```

All four are the CI gate. The engine tests hold the meters against arithmetic:
a sine of amplitude *A* peaks at *A* and has an RMS of *A*/√2, exactly 3.0103 dB
lower. If those drift, the meters are wrong — not the tone.

### Common Patterns

- Long file-header comments stating *why*, usually naming the failure mode that
  forced the design. Match that register. If a comment could be deleted without
  losing information, delete it.
- C: C11, `bel_` prefix on everything exported, no globals, no allocation
  outside `bel_engine_create`.
- Dart: sealed classes with exhaustive `switch` where it fits; Riverpod for
  configuration only; `CustomPainter(repaint:)` for anything that shows a
  measurement.
- Modules are `ModuleFrame` + a painter. A module that owns its own border is a
  module that will drift from the other eleven.

## Dependencies

### Internal

`lib/` → `bel_ui` → `bel_core`; `lib/` → `bel_engine` → `engine/`.
`bel_core` depends on nothing.

### External

- **App:** `flutter_riverpod` only.
- **Engine:** nothing yet. Phase 1 adds `miniaudio` and `pffft`, Phase 5
  `dr_libs` — all vendored under `engine/third_party/`, all permissive.
- **Build:** `native_toolchain_c`, `hooks`, `code_assets`, `ffigen`.
