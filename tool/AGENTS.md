# tool/

Repository scripts. Nothing here ships. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `docs.dart` | Builds the documentation site from the Markdown in this repository, and the mark from `assets/brand/oaa-mark.svg`. `dart run tool/docs.dart --out build/docs`. |
| `bench_spectrogram.dart` | The measurements behind the figures in `lib/src/modules/spectrogram.dart`: the run-length strategy against a rect per run, and the run counts on realistic band jitter that retired it in favour of the pixel path. `flutter test tool/bench_spectrogram.dart`. |
| `fetch_test_audio.dart` | Downloads the Creative Commons music the application is looked at with. `dart run tool/fetch_test_audio.dart`. Writes to `test_audio/`, which is gitignored. |

## Rules

- **`fetch_test_audio.dart` downloads what a *person* looks at, and no test
  depends on it.** Nothing in `ci.yml` runs it: a gate that fetches 35 MB of
  music from somebody else's CDN to prove a socket carries frames is a gate that
  fails for reasons unrelated to this repository. That is not hypothetical — the
  first host this script used, archive.org, stopped serving the item for hours
  at a stretch while the rest of the site stayed up, which is why the manifest
  now points at `upload.wikimedia.org`. The end-to-end test in
  `packages/oaa_wire/` generates its own signal for that reason and takes
  `OAA_TEST_TRACK` when somebody wants the real thing. What the download is for
  is the judgement a tone cannot support: a spectrogram fed a sine is one bright
  line, and a stereo cloud fed one is a dot.

- **The track was chosen by measuring candidates, not by reading titles.** Four
  permissive ones were fetched and run through `oaa`; the manifest's default won
  on numbers — a loud master at −8.6 LUFS, a real 10.3 LU range, a true peak
  *above* its sample peak, and a correlation that moves between −0.11 and 1.00.
  The rejected ones failed on exactly the properties a tone also lacks: one had
  a correlation pinned at 1.00, so the stereo cloud drew a line. The header of
  the script records the figures.

- **It sets `exitCode` rather than returning one.** `Future<int> main()`
  compiles and the value is discarded, so the script exited 0 after a failed
  download. That was the first version, and it is the shape of bug that makes a
  CI step green for a year.

- **The licence travels with the files.** The audio is CC BY, the files are
  gitignored, so nothing in the repository would record where they came from —
  the script writes `ATTRIBUTION.md` beside them, for the tracks it actually
  produced rather than the ones it was asked for.

- **`docs.dart` has no dependencies, and that is the reason it is here rather
  than a `mkdocs.yml`.** The documents the site publishes — `docs/METRICS.md`,
  `docs/WIRE.md` — are normative and held by tests, so a site that can break on
  a machine where the code is fine is a site that will. `docs.dart` imports
  `dart:io` and `dart:convert` and nothing else, which is why
  `ci.yml`'s `docs` job is a Dart SDK and forty seconds with no Flutter
  anywhere in it. That constraint belongs to `docs.dart` rather than to this
  directory — `bench_spectrogram.dart` needs `dart:ui`, and therefore an engine
  — and it survives as long as the `docs` job runs `docs.dart` and nothing else.

- **`bench_spectrogram.dart` is run by hand, and is not a gate.** It is written
  as a `flutter test` file because `dart:ui` needs an engine, not because it
  tests anything: `flutter test` with no arguments globs `test/`, so this never
  runs in CI, and it asserts nothing about a timing. A stopwatch in the gate
  fails on a loaded runner, a flaky gate gets deleted, and a deleted benchmark
  is how the figure it backs became unfalsifiable the last time — an earlier
  "205 µs" was quoted here for a phase after its benchmark was gone, and turned
  out to be a recording cost being read as a frame cost. Do not add it to
  `ci.yml`, and do not describe it anywhere as something CI checks.

- **The mark is read from `assets/brand/oaa-mark.svg`, never held here.** It
  was held here, as two hand-copied constants of the icon's geometry, and it
  went stale the first time the mark was redrawn: every icon the project ships
  followed, and the site kept publishing the previous identity in its sidebar
  and in the browser tab of every page. Nothing caught it — the site has no
  test, and the geometry was numbers inside a string literal 200 lines from
  where it was used. A missing file now fails the run. The same applies to
  anything else the site shows about itself: read it from the file that owns
  it, because a copy in a generator is a copy no reviewer will diff.

- **The page list is written out, not globbed.** A site whose contents are
  whatever happens to be in `docs/` publishes `PLAN.md` to users the day
  somebody moves it — and a plan is not documentation, it is a record of what
  was intended, which reads as a promise when a stranger finds it.

- **The Markdown subset is only as wide as the sources need.** Adding a
  construct without a document that uses it is how a renderer acquires a
  footnote parser nobody asked for. Anything unrecognised passes through as
  text rather than being dropped: a page that renders wrong gets fixed, one that
  renders *short* is not noticed.

- **`docs/site/keyboard.md` is generated somewhere else.** It comes from the
  shortcut table in `lib/src/app/shortcuts.dart`, and `test/shortcuts_test.dart`
  rewrites it under `UPDATE_DOCS=1` and fails without it when the checked-in
  copy has drifted. This script only publishes it. Editing that page by hand is
  a change the test will reject.
