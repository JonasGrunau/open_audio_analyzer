# lib/src/app/

The shell everything else is mounted in. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `oaa_app.dart` | `MaterialApp`, the widget that owns the engine and the clock, **both bars**, and the notices. `_MenuBar` is the row across the top — the commands, and the open document's name centred in the window — and `_StatusBar` is the row across the bottom, which is every reading and the two menus that say what a reading is. |
| `bar_controls.dart` | `BarButton`, `BarChip` and `BarSwitch` — the three shapes both bars are built from — **and `BarMetrics`, the width of every control in them.** Public because neither row is assembled in one file: `PublishSwitch`, `PairingCodeButton` and `AttachButton` own a socket between them and live in `lib/src/remote/`, and because the widths are held against the widgets by `test/scaling_test.dart`. |
| `shortcuts.dart` | **Every keyboard shortcut Open Audio Analyzer has, as one table**, plus the widget that installs it and the generator for `docs/site/keyboard.md`. |
| `transport_readout.dart` | The DAW's playhead, painted: position, tempo and meter, and the rules about which of the three a host has actually earned the right to have drawn. Built by the status bar and by the tablet's link bar, which is why it lives here rather than in `lib/src/remote/`. |
| `launch_options.dart` | `--config-dir` and `--open-panel`, parsed by hand. Both exist to make something else reviewable on a Mac; a third that drew the in-window FILE button was folded into `fileMenuInWindowProvider`, which a debug build answers true. |
| `preset_file.dart` | **The preset as a document**: which file the canvas came from, whether it differs from that file, and the four commands — Open, Save, Save as, and the two rows that decide what the preset carries. The file dialogs sit behind a seam a test replaces, because a native panel is a modal sheet owned by the platform and there is nothing in a test to tap. |
| `file_menu.dart` | The File menu, drawn twice: `FileMenuButton` at the leading edge of the menu bar off macOS, and `MacFileMenu` over a channel to `macos/Runner/OaaFileMenu.swift` on it. Also `RouteDepth`, which is how the second one knows to grey, and `fileMenuInWindowProvider`, which decides between them. |
| `window_chrome.dart` | The window itself: the palette its buttons are drawn against, the room the menu bar leaves them, and the drag and zoom a window with no title bar cannot get for free. macOS only. |

## Rules

- **The `OaaTheme` belongs in `MaterialApp.builder`, not around `home`.**
  `builder` wraps the `Navigator`; `home` is inside it. A panel is a route, so a
  palette under `home` is one no panel can see — and for eight phases every
  panel was handed a copy taken when it opened, which left the settings panel in
  the previous skin while the canvas behind it, the window chrome and its own
  Material widgets moved to the new one. Anything else a route must be able to
  read goes in the same place, for the same reason.

- **The window has two rows and they have one membership rule: what you read is
  in the bottom one and what you press is in the top one.** `_StatusBar` carries
  the source, the format, the DAW's playhead, the elapsed clock and the delivery
  target — every one of them a reading or the units of one — and `_MenuBar`
  carries the File menu, ANALYSE FILE, the three remote controls, settings,
  restart and `?`, with the open document's name centred between them.

  They were one row for eight phases and it could not hold both jobs. The
  readings and the commands together left the document's own name with the
  highest width gate in the bar — gone below 1266 px of window — and put PUBLISH
  behind a gate too, which is the one item whose absence takes a capability away
  rather than hiding it: under it there was no way anywhere in the application to
  stop publishing. Both are fixed by the split rather than by a wider gate. A
  new item belongs in the row its own sentence puts it in; a control that reports
  a value *and* acts is a chip in the bottom row, which is what both pickers are.

- **Neither row may have a `Flexible` child beside its slack.** The menu bar's
  slack is a `Spacer` and the status bar's is an `Expanded` group, and both are
  an `Expanded` with `flex: 1` — `Flexible` defaults to `flex: 1` too, so
  `RenderFlex` divides the row's free space *between* them. The tight one takes
  its share; a loose `Flexible` takes only what its child asks for, and the
  difference is laid out after the last child — so the whole trailing group
  drifts left, by half of every pixel the window gains. It looks like a missing
  alignment and it is a flex-factor collision; nothing overflows and no
  assertion fires. Bound a long label with a `ConstrainedBox` and an ellipsis, as
  the two pickers do, and drop whole items at narrow widths through the
  `LayoutBuilder` rather than squeezing them. The one `Flexible` in either row is
  the source picker, and it is *inside* the status bar's `Expanded` group rather
  than beside it.

- **Every gate is arithmetic on `BarMetrics`, and `BarMetrics` is held against
  the widgets by a test.** A gate is the width at which everything up to and
  including one item still fits, which is a sum of the widths either side of it
  plus `BarMetrics.margin`. Do not write a measured total: write the sum. The
  eight hand-measured totals this replaced could only be re-derived by measuring
  all eight again — one control becoming three moved every one of them by 165 px,
  and putting the source in a chip moved all eight again by 25 or 40 px each —
  and twice a total was measured against a string the running application had
  already replaced. `REMOTE · 12` outgrew `REMOTE`, and the *default* delivery
  target's name is 100 px shorter than the longest one a user can pick; both
  times the suite stayed green while the row ran off its edge.

  `test/scaling_test.dart` now holds every number in that table from both sides:
  it loads the real typefaces, pumps the real rows, and fails with the number to
  write if a label grows **or if a bound has gone slack**. The second half
  matters as much as the first — a bound 40 px loose pushes every gate above it
  40 px out, which drops a control at a width it would have fitted at. It also
  still sweeps both rows for overflow every 20 px from 480 to 2560, and every
  5 px through the band where the five cliffs are, because a `Row` that cannot
  fit its children does not shrink them: it overflows, which is a striped
  warning in debug and silently clipped controls in release.

  **One term in that arithmetic is the platform.** FILE is only built where
  there is no system menu bar to put the File menu in, and the two arrangements
  differ by 2 px — 80 px of window buttons on macOS against 16 px of padding
  plus the button and its group seam elsewhere — which is why one set of gates
  answers all three platforms. It is a claim rather than a coincidence, so the
  sweep runs a band with `inWindowMenu` forced; the suite runs on a macOS host,
  where that button would otherwise be drawn at no width at all.

  **A debug build draws it on a Mac and a test run does not**, which is the one
  place `fileMenuInWindowProvider` is not simply the platform. A person running
  the application has to be able to see the row Windows and Linux ship — it was
  never once on screen here, and both defects it has had were ones a glance
  would have caught — while the suite, which is also a debug build on a macOS
  host, has to keep covering the row a Mac actually ships. So the provider reads
  `kDebugMode` and `FLUTTER_TEST`, and a test that wants the other arrangement
  overrides it.

- **The document's name is centred in the window, which means it is a layer of a
  `Stack` and not a child of the row — and two layers of a `Stack` overlap in
  silence.** A row can only centre a child between its neighbours, and these
  neighbours are nothing like the same width: 186 px of window buttons and one
  command against 394 px of everything else. Centred between them, the name
  would sit 104 px left of where a reader looks for it; centred in the window it
  has to clear the *wider* group twice over, which is what the room arithmetic in
  `_MenuBar` computes and what the two marks in the trailing group buy. There is
  no exception thrown, no stripe and no clipped control if that arithmetic is
  wrong — just a name printed underneath a button — so `test/scaling_test.dart`
  measures the distance from the name to every `BarButton` and `BarSwitch` in the
  row at every width it sweeps, and asserts the name is centred to within a
  pixel. Below `BarMetrics.titleFloor` there is no name at all rather than an
  ellipsis and a letter, which is the same rule the rest of both rows follows.

- **An overflow is not the only thing an item can do to a row, and the other
  thing is silent.** The status bar's left group is an `Expanded`, and its
  children pack left, so the space between it and the first item of the
  right-hand group is whatever the window is not using — zero from the moment
  the row is full, which is most of the band above a new item's gate. The source
  name ellipsises before the row overflows, so nothing fails: the sample rate
  and channel count simply printed flush against the transport readout at every
  width from about 1160 px to 1310 px, with a green sweep the whole time.
  Anything placed at that seam states its own gap and counts it into its gate;
  `test/scaling_test.dart` measures the gap at every swept width, and a
  `SizedBox` inside the `Expanded` is what makes it a gap rather than a wish.

- **A readout's box is a reservation, so decide which edge the ink sits
  against.** A painted readout is given a fixed width so the row does not move
  when the reading does — `ElapsedReadout` reserves 60 px, `TransportReadout`
  92 — and whatever a shorter string leaves over has to go somewhere. It goes on
  the far side of the ink from the group the readout belongs to, so that it
  joins the row's own slack instead of becoming a hole between two items. Both
  readouts in the status bar are therefore packed right. The playhead was
  packed left, and under a host that counts bars rather than frames its five
  characters sat in the middle of the title bar with 56 px of nothing beside
  them.

  **Which edge that is depends on where the slack is, so a reservation has to be
  placed next to some, and moving one in its row means choosing its edge again.**
  Neither value of `TransportAlign` can help a box with a hard item on both
  sides: the tablet's link bar had the same readout between the host name and the
  tab control, and its unspent reserve — 66 px under a host reporting a clock and
  a tempo, 190 under one reporting a clock alone — could only ever be a hole
  beside one of the two. It is behind the tabs now, where the row's own slack
  follows it. `test/remote_display_screen_test.dart` measures both gaps, with a
  playhead and without one.

- **Everything in either row is a `BarButton`, a `BarChip` or a `BarSwitch`, and
  the two chips are the two menus that hold a value.** The delivery target and
  the signal source report what a reading *is* — what it is measured against, and
  what is being measured — so they wear the same shape, and the source carries a
  state dot the target has no use for. The source spent eight phases as a bare
  dot and a word beside four bordered controls, which reads as a caption rather
  than as a menu: the commonest thing anybody changes in either row was the one
  item that did not look changeable. Not a `TextButton`, and not `OaaButton`
  either — `oaa_ui`'s buttons are sized for a panel, where a control has a row to
  itself, and these are sized for a 40 px row. `BarSwitch` is the third because a
  state you set is not a state you press, and it is not `OaaToggle` for a reason
  that is about colour rather than size: `OaaToggle` fills with `accent`, and
  `accent` in this application means "in spec". All three take their height from
  `_barControlHeight` rather than adding one up out of a text style and a padding
  — `OaaControl.height`'s argument applied to these rows, and for the same
  reason: the two styles differ, so the chip stood 3.4 px taller than the buttons
  and its border crossed theirs in a row where the borders are the only
  horizontal line. Neither row is assembled in one file, which is how the remote
  display's entry spent a phase putting a borderless, ink-rippled,
  keyboard-unreachable Material button between four bordered ones.

  **Three of the menu bar's buttons are a mark rather than a word, and that is
  an exception with an argument behind it.** `BarButton`'s own rule is that
  anything which can be said in a word is said in one, and `OaaMark`'s is that
  the set of marks is closed. Settings and restart broke both, because the row
  they are in is what decides whether the document's name can be centred in the
  window at all: `SETTINGS` and `RESET` are 145 px of the trailing group and two
  marks are 84, and that 61 px is the difference between a name on screen at the
  narrowest supported window and one that needs 1026 px. Neither is new
  vocabulary — a fader pair and a ring with a head on it are two of the three
  marks a reader already holds — and both keep a tooltip, which is where RESET's
  scope has always been written. The argument is in `OaaMark`'s own doc comment;
  a fourth mark is a decision to make there, not at a call site.

  **`?` is the fourth and it is not a mark: it is a label drawn at a mark's
  size** — `BarButton.labelIsMark`, which exists for this one button. No word
  for a sheet of key bindings is shorter or clearer than the character, so it
  stays type; but at the row's 10 px, standing between two marks drawn in a
  16 px box, it was the smallest ink in the group. `body`'s 13 px puts its cap
  band level with the marks' ink, which is the same "matched on weight rather
  than on height" rule `OaaGlyph`'s default size follows. Not 16: a glyph's ink
  fills its em where a mark's fills about two thirds of its box, so a 16 px `?`
  is the loudest thing in the row.

- **A control a row may drop is a control nothing may depend on running.** The
  publish service used to be configured, and its layout, skin and delivery
  target published, from inside the bar widget's `build` — so narrowing the
  window past that item's gate left the socket streaming measurements while
  everything else about them stopped arriving, and settings written in a panel
  with no gate at all were never adopted. The service moved out to
  `_WorkspaceState` when a narrow window used to tear the session down; what
  drives it did not follow until `RemoteDisplayScope`, which is built
  unconditionally above both rows. Anything that has to keep happening belongs
  there. PUBLISH itself no longer has a gate — the whole remote group survives
  every width the menu bar is built at — but the rule is what the gate taught.

- **The macOS File menu's chords come from `oaaShortcuts` too, over the
  channel.** `OaaFileMenu.swift` sets no key equivalent of its own: an
  `NSMenuItem` key equivalent *is* a binding, so one declared in Swift would be
  a shortcut that works and is documented nowhere — the thing the rule below
  exists to prevent. `fileCommandChord` reads it off the table and
  `fileMenuPayload` sends it, so ⌘S moves in one place or not at all.

  **`PlatformMenuBar` is the obvious tool and cannot do this job.** The
  `flutter/menu` channel carries no checked state at all — two of the six rows
  *are* a state, and Flutter's own sample toggles a row by rewriting its label —
  and `setMenus` replaces the whole main menu, which would delete the stock Edit
  menu that `MainMenu.xib` provides and that Flutter offers no platform-provided
  Cut, Copy or Paste to rebuild.

  **AppKit serves a key equivalent before the Flutter view sees the event**, so
  unlike the Dart bindings the menu fires while a panel is open — where a
  binding cannot, because a panel route sits above `OaaShortcuts`' `FocusScope`.
  `RouteDepth` counts routes and the menu greys above one, which is what stops
  ⌘O meaning different things on macOS and on Windows.

- **A shortcut is one row in `oaaShortcuts` and nothing else.** The bindings,
  the sheet `?` opens, and the documentation page are all derived from that
  list, and `test/shortcuts_test.dart` fails when the checked-in Markdown has
  drifted from it. Adding a binding anywhere else — a `CallbackShortcuts` in a
  panel, a bare `Focus.onKeyEvent` — creates a shortcut that works and is
  documented nowhere.

- **`OaaShortcuts` installs a `FocusScope`, and it is load-bearing.** A key
  event travels *up* from whatever holds focus, so a binding is only reachable
  from below it. When a text field goes away — finishing a tab rename, closing a
  panel — Flutter does not choose a new node; it drops focus to the nearest
  enclosing scope. Without one of our own that is the `Navigator`'s modal scope,
  which sits *above* the bindings, and the entire keyboard stops working until
  the user clicks something. It is indistinguishable from the shortcuts never
  having been installed.

- **A chord with no Ctrl or Cmd stands aside while a text field has focus.**
  Bare digits switch tabs; typing `Mix 2` into a tab name must not jump to the
  second tab halfway through. `Chord.guarded` decides this, and it is computed
  from the modifiers rather than listed per shortcut.

- **Both Ctrl and Cmd are bound, on every platform.** Asking the platform which
  one to accept is how a Mac driving an external PC keyboard ends up with no
  undo. Only the *printed* label is platform-specific, and that is a question
  about the keyboard in front of the user rather than about the OS.

- **The engine's lifetime belongs to `_WorkspaceState`, not to a provider.** It
  owns a native thread that must be stopped when the widget goes away, and the
  clock needs that element's vsync. A provider would add a second place for the
  disposal to be forgotten. The two things in its `initState` that must survive
  any refactor are the session autosave and the `AppLifecycleListener` that
  flushes pending writes on exit — the last edit before quitting is the one edit
  a user is most likely to notice losing.

- **The source is watched on a `Timer`, and it cannot be the meter clock.**
  `_watchSource` asks the local engine twice a second whether its capture source
  is still delivering, and reopens the engine when only a new one can follow the
  device to a new sample rate. Two reasons it is not folded into `MeterClock`,
  and both would have been bugs: a `Ticker` stops when the window is occluded,
  which is exactly when a tablet is the screen in use and a stopped device would
  go unrecovered for as long as the lid was shut; and the clock reads whatever is
  *on the canvas*, which may be a plugin, while the thing that can stop is
  always the local engine. It calls `refresh()` itself for the same reason —
  while a plugin holds the canvas, the local engine's snapshot is never read by
  anything else and goes stale by minutes.

  The reopen is capped and the cap is not optional: a source that stops again
  seconds after every reopen would otherwise discard a measurement every two
  seconds for as long as the application stayed open. Three attempts, forgiven
  after thirty seconds of the source behaving, and then a notice that says so
  instead. **The notice names going away and coming back as the manual remedy,
  not reselecting the source**, because choosing the source that is already
  chosen changes no setting and the source listener never fires — the comments
  in `oaa_tap.h` claimed otherwise for eight phases.

- **`_WorkspaceState` is a `TickerProviderStateMixin`, and must stay one.**
  There is only ever one clock alive, so the single-ticker mixin looks correct
  and is not: it allows one `createTicker` call *per State*, for the life of the
  State, and disposing the ticker does not buy another. A new clock is built for
  every source, so with the single mixin the source chosen at launch worked and
  every change after it threw. Worse, it threw a `FlutterError` out of the
  `setState` callback in `_openFor`, which catches `OaaEngineException` and
  nothing else: the engine was already created and started, so the capture
  device was opened and held with nothing reading it, while the window went on
  painting the previous source — same label, same channel count, same elapsed
  clock. Choosing a microphone looked exactly like a microphone that did not
  work. `test/source_switch_test.dart` changes the source twice for this reason;
  a test that stops at one source cannot see it.

- **The menu bar is the window's title bar on macOS, and two numbers say so.**
  `BarMetrics.rowHeight` is written out again as `menuBarHeight` in
  `MainFlutterWindow.swift`, because the window buttons have to be centred on the
  row in the first frame and Dart has not run yet; nothing can share it. Move one
  without the other and the buttons sit a few points above or below the row they
  are part of, which reads as a fault in the row. `WindowChrome.menuBarLeading`
  is the second: AppKit draws those buttons over the top of whatever Flutter
  paints there, so a bar that starts at `Space.md` starts underneath them — and
  it is a term in the centred name's arithmetic for the same reason, because the
  buttons are between the window's edge and the first thing the name may touch.
  The status bar has neither problem: nothing is drawn over it, so its padding is
  `Space.md` at both ends on every platform.

- **The menu bar's double click is counted in AppKit, not in Flutter.**
  Double-clicking it zooms the window, because it is the title bar and a Mac
  window whose title bar ignores that gesture ignores the system. A
  `DoubleTapGestureRecognizer` over this row holds the gesture arena for 300 ms
  and every control in it then answers that late — that shipped in 0.2.0, and it
  is why the gesture was taken out again in 0.3.0 rather than fixed. `WindowDragArea` recognises a
  single tap instead: it holds nothing, and it loses the arena to any control
  under it, so what crosses the channel is a click on the bar itself and never
  one a button took. `MainFlutterWindow.swift` pairs them, against
  `NSEvent.doubleClickInterval` and `AppleActionOnDoubleClick` — the interval
  and the action this Mac was configured with, neither of which Flutter knows.
  Not off `NSApp.currentEvent`, though `startDrag` two lines above does read the
  event: a tap resolves in Dart and comes back a frame later, when any pointer
  movement at all has replaced it, and `clickCount` raises on an event that is
  not a mouse click.

- **The minimum window size is arithmetic, and it is written down three
  times.** `minimumSize` in `MainFlutterWindow.swift`, `kMinimumWindow` in
  `test/scaling_test.dart`, and the sentence in `CHANGELOG.md`. It follows from
  the canvas being a fixed 24x16 cells: the row height is `(height - 144) / 16`
  once **both** bars, the tab strip and the canvas inset are taken, and the
  smallest module in the default preset is two rows and needs 24 px of body
  left after its own title bar and margin. At the old 480 it had 12, which is
  why every Number Box on the default tab was an empty panel. The test is what
  keeps the Swift and the arithmetic in step.

  **A second row costs the window its own height, not the modules theirs.** At
  768 a two-row Number Box had 4 px of body to spare and the Alert Meter had
  exactly none, so the status bar's 40 px could not come out of the canvas: the
  floor moved to 808 in the same change. The group that draws every module at
  its smallest legal size on the smallest window is what says so — a bar added
  to either edge of the window is a change to that arithmetic, and it fails
  there first.

- **`--open-panel` is debug-only and says so when it is not.** A release build
  reports the flag as unusable rather than ignoring it; a flag that silently
  does nothing sends somebody to debug their script.

- **Anything the command line could not understand is shown, not printed.** A
  desktop application's stdout goes nowhere a user will look. Warnings are
  joined onto the storage notice rather than replacing it: a misspelt flag is
  worth mentioning, a config directory that cannot be written is worth more.
