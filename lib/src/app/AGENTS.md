# lib/src/app/

The shell everything else is mounted in. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `oaa_app.dart` | `MaterialApp`, the widget that owns the engine and the clock, the status bar, and the notices. |
| `bar_controls.dart` | `BarButton`, `BarChip` and `BarSwitch` — the three shapes the status bar is built from. Public because the bar is not assembled in one file: `PublishSwitch`, `PairingCodeButton` and `AttachButton` own a socket between them and live in `lib/src/remote/`. |
| `shortcuts.dart` | **Every keyboard shortcut Open Audio Analyzer has, as one table**, plus the widget that installs it and the generator for `docs/site/keyboard.md`. |
| `transport_readout.dart` | The DAW's playhead, painted: position, tempo and meter, and the rules about which of the three a host has actually earned the right to have drawn. Built by the status bar and by the tablet's link bar, which is why it lives here rather than in `lib/src/remote/`. |
| `launch_options.dart` | `--config-dir` and `--open-panel`, parsed by hand. |
| `preset_file.dart` | **The preset as a document**: which file the canvas came from, whether it differs from that file, and the four commands — Open, Save, Save as, and the two rows that decide what the preset carries. The file dialogs sit behind a seam a test replaces, because a native panel is a modal sheet owned by the platform and there is nothing in a test to tap. |
| `file_menu.dart` | The File menu, drawn twice: `FileMenuButton` in the status bar off macOS, and `MacFileMenu` over a channel to `macos/Runner/OaaFileMenu.swift` on it. Also `RouteDepth`, which is how the second one knows to grey. |
| `window_chrome.dart` | The window itself: the palette its buttons are drawn against, the room the status bar leaves them, and the drag and zoom a window with no title bar cannot get for free. macOS only. |

## Rules

- **The `OaaTheme` belongs in `MaterialApp.builder`, not around `home`.**
  `builder` wraps the `Navigator`; `home` is inside it. A panel is a route, so a
  palette under `home` is one no panel can see — and for eight phases every
  panel was handed a copy taken when it opened, which left the settings panel in
  the previous skin while the canvas behind it, the window chrome and its own
  Material widgets moved to the new one. Anything else a route must be able to
  read goes in the same place, for the same reason.

- **Nothing in the status bar is `Flexible`, because the bar has a `Spacer`.**
  `Spacer` is an `Expanded` with `flex: 1` and `Flexible` defaults to `flex: 1`
  too, so `RenderFlex` divides the row's free space *between them*. The Spacer
  is tight and takes its share; a loose `Flexible` takes only what its child
  asks for, and the difference is laid out after the last child — so the whole
  trailing group drifts left, by half of every pixel the window gains. It looks
  like a missing alignment and it is a flex-factor collision; nothing overflows
  and no assertion fires. Bound a long label with a `ConstrainedBox` and an
  ellipsis, as the source and calibration pickers do, and drop whole items at
  narrow widths through the `LayoutBuilder` rather than squeezing them.

- **Adding anything to the bar means re-checking every drop-out gate, and
  re-checking them means measuring.** There are eight — preset, transport,
  format, analyse, attach, pairing code, publish, file — plus help, and they are
  arithmetic on each other rather than independent numbers: one control becoming
  three moved every gate above it by 165 px, and putting the source in a chip
  moved every single one of them — 25 px for the five below the format readout
  and 40 px for the format gate and the one above it, which is the chip's
  border and padding plus the seam that now follows it. A gate is a statement
  about the *left group's* floor as much as about its own item: what overflows
  at the bottom of the bar is the group inside the `Expanded`, not the bar's
  own row. The row is a sum of fixed widths, so it
  does not shrink — it overflows, which is a striped warning in debug and
  silently clipped controls in release. One gate at 860 px was carried for a
  phase on the strength of looking right at every window anybody had opened,
  and it was 20 px short: at the smallest window the platform allowed, the bar
  ran 121 px past its own edge. `test/scaling_test.dart` pumps the whole
  application every 20 px from 480 to 2560 and fails on the overflow; the gates
  are cliffs, so sampling round numbers is not enough. The order items leave in
  is stated in `_StatusBar` and is a design decision, not a fitting exercise.

  **One term in that arithmetic is the platform.** FILE is only built where
  there is no system menu bar to put the File menu in, so every gate above its
  own carries `+ file` — 58 px on Windows and Linux, zero on macOS, which keeps
  the numbers there exactly as they were measured. The sweep runs on a macOS
  host, so it would have drawn that button at no width at all: `_pumpApp` takes
  `inWindowMenu` and there is a band of the sweep that passes it, which is the
  only reason the five widths where the button did not fit were found before
  anybody on Windows saw them.

- **An overflow is not the only thing an item can do to that row, and the other
  thing is silent.** The bar's left group is the `Expanded`, and its children
  pack left, so the space between it and the first item of the right-hand group
  is whatever the window is not using — zero from the moment the row is full,
  which is most of the band above a new item's gate. The source name ellipsises
  before the row overflows, so nothing fails: the sample rate and channel count
  simply printed flush against the transport readout at every width from about
  1160 px to 1310 px, with a green sweep the whole time. Anything placed at that
  seam states its own gap and counts it into its gate; `test/scaling_test.dart`
  measures the gap at every swept width now, and a `SizedBox` outside the
  `Expanded` is what makes it a gap rather than a wish.

- **A readout's box is a reservation, so decide which edge the ink sits
  against.** A painted readout is given a fixed width so the row does not move
  when the reading does — `ElapsedReadout` reserves 72 px, `TransportReadout`
  92 — and whatever a shorter string leaves over has to go somewhere. It goes on
  the far side of the ink from the group the readout belongs to, so that it
  joins the row's own slack instead of becoming a hole between two items. Both
  readouts on the right of the bar are therefore packed right. The playhead was
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

- **Everything in the status bar is a `BarButton`, a `BarChip` or a
  `BarSwitch`, and the two menus are both chips.** The delivery target and the
  signal source report what a reading *is* — what it is measured against, and
  what is being measured — so they wear the same shape, and the source carries
  a state dot the target has no use for. The source spent eight phases as a
  bare dot and a word beside four bordered controls, which reads as a caption
  rather than as a menu: the commonest thing anybody changes in the bar was the
  one item in it that did not look changeable. Not a `TextButton`, and not `OaaButton` either — `oaa_ui`'s
  buttons are sized for a panel, where a control has a row to itself, and these
  are sized for a 40 px bar that also holds the source, the clock and the
  calibration. `BarSwitch` is the third because a state you
  set is not a state you press, and it is not `OaaToggle` for a reason that is
  about colour rather than size: `OaaToggle` fills with `accent`, and `accent`
  in this row means "in spec". All three take their height from
  `_barControlHeight` rather than adding one up out of a text style and a
  padding — `OaaControl.height`'s argument applied
  to this bar, and for the same reason: the two styles differ, so the chip stood
  3.4 px taller than the buttons and its border crossed theirs in a row where
  the borders are the only horizontal line.
  The bar is not assembled in one file, which is how the remote display's entry
  spent a phase putting a borderless, ink-rippled, keyboard-unreachable Material
  button between four bordered ones.

- **A control the bar may drop is a control nothing may depend on running.**
  The publish service used to be configured, and its layout, skin and delivery
  target published, from inside the status-bar widget's `build` — so narrowing
  the window past that item's gate left the socket streaming measurements while
  everything else about them stopped arriving, and settings written in a panel
  with no gate at all were never adopted. The service moved out to
  `_WorkspaceState` when a narrow window used to tear the session down; what
  drives it did not follow until `RemoteDisplayScope`, which is built
  unconditionally above the bar. Anything that has to keep happening belongs
  there.

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

- **The status bar is the window's title bar on macOS, and two numbers say so.**
  `_StatusBar.height` is written out again in `MainFlutterWindow.swift`, because
  the window buttons have to be centred on the row in the first frame and Dart
  has not run yet; nothing can share it. Move one without the other and the
  buttons sit a few points above or below the row they are part of, which reads
  as a fault in the row. `WindowChrome.statusBarLeading` is the second: AppKit
  draws those buttons over the top of whatever Flutter paints there, so a bar
  that starts at `Space.md` starts underneath them.

- **The status bar's double click is counted in AppKit, not in Flutter.**
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
  the canvas being a fixed 24x16 cells: the row height is `(height - 104) / 16`
  once the status bar, the tab strip and the canvas inset are taken, and the
  smallest module in the default preset is two rows and needs 24 px of body
  left after its own title bar and margin. At the old 480 it had 12, which is
  why every Number Box on the default tab was an empty panel. The test is what
  keeps the Swift and the arithmetic in step.

- **`--open-panel` is debug-only and says so when it is not.** A release build
  reports the flag as unusable rather than ignoring it; a flag that silently
  does nothing sends somebody to debug their script.

- **Anything the command line could not understand is shown, not printed.** A
  desktop application's stdout goes nowhere a user will look. Warnings are
  joined onto the storage notice rather than replacing it: a misspelt flag is
  worth mentioning, a config directory that cannot be written is worth more.
