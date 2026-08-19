# lib/src/app/

The shell everything else is mounted in. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `oaa_app.dart` | `MaterialApp`, the widget that owns the engine and the clock, the status bar, and the notices. |
| `bar_controls.dart` | `BarButton` and `BarChip` — the two shapes the status bar is built from. Public because the bar is not assembled in one file: `RemoteDisplayControl` owns a socket and lives in `lib/src/remote/`. |
| `shortcuts.dart` | **Every keyboard shortcut Open Audio Analyzer has, as one table**, plus the widget that installs it and the generator for `docs/site/keyboard.md`. |
| `launch_options.dart` | `--config-dir` and `--open-panel`, parsed by hand. |
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

- **Adding anything to the bar means re-checking the five drop-out gates, and
  re-checking them means measuring.** The row is a sum of fixed widths, so it
  does not shrink — it overflows, which is a striped warning in debug and
  silently clipped controls in release. One gate at 860 px was carried for a
  phase on the strength of looking right at every window anybody had opened,
  and it was 20 px short: at the smallest window the platform allowed, the bar
  ran 121 px past its own edge. `test/scaling_test.dart` pumps the whole
  application every 20 px from 480 to 2560 and fails on the overflow; the gates
  are cliffs, so sampling round numbers is not enough. The order items leave in
  is stated in `_StatusBar` and is a design decision, not a fitting exercise.

- **Everything in the status bar is a `BarButton` or a `BarChip`.** Not a
  `TextButton`, and not `OaaButton` either — `oaa_ui`'s buttons are sized for a
  panel, where a control has a row to itself, and these are sized for a 40 px
  bar that also holds the source, the clock, the calibration and the frame
  rate. Both take their height from `_barControlHeight` rather than adding one
  up out of a text style and a padding — `OaaControl.height`'s argument applied
  to this bar, and for the same reason: the two styles differ, so the chip stood
  3.4 px taller than the buttons and its border crossed theirs in a row where
  the borders are the only horizontal line.
  The bar is not assembled in one file, which is how `RemoteDisplayControl`
  spent a phase putting a borderless, ink-rippled, keyboard-unreachable Material
  button between four bordered ones.

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
