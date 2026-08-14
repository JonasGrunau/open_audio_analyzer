# lib/src/canvas/

The arrangeable canvas. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `workspace.dart` | `Workspace` state, the Riverpod controller every layout edit goes through, undo/redo, and the default preset. |
| `grid_canvas.dart` | The canvas: positioning, drag, resize, selection, the drag preview overlay, keyboard shortcuts. |
| `module_host.dart` | The only place that knows which `ModuleKind`s exist as code. |
| `tab_strip.dart` | Tabs, inline rename, and the add/undo/redo buttons. |
| `menus.dart` | The popup menus the canvas and the strip share. |

The placement rules themselves are **not here** — they are pure functions over
`TabSpec` in `bel_core/src/grid.dart`, so the same rules hold for a preset
loaded from disk and for the Phase 6 remote display, and so they can be tested
with no window. Anything that decides *where a module may go* belongs there;
anything that decides *what a pointer means* belongs here.

## Rules

- **A drag must not rebuild anything.** The module stays where it is and a
  single `ValueNotifier` drives one painter that draws the target rectangle.
  Moving the module itself during the gesture would rebuild a dozen live meter
  subtrees per pointer event, at exactly the moment the user is watching the
  screen most closely. The layout is edited once, on release.

- **The notifier's value is immutable with a real `==`.** Pointer events that do
  not change which cell is targeted must not repaint.

- **Interaction layers sit *behind* the module, not in front.** That is what
  gives the frame's own menu button priority without any gesture-arena
  arbitration. It only works because nothing in `ModuleFrame` absorbs pointer
  events — see `MeterPainter` and the `IgnorePointer` around the title label. If
  you add chrome, check it is inert: `DecoratedBox` and `Text` both absorb by
  default, and the failure is silent.

- **An illegal drop is not a drop.** Nothing snaps to a nearby free space and
  nothing pushes a neighbour aside. Validity is shown live while the pointer is
  down and an invalid release leaves the layout untouched.

- **A refusal must say so.** "No room for that" surfaces in the canvas; a click
  that silently does nothing is indistinguishable from a broken canvas, and the
  user's next move is to click again.

- **Selection is not an edit.** It never enters the undo history. Undo that
  walks back through every click before it undoes anything is undo nobody uses.

- **Every affordance needs a non-keyboard, non-right-click route.** Bel runs on
  tablets. Add, undo and redo are buttons in the tab strip for that reason.

- **`pumpAndSettle` does not work in tests here.** The meter clock schedules a
  frame forever by design, so the tree never settles. Pump a fixed duration.
