# packages/oaa_ui/

The design system. Every visual decision in Open Audio Analyzer is made here
exactly once.

| File | Contents |
|------|----------|
| `src/tokens.dart` | `Space`, `OaaControl`, `OaaRadius`, `OaaStroke`, `OaaColors`, `OaaType`. |
| `src/theme.dart` | `OaaTheme` (an `InheritedWidget`) and a derived Material theme. |
| `src/module_frame.dart` | `ModuleFrame` — the chrome all fourteen modules sit inside. |
| `src/meter_painter.dart` | The base every module painter extends. It exists to make `hitTest` return false; see the rules below. |
| `src/readout.dart` | `ReadoutPainter` (cached paragraph layout) and `ReadingState`. |
| `src/text_cache.dart` | `layoutParagraph` for static labels and `ValueParagraph` for changing ones — the cache that re-lays out only when a *formatted string* differs. |
| `src/scale.dart` | `MeterScale` and `ScaleGraticule`. Five modules draw a dB scale, and two side by side whose ticks disagree look like a rendering bug. |
| `src/grid_geometry.dart` | Grid cells to pixels. The one place the 24×16 canvas becomes a rectangle. |
| `src/point_buckets.dart` | Marks sorted by the colour they are drawn in, so a display of tens of thousands of them is a few dozen `drawRawPoints` calls. Behind the stereo cloud; the spectrogram drew through it too until real material's run counts outgrew it. |
| `src/panel.dart` | `PanelScaffold` and the controls panels are assembled from, plus `showOaaPanel`. |
| `src/qr.dart` | `QrCode` — just enough QR to carry one address, byte mode at error level M — and `OaaQrCode`, which paints it. The one widget here that does not take its colours from the skin: a code is read by thresholding a camera image, and dark-on-light is a property of the format rather than a choice. Held against ZXing by `test/qr_test.dart`. |
| `src/glyph.dart` | `OaaMark` and `OaaGlyph` — the closed set of marks the interface draws, as paths. There is no icon font, and a mark that is a codepoint is a mark that can go missing. |
| `src/skin_palette.dart` | The one adapter between a `Skin` (data, in `oaa_core`) and a `OaaColors`. |
| `src/focusable.dart` | `OaaFocusable` — keyboard focus, Enter/Space activation and the screen-reader identity every control Open Audio Analyzer paints itself would otherwise be missing. |
| `src/drag_devices.dart` | `kDragDevices` — the `supportedDevices` every drag detector needs, and why a trackpad is not one of them — and `kTouchDragDevices`, the narrower set that an enlarged, invisible hit target is admitted to. |

## Rules

- **No raw spatial or colour values anywhere in the repo.** If a layout needs a
  value that is not in `Space`, that is a design decision — make it here, name
  it, and use it everywhere. Thirteen modules drift apart one `EdgeInsets.all(11)`
  at a time.
- **No shadows.** Depth is background steps and hairlines. Shadows imply
  floating cards; measurement gear is machined panels sitting flush. This
  includes Material's own — see the Panels section.
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
  the note on `OaaColors.accent`: the signal hue means "in spec" everywhere
  else, and selection *inside* a panel is `hairlineStrong`. The exception buys
  the affirmative button and nothing else.
- **One way out per panel.** A Done next to a Close is two.
- **`width:` is for a panel of rows, and the keyboard sheet is the one
  exception.** 620 is a column of labels and controls read left to right in
  short lines; the sheet is a reference *table* read by scanning down it, and at
  that width its seventeen rows did not fit the scaffold's 760 px of height, so
  it scrolled and cut its own footnote in half. It takes 880 and two columns.
  A second panel wanting the same is a panel to look at twice — but this is the
  shape that fixes it, and the way it is kept honest is
  `test/scaling_test.dart`, which fails if the sheet ever needs to scroll at the
  smallest window the application supports.
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

### The body

| Use | For |
|---|---|
| `PanelSection(title:, note:, ruled:, children:)` | A group of rows. Draws a hairline above itself — **`ruled: false` on the first section in a panel only**, where a rule under the title bar is a doubled line. |
| `PanelRow(label:, child:, note:)` | A label and a control on one line, with the explanation full-width beneath. The note is *not* beside the control: sharing the line means every note wraps at whatever the control left over. The gap above it clears the control rather than hugging the label, because the row is as tall as whatever sits on its right. |
| `PanelListRow(title:, note:, selected:, onTap:, trailing:, mark:, opens:)` | A row that selects rather than acts — a preset, a skin, a discovered host, one arm of a chooser. `mark:` for a list whose rows are *kinds* rather than peers; `opens:` puts a chevron on the ones that push a panel instead of choosing in place. The title brightens on hover and focus, so a list nothing is ever selected in does not read as disabled. |
| `PanelNote(text, tone:, mark:)` | Prose below the rows it explains. `tone:` only for the ones that are warnings, and `mark:` with it — a panel is mostly caption-sized prose in one grey, and one step of colour is enough to see once you are looking and not enough to stop you scrolling past. |
| `PanelActions(children:)` | The button row that ends a section. |
| `SegmentedControl` / `OaaButton` / `OaaToggle` / `OaaTextField` / `PanelMenu` | The controls. There are no others. |

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
holds the set, `_Caret` is the one that predates it.

**The set of marks is closed, and it is eight.** `OaaMark.broadcast`,
`display`, `chevron`, `qr`, `scan`, `warning`, `undo` and `redo`. `display` has
had no call site since the remote display's chooser panel became two controls in
the status bar; it is kept rather than deleted because it is half of a pair
— "this machine sends" against "this machine shows" — and the set is a
vocabulary rather than an inventory of what is currently drawn. A vocabulary
that gains a mark per panel is one nobody learns — the reader stops to decode each one, which
is slower than the word it replaced — so a new mark is a decision to make in
`glyph.dart`, with a sentence saying what it tells the reader that the text
beside it does not. There is no icon font here and there is not going to be one.

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
settings panel has always done this — it pushes the preset browser and the
delivery-target editor from rows inside itself.

Do not add a Back button when the parent panel is directly behind: the × and
Escape are the way out, and a third one is clutter.
