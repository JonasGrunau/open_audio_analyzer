# packages/oaa_ui/

The design system. Every visual decision in Open Audio Analyzer is made here
exactly once.

| File | Contents |
|------|----------|
| `src/tokens.dart` | `Space`, `OaaControl`, `OaaRadius`, `OaaStroke`, `OaaColors`, `OaaType`. |
| `src/theme.dart` | `OaaTheme` (an `InheritedWidget`) and a derived Material theme. |
| `src/module_frame.dart` | `ModuleFrame` — the chrome all fourteen modules sit inside. |
| `src/module_tap_group.dart` | `ModuleTapGroup` — the `TapRegion` group a module's body may join, so that a press on the module's own chrome or menu is not a press *away* from what the body holds — and `isPressAway`, which says a press belongs to a menu or panel standing above the route rather than to the canvas. Why it is `ModalRoute.isCurrent` and not `Navigator.canPop` is in the file: the remote display is itself a pushed route. |
| `src/meter_painter.dart` | The base every module painter extends — it exists to make `hitTest` return false; see the rules below. Also `MeterFill`, the one shading every filled meter body is painted with — the ink flat over the top three tenths, running to `OaaColors.deepen`'s floor colour, and for the LUFS Meter alone a tube across the width, shaded at both edges and, where `centre:` asks for it, lit down the middle in the same gradient; both layers built once as a unit square and scaled to the fill, so nothing allocates on the frame path. `ramp: false` leaves the ink flat and keeps the tube, which is the LUFS Meter's overshoot and nothing else — it takes no centre light either, and the reasons for both are on `prepare`. The ramp is measured off Decibel's bars, and the Super Meter sweeps it round its rings from the constants `MeterFill` exposes. |
| `src/readout.dart` | `ReadoutPainter` (cached paragraph layout), `ReadingState`, and `colorForState` — the one place that decides what colour a number is. A reading is `accent`; the palette's other colours are for what is wrong with one. `inkForReading` is the same rule reached from the other end, for the modules that settle a reading's colour before they have its number — the em dash is `text_muted` there too, or the signal hue ends up spent on the statement that there is no signal. |
| `src/text_cache.dart` | `layoutParagraph` for static labels and `ValueParagraph` for changing ones — the cache that re-lays out only when a *formatted string* differs. |
| `src/scale.dart` | `MeterScale` and `ScaleGraticule`, plus the shared frequency-label series `kHzGrid` and `fitHzLabels`, the one rule the three frequency axes label by, and the two ways a frequency is printed — `formatHz` for a tick ("2k") and `formatHzReading` for a reading ("1.02 kHz", three significant figures, which is what the bands resolve) — every value that fits, 100 Hz, 1 kHz and 10 kHz first. The level scale is tapered — the filled fraction is `10^(dB/60)`, −∞ is the floor — and four modules draw it; two side by side whose ticks disagree look like a rendering bug. The linear constructor serves axes that are a domain rather than a level, and the one level axis that is deliberately not tapered: the analyser's, over its chosen `Range`. `paint`'s `snapPitch` puts the gridlines on a ruling the caller draws itself — the Digital Meter's segments — because a scale a pixel off a ruling in the same picture is a second ruling, and the two beat against each other; `ScaleGraticule.snapped` is that rounding, public so the caller finds the same rows the graticule did. |
| `src/color_ramp.dart` | What `ColorRamp` paints, and the one place the argument for it is written down: colour carries whatever a module's axes do not. The spectrogram's level ramp — the skin's, or the rainbow — and the oscilloscope's three-band mix, where red, green and blue *are* the bass, the mids and the highs. |
| `src/grid_geometry.dart` | Grid cells to pixels. The one place the 24×16 canvas becomes a rectangle. |
| `src/plot_border.dart` | `PlotBorder` — the hairline box around a plot, in the gridlines' own ink. Six modules draw one and the histogram draws two, and it is one class so that two of them side by side cannot disagree about the weight or the ink of an edge. It replaced the rules each of them drew on whichever one or two sides a scale sat against. `PlotBorder.inside` is the other half of it and is not optional: the box is drawn on the rectangle a module was given and the picture goes inside, so that a spectrogram's newest column and a scope's newest sample — both hard against the right-hand edge — are framed rather than covered. |
| `src/point_buckets.dart` | Marks sorted by the colour they are drawn in, so a display of tens of thousands of them is a few dozen `drawRawPoints` calls. Behind the stereo cloud; the spectrogram drew through it too until real material's run counts outgrew it. |
| `src/panel.dart` | `PanelScaffold` and the controls panels are assembled from, plus `showOaaPanel`, `showOaaConfirm` and `showOaaSavePrompt`. |
| `src/menu_row.dart` | `OaaMenuRow` — one row of a popup menu, and the band and the check that mark the value the menu holds. Every menu in the application is built through it: the panel control, the status bar's two pickers and a module's dozen settings. `selected` is tri-state: `null` is a menu of actions, which gets neither mark nor the column reserved for one; `reservesCheck` is the fourth case, for the menu that is both — the File menu's four actions keep the column its two toggles need, or the labels step sideways at the divider. The one widget here handed its palette rather than reading it, for the reason in its header. |
| `src/qr.dart` | `QrCode` — just enough QR to carry one address, byte mode at error level M — and `OaaQrCode`, which paints it. The one widget here that does not take its colours from the skin: a code is read by thresholding a camera image, and dark-on-light is a property of the format rather than a choice. Held against ZXing by `test/qr_test.dart`. |
| `src/glyph.dart` | `OaaMark` and `OaaGlyph` — the closed set of marks the interface draws, as paths. There is no icon font, and a mark that is a codepoint is a mark that can go missing. |
| `src/skin_palette.dart` | The one adapter between a `Skin` (data, in `oaa_core`) and a `OaaColors`, plus `skinArgb` — the one place a `Color` is quantised back to the eight-bit hex the format stores. |
| `src/color_field.dart` | `OaaColorWell` — a colour as a boxed control — and `OaaColorPicker` — a saturation/value plane, a hue strip, a hex field and an opacity slider. The two controls behind the skin editor, and the only two here that were not in the closed control table below before they were written. |
| `src/slider.dart` | `OaaSlider` — a value dragged rather than picked, and one of the two controls here that live on a meter rather than in a panel. Continuous while it is dragged and committed once at the end, because its callers' values are layout state. Disabled it still draws where the value has got to, because the case for disabling one is that something else is moving it. |
| `src/check.dart` | `OaaCheck` — a boolean on a meter: a box, and the word it switches. The other control that lives on the measurement surface, and not `OaaToggle` because a panel's switch is two pixels taller than a slider's whole row and draws its on state in `accent`, which nothing on a module may borrow. |
| `src/focusable.dart` | `OaaFocusable` — keyboard focus, Enter/Space activation and the screen-reader identity every control Open Audio Analyzer paints itself would otherwise be missing. `OaaFocusable.range` is the same thing for a value: the arrows instead of Enter, a slider's announcement instead of a button's, and the control's own pointer handling, because where a press landed *is* the value it sets. |
| `src/edge_glow.dart` | `EdgeGlow` — a wash of colour rising out of one edge of a module, and the two edges any of them rises from: the Number Box's foot and the Alert Meter's left side. One class because the shape is where every defect it has had lived — an ellipse scaled on both axes so that a module's aspect cannot turn a glow into a flat sheet with the shader's own edge across it, anchored outside the edge so only its crown reaches in. Drawn to the *panel* rather than to the body, which is what `ModuleFrame.bleed` exists to allow. |
| `src/drag_devices.dart` | `kDragDevices` — the `supportedDevices` every drag detector needs, and why a trackpad is not one of them — and `kTouchDragDevices`, the narrower set that an enlarged, invisible hit target is admitted to. |

## Rules

- **No raw spatial or colour values anywhere in the repo.** If a layout needs a
  value that is not in `Space`, that is a design decision — make it here, name
  it, and use it everywhere. Thirteen modules drift apart one `EdgeInsets.all(11)`
  at a time.
- **No shadows.** Depth is background steps and hairlines. Shadows imply
  floating cards; measurement gear is machined panels sitting flush. This
  includes Material's own — see the Panels section.
- **Selection is a fill, and in a menu it is a band and a check.** A list row
  and a segment take `panelRaised`, a step up from the panel they sit on. A menu
  is already drawn on `panelRaised`, so there is no step left in the surfaces
  and its current value takes the role the rest of a panel already means by
  selection — `hairlineStrong`, a quarter of the way from the menu's own
  surface, as a wash rather than as the 2 px border it is elsewhere. It went to
  `background` for a while, which is the deepest surface in the skin and two
  steps below the menu: recessed as intended, and in Precision Instrument it
  read as a hole punched in the menu rather than as a row of it. `hairline` was
  the next try and is 1.09:1 against `panelRaised` dark against 1.31:1 light —
  one value, two strengths, and the dark skin got the weak one. Marking the row
  by making it the lightest in the menu, which is what every menu here did
  before any fill, emphasises the one choice pressing cannot change and leaves
  the live options reading as the disabled ones — so the ink stays
  `textPrimary` against `textMuted` and the band and the check are what carry
  it. **The band spans the menu edge to
  edge**; it is safe against the rounded corners because Material pads the item
  list by 8 px top and bottom, twice `OaaRadius.sm`, and nothing here overrides
  that. A call site that sets `menuPadding: EdgeInsets.zero` must also pass
  `clipBehavior: Clip.antiAlias`. `test/menu_row_test.dart` asserts all three
  signals, the reserved column and the band's contrast floor against the menu's
  surface, in both skins, because nothing about a screenshot says which of them
  is meant to be there.
- **Every number uses `OaaType`'s tabular figures.** A readout whose digits
  change width jitters while you watch it.
- **A `BoxDecoration` may not combine `borderRadius` with a non-uniform
  `Border`.** Flutter asserts, the decoration paint aborts, and it takes the
  child with it — a correctly sized box containing nothing. Use a sibling strip
  inside a `ClipRRect`.
- **`ModuleFrame` is a `StatelessWidget` and stays off the frame path.** Only
  its child repaints, inside a `RepaintBoundary`, so a spectrogram scrolling at
  60 fps cannot dirty the border around it.
- **`ReadoutPainter` holds `ui.Paragraph`s.** It belongs in a `State` so it
  survives the painter being recreated on a theme change, and it must be
  disposed.
- **A paragraph aligned centre or right needs a `maxWidth`.** Alignment is
  relative to the line box, and `layoutParagraph` gives an unconstrained one a
  megapixel of width — so the glyph is drawn half a megapixel from where it is
  painted while `longestLine` still reports the ink, and every measurement
  taken around the label agrees it is somewhere it is not. Centre a bare
  paragraph by measuring it instead. `test/app_test.dart` fails on a new one.
- **An end label of a `ScaleGraticule` is held inside the track.** The first
  and last gridlines sit on the track's own edges, and a track is normally
  flush with the edge of its module, so a label centred on one is a label with
  half of it clipped away.

## Panels

Every modal in Open Audio Analyzer — settings, presets, the delivery-target
editor, the analysis report, the remote panels, the keyboard sheet — is composed
the same way, out of `src/panel.dart` and nothing else. **A panel that invents
its own structure is a panel that will be visibly a different product from the
one beside it**, and the way that happens is never a decision; it is a `Row`
with two `SizedBox`es in it that nobody had a reason to write differently.

### The shell

`showOaaPanel` opens it. Not `showDialog`, and not `showGeneralDialog` by hand:
a route is built by the `Navigator`, which sits *above* `MaterialApp.home`, so a
panel sees only what the application installed above its navigator.
`showOaaPanel` re-provides the palette from there — `MaterialApp.builder`, where
`OaaApp` puts it beside the Material theme — and paints its own scrim, because a
route's `barrierColor` is fixed when the route is constructed and a skin change
is not. `PanelScaffold` provides the `Material` that every stock widget drawing
an ink response needs. The reasons all three are load-bearing are in the file;
the palette one cost a phase of panels that could not follow a skin change while
they were open, which is precisely when skins are chosen.

`showOaaConfirm` is the one shape built on top of it rather than beside it: a
yes-or-no question over whatever is already open, returning false for Cancel,
the × and the scrim alike. **It is a modal over a modal, which this system
otherwise refuses**, and it exists for the one case the in-place confirmation
cannot carry — an action whose consequence is larger than the control that
starts it, where a button reading `Reset?` is a sentence nobody has read.
Settings' delivery-target reset is the only caller; `lib/src/panels/AGENTS.md`
has the test for when a second one would be justified. Two conventions bend
inside it and both are argued in the function's own header: it is **420** wide,
because a dialog exactly as wide as the panel under it reads as that panel
having been replaced, and its destructive button is **last**, in the affirmative
slot, because in a confirmation the destructive action *is* the affirmative one.

`showOaaSavePrompt` is its sibling and the only other modal-over-a-modal: the
same 420, asked when a command would replace work that is not in a file. It has
**three** answers, and the third is the reason it is not `showOaaConfirm` with a
different label — Don't Save is a decision about the document rather than a
refusal of the question, and collapsing it into Cancel leaves the only way to
discard an edit being the button that keeps it. Save is last, in the affirmative
slot, because here the answer that loses nothing is the recommended one; Don't
Save takes the destructive slot hard left; Cancel, the × and the scrim all
answer cancel.

`PanelScaffold(title:, child:, onClose:, footer:, width: 620)`.

- The title is sentence case in the source. The title bar uppercases it.
- `onClose` is the ×. Always pass it.
- The body is `Column(crossAxisAlignment: stretch)` of sections, and nothing
  else. The scaffold owns the padding; do not add your own.
- The footer is a `Row` you own: status text in an `Expanded` on the left or a
  `Spacer` if there is none, then buttons left to right in increasing emphasis
  with the affirmative one **last**. A destructive button goes hard left,
  before the spacer.
- **The footer is the only place a primary (accent) button is allowed.** See
  the note on `OaaColors.accent`: the signal hue means "this is a measurement"
  everywhere else — every number a module prints wears it — and selection
  *inside* a panel is `hairlineStrong`. The exception buys the affirmative
  button and nothing else.
- **One way out per panel.** A Done next to a Close is two.
- **`width:` is for a panel of rows, and there are two exceptions.** 620 is a
  column of labels and controls read left to right in short lines; the keyboard
  sheet is a reference *table* read by scanning down it, and at that width its
  seventeen rows did not fit the scaffold's 760 px of height, so it scrolled and
  cut its own footnote in half. It takes 880 and two columns. A confirmation
  takes 420, through `showOaaConfirm` rather than by writing a number, because a
  dialog the same width as the panel under it reads as a replacement rather than
  as something laid on top. A third panel wanting its own width is a panel to
  look at twice — but these are the shapes that fix those two, and the way the
  sheet is kept honest is `test/scaling_test.dart`, which fails if it ever needs
  to scroll at the smallest window the application supports.
- **A panel makes room for the software keyboard, and asks its own context how
  much room.** `PanelScaffold` pads its bottom by
  `MediaQuery.viewInsetsOf(context).bottom`, which is the keyboard's height in
  an overlay route and *zero* inside a `Scaffold` body — the default
  `resizeToAvoidBottomInset` has already taken the keyboard out of that body's
  height and hands it a MediaQuery with the inset removed, and the remote
  display screen builds the host picker straight into one. Reading the window
  instead breaks both mountings: the body's panel loses the height twice, and
  the route's panel never moves at all, because `View.of` establishes no
  dependency to rebuild on when the metrics change. Moving the panel is only
  half of it — the scroll view is what then puts the *field* in front of
  whoever is typing, which `EditableText` asks it to do on the same metrics
  change. Only a tablet has a keyboard to be covered by, so nothing on a desk
  can show you this; the three cases are in `test/panels_test.dart`.

- **A panel wider than the window is a panel the window shrinks.** `width:` is a
  maximum, so a layout that only works at that maximum breaks quietly below it —
  text wraps, which is fine, and boxed controls do not, which is not. The sheet
  stacks its two columns into one under a `LayoutBuilder` rather than letting
  its keycaps run past the edge, where a `Row` clips them in release with
  nothing said.

- **A scrolling region says it does not want the platform's scrollbar, or it
  gets a second one.** `MaterialScrollBehavior` wraps every *vertical*
  scrollable in a `Scrollbar` of its own on macOS, Windows and Linux — asked
  for by nothing, logged nowhere — so `PanelScaffold`'s own 4 px thumb in
  `hairlineStrong` had Flutter's 8 px grey one immediately inside it, fading in
  on every scroll. The body is wrapped in
  `ScrollConfiguration(behavior: …copyWith(scrollbars: false))` for that reason.
  Two things make this class of defect hard to see: a tablet gets no ambient
  bar, so only a desktop run shows it, and the platform in a widget test
  defaults to Android, so the whole panel suite passed throughout. A test for it
  therefore names its platforms and counts by the *controller* a bar was handed
  rather than by widget type — the second bar is a private `RawScrollbar`
  subclass, and a multiline `EditableText` inside the body carries a third that
  `EditableText` insists on and that never draws. `test/panels_test.dart`.

### The body

| Use | For |
|---|---|
| `PanelSection(title:, note:, ruled:, children:)` | A group of rows. Draws a hairline above itself — **`ruled: false` on the first section in a panel only**, where a rule under the title bar is a doubled line. |
| `PanelRow(label:, child:, note:)` | A label and a control on one line, with the explanation full-width beneath. The note is *not* beside the control: sharing the line means every note wraps at whatever the control left over. The gap above it clears the control rather than hugging the label, because the row is as tall as whatever sits on its right. |
| `PanelListRow(title:, note:, selected:, onTap:, trailing:, mark:, opens:)` | A row that selects rather than acts — a preset, a skin, a discovered host, one arm of a chooser. `mark:` for a list whose rows are *kinds* rather than peers; `opens:` puts a chevron on the ones that push a panel instead of choosing in place. The title brightens on hover and focus, so a list nothing is ever selected in does not read as disabled. |
| `PanelNote(text, tone:, mark:)` | Prose below the rows it explains. `tone:` only for the ones that are warnings, and `mark:` with it — a panel is mostly caption-sized prose in one grey, and one step of colour is enough to see once you are looking and not enough to stop you scrolling past. |
| `PanelActions(children:)` | The button row that ends a section. |
| `SegmentedControl` / `OaaButton` / `OaaToggle` / `OaaTextField` / `PanelMenu` | The controls. There are no others. |
| `OaaColorWell` + `OaaColorPicker` | A colour, in the one panel that edits thirteen of them. **The decision this table asks for, made and written down:** a text field alone very nearly won — the format is hex, `Skin.parseColor` already takes every spelling of it, and zero new controls is a real argument in a system whose premise is that a closed set cannot drift. What decided it is that typing hex is a way of *recording* a colour you have already chosen, and nobody chooses one that way. The field is still underneath and is still what commits. |

Anything reached for outside this table is a decision to make here first.

**A section with no rows says so in its heading's note, not in a note below
it.** A `PanelNote` under a heading with nothing beneath it reads as a row that
failed to draw, and a section note written for the populated case — "Tap a host
to show its meters here" — is an instruction to do something that cannot be
done yet when the list is still empty. Put the state of the list in the
section's own `note` and keep `PanelNote` for the things that are genuinely
notes. Found in the host picker, in a rendering, in both directions.

### Control metrics

**Every boxed control is `OaaControl.height`.** `OaaButton`, `PanelMenu`,
`SegmentedControl` and `OaaTextField` stand side by side in a row; while each
derived its height from its own type style and its own padding they came out at
30, 31.4 and 28.9 px and no two of them ever matched. A new control that sits in
a row with these takes the same constant. `OaaToggle` is exempt and so is
`PanelListRow` — a switch and a block of text are not boxed controls.

**A control's own word is uppercase; a value it holds is not.** `OaaButton` and
`SegmentedControl` set their labels in `OaaType.label` — the caps face, tracked
out — the same way the tabs and every section heading do, and both uppercase in
the widget so call sites stay sentence case. `PanelMenu` and `OaaTextField` do
not, because what they show is a device name, a target or something typed, and
shouting a user's own words at them is a different statement. The segmented
control was the exception for eight phases and it read as prose that happened to
have a box around it: `Test tone` beside a `RESCAN` in the row below.

**A control whose value is a *point* comes through `OaaFocusable.plane`.**
There is exactly one — the colour picker's saturation/value square — and it
exists because `.range` cannot be bent into it: `.range` binds right *and* up
to `onIncrease`, which is right for a slider drawn either way round and useless
for a surface whose two axes are different quantities. So the four arrows are
separate, shift multiplies the step by ten (a two-hundred-pixel square is a
hundred presses across at one step a time, which is reachable and not usable),
and assistive technology gets four *named custom actions* rather than an
increase/decrease pair that would silently expose half the control.

**A control that has to focus itself takes `OaaFocusable`'s `focusNode`.** A
`FocusableActionDetector` is reached by Tab and not by a click, which is right
for a button — clicking one runs it — and wrong for a value: somebody who has
just clicked a point on a colour plane is exactly the person about to nudge it,
and being told to Tab back to the thing under their pointer is not an answer.
The picker owns its nodes and requests them on the way down.

**A control that opens something is a `OaaFocusable`, not a `PopupMenuButton`.**
The Open Audio Analyzer theme sets `NoSplash` and a transparent highlight, so a
`PopupMenuButton`'s `InkWell` renders no hover and no focus ring at all — its
child becomes a control the keyboard can land on invisibly. `PanelMenu` drives
`showMenu` by hand for exactly this reason.

**Stock Material arrives with a shadow.** `showMenu` and anything like it needs
`elevation: 0` with `shadowColor` and `surfaceTintColor` transparent, or it
lands as the one floating card in an interface of panels sitting flush.

**A mark is geometry, not a glyph.** `▾` and `✓` are in neither Inter nor most
of the fallback stack, and the first build of `PanelMenu` put a tofu box where
the caret should be, on both menus, on every platform. Draw it — `src/glyph.dart`
holds the set, `_Caret` is the one that predates it, and `OaaMark.check` is the
second of the two the sentence above names.

**The set of marks is closed, and it is eleven.** `OaaMark.broadcast`,
`display`, `chevron`, `check`, `qr`, `scan`, `warning`, `undo`, `redo`,
`settings` and `restart`. `display` has
had no call site since the remote display's chooser panel became two controls in
the menu bar; it is kept rather than deleted because it is half of a pair
— "this machine sends" against "this machine shows" — and the set is a
vocabulary rather than an inventory of what is currently drawn. A vocabulary
that gains a mark per panel is one nobody learns — the reader stops to decode each one, which
is slower than the word it replaced — so a new mark is a decision to make in
`glyph.dart`, with a sentence saying what it tells the reader that the text
beside it does not. There is no icon font here and there is not going to be one.

**Nine of the eleven annotate a word; the last two replace one, and that is an
exception with its argument written down.** `settings` and `restart` are the
menu bar's two panel commands drawn as marks, and what earns them the exception
is arithmetic rather than taste: that row's width is what decides whether the
open document's name can be centred in the window at all, and `SETTINGS` plus
`RESET` are 61 px more of it than two marks. Both are also marks a reader
already holds without being taught, which is the test the rule above is really
applying — a fader pair and a ring with a head on it are not new vocabulary.
The full argument is in `glyph.dart`'s own doc comment; do not extend it to a
third by analogy.

**The Material set was compared, not ignored.** `Icons.refresh` and
`Icons.restart_alt` are the canonical shapes, the font is already paid for by
`uses-material-design: true`, and Flutter tree-shakes it to what a build draws —
so the argument against them is not cost. It is the one `tab_strip.dart` makes
about `Icons.undo`: Material's icons are drawn on a 24 dp grid at their own ink
weight, several times heavier than the hairlines this interface is made from, and
one of them in the menu bar would sit beside `qr` and a seam from `undo`. Two
vocabularies in one row is worse than either. What the comparison settled is the
*size* of `restart`'s head — it is Material's, because a head small enough to be
tasteful is a head nobody reads as an arrow, and this one was twice too small
before it was held against theirs at 16 px in the same button.

**An arrowhead is a filled silhouette, not two strokes.** `restart`'s head was
drawn as two barbs turned off the arc's tangent first, and it is wrong at both
ends of the size range for the reason `_weight` exists: the stroke is a fixed
1.5 px whatever the mark is drawn at, so barbs long enough to read at 16 px are
whiskers half the radius long at 96, and barbs short enough to look right at 96
are a pixel of ink each in a row. A triangle has no stroke width to be out of
proportion with.

**A head on a circle is solved from the circle, and its tip is level.** Two
properties, and `restart` took four attempts to hold both. A triangle built off
the *tangent* leaves the curve as it grows: at the size this head has to be, its
tip sat 0.048 outside a ring of radius 0.30 — a sixth of the radius, which reads
exactly as an arrow that has come off its own path. And a head whose tip is not
halfway up its own height reads as an arrow pointing out of the ring rather than
round it, however correct the geometry is; that was the version with a *radial*
base, where the tip landed a hair above the base's lower corner.

The two cannot both be had with a radial base — solve `sin(θ) = -1` and the tip
lands on the base's own midpoint — so the base is a vertical chord standing
`length` behind a tip that is on the circle, crossing the ring rather than
sitting on it, and the arc's ink stops at that crossing so the stroke's round cap
ends underneath the head. `length` against `2 * half` is a shape rather than two
sizes: 0.26 by 0.29 is an arrowhead, 0.26 by 0.20 is a dart, 0.15 by 0.29 is a
wedge. Both are large because the mark is drawn at 16 px and nowhere else.

**A mark on a `PanelNote` centres on the note, not on its first line.** The
mark annotates the whole sentence, and every note that carries one wraps — two
lines in a panel, three on a phone-shaped display. Hung at the top of a wrapped
paragraph it reads as belonging to the first line rather than to the note, which
is what the remote panel's password warning looked like against its two lines of
orange.

**A shape whose proportions are the point is cut, not stroked.** `OaaMark.qr`
is drawn on the 24-unit grid Material Symbols uses, and its three finders are
rings made by an even-odd fill rather than by stroking a square. A stroke keeps
one weight whatever the mark is drawn at, so the hole closes as the glyph
shrinks and three grey blobs are left where the one feature a QR code is
recognised by should be. This is the exception that proves the weight rule
below: the ring's thickness is part of the symbol, not a line drawn around it.

**A mark's stroke weight is a property of the mark, not of its size.**
`_MarkPainter._weight`, and it is `OaaStroke.mark` for every one of them: they
all sit beside the words that name the thing, and a mark heavier than the
graticules a few pixels away is a second idea of "thin" in one interface.
Nothing scales the stroke with `size` — a mark beside a caption and a mark
beside a title are the same line. `undo` and `redo` were briefly set at
`OaaStroke.emphasis`, which was right while they stood alone in the tab strip
carrying an action with no word to be found by; beside `UNDO` and `REDO` that
weight is a mark shouting over its own label. A second weight here needs a
second reason of that kind.

That last part is a decision and not an oversight, so it is worth writing down
why the obvious escape does not apply. `Icons.undo` and
`CupertinoIcons.arrow_uturn_left` **are** platform-independent — both are
ordinary TTFs Flutter rasterises itself, not lookups into the host's symbol set
the way SF Symbols is, and the Material font is already bundled by
`uses-material-design: true`. The objection is not portability. It is that both
are filled shapes drawn on a 24 dp grid: at the sizes this interface uses them
they carry several times the optical weight of the hairlines everything else is
made of, and one imported vocabulary beside a drawn one is two.

**A mark inside a control must refuse hits.** `CustomPainter.hitTest` returns
null by default and `RenderCustomPaint` reads that as *true*, so a glyph dropped
into a row is a dead spot in the middle of it — the row still works everywhere
else, which is what makes it ship. `_MarkPainter` returns false, for the same
reason `MeterPainter` does; `test/panels_test.dart` presses a row on its own
mark.

The rule is about *symbols* — arrows, carets, ticks, geometric shapes, box
drawing — and deliberately not about a codepoint range. Punctuation is fine and
is already everywhere: the ellipsis, the em dash, the typographic minus and the
right single quote are all outside Latin-1, all present in Inter, and all
render correctly (`Choose…` and `Streaming (−14 LUFS)` are captures, not
assumptions). Do not go replacing em dashes.

### Multi-step modals

**Push a second panel; do not mutate the first one's body.** `showOaaPanel` is
a route with a zero-length transition, so pushing costs nothing on screen,
Escape and the system back gesture return to the parent for free, and each
panel stays a plain widget with its own title. A panel that swapped its own body
would have to hand-roll the back stack the `Navigator` is already keeping. The
settings panel has always done this — it pushes the delivery-target editor and
the theme editor from rows inside itself.

Do not add a Back button when the parent panel is directly behind: the × and
Escape are the way out, and a third one is clutter.
