# packages/bel_ui/

The design system. Every visual decision in Bel is made here exactly once.

| File | Contents |
|------|----------|
| `src/tokens.dart` | `Space`, `BelRadius`, `BelStroke`, `BelColors`, `BelType`. |
| `src/theme.dart` | `BelTheme` (an `InheritedWidget`) and a derived Material theme. |
| `src/module_frame.dart` | `ModuleFrame` — the chrome all twelve modules sit inside. |
| `src/readout.dart` | `ReadoutPainter` (cached paragraph layout) and `ReadingState`. |

## Rules

- **No raw spatial or colour values anywhere in the repo.** If a layout needs a
  value that is not in `Space`, that is a design decision — make it here, name
  it, and use it everywhere. Twelve modules drift apart one `EdgeInsets.all(11)`
  at a time.
- **No shadows.** Depth is background steps and hairlines. Shadows imply
  floating cards; measurement gear is machined panels sitting flush.
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
