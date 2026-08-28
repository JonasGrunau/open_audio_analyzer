# lib/src/panels/

The panels that sit over the canvas. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `settings_panel.dart` | Signal — the source, the capture device and the connected DAW plugin — refresh rate and delivery target, publishing, skins, session. The hub the others open from. Its Publish section is `PublishSection`, composed from `lib/src/remote/` because it reads a live socket. |
| `calibration_editor.dart` | The six numbers a delivery target is. |
| `theme_editor.dart` | The thirteen colours a skin is. Previews by *being* the skin — every change goes into `skinDraftProvider`, which `skinProvider` answers with — and prints each role's contrast ratio against the surface it has to be read on. The two built-ins are fixed and it says so before anything is dragged. |
| `report_panel.dart` | Offline analysis: drop a file, watch it run, cancel it, export the result. |
| `report_card.dart` | The report as a **PNG** — a fixed layout drawn deliberately, not a screenshot of the panel, so two people exporting the same report get the same picture. It lives here rather than beside the other exports in `oaa_core` because rendering needs `dart:ui`. |
| `shortcuts_sheet.dart` | The keyboard shortcuts, drawn from the table in `lib/src/app/shortcuts.dart`. Holds no list of its own. The one panel that is wider than 620 and laid out in two columns, because it is a reference table rather than a column of controls — see `packages/oaa_ui/AGENTS.md` § Panels, and `test/scaling_test.dart`, which fails if it ever needs to scroll again. |

**Presets are not a panel.** They were until 0.11.0 — `preset_browser.dart` was
a name field, a list of everything in `presets/`, and two save-time switches —
and they are documents now: `File → Open…`, `Save` and `Save as…` over the
platform's own dialogs, from `lib/src/app/preset_file.dart`. Nothing in this
directory opens or saves one. What is left here is the sentence in Settings →
Session that says where the folder is and what the commands are called.

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

- **A destructive action confirms in place, until it deletes more than the row
  it is in.** The delete button becomes `Delete?` and takes a second press. No
  undo stack for files.

  **The exception is an action whose consequence does not fit on the button, and
  there is exactly one.** Settings → Meters → **Reset** removes every file in
  `calibrations/` — targets somebody wrote months ago, and corrections they made
  to the built-ins, none of which is visible from that row. A changed word on a
  button can be pressed through in half a second by somebody who has read
  nothing, so this one goes through `showOaaConfirm`, which is a modal over a
  modal and says in its own header why it is allowed to be. The test of which
  applies: can the sentence describing what will be lost fit on the button? One
  skin, one preset, the target the row is about — yes. A whole library — no.

  **A question with three answers is `showOaaSavePrompt`, and there is one of
  those too.** "This layout has changes that are not in a file" is answered by
  Save, Don't Save or Cancel, and the third is not a refusal — deciding to
  discard an edit is a decision, and folding it into Cancel would leave the only
  way to throw work away being the button that keeps it. Cancel, the × and the
  scrim all answer cancel; Save takes the affirmative slot because it is the
  answer that loses nothing, and Don't Save takes the destructive one hard left.

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

  **A row whose *contents* are somebody else's to change is the exception, and
  it listens.** Settings › Signal offers the connected DAW plugins, and those
  arrive and leave on a DAW's schedule — very possibly because the row itself
  just said nothing was connected — so it is a `ListenableBuilder` over
  `PluginLink`, which notifies on membership and on nothing else. That is the
  line: session *membership* is a human doing something in another application;
  a session's *measurements* are the frame path and never come through here.

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
