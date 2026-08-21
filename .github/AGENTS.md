# .github/

**`ci.yml` is the only workflow.** One run answers all three questions a push
can raise — is this correct, does the site still build, can somebody install it
— and what runs is decided by the event rather than by which file a job lives
in:

| Event | Jobs |
|---|---|
| pull request | `checks`, `engine`, `docs` |
| push to `main` | the same, plus `pages` |
| `workflow_dispatch` | the same, plus `plugin` and every installer |
| tag `v*` | the same, plus `publish` |

It was three files — `ci.yml`, `docs.yml`, `release.yml` — split on the argument
that packaging is an order of magnitude slower than testing and must not slow
the signal everybody waits on. **That argument was right about the cost and
wrong about the remedy.** What keeps a push fast is not running the packaging
jobs, which is an `if:` condition; the file boundary contributed nothing to it
and took away two things worth more.

It took away the gate. A tag could publish a release from a commit whose tests
were red, because a job in `release.yml` had no way to depend on a job in
`ci.yml`. `publish` now names every test job in `needs`, and the installers name
`checks`.

And it took away any coverage of the packaging paths. `release.yml` ran for the
first time on the v0.2.0 tag, long after it was written, and four of its six
jobs failed on that first execution. Every failure was a command that had never
run in CI. Keep `workflow_dispatch` for that reason: it builds every installer
without publishing, and it is the only thing standing between a packaging script
and six weeks of quiet rot.

The jobs are split by what they need, and that split is deliberate:

- **`checks`** runs `flutter analyze`, `dart format`, the `oaa_core` domain
  tests, the `oaa_wire` protocol tests, `plugin/test/sources_match.sh` and then
  the widget tests. The first four need **no C toolchain** — `oaa_core` and
  `oaa_wire` depend on nothing, and the source-list check is a shell script — so
  they run first and a regression in any of them is diagnosed without waiting on
  a native build. The widget tests do compile the engine, because the app
  depends on `oaa_engine`.
- **`plugin`** is the only thing that compiles `plugin/`, and it runs on a
  release or a manual run, not on a push — three parallel JUCE builds is the
  most expensive thing in the file by an order of magnitude. `sources_match.sh`
  in `checks` compares two text files and never invokes CMake, so before this
  job the VST3 and the AU were built by whoever last did it by hand, with a
  JUCE dependency fetched by tag. AU is macOS-only and
  `plugin/CMakeLists.txt` decides that, not this workflow.

  It also builds `plugin/host/`, the fake DAW, and then runs
  `dart test` in `packages/oaa_wire` a second time — the same suite `checks`
  runs, where the end-to-end cases skip for want of a built binary. Here they
  do not: the host plays a generated signal through the VST3 with no window and
  no sound card, and the Dart codec decodes what arrives on the socket. That is
  the only coverage anywhere of `prepareToPlay`, the FIFO, the playhead, the
  streaming thread and the socket. Linux needs `xvfb-run` because JUCE's
  initialisation wants a display even when the application never opens a
  window; nothing needs audio hardware.

  On Linux it then runs one file of the application's suite,
  `test/plugin_to_display_e2e_test.dart`, which is the same run carried one hop
  further: the app's `PluginLink` accepts the plugin, its `DisplayHost`
  publishes what arrives, and a `DisplayClient` reads it back as a tablet would.
  That join is covered nowhere else — what a display receives is a *re-encode*
  of a snapshot the app decoded, so a field lost in the middle leaves both
  halves' suites green. It is one runner rather than three because the hop is
  Dart over loopback and the same everywhere; it needs Flutter, which the rest
  of this job does not, and it skips in `checks` for want of a built plugin.

  **Know what the gating costs.** `ctest` moves with the job, and that run is
  the producing half of the wire golden: `checks` asserts the committed
  `wire_v2.bin` decodes, and only this job asserts that
  `plugin/src/OaaWire.cpp` still writes it. The end-to-end run moves with it
  too, so between releases the byte-for-byte agreement `docs/WIRE.md` exists to
  guarantee is checked from one side and the live path is not checked at all.
  The cheap repair is to build only the `oaa_wire_fixture` target on pushes — it
  needs the engine and one translation unit, not JUCE — which needs the JUCE
  fetch in `plugin/CMakeLists.txt` to become conditional. It is not today, and
  it would not recover the end-to-end run, which needs the whole plugin.

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
  that ever ran the packaging jobs.

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
- **The flatpak job validates the metainfo before it builds, and prints the
  compose report when it fails.** `flatpak-builder` finishes with
  `appstreamcli compose`, which reports a component id and an error tag, says
  "refer to the generated issue report data", and then discards that report —
  so a metainfo defect surfaces ten minutes into the job as three lines naming
  no file. `appstreamcli validate --explain` is the same check in two seconds
  and runs first. Keep both: the second one is what makes a failure the log can
  answer rather than a guessing exercise against the manifest.

- **Every installer this repository builds has spaces in its name, so no
  filename may be word-split.** The publish step collects assets NUL-delimited
  into an array; `$(find ...)` unquoted turns
  `Open Audio Analyzer-0.2.0-x86_64.AppImage` into three arguments and the job
  dies on `no matches found for .../Open` with all seven builds green. The
  documentation's shell examples quote the names for the same reason — they did
  not, and neither command worked as printed.

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
