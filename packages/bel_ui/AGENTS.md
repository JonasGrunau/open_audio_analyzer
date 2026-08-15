# packages/bel_ui/

The design system. Every visual decision in Bel is made here exactly once.

| File | Contents |
|------|----------|
| `src/tokens.dart` | `Space`, `BelControl`, `BelRadius`, `BelStroke`, `BelColors`, `BelType`. |
| `src/theme.dart` | `BelTheme` (an `InheritedWidget`) and a derived Material theme. |
| `src/module_frame.dart` | `ModuleFrame` — the chrome all thirteen modules sit inside. |
| `src/meter_painter.dart` | The base every module painter extends. It exists to make `hitTest` return false; see the rules below. |
| `src/readout.dart` | `ReadoutPainter` (cached paragraph layout) and `ReadingState`. |
| `src/text_cache.dart` | `layoutParagraph` for static labels and `ValueParagraph` for changing ones — the cache that re-lays out only when a *formatted string* differs. |
| `src/scale.dart` | `MeterScale` and `ScaleGraticule`. Five modules draw a dB scale, and two side by side whose ticks disagree look like a rendering bug. |
| `src/grid_geometry.dart` | Grid cells to pixels. The one place the 24×16 canvas becomes a rectangle. |
| `src/point_buckets.dart` | Marks sorted by the colour they are drawn in, so a display of tens of thousands of them is a few dozen `drawRawPoints` calls. Behind the spectrogram and the stereo cloud. |
| `src/panel.dart` | `PanelScaffold` and the controls panels are assembled from, plus `showBelPanel`. |
| `src/skin_palette.dart` | The one adapter between a `Skin` (data, in `bel_core`) and a `BelColors`. |
| `src/focusable.dart` | `BelFocusable` — keyboard focus, Enter/Space activation and the screen-reader identity every control Bel paints itself would otherwise be missing. |
| `src/drag_devices.dart` | `kDragDevices` — the `supportedDevices` every drag detector needs, and why a trackpad is not one of them. |

## Rules

- **No raw spatial or colour values anywhere in the repo.** If a layout needs a
  value that is not in `Space`, that is a design decision — make it here, name
  it, and use it everywhere. Thirteen modules drift apart one `EdgeInsets.all(11)`
  at a time.
- **No shadows.** Depth is background steps and hairlines. Shadows imply
  floating cards; measurement gear is machined panels sitting flush. This
  includes Material's own — see the Panels section.
- **Every number uses `BelType`'s tabular figures.** A readout whose digits
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

Every modal in Bel — settings, presets, the delivery-target editor, the
analysis report, the remote panels, the keyboard sheet — is composed the same
way, out of `src/panel.dart` and nothing else. **A panel that invents its own
structure is a panel that will be visibly a different product from the one
beside it**, and the way that happens is never a decision; it is a `Row` with
two `SizedBox`es in it that nobody had a reason to write differently.

### The shell

`showBelPanel` opens it. Not `showDialog`, and not `showGeneralDialog` by hand:
a route is built by the `Navigator`, which sits *above* `MaterialApp.home`, so a
panel sees only what the application installed above its navigator.
`showBelPanel` re-provides the palette from there — `MaterialApp.builder`, where
`BelApp` puts it beside the Material theme — and paints its own scrim, because a
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
  the note on `BelColors.accent`: the signal hue means "in spec" everywhere
  else, and selection *inside* a panel is `hairlineStrong`. The exception buys
  the affirmative button and nothing else.
- **One way out per panel.** A Done next to a Close is two.

### The body

| Use | For |
|---|---|
| `PanelSection(title:, note:, ruled:, children:)` | A group of rows. Draws a hairline above itself — **`ruled: false` on the first section in a panel only**, where a rule under the title bar is a doubled line. |
| `PanelRow(label:, child:, note:)` | A label and a control on one line, with the explanation full-width beneath. The note is *not* beside the control: sharing the line means every note wraps at whatever the control left over. |
| `PanelListRow(title:, note:, selected:, onTap:, trailing:)` | A row that selects rather than acts — a preset, a skin, a discovered host, one arm of a chooser. |
| `PanelNote(text, tone:)` | Prose below the rows it explains. `tone:` only for the ones that are warnings. |
| `PanelActions(children:)` | The button row that ends a section. |
| `SegmentedControl` / `BelButton` / `BelToggle` / `BelTextField` / `PanelMenu` | The controls. There are no others. |

Anything reached for outside this table is a decision to make here first.

**A section with no rows says so in its heading's note, not in a note below
it.** A `PanelNote` under a heading with nothing beneath it reads as a row that
failed to draw, and a section note written for the populated case — "Tap a host
to show its meters here" — is an instruction to do something that cannot be
done yet when the list is still empty. Put the state of the list in the
section's own `note` and keep `PanelNote` for the things that are genuinely
notes. Found in the host picker, in a rendering, in both directions.

### Control metrics

**Every boxed control is `BelControl.height`.** `BelButton`, `PanelMenu`,
`SegmentedControl` and `BelTextField` stand side by side in a row; while each
derived its height from its own type style and its own padding they came out at
30, 31.4 and 28.9 px and no two of them ever matched. A new control that sits in
a row with these takes the same constant. `BelToggle` is exempt and so is
`PanelListRow` — a switch and a block of text are not boxed controls.

**A control that opens something is a `BelFocusable`, not a
`PopupMenuButton`.** The Bel theme sets `NoSplash` and a transparent highlight,
so a `PopupMenuButton`'s `InkWell` renders no hover and no focus ring at all —
its child becomes a control the keyboard can land on invisibly. `PanelMenu`
drives `showMenu` by hand for exactly this reason.

**Stock Material arrives with a shadow.** `showMenu` and anything like it needs
`elevation: 0` with `shadowColor` and `surfaceTintColor` transparent, or it
lands as the one floating card in an interface of panels sitting flush.

**A mark is geometry, not a glyph.** `▾` and `✓` are in neither Inter nor most
of the fallback stack, and the first build of `PanelMenu` put a tofu box where
the caret should be, on both menus, on every platform. Draw it — see `_Caret`.

The rule is about *symbols* — arrows, carets, ticks, geometric shapes, box
drawing — and deliberately not about a codepoint range. Punctuation is fine and
is already everywhere: the ellipsis, the em dash, the typographic minus and the
right single quote are all outside Latin-1, all present in Inter, and all
render correctly (`Choose…` and `Streaming (−14 LUFS)` are captures, not
assumptions). Do not go replacing em dashes.

### Multi-step modals

**Push a second panel; do not mutate the first one's body.** `showBelPanel` is
a route with a zero-length transition, so pushing costs nothing on screen,
Escape and the system back gesture return to the parent for free, and each
panel stays a plain widget with its own title. A panel that swapped its own body
would have to hand-roll the back stack the `Navigator` is already keeping. The
settings panel has always done this — it pushes the preset browser and the
delivery-target editor from rows inside itself.

Do not add a Back button when the parent panel is directly behind: the × and
Escape are the way out, and a third one is clutter.
