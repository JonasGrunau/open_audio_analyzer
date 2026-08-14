# Changelog

All notable changes to Bel are recorded here. The format is defined in
[CLAUDE.md](CLAUDE.md#changelogmd-format); the short version is that
**📐 Measurement always comes first**, because a change to a reported number can
invalidate a decision somebody already made about a master.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-08-15

First release. The architecture is proven end to end and the app runs; most
meters do not exist yet. See the [roadmap](README.md#roadmap).

### 📐 Measurement

- Peak, peak max, RMS, crest factor, inter-channel correlation and stereo
  balance are measured. Peak uses a 1.5 s hold and a 20 dB/s fall; RMS is
  smoothed with a 300 ms time constant.
- **Every loudness quantity is unmeasured and reads as a dash** — LUFS-M,
  LUFS-S, LUFS-I, LRA, true peak, TP max, DR-S, DR-I, PLR and PSR. They are
  `NaN` behind `BEL_FLAG_LOUDNESS_UNAVAILABLE`, never a zero that looks like a
  reading. K-weighting, R128 gating, LRA and true-peak oversampling arrive in
  the same release as the EBU conformance vectors that prove them.
- Bel does not implement Decibel's proprietary `TrueDyn` and will not
  approximate it. `DR-S` and `DR-I` are defined in [docs/METRICS.md](docs/METRICS.md)
  instead, reproducibly.
- All dB readings clamp to a −144.0 floor rather than negative infinity, so that
  differences between them stay finite.

### ✨ Added

- A C11 measurement engine with a lock-free snapshot, published by a dedicated
  analysis thread and read once per frame over FFI with no allocation.
- A built-in 1 kHz test signal, so the engine is measurable on a machine with no
  audio hardware.
- The Precision Instrument design system: one spacing scale, one border weight,
  no shadows, tabular figures on every number.
- A domain model with a 24-column grid layout, delivery-target calibrations for
  streaming, podcast, EBU R 128, ATSC A/85 and CD, and forward-compatible preset
  serialisation that skips module kinds a build does not have.
- Number Box module and the application shell.

### 🚧 Internal

- Native code builds through a Dart build hook on all five platforms. There is
  no `CMakeLists.txt`, podspec or `build.gradle` for it anywhere.
- POSIX feature-test macros are declared in the build hook. Without them
  `-std=c11` hides `clock_gettime` and `nanosleep`, which built cleanly on the
  development machine and failed on both POSIX CI runners.
- CI runs analysis, formatting, and the domain, widget and engine suites, with
  the engine built on Linux, macOS and Windows.
- Licensing is split: MIT for `engine/`, `bel_engine` and `bel_core`;
  GPL-3.0-or-later for the application, UI, CLI and plugin.

[unreleased]: https://github.com/JonasGrunau/open_music_analyzer/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/JonasGrunau/open_music_analyzer/releases/tag/v0.1.0
