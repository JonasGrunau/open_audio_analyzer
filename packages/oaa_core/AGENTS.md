# packages/oaa_core/

The domain model. Pure Dart: **no Flutter, no `dart:ffi`, no I/O, no
dependencies at all.** See `packages/AGENTS.md` for why that is enforced rather
than aspired to.

| File | Contents |
|------|----------|
| `src/metric.dart` | `Metric` — the closed set of sixteen things that can be measured. |
| `src/meter_source.dart` | `MeterSource` — everything a module is allowed to read, measurements and the DAW's playhead. `OaaEngine` implements it over native memory and `WireSnapshot` over a socket, and the fourteen modules cannot tell them apart. One member is not a measurement and is easy to skip past: `scopeFrames` says how much of `scope` is this frame's, because a wire may carry several analysis blocks in one snapshot and reading `scope.length` instead is what made a remote oscilloscope refuse to draw. |
| `src/calibration.dart` | `Calibration`, the six built-in delivery targets, and `mergeCalibrations` — the one implementation of "a user file with a built-in's id replaces it", shared by the app's library and the CLI's. |
| `src/config_locations.dart` | Where the configuration directory is, on each platform, and `slugify`. Pure functions of an environment map and — on the two platforms whose environment answers nothing — of the temporary directory on iOS and of `getFilesDir()` on Android, both passed in. No `dart:io`. Here rather than in the app because the CLI reads the same targets and cannot import the app. |
| `src/layout.dart` | `GridRect`, `ModuleKind`, `ModuleSpec`, `TabSpec`, `PresetSpec`, and the typed readings of `ModuleSpec.options` — `SpectrumResponse`, `SpectrumTilt`, `HistogramSmoothing`, `ScopeTimeBase`, `ScopeSync`, `ScopeDivision`, `ScopeGrid`, `ScopeStereo`, `ScopeZoom`. |
| `src/grid.dart` | Every rule about where a module may go, as pure functions over `TabSpec`. No pixels, no widgets — so the same rules hold for the canvas, for a preset loaded from disk and for the remote display. |
| `src/settings.dart` | `AppSettings`, `AudioSourceKind`, and the schema version every file Open Audio Analyzer writes carries. |
| `src/skin.dart` | `Skin` and the thirteen colour roles, as integers. The adapter to `OaaColors` is `oaa_ui`'s. |
| `src/report.dart` | `AnalysisReport` and the delivery verdict. Holds no engine handle, so it serialises to JSON and rides the wire; there is deliberately no reader. |
| `src/report_export.dart` | The same report as text, JSON and CSV. |
| `src/transport.dart` | The DAW's transport position, with a presence bit per field. |

## Rules

- **Stable string ids, declared explicitly.** `Metric.id`, `ModuleKind.id` and
  `Calibration.id` appear in saved presets, exported reports and the wire
  protocol. A Dart rename must not invalidate every file on a user's disk. Add
  a new value; never repurpose an old id.
- **A cell count is not a size.** `ModuleKind` declares its minimum twice on
  purpose: `minColumns`/`minRows` bound what a layout may ask for, and
  `minBodyWidth`/`minBodyHeight` bound what a painter can actually draw in. The
  canvas is 24x16 cells at every window size, so the same legal two-row module
  is 160 px tall on a 27" display and 40 px on a small window. Only the second
  pair can catch that, and without it a painter declines to draw and the user
  gets an empty panel with a title bar. `test/scaling_test.dart` holds both.
- **Unknown data is skipped, not fatal.** `ModuleSpec.fromJson` returns null for
  a module kind this build does not have, and the tab loads without it. A
  preset written by a newer version must not be unopenable.
- **`options` stays an untyped map.** A sealed hierarchy across fourteen modules
  would buy type safety in one place and make forward compatibility impossible.
- **Targets are data.** `BuiltInCalibrations` is compiled in only because the
  set has to start somewhere; the loader treats it exactly like a JSON file a
  user dropped in their config directory.
- **NaN is not a pass.** Predicates like `meetsLoudnessTarget` return false for
  an unmeasured value rather than guessing.
