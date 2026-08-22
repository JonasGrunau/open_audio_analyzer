# lib/src/canvas/

The arrangeable canvas. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `workspace.dart` | `Workspace` state, the Riverpod controller every layout edit goes through, undo/redo, and the default preset. |
| `grid_canvas.dart` | The canvas: positioning, drag, resize, selection, the drag preview overlay, and the six-layer stack per module that decides what a pointer over one means. |
| `canvas_notice.dart` | The one line the canvas says out loud. Refusals only. |
| `module_host.dart` | The only place that knows which `ModuleKind`s exist as code, and where "too small" is decided — in cells *and* in pixels. |
| `tab_strip.dart` | Tabs, inline rename, and the add/undo/redo buttons. Three of the four are a word with a `OaaMark` or a `+` beside it; only the tab plus stands alone. |
| `menus.dart` | The popup menus the canvas and the strip share. |

The placement rules themselves are **not here** — they are pure functions over
`TabSpec` in `oaa_core/src/grid.dart`, so the same rules hold for a preset
loaded from disk and for the remote display, and so they can be tested with no
window. Anything that decides *where a module may go* belongs there; anything
that decides *what a pointer means* belongs here.

## Rules

- **A drag must not rebuild anything.** The module stays where it is and a
  single `ValueNotifier` drives one painter that draws the target rectangle.
  Moving the module itself during the gesture would rebuild a dozen live meter
  subtrees per pointer event, at exactly the moment the user is watching the
  screen most closely. The layout is edited once, on release.

- **The notifier's value is immutable with a real `==`.** Pointer events that do
  not change which cell is targeted must not repaint.

- **Everything a drag shows is drawn by that one painter.** The scrim over the
  modules that are not being carried, the ruled cells, the border around them
  and the ghost are four draws in `_PreviewPainter`, not widgets. A
  `BackdropFilter` — the obvious way to blur instead of dim — would be a widget,
  so it would rebuild the canvas on both edges of the gesture, and it would
  re-run a full-screen Gaussian every frame over meters that are still
  publishing at 47 Hz. The scrim costs one path, and the raster thread
  composites it over the meters' own layers without touching them.

- **Interaction layers sit *behind* the module, not in front.** That is what
  gives the frame's own menu button priority without any gesture-arena
  arbitration. It only works because nothing in `ModuleFrame` absorbs pointer
  events — see `MeterPainter` and the `IgnorePointer` around the title label. If
  you add chrome, check it is inert: `DecoratedBox` and `Text` both absorb by
  default, and the failure is silent.

  **A control inside a module works with that rather than against it**, and the
  oscilloscope's slider strip is the first one. An opaque detector in the module
  takes the hit before the selection catcher underneath ever sees it, so nothing
  has to be arbitrated and no layer has to move — which is what `_ModuleSlot`'s
  note about a body that wants scrubbing anticipated. Two things it does have to
  do: keep clear of the **corner grip**, whose ink is 16 px and whose touch
  target is twice that, both drawn *above* `ModuleHost` at the bottom-right
  corner (`_gripClearance` in `oscilloscope.dart` is that reservation); and give
  every drag detector `kDragDevices`, like every other one here. A right click
  over such a control opens no menu, because an opaque detector with no
  secondary handler absorbs that too — acceptable for a sixteen-pixel strip on a
  module whose whole face still opens it, and worth knowing before somebody adds
  a taller one.

- **An illegal drop is not a drop.** Nothing snaps to a nearby free space and
  nothing pushes a neighbour aside. Validity is shown live while the pointer is
  down and an invalid release leaves the layout untouched.

- **A refusal must say so, through `canvasNoticeProvider` and nowhere else.**
  "No room for that" surfaces at the foot of the canvas; a click that silently
  does nothing is indistinguishable from a broken canvas, and the user's next
  move is to click again. Two paths can refuse — a drop the grid will not take,
  and a module added from the keyboard — and the second lives *above* this
  directory, which is why the notice is a provider rather than a
  `ValueNotifier` in `grid_canvas.dart`. A second toast is two timeouts, two
  positions and eventually two wordings for one refusal.

- **The keyboard is not here.** `grid_canvas.dart` keeps a `Focus`, because a
  key event needs a focused node to start from; the bindings are one table in
  `lib/src/app/shortcuts.dart`, wrapped around the whole workspace. They used to
  live here and stopped working whenever focus left the canvas — opening the
  source picker was enough to silently disable undo. Add a shortcut there.

- **Selection is not an edit.** It never enters the undo history. Undo that
  walks back through every click before it undoes anything is undo nobody uses.

- **Every affordance needs a non-keyboard, non-right-click route.** Open Audio
  Analyzer runs on tablets. Add, undo and redo are buttons in the tab strip for
  that reason, and a long press opens the same menu a secondary click does — on
  empty canvas and on a tab.

- **Not a double tap. Ever.** `DoubleTapGestureRecognizer` holds the gesture
  arena from the first tap until `kDoubleTapTimeout` — 300 ms — and a held
  arena is never swept, so *every* tap recogniser under it waits that long to
  resolve. Both routes into "add a module here" and "rename this tab" were
  double clicks, and they made the tabs and the whole macOS status bar feel
  like an application that was busy. A long press is the touch-and-mouse
  gesture that costs nothing: it rejects the moment the pointer lifts early.
  The macOS window's top edge does answer a double click, and it is not an
  exception to this: `lib/src/app/window_chrome.dart` recognises single taps and
  AppKit pairs them. That is available because the gesture belongs to the
  platform, which nothing on a canvas does.

- **Every `onPan*` detector passes `kDragDevices` to `supportedDevices`.** A
  trackpad pan is not a button press, so `allowedButtonsFilter` — which defaults
  to the primary button — never sees it: it arrives as a pan-zoom sequence,
  admitted by `supportedDevices` alone, and accepted on the *start* event with
  no slop to cross. A two-finger gesture anywhere over a title bar therefore
  dragged the module, and since a two-finger tap is how a trackpad sends a right
  click on macOS, opening a module's menu flashed the placement grid. The grip
  had it too, and so did the window drag area in `lib/src/app/`.

- **An affordance smaller than a fingertip carries a touch layer *beneath* it,
  never a second recogniser on top.** The title bar paints 24 px and the corner
  grip 16, both under the 44 pt and 48 dp the platforms ask for, and neither can
  grow outward: a slot is a `Positioned.fromRect`, and a `RenderBox` rejects
  hits outside its own size, so a box overhanging the gutter would paint there
  and never be touched. So `_ModuleSlot` puts a larger, invisible
  `HitTestBehavior.translucent` detector *under* each one, admitting
  `kTouchDragDevices` alone. Two properties make that work and both are easy to
  lose. **Translucent, so the layer is added to the hit-test result and returns
  false** — a mouse, which it admits no drag from, carries on down to the
  selection catcher and still selects the module. **Underneath, so the opaque
  affordance above masks the part of it they share**: `RenderStack.hitTestChildren`
  walks back to front and stops at the first child that returns true, which
  leaves exactly one pan recogniser in the arena rather than two identical ones
  racing to accept. Put the touch layer on top instead and both are live at
  once. Size them in `GridCanvas`, where the module's pixel rect is known — the
  touch grip sits above `ModuleHost`, so on a short module an unclamped square
  reaches the frame's menu button and the move strip and takes both.

- **`pumpAndSettle` does not work in tests here.** The meter clock schedules a
  frame forever by design, so the tree never settles. Pump a fixed duration.

- **Everything in the tab strip reserves the height of the active-tab rule.** A
  `_Tab` carries a bottom border whether or not it is the active one, and a
  border insets the child — so a tab's label is centred in the strip *minus*
  the rule while an unbordered button is centred in the whole of it. Add a
  control to the strip without that reservation and its label sits a pixel
  below every tab name, which is invisible in a review and obvious on screen.

- **A mark in the strip is not aligned by centring it, and the offset is
  measured rather than derived.** Centring puts the middle of a *line box* in
  the middle of the row, and a line box is taller than the cap band inside it
  and not concentric with it — so every word in the strip is off by the same
  amount and agrees with itself, while a drawn mark or a larger glyph centred
  beside them is not. `_HistoryAction._drop` and `_Plus._drop` are those
  offsets.

  The formula is tempting and it does not work. Cap band as a fraction of the
  label size, math axis as a fraction of the plus size, subtract: that lands
  the lone plus and is out by two thirds of a pixel on the one inside
  `+ MODULE`, because the two do not sit in the same kind of box — one is
  centred alone in the row, the other by a `Row` against a line box two thirds
  its height. One number per site, measured, beats one formula that is nearly
  right.

  Eyeballing this in a widget test finds nothing, and neither does looking at
  the app. Render the strip to a PNG (`RepaintBoundary` above `MaterialApp`,
  `toImage` inside `tester.runAsync`, real fonts via `FontLoader` — see
  `CLAUDE.md`), threshold it, and compare ink bounding boxes. Re-measure when a
  size changes.
