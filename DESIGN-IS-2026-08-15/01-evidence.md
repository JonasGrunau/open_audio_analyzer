# 01 — Evidence

All citations are `file:line` against the working tree on 2026-08-15.
Facts only. No scoring — scoring is in `02-scorecard.md`.

---

## §1 Structural

**Module inventory.** 12 module kinds, declared once as a closed enum
(`packages/oaa_core/lib/src/layout.dart:10`) and dispatched through a single
exhaustive switch with **no default arm** (`lib/src/canvas/module_host.dart:71-120`,
rationale at `:68-70`). One place in the app knows which kinds exist as code.

**Interactive-element counts** (`lib/`, whole app):

| Affordance | Count |
|---|---|
| `onPressed` | 44 |
| `onTap` | 21 |
| `TextButton` | 8 |
| `GestureDetector` | 7 |
| `TextField` | 7 |
| `PopupMenuButton` | 5 |
| `MouseRegion` | 4 |
| `InkWell` | 1 |
| `IconButton` | 0 |
| `Draggable` | 0 |

**Top toolbar** carries 10 items (`lib/src/app/oaa_app.dart:430-478`): source
picker, format readout, elapsed readout, calibration picker, fps picker, remote
display control, `ANALYSE FILE`, `?`, `SETTINGS`, `RESET`. Two hide responsively
— format below 860 px, fps below 700 px (`:417-418`).

**Repeated affordances** (same purpose, two locations):
- Refresh rate — toolbar `_FpsPicker` (`oaa_app.dart:447`) and Settings
  "Refresh rate" (`lib/src/panels/settings_panel.dart:170-177`).
- Delivery target — toolbar `_CalibrationPicker` (`oaa_app.dart:444`) and
  Settings "Delivery target" (`settings_panel.dart:182`).

**Dead code / unused imports:** `flutter analyze` across the whole workspace —
**"No issues found!"** (ran 2026-08-15, 1.3 s). Zero.

**Nesting depth of the primary component tree:** `GridCanvas` →
`LayoutBuilder` → `Stack` → `Positioned.fromRect` → `_ModuleSlot` → `ModuleHost`
→ `ModuleFrame` → `Stack` → `Column` → `Expanded` → `Padding` →
`RepaintBoundary` → module painter. **Depth 13** to a painted meter
(`lib/src/canvas/grid_canvas.dart:270-310`, `packages/oaa_ui/lib/src/module_frame.dart:69-105`).

---

## §2 Visual

**Spacing scale** — 9 values, closed set, each with a stated purpose
(`packages/oaa_ui/lib/src/tokens.dart:16-48`):
`[2, 4, 8, 12, 16, 24, 32, 48, 64]`.

**Enforcement is total.** Repo-wide search for raw numeric literals in
`EdgeInsets.all|symmetric|only|fromLTRB` across `lib/` and `packages/oaa_ui/`
returns **exactly one hit, and it is inside a doc comment**
(`tokens.dart:10`, the sentence warning against `EdgeInsets.all(11)`).
`SizedBox(width:|height: <number>)` → **0 hits**.

**Type scale** — 7 styles, 5 distinct sizes (`tokens.dart:234-339`):
words `[10, 11, 13]` (label / unit+caption / body); numbers `[10, 12, N]`
(tick / readingSmall / `reading(size)` sized by the module).
Every numeric style carries `FontFeature.tabularFigures()` (`:266`, applied at
`:278, :288, :298`).

**Distinct colour count: 13 semantic roles**, closed set, named identically in
`oaa_core` (`packages/oaa_core/lib/src/skin.dart:25-38`) and `oaa_ui`
(`tokens.dart:93-108`). Two skins ship (`skin.dart:218-266`).

**Colour literals outside the token/skin files: 2**, both the same value —
`const Color(0xFFFFFFFF).withValues(alpha: _decay)` at
`lib/src/modules/phase_scope.dart:100` and
`lib/src/modules/stereo_cloud.dart:116`. Both are the persistence-layer decay
blend, not a palette choice.

**Decoration inventory** across `lib/` and `packages/oaa_ui/`:

| Effect | Count |
|---|---|
| `BoxShadow` | **0** |
| `LinearGradient` | **0** |
| `RadialGradient` | **0** |
| `ImageFilter.blur` | **0** |
| `BackdropFilter` | **0** |
| `Opacity(` | **0** |

One border weight (`OaaStroke.hairline = 1`), with `mark = 1.5` reserved for
graticules and `emphasis = 2` for target lines (`tokens.dart:75-83`).
Max corner radius is 8; meters use `Radius.zero` (`tokens.dart:51-67`).

### Contrast ratios — computed, WCAG 2.x, against `panel`

**Precision Instrument** (default, dark):

| Role | Ratio | AA (4.5) |
|---|---|---|
| textPrimary | 15.03:1 | pass |
| accent | 11.08:1 | pass |
| warn | 9.67:1 | pass |
| textMuted | 5.79:1 | pass |
| over | 5.64:1 | pass |
| meterFill | 4.20:1 | large-text only |
| **textFaint** | **2.81:1** | **fail** |
| hairlineStrong | 1.47:1 | n/a (border) |
| hairline | 1.17:1 | n/a (border) |

**Daylight** (light):

| Role | Ratio | AA (4.5) |
|---|---|---|
| textPrimary | 17.37:1 | pass |
| textMuted | 7.20:1 | pass |
| over | 5.43:1 | pass |
| accent | 4.71:1 | pass |
| warn | 4.57:1 | pass |
| meterFill | 3.67:1 | large-text only |
| **textFaint** | **3.08:1** | **fail (AA-large only)** |

Surface separation is deliberately near-invisible: `panel` vs `background`
**1.06:1** (dark) / **1.11:1** (light); `panelRaised` vs `panel` **1.06:1** /
**1.04:1**.

`meterFill` vs `meterTrack` — **3.82:1** (dark), **3.01:1** (light).

**What `textFaint` is used for** (`tokens.dart:131-132`, verbatim): *"Scale
ticks, disabled state, and the em dash that means 'not measured'."* Three
unrelated jobs on the one role that fails AA, one of which is a measurement
statement (`packages/oaa_ui/lib/src/readout.dart:121`,
`lib/src/modules/validator.dart:104`).

### States checklist

| State | Present | Evidence |
|---|---|---|
| empty | **yes** | `lib/src/canvas/grid_canvas.dart:295` (`_Empty`); `lib/src/remote/display_screen.dart:161, 355, 559` |
| loading | **yes** | `lib/src/panels/report_panel.dart:288, 296-315` — determinate progress with filename |
| error | **yes** | `lib/src/canvas/canvas_notice.dart` (4 s refusal toast); `lib/src/storage/startup_config.dart:150`; overrun banner via `lib/src/clock/meter_clock.dart:63` |
| success | **yes** | `lib/src/modules/validator.dart:220` (`READY TO DELIVER`); `lib/src/panels/report_panel.dart:567` |
| disabled | **yes** | `packages/oaa_ui/lib/src/panel.dart:469, 504-508` — colour, cursor and null callback; doc at `:453-454` |
| **focus** | **NO** | see §5 |

**Additional detail-level care observed** (relevant to thoroughness):
`ModuleTooSmall` refuses to draw rather than smear (`module_host.dart:63-66`);
paragraph disposal (`readout.dart:103-108`); GPU texture ping-pong and disposal
(`packages/oaa_ui/lib/src/persistence_layer.dart`); the `?` toolbar button
exists solely because Open Audio Analyzer draws its own chrome and so has no
menu bar to read shortcuts from (`oaa_app.dart:459-470`, comment); notice timer
cancelled on dispose because a 4-second fuse outlives a closing tab
(`canvas_notice.dart:36-40`).

---

## §3 Copy and honesty

**Every user-facing string was enumerated** (78 hits across `Text('…')`,
`label:`, `title:`). Full list in the raw sweep; representative sample:

`ANALYSE FILE`, `SETTINGS`, `RESET`, `UNDO`, `REDO`, `+ MODULE`, `Settings`,
`Signal`, `Source`, `Test tone`, `Silence`, `Device`, `Capture device`,
`Rescan`, `Meters`, `Refresh rate`, `Delivery target`, `Appearance`,
`Reload from disk`, `Duplicate for editing`, `Session`,
`Restore the last layout at launch`, `Presets`, `Browse`, `Save the current
layout`, `Store the delivery target with it`, `Store the skin with it`,
`Saved layouts`, `Delete?`, `Identity`, `Loudness`, `Target`, `Tolerance`,
`Loudness range ceiling`, `True peak ceiling`, `Analogue`, `VU reference`,
`Keyboard shortcuts`, `File analysis`, `Analyse another…`, `Choose a file…`,
`Measurements`, `Loudness over time`, `CONNECT`, `DISCONNECT`, `APPLY`,
`USE AS DISPLAY`.

**Flagged inflations — user-facing: 0.** No superlatives, no marketing register
anywhere in the interface. Sweep for
`best|fastest|powerful|seamless|effortless|beautiful|world-class|revolutionary|instantly|just
works` across `README.md` returns **one** hit: `README.md:12` — *"the modular
canvas is the best interaction model anybody has found for this problem."* Prose
in the design document, not a product claim, and it is an argument about a
borrowed pattern rather than about Open Audio Analyzer.

**Flagged dark patterns: 0.** No forced continuity, no hidden cost, no fake
scarcity, no confirmshaming. Destructive actions use a two-step reveal
(`Delete?` → `Delete`, `lib/src/panels/preset_browser.dart:171-176`) and a
dedicated `ButtonEmphasis.destructive` (`panel.dart:461, 475`).

**Jargon:** `LUFS-I`, `LRA`, `dBTP`, `PLR`, `PSR`, `DR-S`, `DR-I`, `Crest`
(`packages/oaa_core/lib/src/metric.dart:11-27`). All domain-correct for the
stated primary user, all defined in `docs/METRICS.md`. **No plain-language
replacement proposed** — replacing them would make the tool worse for the person
it is for.

**Label→behaviour mismatches — user-facing: 0 found.**

**Label→behaviour mismatch — internal, 1 found and it is load-bearing:**
`tokens.dart:134-136` declares accent as *"In spec. The single signal hue in the
whole interface — which is what makes it mean something."* The shipped code uses
`accent` at **~35 call sites spanning three unrelated meanings**:

1. *Measurement / in-spec* — `readout.dart:118`, `validator.dart:102, 220`,
   `report_panel.dart:567`, `report_card.dart:257`.
2. *Selection and active chrome* — `module_frame.dart:78` (module selection
   border), `panel.dart:338` (selected list row), `:473` (primary button),
   `:541-544` (toggle on), `:616` + `tab_strip.dart:284` (text cursor),
   `tab_strip.dart:243` (active tab), `grid_canvas.dart:244, 470`,
   `oaa_app.dart:562, 595, 628, 660`.
3. *Data traces* — `spectrum_analyzer.dart:129`, `spectrogram.dart:98-100`
   (heat ramp), `phase_scope.dart:97`, `stereo_cloud.dart:74`,
   `histogram.dart:107-109`.

Meanwhile `hairlineStrong` — documented at `tokens.dart:122-123` as *"A border
that needs to be seen: focus, selection, active module"* — is used **5 times and
never for module selection** (`panel.dart:479, 544`,
`stereo_cloud.dart:123`, `report_panel.dart:371`, `oaa_app.dart:727`).

**Honesty machinery, verified present:**
- NaN-never-zero, with the reasoning written down:
  `packages/oaa_core/lib/src/metric.dart:60-70` — *"`0.0` — the other obvious
  placeholder — looks like a measurement."*
- Engine-side flags: `OAA_FLAG_LOUDNESS_UNAVAILABLE`,
  `OAA_FLAG_SPECTRUM_UNAVAILABLE` (`engine/include/oaa/oaa.h:169, 175`).
- Em dash rendering: `metric.dart:66`, `report.dart:375`, `readout.dart:24, 121`,
  `lib/src/data/metric_reader.dart:53-57`.
- **Refusal to fabricate a competitor's metric** — `README.md:117-125`:
  Decibel's *TrueDyn* is proprietary and undocumented, *"so any claim to match
  it would be a guess presented as a measurement. Open Audio Analyzer does not
  implement it."* Open Audio Analyzer publishes `DR-S`/`DR-I` from stated
  definitions instead.
- **"Known gaps, stated plainly"** (`README.md:569-610+`) enumerates unbuilt
  modes, the macOS/Linux loopback gap versus Decibel, unsupported codecs, and —
  unprompted — *"The remote display has no authentication and no encryption…
  Do not switch it on at a venue whose Wi-Fi you do not control."*
- EBU Tech 3341/3342 conformance runs in CI on three platforms
  (`README.md:137+`).

---

## §4 Weight and friction (Flutter equivalents)

Web metrics do not apply. Substituted, per `00-scope.md`:

- **External runtime dependencies: 3** — `flutter_riverpod`, `desktop_drop`,
  `file_selector` (`pubspec.yaml`, `dependencies:`). Native side vendors 4
  permissive single-header C libraries. `pubspec.yaml` states riverpod carries
  *configuration and UI state only; measurements never pass through it*.
- **Allocations on the frame path: 0 by rule** — one FFI call per frame
  (`lib/src/clock/meter_clock.dart:86`), painters read pre-built views.
- **Frame skipping:** repaints are skipped whenever the engine generation has not
  advanced (`meter_clock.dart:97-106`). The comment at `:69-74` states the skip
  count *should be large* — engine publishes ~47 Hz against a 60/120 Hz display.
- **Paragraph re-layout avoided** unless the formatted string, colour or size
  changed (`packages/oaa_ui/lib/src/readout.dart:69-85`).
- **Repaint isolation:** `RepaintBoundary` per module so a scrolling spectrogram
  does not re-raster its own frame (`module_frame.dart:96-101`).
- **Occlusion:** the `Ticker` stops when the window is occluded
  (`meter_clock.dart:91`).
- **Battery affordance:** 30 fps option exists explicitly *"because it halves GPU
  load on a laptop running on battery with a session open all day"*
  (`meter_clock.dart:44-46`).
- **Animation count on an idle screen: 0 decorative.** Zero `AnimationController`,
  `Tween`, `CurvedAnimation` or `AnimatedContainer` in `lib/` or `oaa_ui/`. The
  only tickers are the single `MeterClock` (`meter_clock.dart:29`) and the remote
  display's (`display_screen.dart:37`). Meters move because the signal moves.
- **Notifications / badges / modals on initial load: 0.** One transient toast
  exists and is reserved for refusals only, 4 s
  (`canvas_notice.dart:9-13, 31-33`).
- **Dark mode:** default, plus a shipped light skin and user-authored skins
  (`skin.dart:218-266`).
- **`prefers-reduced-motion` / `disableAnimations` / `highContrast` /
  `textScaler`: 0 hits** across `lib/` and `packages/oaa_ui/`.

---

## §5 Accessibility

- **`Semantics(` widgets in the entire app: 0.** (`lib/` + `packages/oaa_ui/`.)
- **Focus state: absent from every custom control.** All five interactive
  primitives in `packages/oaa_ui/lib/src/panel.dart` are
  `MouseRegion` + `GestureDetector` with no `FocusableActionDetector`, no
  `Focus`, no `FocusNode`, and no focus ring:
  `PanelListRow:319-325`, `SegmentedControl:413`, `OaaButton:483-487`,
  `OaaToggle:532-534`, `_IconTarget:652-654`.
  The sole focus participant is `OaaTextField` (`:580, 590, 614` — `autofocus`).
- **`FocusNode` in `lib/`: 2 occurrences**, both the tab-rename field
  (`lib/src/canvas/tab_strip.dart:27, 268`).
- **Keyboard reachability of primary actions:** app-level shortcuts exist and are
  well built (`lib/src/app/shortcuts.dart:108-113`, meta/control dual binding),
  with a discoverable sheet (`lib/src/panels/shortcuts_sheet.dart`) reachable
  from a `?` button placed there deliberately because there is no menu bar
  (`oaa_app.dart:459-470`). **But** no button, toggle, segmented control or list
  row inside any panel can be reached by Tab or activated by Enter/Space.
- **ARIA-landmark equivalent:** n/a (not web). **Skip link:** n/a.
- **Hit-target discipline** is handled and documented — painted chrome
  swallowing pointer events is a known, solved failure mode
  (`packages/oaa_ui/lib/src/module_frame.dart:31`, and `CLAUDE.md`).

---

## Known gaps in this evidence

- **Not run.** Source-only by instruction, so nothing here observes real rendered
  pixels, actual text wrapping, or focus behaviour at runtime. Layout defects
  that are "merely wrong to look at" — the class `CLAUDE.md` warns tests do not
  catch — are outside what this audit can see.
- **Nesting depth 13** counts widget layers, not visual layers; it is a
  structural figure, not a complexity verdict.
- **Contrast is computed against `panel`.** Text drawn over `meterTrack`,
  `background` or a spectrogram's heat ramp will differ, and the ramp case
  cannot be evaluated statically at all.
- **User-authored skins are unbounded.** Contrast findings apply to the two
  shipped skins; a user skin can be arbitrarily illegible and nothing validates
  it (`skin.dart:95-98` resolves missing roles but never checks contrast).
- **Phase 8 is in flight** in this same working tree. Line numbers may drift.

---

# Round 2 — pixel evidence (post-fix)

The round-1 gaps above are closed: this round was captured from the **rendered
application**, so the "layout that is merely wrong to look at" class of defect is
now in scope.

## Method

Two independent capture paths, both against the real engine:

1. **Deterministic** — `flutter test` renders the real canvas over a live
   `OaaEngine` at a fixed 1600×940 @2×, with the bundled Inter and JetBrains
   Mono loaded via `FontLoader`, and writes PNGs through
   `RenderRepaintBoundary.toImage()`. No window, no display geometry, no
   synthetic clicking. Harness preserved at `capture-harness.dart.txt`.
2. **Live** — the built `oaa.app` on macOS, driven by `--open-panel=settings`
   and real key events, captured with `screencapture`. Used to confirm the
   deterministic path matches a real window.

Shots are in `shots/`. An earlier attempt to drive the live app by synthetic
AppleScript clicks **silently did nothing** — the click was accepted and no
selection occurred — which is why the deterministic path is the one the findings
rest on.

## What the fixes look like rendered

| Claim | Shot | Rendered result |
|---|---|---|
| Signal hue means one thing on the canvas | `01-canvas-dark.png` | Teal appears on TP MAX, the two PASS rows and the alert meter only. The failing LUFS-I is red. No chrome is teal. |
| Selection is not the signal hue | `02-canvas-dark-selected.png`, `08-settings-panel-live.png` | Selected module carries a brighter 2 px border. Sampled colour `(92,100,109)` = the new `hairlineStrong` `#5A646E`. |
| Focus ring exists and is distinct from selection | `05-controls-dark-focus.png` | One Tab lands on `NORMAL`, which takes a white hairline. The selected list row beside it carries the dimmer `hairlineStrong` border. The two are unmistakable at a glance. |
| All six states present | `05`/`06-controls-*-focus.png` | normal / primary / destructive / **disabled** / **focused** / selected all render distinctly, in both skins. |
| The em dash is legible | `03-canvas-dark-unavailable.png` | Four unavailable readings render a clearly visible dash. Measured `5.79:1` (Precision) and `7.20:1` (Daylight) against panel, up from `2.81:1` / `3.08:1`. |
| Light skin unaffected | `04-canvas-light.png`, `06` | Same structure, correct inversion, dashes legible, in-spec hue reads as dark green. |

Verified palette values, computed: `hairlineStrong` now **3.06:1** (Precision)
and **3.30:1** (Daylight) against panel, up from 1.47:1 / 1.89:1.

## New findings — visible only in pixels

**A. The VU needle overshoots its own pivot.** `shots/07-vu-detail.png`. The
needle is drawn as a line through the pivot rather than to it, so a visible stub
protrudes below the grey pivot cap. Present in both skins and at every deflection
(`01`, `03`, `04`).

**B. The needle strikes through the `-20` label.** Same shot. At rest the needle
lies directly over the leftmost scale number, which is exactly the reading a user
checks when confirming the meter is at rest.

**C. The VU scale labels are not on a common radius.** Same shot. `-20`, `-10`,
`-5`, `-3`, `0`, `+3` sit at visibly different distances from the arc, and `0`
hangs well below its own tick. They read as scattered rather than as a dial face.
`CLAUDE.md` records "a crowded VU face" as a previously fixed defect on this same
module.

**D. The VU dial is not centred in its module.** Same shot. The pivot sits low
and left; roughly the bottom-right third of the module is empty, with the `VU`
badge floating in it.

**E. The unfilled meter track is at the edge of visibility, in both skins.**
Sampled from the rendered arcs of the Super Meter against the panel behind them:
**1.10:1** in Precision Instrument, **1.22:1** in Daylight. All three bar/arc
meters paint it — `super_meter.dart:95-96`, `digital_meter.dart:108`,
`lufs_meter.dart:105`. The consequence is that a meter shows how full it is but
not how much room is left, which on a meter is half the information. (This is a
large-area shape, not text, so WCAG text thresholds do not directly govern it —
but 1.1:1 is below any usable discrimination threshold for reading an extent.)

**F. `REMOTE` does not look like a control.** `01-canvas-dark.png`, toolbar. It
is bare text between the calibration picker and the bordered `ANALYSE FILE`,
`?`, `SETTINGS` and `RESET` buttons. Every other actionable item in that bar
carries a border; this one does not.

**G. The settings panel's last row is overlapped by its own footer.**
`08-settings-panel-live.png`. `Presets` / `BROWSE` sits half-hidden behind the
`DONE` bar.

## Not a defect, checked and dismissed

- **Silence reads `-144.0 dBTP` and the validator says `PASS`.** This looked like
  a number invented from nothing. It is not: −144 dBFS is the real measurement of
  a silent stream, true peak needs no integration window to be defined, and the
  validator's overall state correctly reads `MEASURING` rather than a delivery
  verdict. Loudness, which *does* need a window, correctly shows dashes in the
  same frame. The distinction is exactly what `README.md:117-135` describes.

---

# Round 3 — after the five moves, plus a padding pass

## Method

Same harness as round 2, extended: `_Rack` renders any set of module kinds at
any grid size over a live `OaaEngine`, `_pumpSettings` opens the settings panel
through `showOaaPanel` with the boundary **above** `MaterialApp` (below it the
route is not in the picture — see `CLAUDE.md`), and `_pumpApp` renders the whole
application for the status bar. Captured before and after every change with
`--dart-define=STAGE=before|after`.

Round 2 was scored by eye from screenshots. This round the padding was measured
instead: for each module rendered alone, the ink's bounding box inside the
content area, scanning only the middle 60% of the opposite axis so the frame's
rounded corners cannot be counted as ink. Numbers below are logical pixels from
the module's inner border and therefore *include* the frame's own inset.

## What the five moves cost, measured

| Move | Before | After |
|---|---|---|
| 2 — meter track vs panel | 1.10:1 dark, 1.22:1 light | **1.58:1** dark (`0xFF323942`), **1.61:1** light (`0xFFC2C9D1`); still 2.66:1 and 2.28:1 *below* `meterFill` |
| 1 — VU face | needle through the pivot, needle across `-20`, labels scattered, dial high-left | needle from the pivot outward only; labels outside the sweep on one radius; dial solved to the tile |
| 3 — `REMOTE` | bare text among four bordered buttons | bordered `BarButton` (fixed concurrently by the Phase 8 session; **verified here in pixels**, `after-app-dark.png`) |
| 4 — settings panel | last row cut in half, no affordance | scrollbar in `hairlineStrong`, hidden when the content fits |
| 5 — fast paths | fps chip and delivery target both duplicated the panel | fps chip removed; delivery target kept, with the rule written into `oaa_app.dart` |

## Padding, measured (dark, each module alone at its default size)

L / R / T / B, logical px from the module's inner border.

| Module | Before | After |
|---|---|---|
| superMeter | 146.5 / 146.5 / **15.5 / 120.0** | 82.0 / 82.0 / **11.5 / 23.5** |
| lufsMeter | **19.5 / 6.5** / 7.0 / 17.0 | 11.5 / 10.5 / 11.0 / 21.0 |
| digitalMeter | **19.5 / 6.5** / 7.5 / 8.5 | 11.5 / 10.5 / 11.5 / 12.5 |
| spectrumAnalyzer | **6.5 / 19.0** / 7.0 / 10.0 | 10.5 / 11.0 / 11.0 / 14.0 |
| histogram | 6.0 / 6.0 / 7.5 / 8.0 | 10.0 / 10.0 / 11.5 / 12.0 |
| vuMeter | 73.0 / 77.5 / 16.0 / 16.0 | 67.0 / 71.5 / 12.5 / 12.0 |
| validator | 6.5 / 6.5 / **32.0 / 132.0** | 10.5 / 10.5 / 36.0 / 66.0 |
| alertMeter | 6.5 / 281.5 / **22.5 / 106.0** | 10.5 / 277.5 / 71.5 / 57.0 |
| numberBox | *ink at the left edge* | 181.0 / 181.0 / 51.0 / 57.0 |
| phaseScope | 120.5 / 120.5 / 12.5 / 6.5 | 124.5 / 124.5 / 16.5 / 10.5 |
| stereoCloud | 6.5 / 6.5 / 7.5 / 18.5 | 10.5 / 10.5 / 11.5 / 22.5 |

Three causes, all systemic rather than per-module:

**H. The scale gutter was a constant, not a measurement.**
`ScaleGraticule.gutter` returned a flat 30 px whatever the labels said, while
the meter itself ran flush to the opposite edge — so four modules leaned the
same way by about 13 px. It is measured from the laid-out labels now.

**I. Two painters centred a shape they were not drawing.** The Super Meter
opens 120° at the bottom, so its ink reaches only `sin(143°)` of the way below
the centre that it does above it; centring the notional circle left a dead band
a fifth of the module deep. The VU had the same class of error.

**J. Four modules drew from the origin rather than in the box.** Number Box
(reading against the left edge — an unavailable reading was a single em dash
alone in a corner), Alert Meter (block hung from the top edge), Super Meter,
Validator (rows capped at 34 px, rest of the tile blank).

## Found while measuring

**K. A one-row Number Box drew a title bar and an empty body.** `minRows` was 1;
a grid row is about 55 px on a 1600x880 canvas and the title bar takes 24 of it,
so `_minimumHeight` was never met and the painter returned without drawing.
Not "too small", which is a statement — blank, which is a fault. Pre-existing,
not introduced by the padding change, and found only because every kind was
rendered at its minimum legal size. `after-min-numberBox-2x1.png`.

**L. The delivery-target menu could not show which target was selected.** Both
arms of the ternary picking the row colour returned `colors.textPrimary`, so all
six entries drew identically. A round-1 fix applied one step too far.

## Residuals, stated rather than fixed

- **The VU leaves side margins in a very wide tile.** At 9x4 the height binds
  and the sweep is capped at 55° either side, so the dial is centred with about
  a third of the width free. The cap is a documented decision — past it the face
  reads as a speedometer — not an oversight. `after-vu-dark-wide.png`.
- The remaining vertical differences in the table (lufsMeter 11/21, stereoCloud
  11.5/22.5) are where a reserved band's *ink* sits inside it, not unused
  reserve: the labels concerned are at the far left and right and fall outside
  the measured middle band.
