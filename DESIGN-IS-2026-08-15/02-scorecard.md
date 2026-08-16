# 02 — Scorecard

**Round 3**, scored against the rendered application after the five round-2
moves and a module padding pass. Earlier rounds shown for comparison; their
justifications are preserved in `01-evidence.md`.

Anchors applied as written. Tie-breaker: when between two scores, the lower.
Evidence anchors refer to `01-evidence.md`, including its Round 3 section.

---

**1. Good design is innovative — 2/3** (R1 2, R2 2)
Evidence: §1, §3; `meter_source.dart`; `skin.dart:3-16`.
Justification: nothing in this pass touched innovation — the canvas remains an
acknowledged reimplementation lifted by two real structural advances, the
socket-fed `MeterSource` and the open skin format.

**2. Good design makes a product useful — 3/3** (R1 2, R2 **3**)
Evidence: `05`/`06-controls`; every painted control built through
`BelFocusable`.
Justification: unchanged and still met — the primary task completes in zero
steps and the configuration surface beside it is fully keyboard-operable.

**3. Good design is aesthetic — 3/3** (R1 2, R2 2)
Evidence: Round 3 §"What the five moves cost" and §"Padding, measured";
findings **H**, **I**, **J** all fixed and re-measured.
Justification: both round-2 deductions are gone and verified — the meter track
now reads at 1.58:1 / 1.61:1 against its panel while staying well under the
fill, and the VU's scale labels sit on one radius. What replaces the eye is a
measurement: left and right ink margins now agree to within 1.5 px on every
module, where four of them leaned 13 px one way. The system is single and
visible, which is the anchor-3 condition.

**4. Good design makes a product understandable — 2/3** (R1 2, R2 2)
Evidence: `after-app-dark.png` — `REMOTE` now carries the same border, padding
and focus ring as its four neighbours; Round 3 finding **L**, fixed.
Justification: the round-2 deduction is resolved and a second defect found on
the way — the delivery-target menu could not indicate which target was active.
It stays at 2 on the anchor as written: `RESET` is one control whose scope
cannot be read from its label and which therefore needs its tooltip. That is a
deliberate design, but the anchor does not distinguish deliberate from
accidental, and inflating it here would make the other nine scores worth less.

**5. Good design is unobtrusive — 3/3** (R1 2, R2 **3**)
Evidence: `after-app-dark.png` — teal appears only on TP MAX, PEAK MAX, the
`PASS` row and the alert meter. Chrome is neutral throughout.
Justification: unchanged; removing the frame-rate chip took one more item out
of the bar without adding any colour to it.

**6. Good design is honest — 3/3** (R1 3, R2 3)
Evidence: §3 honesty machinery; `tokens.dart` `meterTrack` now documents the
ratio it is held at and the ceiling it must stay under, in the same register as
`hairlineStrong` and `accent`; the CHANGELOG states that a user skin setting
`meter_track` keeps its own value.
Justification: every user-facing claim still maps 1:1 to behaviour, and the
palette's documentation continues to state the rules the code actually follows
rather than the ones it would like to.

**7. Good design is long-lasting — 3/3** (R1 3, R2 3)
Evidence: `after-sheet-a-dark.png`, `after-sheet-a-light.png` — zero shadows,
gradients, blur or opacity in the rendered result, in either skin.
Justification: unchanged. The raised track is a flat value, not a gradient.

**8. Good design is thorough down to the last detail — 3/3** (R1 2, R2 2)
Evidence: Round 3 findings **I**, **J**, **K** — all fixed and re-measured;
`after-min-*.png` renders every kind at its minimum legal size.
Justification: the four VU drawing defects and the four modules that drew in a
corner are gone, the panel that scrolled silently now says so, and rendering
every kind at its *minimum* size — not just its default — turned up a Number
Box that drew a title bar and nothing at all. Checking the smallest case rather
than the comfortable one is what the anchor is asking for.

**9. Good design is environmentally friendly — 3/3** (R1 2, R2 **3**)
Evidence: `meter_clock.dart` `reducedMotion`; the settings disclosure; no new
dependency and nothing new allocated on the frame path — the VU's two scale
endpoints were hoisted out of `paint`, removing 24 `pow` calls a frame.
Justification: unchanged, and marginally better.

**10. Good design is as little design as possible — 2/3** (R1 2, R2 2)
Evidence: the frame-rate chip is gone from `bel_app.dart`; the rule that
replaced it is written at the top of `_StatusBar`.
Justification: the clearer of the two duplicated affordances is removed and the
rule for the next candidate is stated in the code — the bar carries what changes
while you work, or what a reading has to be read against. It stays at 2 by the
tie-breaker rather than the argument: the `?` button duplicates a shortcut that
already works two ways, and the format readout is informative rather than
load-bearing. Two removable elements is the anchor-2 line exactly.

---

## Total

| # | Principle | R1 | R2 | R3 |
|---|---|---|---|---|
| 1 | Innovative | 2 | 2 | 2 |
| 2 | Useful | 2 | **3** | 3 |
| 3 | Aesthetic | 2 | 2 | **3** |
| 4 | Understandable | 2 | 2 | 2 |
| 5 | Unobtrusive | 2 | **3** | 3 |
| 6 | Honest | 3 | 3 | 3 |
| 7 | Long-lasting | 3 | 3 | 3 |
| 8 | Thorough | 2 | 2 | **3** |
| 9 | Environmentally friendly | 2 | **3** | 3 |
| 10 | As little design as possible | 2 | 2 | 2 |

**Round 1: 22/30 (source only). Round 2: 25/30 (rendered). Round 3: 27/30
(rendered and measured).** No zeros in any round.

Two principles moved, and both were the ones round 2 explicitly said had been
held down by newly-visible evidence rather than by failed fixes. #3 and #8 were
the pixel-only findings; both are now fixed, re-rendered and measured. #4 and
#10 are unchanged and are the honest remainder — each is held at 2 by an anchor
clause rather than by a defect, and both are stated plainly above rather than
argued away.
