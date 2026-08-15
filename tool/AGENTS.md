# tool/

Repository scripts. Nothing here ships. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `docs.dart` | Builds the documentation site from the Markdown in this repository. `dart run tool/docs.dart --out build/docs`. |

## Rules

- **No dependencies, and that is the reason it is here rather than a
  `mkdocs.yml`.** The documents the site publishes — `docs/METRICS.md`,
  `docs/WIRE.md` — are normative and held by tests, so a site that can break on
  a machine where the code is fine is a site that will. `docs.dart` imports
  `dart:io` and `dart:convert` and nothing else, which is why
  `.github/workflows/docs.yml` is a Dart SDK and forty seconds with no Flutter
  anywhere in it.

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
