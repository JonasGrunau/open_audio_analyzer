# lib/src/app/

The shell everything else is mounted in. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `bel_app.dart` | `MaterialApp`, the widget that owns the engine and the clock, the status bar, and the notices. |
| `shortcuts.dart` | **Every keyboard shortcut Bel has, as one table**, plus the widget that installs it and the generator for `docs/site/keyboard.md`. |
| `launch_options.dart` | `--config-dir` and `--open-panel`, parsed by hand. |

## Rules

- **A shortcut is one row in `belShortcuts` and nothing else.** The bindings,
  the sheet `?` opens, and the documentation page are all derived from that
  list, and `test/shortcuts_test.dart` fails when the checked-in Markdown has
  drifted from it. Adding a binding anywhere else — a `CallbackShortcuts` in a
  panel, a bare `Focus.onKeyEvent` — creates a shortcut that works and is
  documented nowhere.

- **`BelShortcuts` installs a `FocusScope`, and it is load-bearing.** A key
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

- **`--open-panel` is debug-only and says so when it is not.** A release build
  reports the flag as unusable rather than ignoring it; a flag that silently
  does nothing sends somebody to debug their script.

- **Anything the command line could not understand is shown, not printed.** A
  desktop application's stdout goes nowhere a user will look. Warnings are
  joined onto the storage notice rather than replacing it: a misspelt flag is
  worth mentioning, a config directory that cannot be written is worth more.
