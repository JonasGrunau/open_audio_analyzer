# .github/

| Workflow | What it answers |
|------|---------|
| `ci.yml` | Is this correct? Runs on every push and pull request. **The gate — nothing merges red.** |
| `docs.yml` | Does the documentation site still build? Publishes it from `main`. |
| `release.yml` | Can somebody install it? Builds the four installers and the CLI on a tag. |

**`docs.yml` and `release.yml` are deliberately not part of `ci.yml`.** Both are
an order of magnitude slower — four release builds, a notarisation round trip to
Apple, a flatpak runtime download — and both answer a question nobody asked on
the commit being pushed. Making the signal everybody waits on slower for them
would be the wrong trade. `release.yml` also runs on demand, because an
installer that is only ever built at release time is one whose script has been
broken for six weeks by the time anybody finds out.

The `ci.yml` jobs are split by what they need, and the split is deliberate:

- **`checks`** runs `flutter analyze`, `dart format`, the `bel_core` domain
  tests, the `bel_wire` protocol tests, `plugin/test/sources_match.sh` and then
  the widget tests. The first four need **no C toolchain** — `bel_core` and
  `bel_wire` depend on nothing, and the source-list check is a shell script — so
  they run first and a regression in any of them is diagnosed without waiting on
  a native build. The widget tests do compile the engine, because the app
  depends on `bel_engine`.
- **`engine`** compiles the C through the build hook and runs the meters, the
  EBU Tech 3341/3342 conformance cases and then the `bel` CLI on Linux, macOS
  and Windows. It needs no audio hardware — that is what the built-in test tone
  is for. The CLI runs on all three because **file decoding is where the
  platforms differ most**: Windows takes a UTF-16 path, so a filename with an
  umlaut in it fails there and nowhere else.

## Rules

- **`FLUTTER_VERSION` must match `.tool-versions`.** CI that passes on a
  different Flutter than everybody develops against is worse than no CI.
- **Keep all three platforms in the `engine` matrix.** The first CI run failed
  on Linux and macOS and passed on Windows, because `-std=c11` hides POSIX
  declarations behind `__STRICT_ANSI__` and MSVC never sees them. Dropping a
  platform to save minutes would have hidden it; a local build had already
  hidden it once.
- **The conformance run is a gate, not a report.** The EBU Tech 3341/3342 cases
  run inside the `engine` job's Dart suite; a red conformance run blocks the
  release, because these are the numbers users deliver against. The official
  BS.2217 WAV vectors are deliberately *not* here — the material is not
  licensed for redistribution and fetching it would put a network dependency in
  front of the one suite that must never be flaky. See `docs/METRICS.md`.
- **Never add `continue-on-error` to a test step.** A test that is allowed to
  fail is a test that has already been deleted, just more slowly.
- **A gate named in a document and missing from `ci.yml` is worse than no
  gate,** because everybody believes it is running. When a suite is added to the
  repository it is added here in the same change, and `CLAUDE.md`'s Testing
  Requirements and `README.md`'s Tests list are the two places that must agree
  with this file. `dart test packages/bel_wire` and `sources_match.sh` were both
  documented as gates for a phase before either was actually wired in.
- **An installer that cannot be installed is published, and labelled.** Signing
  needs secrets a fork does not have, so every packaging script produces an
  unsigned artefact and says so rather than failing. A release job that quietly
  published something a user cannot install would be worse than one that failed;
  a fork that could not build at all would be worse than both.
