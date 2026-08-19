# 03 — Verdict (Round 3)

## REFINE

**Open Audio Analyzer scores 27/30 with every measurement-surface principle at
full marks, and the three points still missing are both known, both stated, and
both a matter of one control's label and two elements that could be deleted —
not of anything the instrument does wrong.**

### Why this verdict follows mechanically

Phase 3's rule: REFINE when total ≥ 20 **and** no principle scored 0. Total is
27; the minimum is 2. The verdict is unchanged across three rounds, but what it
means has changed completely: round 1 found systemic defects, round 2 found
local ones, and round 3 found only the two anchor clauses named below.

### What this round bought

Two principles moved, and they are exactly the two that round 2 said were being
held down by evidence that only existed in pixels:

- **#3 Aesthetic, 2 → 3.** The meter track went from 1.10:1 / 1.22:1 against its
  panel to 1.58:1 / 1.61:1, while staying 2.66:1 and 2.28:1 *below* the fill so
  the reading stays the figure. The VU's scale labels now sit on one radius.
- **#8 Thorough, 2 → 3.** The VU's four drawing defects are gone, four modules
  that drew their contents in a corner now draw them in the box, and a panel
  that scrolled silently now says so.

Three more fixes landed without moving a score, because their principles were
already where they should be: the frame-rate chip left the status bar, `REMOTE`
was confirmed in pixels to now look like a control, and the delivery-target menu
can once again show which target is selected.

### The part that came from measuring rather than looking

Round 2's lesson was that source review cannot see layout. Round 3's is that
looking cannot see it either, past a point. Three defects were invisible to both
eyes and source and turned up only once the ink's bounding box was measured
against the module's content box:

- Four modules leaned 13 px one way because `ScaleGraticule` reserved a flat
  30 px gutter whatever the labels said.
- Two modules centred a shape they were not drawing — the Super Meter opens 120°
  at the bottom, so centring it as a circle left a dead band a fifth of the
  module deep.
- A one-row Number Box drew a title bar and nothing else. This one required
  rendering every kind at its *minimum* legal size rather than its default, and
  it had been shipping.

### What is genuinely excellent and must survive

- **Honesty (#6, 3/3)** — NaN-never-zero, the refusal to reverse-engineer
  TrueDyn, the volunteered security gap, and a palette whose documentation now
  states the ratio each role is held at and the ceiling it must stay under.
- **Durability (#7, 3/3)** — confirmed in pixels in both skins. Zero shadows,
  gradients, blur or opacity. The raised track is a flat value.
- **The frame-path discipline (#9, 3/3)** — nothing added an allocation; the VU
  lost 24 `pow` calls a frame.
- **One inset, one rule** — `ModuleFrame` provides the only margin a module gets
  and painters draw to the edges of what they are handed. That sentence is now
  in the code, which is what stops the eleven-ad-hoc-insets problem recurring.

---

## Highest-leverage moves remaining

Both are small, and neither is urgent.

**1. #4 Understandable — `RESET` still needs its tooltip.**
Evidence: `oaa_app.dart`, wording tracked to `oaa_engine_reset()` in
`oaa.h:390-393`. One word cannot carry "restarts the integration but not the
layout, the target or the momentary readings". Either the label grows — `RESET
MEASUREMENT` — or this principle stays at 2 by choice, which is a defensible
place to leave it.

**2. #10 As little design as possible — two elements still fail the deletion
test.** Evidence: the `?` button duplicates `?` and `F1`, both of which already
work; the `48.0 kHz · 2 ch` readout is informative rather than load-bearing and
already drops out below 860 px. Removing either breaks nothing. Keeping them is
also defensible — discoverability is a real argument for the first — but the
rule now written into `_StatusBar` should be applied to them and the answer
recorded, rather than left open a third time.

**3. #1 Innovative — capped by a deliberate decision, and correctly so.** Not
worth chasing. Open Audio Analyzer is an acknowledged reimplementation lifted by
two real structural advances; a third would have to be a genuine idea, not a
feature.

### Not worth doing

- Reworking anything that scored 3. In particular, do not "improve" the absence
  of shadows and gradients; that absence is the design.
- Raising `meter_track` further. It is 2.5:1 below the fill by design; past that
  the track becomes a second bar, which is worse than an invisible one.
- Opening the VU's sweep past 55° to fill a very wide tile. The cap is a
  documented decision — past it the face reads as a speedometer.
