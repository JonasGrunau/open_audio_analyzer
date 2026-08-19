# 04 — Handoff (Round 3)

Round 2's five moves are **implemented, measured, and the full CI gate is
green**, and a module padding pass went in alongside them. What is left is two
small decisions, both stated below. Copy the fenced block into a fresh session;
it is self-contained.

````
/make-plan Close out the last two Dieter Rams deductions on Open Audio Analyzer and add the regression tests that keep the nine fixed defects fixed (total 27/30, up from 25/30 and 22/30).

Verdict paragraph (quoted from the audit):
> Open Audio Analyzer scores 27/30 with every measurement-surface principle at full marks, and the three points still missing are both known, both stated, and both a matter of one control's label and two elements that could be deleted — not of anything the instrument does wrong.

Context: Open Audio Analyzer is a free/open-source loudness and spectrum analyser (Flutter desktop/tablet, repo `open_audio_analyzer`). Primary user is a mix or mastering engineer; primary task is glanceable live monitoring, with a delivery pass/fail verdict as the secondary flow. `README.md` is the real design document. A second agent has been working Phase 8 in the same working tree — stage explicit paths and expect line numbers to have drifted.

Keep (already strong, do NOT touch in this pass):
- Principle #3 (Aesthetic) scored 3 — Evidence: `meter_track` at 1.58:1 (dark, `0xFF323942`) and 1.61:1 (light, `0xFFC2C9D1`) against `panel`, and still 2.66:1 / 2.28:1 below `meter_fill`; left and right ink margins agree to within 1.5 px on every module. Regression check: re-measure before/after any palette or layout change; a track raised until it competes with the fill is a second bar and is worse than an invisible one.
- Principle #8 (Thorough) scored 3 — Evidence: the VU face, four corner-drawing modules and the silent scroll region are all fixed; every kind renders at its minimum legal size. Regression check: render every `ModuleKind` at `minColumns x minRows` and confirm none draws a title bar over an empty body.
- Principle #6 (Honest) scored 3 — Evidence: NaN-never-zero; `OAA_FLAG_*_UNAVAILABLE`; the refusal to implement TrueDyn; `tokens.dart` documents the ratio each colour role is held at and the ceiling it must stay under. Regression check: `rg -i "best|powerful|seamless|effortless|instantly" lib/` stays at zero user-facing hits.
- Principle #7 (Long-lasting) scored 3 — Regression check: `rg -c "BoxShadow|LinearGradient|RadialGradient|ImageFilter.blur|BackdropFilter|Opacity\(" lib packages/oaa_ui` must stay at **0** for every pattern.
- Principle #2 (Useful) and #5 (Unobtrusive) and #9 (Environmental), all 3 — `OaaFocusable` on every painted control; `accent` only on measurements on the canvas; `MeterClock.reducedMotion`.
- **One inset, one rule.** `ModuleFrame` supplies the only margin a module gets (`Space.smd`, all four sides, matching the title bar) and painters draw to the edges of what they are handed. Regression check: no module painter may reintroduce an inset of its own.

Fix in priority order:

1. #4 Understandable — decide `RESET`. Evidence: `oaa_app.dart`, tooltip wording tracked to `oaa_engine_reset()` in `oaa.h:390-393`. One word cannot carry "restarts the integration but not the layout, the target or the momentary readings", which is why it needs a tooltip, which is exactly the anchor-2 clause holding this principle at 2. Either widen the label (`RESET MEASUREMENT`) and check it still fits the bar's drop-out gates, or record the decision to keep the tooltip and leave the score. Do not do both.

2. #10 As little design as possible — apply the bar's own rule to its last two candidates. Evidence: the rule is now written at the top of `_StatusBar` in `oaa_app.dart` — the bar carries what changes while you work, or what a reading has to be read against. The `?` button duplicates `?` and `F1`, which both already work. The `48.0 kHz · 2 ch` readout is informative rather than load-bearing and already drops out below 860 px. Removing either breaks nothing. Decide each against the stated rule and write the answer down, rather than leaving it open a third round.

3. Regression tests for the nine defects this round fixed. There are none, and every one of them passed `flutter analyze` and the full widget suite while broken. At minimum: every `ModuleKind` renders non-empty at `minColumns x minRows`; `meter_track` holds ≥1.5:1 against `panel` and ≤ half the fill's contrast in both shipped skins; `ScaleGraticule.gutter` equals the widest laid-out label plus `Space.xs`, not a constant.

Constraints the plan must respect (project rules, not preferences):
- Changing a colour role means changing it in BOTH `SkinColor` (`packages/oaa_core/lib/src/skin.dart`) and `OaaColors` (`packages/oaa_ui/lib/src/tokens.dart`), plus both shipped skins, in one commit. Never rename a `SkinColor.key`. A user skin that sets the role keeps its own value, so state the change in `CHANGELOG.md` under `### ⚡ Changed`.
- Nothing may allocate on the frame path — no `Paint`, `Path`, `TextPainter` or list inside `paint()`.
- A module that accumulates advances on `engine.generation`, not on `paint`.
- Painted chrome absorbs pointer events unless stopped; module painters extend `MeterPainter`.
- A `BoxDecoration` may not combine `borderRadius` with a non-uniform `Border`.
- No reported number may change. If one does, it needs a `### 📐 Measurement` entry stating old behaviour, new behaviour and magnitude.

Out of scope for this pass — do NOT touch:
- The engine, the DSP, or any reported value.
- The VU sweep cap of 55° either side. It is a documented decision: past it the face reads as a speedometer. A very wide VU tile is centred with side margins, and that is correct.
- `meter_track`'s value. It is deliberately 2.5:1 below the fill.
- Principles #2, #3, #5, #6, #7, #8 and #9 — see the Keep list.
- `plugin/` (AGPL boundary) and `cli/`.

Deliverables for the plan:
- Per fix: target files, exact change, verification step.
- **Measured before/after for anything visual.** The harness that does this is preserved at `DESIGN-IS-2026-08-15/capture-harness.dart.txt` — drop it into `test/`, run `flutter test`, and it renders real modules over a live engine with the bundled fonts and writes PNGs. `DESIGN-IS-2026-08-15/margins.py` measures the ink's bounding box inside a module's content box. Round 3's three worst findings were invisible to both source review *and* the eye, and turned up only in those numbers.
- Confirmation the full CI gate passes: `flutter analyze`, `flutter test`, `dart test packages/oaa_core`, `dart test packages/oaa_wire`, `cd packages/oaa_engine && dart test`, `cd cli && dart test`, `sh plugin/test/sources_match.sh`, `dart run tool/docs.dart`.

Anti-patterns to guard against:
- Verifying a layout fix by reading source, or by looking at one screenshot. Both have now failed once each on this project.
- Rendering only the default module size. The blank Number Box shipped because nobody rendered a one-row one.
- Adding abstractions where a direct change suffices.
- Reworking anything that scored 3.
````
