# docs/

| File | Contents |
|------|----------|
| `METRICS.md` | The definition of every published quantity, with its standard. |
| `WIRE.md` | The remote-display and plugin protocol. **Normative** — three implementations, none written against another. |
| `site/` | The pages of the documentation site that have no other home: the landing page, install, analysing files, building — and `keyboard.md`, which is **generated**. `privacy.md` is here too and is the one page not published under `/docs`: it is the privacy policy, it is served at `/privacy` because App Store Connect holds that URL, and it is rendered by `website/src/pages/privacy.astro` rather than by the manual's manifest. `METRICS.md`, `WIRE.md` and `CHANGELOG.md` are published from where they already live rather than copied in. See `website/AGENTS.md` — the site is rendered there, and `tool/docs.dart`, which used to generate it, went in 0.11.0. |

`METRICS.md` is not optional documentation. Open Audio Analyzer does not
implement Decibel's proprietary `TrueDyn`, and instead publishes `DR-S` / `DR-I`
with their formulas stated so anybody can check them. A metric that appears in
the UI without an entry here is a number nobody can verify.

The three files fail in different directions, so they are kept differently:

- **`METRICS.md` goes stale silently.** Its **Availability** column is the part
  that rots — a metric moves from unavailable to measured and nobody comes back
  to the table, so the document says a number is a dash while the app shows it.
  Change a measurement, change this file in the same commit.
- **`WIRE.md` must *not* track the code.** Its byte tables are frozen per
  protocol version and were derived from `oaa_snapshot` rather than tied to it.
  An ABI bump does not touch them. Updating this file to match a struct change
  is the specific mistake that would break every display in the field, and break
  them by drawing wrong numbers rather than by failing.
- **`site/keyboard.md` is not edited by hand.** It is generated from the
  shortcut table in `lib/src/app/shortcuts.dart`, and `test/shortcuts_test.dart`
  fails when the checked-in copy has drifted. Regenerate with
  `UPDATE_DOCS=1 flutter test test/shortcuts_test.dart`.

**`AGENTS.md` is deliberately not published to the site**, and neither was
`PLAN.md`, the phased plan that lived here until every phase in it had shipped.
It was a historical record written in the future tense before anything existed,
which reads as a promise when a stranger finds it. The code and these
`AGENTS.md` files are the source of truth for what exists; `CHANGELOG.md` is the
record of how it got here. The page list in `website/src/lib/docs.mjs` is still
written out rather than globbed, because this directory holds instructions to a
machine and a glob would publish them.
