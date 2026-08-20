# tool/

Repository scripts. Nothing here ships. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `docs.dart` | Builds the documentation site from the Markdown in this repository, and the mark from `assets/brand/oaa-mark.svg`. `dart run tool/docs.dart --out build/docs`. |
| `bench_spectrogram.dart` | The measurement behind the recording figures in `lib/src/modules/spectrogram.dart`. `flutter test tool/bench_spectrogram.dart`. |

## Rules

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
