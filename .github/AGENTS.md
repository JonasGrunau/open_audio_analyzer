# .github/

`workflows/ci.yml` is the gate. Nothing merges red.

The two jobs are split by what they need, and the split is deliberate:

- **`checks`** runs `flutter analyze`, `dart format`, the `bel_core` domain
  tests and the widget tests — with **no C toolchain**. That is only possible
  because `bel_core` depends on nothing and the widget tests never touch the
  engine. Keeping this job toolchain-free is how the package boundary described
  in `packages/AGENTS.md` stays honest: the day it needs a compiler, something
  has reached across a boundary it should not have.
- **`engine`** compiles the C through the build hook and runs the meters on
  Linux, macOS and Windows. It needs no audio hardware — that is what the
  built-in test tone is for.

## Rules

- **`FLUTTER_VERSION` must match `.tool-versions`.** CI that passes on a
  different Flutter than everybody develops against is worse than no CI.
- **Phase 1 adds the EBU R128 / BS.2217 conformance run to the `engine` job,**
  in the same change that adds the loudness code. A red conformance run blocks
  the release. See `docs/METRICS.md`.
- **Never add `continue-on-error` to a test step.** A test that is allowed to
  fail is a test that has already been deleted, just more slowly.
