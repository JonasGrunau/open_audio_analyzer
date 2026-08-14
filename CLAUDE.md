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
