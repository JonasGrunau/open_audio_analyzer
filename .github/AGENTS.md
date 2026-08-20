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

- **`checks`** runs `flutter analyze`, `dart format`, the `oaa_core` domain
  tests, the `oaa_wire` protocol tests, `plugin/test/sources_match.sh` and then
  the widget tests. The first four need **no C toolchain** — `oaa_core` and
  `oaa_wire` depend on nothing, and the source-list check is a shell script — so
  they run first and a regression in any of them is diagnosed without waiting on
  a native build. The widget tests do compile the engine, because the app
  depends on `oaa_engine`.
- **`engine`** compiles the C through the build hook and runs the meters, the
  EBU Tech 3341/3342 conformance cases and then the `oaa` CLI on Linux, macOS
  and Windows. It needs no audio hardware — that is what the built-in test tone
  is for. The CLI runs on all three because **file decoding is where the
  platforms differ most**: Windows takes a UTF-16 path, so a filename with an
  umlaut in it fails there and nowhere else. It then **builds** the CLI with
  `dart build cli` and runs what it built. The tests invoke it with `dart run`,
  so nothing here would have noticed that the release's build command had
  stopped working — and nothing did: `dart compile exe` refuses a package whose
  dependencies have build hooks, and all three CLI jobs failed on the first tag
  that ever ran `release.yml`.

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
  with this file. `dart test packages/oaa_wire` and `sources_match.sh` were both
  documented as gates for a phase before either was actually wired in.
- **A release's notes are its own changelog section, found by version.** The
  publish step reads `## [<tag without the v>]` out of `CHANGELOG.md` and fails
  when that section is missing or blank. It used to take the *first* section
  instead, which on a release commit is `## [Unreleased]` — empty by
  construction — so the release would have carried no notes and no step would
  have gone red. Cutting a tag therefore means moving `[Unreleased]`'s contents
  under a numbered heading in the same commit.
- **An installer that cannot be installed is published, and labelled.** Signing
  needs secrets a fork does not have, so every packaging script produces an
  unsigned artefact and says so rather than failing. A release job that quietly
  published something a user cannot install would be worse than one that failed;
  a fork that could not build at all would be worse than both.
