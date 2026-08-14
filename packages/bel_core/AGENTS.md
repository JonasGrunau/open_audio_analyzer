# packages/bel_core/

The domain model. Pure Dart: **no Flutter, no `dart:ffi`, no I/O, no
dependencies at all.** See `packages/AGENTS.md` for why that is enforced rather
than aspired to.

| File | Contents |
|------|----------|
| `src/metric.dart` | `Metric` — the closed set of things that can be measured. |
| `src/calibration.dart` | `Calibration` and the built-in delivery targets. |
| `src/layout.dart` | `GridRect`, `ModuleKind`, `ModuleSpec`, `TabSpec`, `PresetSpec`. |

## Rules

- **Stable string ids, declared explicitly.** `Metric.id`, `ModuleKind.id` and
  `Calibration.id` appear in saved presets, exported reports and the wire
  protocol. A Dart rename must not invalidate every file on a user's disk. Add
  a new value; never repurpose an old id.
- **Unknown data is skipped, not fatal.** `ModuleSpec.fromJson` returns null for
  a module kind this build does not have, and the tab loads without it. A
  preset written by a newer version must not be unopenable.
- **`options` stays an untyped map.** A sealed hierarchy across twelve modules
  would buy type safety in one place and make forward compatibility impossible.
- **Targets are data.** `BuiltInCalibrations` is compiled in only because the
  set has to start somewhere; the loader treats it exactly like a JSON file a
  user dropped in their config directory.
- **NaN is not a pass.** Predicates like `meetsLoudnessTarget` return false for
  an unmeasured value rather than guessing.
