# docs/

| File | Contents |
|------|----------|
| `PLAN.md` | The phased plan, as approved. **A historical record**, written in the future tense before anything existed. Do not silently diverge from it: a divergence goes in its table of divergences, at the top. `README.md`'s Roadmap is the live status. |
| `METRICS.md` | The definition of every published quantity, with its standard. |
| `WIRE.md` | The remote-display and plugin protocol. **Normative** — three implementations, none written against another. |
| `site/` | The pages of the documentation site that have no other home: the landing page, install, analysing files, building — and `keyboard.md`, which is **generated**. `METRICS.md`, `WIRE.md` and `CHANGELOG.md` are published from where they already live rather than copied in. See `tool/AGENTS.md`. |

`METRICS.md` is not optional documentation. Bel does not implement Decibel's
proprietary `TrueDyn`, and instead publishes `DR-S` / `DR-I` with their formulas
stated so anybody can check them. A metric that appears in the UI without an
entry here is a number nobody can verify.

The three files fail in different directions, so they are kept differently:

- **`METRICS.md` goes stale silently.** Its **Availability** column is the part
  that rots — a metric moves from unavailable to measured and nobody comes back
  to the table, so the document says a number is a dash while the app shows it.
  Change a measurement, change this file in the same commit.
- **`WIRE.md` must *not* track the code.** Its byte tables are frozen per
  protocol version and were derived from `bel_snapshot` rather than tied to it.
  An ABI bump does not touch them. Updating this file to match a struct change
  is the specific mistake that would break every display in the field, and break
  them by drawing wrong numbers rather than by failing.
- **`PLAN.md` is not updated to match reality.** It records what was decided;
  reality is recorded in its divergence table and in `CHANGELOG.md`.
- **`site/keyboard.md` is not edited by hand.** It is generated from the
  shortcut table in `lib/src/app/shortcuts.dart`, and `test/shortcuts_test.dart`
  fails when the checked-in copy has drifted. Regenerate with
  `UPDATE_DOCS=1 flutter test test/shortcuts_test.dart`.
- **`PLAN.md` is deliberately not published to the site.** A plan written in the
  future tense before anything existed reads as a promise when a stranger finds
  it. The page list in `tool/docs.dart` is written out rather than globbed for
  exactly this reason.
