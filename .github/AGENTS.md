# .github/

`workflows/ci.yml` is the gate. Nothing merges red.

The two jobs are split by what they need, and the split is deliberate:

- **`checks`** runs `flutter analyze`, `dart format`, the `bel_core` domain
  tests and then the widget tests. The domain tests need **no C toolchain** —
  `bel_core` depends on nothing — so they run first and a domain regression is
  diagnosed without waiting on a native build. The widget tests do compile the
  engine, because the app depends on `bel_engine`.
- **`engine`** compiles the C through the build hook and runs the meters on
  Linux, macOS and Windows. It needs no audio hardware — that is what the
  built-in test tone is for.

## Rules

- **`FLUTTER_VERSION` must match `.tool-versions`.** CI that passes on a
  different Flutter than everybody develops against is worse than no CI.
- **Keep all three platforms in the `engine` matrix.** The first CI run failed
  on Linux and macOS and passed on Windows, because `-std=c11` hides POSIX
  declarations behind `__STRICT_ANSI__` and MSVC never sees them. Dropping a
  platform to save minutes would have hidden it; a local build had already
  hidden it once.
- **Phase 1 adds the EBU R128 / BS.2217 conformance run to the `engine` job,**
  in the same change that adds the loudness code. A red conformance run blocks
  the release. See `docs/METRICS.md`.
- **Never add `continue-on-error` to a test step.** A test that is allowed to
  fail is a test that has already been deleted, just more slowly.
