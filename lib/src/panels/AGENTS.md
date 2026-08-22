# lib/src/panels/

The panels that sit over the canvas. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `settings_panel.dart` | Signal and capture device, refresh rate and delivery target, publishing, skins, session. The hub the others open from. Its Publish section is `PublishSection`, composed from `lib/src/remote/` because it reads a live socket. |
| `preset_browser.dart` | Save the current arrangement; open or delete a saved one. |
| `calibration_editor.dart` | The six numbers a delivery target is. |
| `report_panel.dart` | Offline analysis: drop a file, watch it run, cancel it, export the result. |
| `report_card.dart` | The report as a **PNG** — a fixed layout drawn deliberately, not a screenshot of the panel, so two people exporting the same report get the same picture. It lives here rather than beside the other exports in `oaa_core` because rendering needs `dart:ui`. |
| `shortcuts_sheet.dart` | The keyboard shortcuts, drawn from the table in `lib/src/app/shortcuts.dart`. Holds no list of its own. The one panel that is wider than 620 and laid out in two columns, because it is a reference table rather than a column of controls — see `packages/oaa_ui/AGENTS.md` § Panels, and `test/scaling_test.dart`, which fails if it ever needs to scroll again. |

The primitives they are assembled from — `PanelScaffold`, `PanelSection`,
`PanelRow`, `PanelListRow`, `PanelNote`, `PanelActions`, `PanelMenu`,
`SegmentedControl`, `OaaButton`, `OaaToggle`, `OaaTextField`, `showOaaPanel` —
live in `oaa_ui/src/panel.dart`. A panel that rolls its own bordered box will
drift from the others within a month.

**How a panel is composed is specified once, in
`packages/oaa_ui/AGENTS.md` § Panels**, and it is not optional or local to this
directory: the shell, the footer convention, which primitive expresses which
kind of row, `ruled: false` on the first section only, and push-a-second-panel
rather than swap-your-own-body for anything with a second step. Read it before
adding a panel anywhere — including in `lib/src/remote/`, whose host picker and
pairing-code panel live there because they own a socket rather than because they
are a different kind of thing. The same goes for a *section*: `PublishSection`
is built there and composed into the settings panel here. Nothing about their
structure differs from the panels in this directory.

## Rules

- **Open with `showOaaPanel`, and build on `PanelScaffold`.** A route is built by
  the `Navigator`, which sits *above* the application's `Material`; without
  `PanelScaffold`'s, every `PopupMenuButton` and `TextField` becomes an error box
  — whose intrinsic width is near 100 000 px, so what you actually see is a
  `RenderFlex` overflow blaming an innocent `Row`. `showOaaPanel` is also what
  keeps a panel on the current skin: it reads the palette from above the
  navigator, where `OaaApp` installs it, so a skin chosen in the settings panel
  reaches the settings panel.

- **There is no OK button.** Every control writes through as it is touched. A
  panel with an OK button can be abandoned in a state the interface has already
  shown, and then the meters and the settings disagree.

  **"As it is touched" is not "on every keystroke", and the difference is one
  row.** The remote display's name and port are committed on Enter and on losing
  focus rather than per character, because a port is not a valid port until it
  is finished — binding to each prefix of one on the way to `5560` would move
  the socket three times. That is still write-through: an edit commits when the
  edit ends, and there is nothing left for a button to do. An Apply button was
  the first shape of it and is the shape this rule forbids.

- **A destructive action confirms in place.** The delete button becomes
  `Delete?` and takes a second press. No modal over a modal, and no undo stack
  for files.

- **Say why something failed, where it failed.** A save that did not happen puts
  the store's own message in the panel — not a log line, and never nothing.
  These panels are the only place a user finds out that persistence is not
  working.

- **Parse numbers leniently.** Accept the typographic minus (U+2212) and the
  comma decimal separator: the interface renders "−14 LUFS" itself, so anybody
  who copies a target out of Open Audio Analyzer and pastes it back in is
  pasting a character `double.parse` rejects, and half of Europe types "−0,5".

- **Nothing here is on the frame path.** These are ordinary widgets that rebuild
  when a human does something; the no-allocation-in-`paint` rule that governs
  `lib/src/modules/` does not apply. Do not import a meter or read a
  measurement — a panel that showed a live number would rebuild at meter rate.

## Testing

`test/panels_test.dart` drives them through the pointer. Two things it has to do
that are not obvious, both documented at the helpers:

- **Scroll a control into view before tapping it.** A panel body scrolls; a
  control below the fold still has a render box, `tap` still derives an offset
  from it, and the hit test lands on the backdrop.
- **Alternate `tester.runAsync` and `tester.pump` when waiting for a save.** The
  I/O only progresses on the real event loop; the continuation that records it
  only runs when the fake zone drains. Poll inside `runAsync` alone and the write
  completes with nothing to show for it.
