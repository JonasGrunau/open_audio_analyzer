<!-- Generated: 2026-08-15 | Updated: 2026-08-15 -->

# Open Audio Analyzer

## Purpose

A free and open-source loudness and spectrum analyzer for desktop and tablets —
a modular canvas of meter modules, driven by presets, delivery targets and
skins. A free reimplementation of the ideas in
[Decibel](https://process.audio/products/decibel) by process.audio.

`README.md` is the real design document: the architecture, the DSP spec table,
the licensing split and the honest list of gaps. Read it before changing
anything non-trivial. `docs/PLAN.md` is the full phased plan.

**Currently Phase 8 complete — every phase in `docs/PLAN.md` has shipped.**
All fourteen modules measure something. Loudness and true peak are held against
the EBU conformance cases in CI, and the spectrum against a sine of known
amplitude. Layouts, settings, delivery targets and skins persist as JSON under
the platform's configuration directory. Files are analysed offline by the app
and by the `oaa` CLI, a tablet mirrors the canvas over the wire protocol, and a
headless VST3 / AU plugin streams the DAW's audio and transport to the app. The
canvas is driven from the keyboard, the macOS, Windows and Linux installers
carry the plugin and install it behind a checkbox, there is also an AppImage and
a flatpak for the application alone, and the documentation site is generated
from this repository. See the
Roadmap in `README.md` for what each phase covered, its **Known gaps** for what
is still not built, and `docs/PLAN.md` for what was planned.

## Key Files

| File | Description |
|------|-------------|
| `engine/include/oaa/oaa.h` | The entire public C ABI. One header, three consumers. If it is not declared here it is not part of the engine. |
| `lib/src/clock/meter_clock.dart` | The only `Ticker` in the app. Everything repaints from it. |
| `packages/oaa_engine/hook/build.dart` | Compiles `engine/` and bundles it as a code asset. The app's only native build description. |
| `engine/CMakeLists.txt` | The same compile, for consumers that are not Dart. A plugin CI runner has no Flutter SDK. **Add a new engine source to both, or `plugin/test/sources_match.sh` fails the build.** |
| `plugin/src/OaaWire.h` | The wire protocol, producer side. `docs/WIRE.md` is the specification; this and `packages/oaa_wire/` are two implementations of it that must agree byte for byte. |
| `plugin/host/src/FakeDawEngine.cpp` | The fake DAW: file → transport → plugin → monitor, driven either by an audio device or by a loop with no device at all. The second one is what makes the plugin's whole path testable without a DAW or a person. |
| `packages/oaa_ui/lib/src/qr.dart` | Just enough QR to carry one address, and the widget that paints it. Held against ZXing — the decoder inside the scanner on the other end — by `test/qr_test.dart`, because a wrong mask produces something that looks exactly like a QR code and that no camera will read. |
| `lib/src/remote/pair_link.dart` | `oaa://host:port`. The one parser behind the pairing code, the scanned code and the address somebody types. |
| `packages/oaa_ui/lib/src/tokens.dart` | `Space`, `OaaControl`, `OaaRadius`, `OaaStroke`, `OaaColors`, `OaaType`. Nothing outside this file invents a spatial or colour value. |
| `packages/oaa_ui/lib/src/scale.dart` | `MeterScale` and `ScaleGraticule`. Five modules draw a dB scale; two side by side whose ticks disagree look like a rendering bug. |
| `packages/oaa_ui/lib/src/point_buckets.dart` | Marks sorted by the colour they are drawn in, one call per colour. What lets the stereo cloud redraw its whole accumulated grid every published frame instead of accumulating it into an image. The spectrogram drew through it too until its run counts on real material outgrew it — see its header. |
| `packages/oaa_ui/lib/src/color_ramp.dart` | `ColorRamp`'s colours. Two modules paint a quantity as a colour rather than as a length, and they are handed *different* quantities on purpose — colour carries whatever the module's axes do not. The reasoning is in the file header; it is the only place it is written down. |
| `engine/src/oaa_tap.h` | Capturing the system's own output on macOS with no driver — a Core Audio process tap, offered as one reserved device id. The engine's only Objective-C lives beside it in `oaa_tap_macos.m`, and it is the only source not built on every platform. |
| `engine/src/oaa_spectrum.h` | The Hann STFT: a 4096-point window, zero-padded into a 16384-point transform. The two lengths are not the same thing and the header says why. One set of transforms serves all three frequency modules. |
| `lib/src/canvas/module_host.dart` | The only place that knows which `ModuleKind`s exist as code. Exhaustive switch, no default arm. |
| `packages/oaa_core/lib/src/layout.dart` | `ModuleSpec` / `TabSpec` / `PresetSpec` — the serialised layout model. |
| `packages/oaa_core/lib/src/meter_source.dart` | `MeterSource` — everything a module is allowed to read. `OaaEngine` implements it; so does the remote display's decoder. |
| `docs/WIRE.md` | The wire protocol, normative. Three implementations, none written against another. |
| `ios/Runner/OaaBonjour.swift` | One of the application's **five** platform channels, and every one of them exists because a platform will not answer a question Flutter can. iOS refuses an app the multicast socket every other platform browses with, so a tablet searches through the system's Bonjour responder instead; `lib/src/remote/mdns/host_discovery.dart` is where the two meet. The others: `lib/src/app/window_chrome.dart` over `oaa/window_chrome`, which removes the macOS title bar; `macos/Runner/OaaFileMenu.swift` over `oaa/file_menu`, which is the File menu, because `PlatformMenuBar` can carry no checkmark and would replace the stock Edit menu — see `lib/src/app/file_menu.dart`, which sends it labels, ticks and the chords off the shortcut table; and Android's two — `OaaMulticastLock.kt`, without which its multicast socket receives nothing, and `OaaFilesDir.kt`, without which it has nowhere to save. Both Android halves are registered in `android/app/src/main/kotlin/com/openaudioanalyzer/oaa/MainActivity.kt`. |
| `packages/oaa_core/lib/src/grid.dart` | Every rule about where a module may go, as pure functions. No pixels. |
| `lib/src/canvas/grid_canvas.dart` | The canvas: drag, resize, selection, the preview overlay. |
| `lib/src/canvas/workspace.dart` | The one path every layout edit takes, and the undo history. |
| `lib/src/storage/config_store.dart` | Every read and write of the user's configuration. Atomic, never throws, and the only code in the app that touches the filesystem. **`root` is not a boundary** — `readJsonAt` and `writeJsonAt` take a path the user chose in a dialog, and they are here so that a preset saved to a Desktop is still written atomically. |
| `lib/src/data/providers.dart` | Settings, and the libraries of targets, skins and presets. One direction only: state is written to disk, never read back from it. |
| `packages/oaa_ui/lib/src/panel.dart` | The chrome every panel is built from, and `showOaaPanel`. |
| `packages/oaa_core/lib/src/skin.dart` | The thirteen colour roles a skin names, as data. `oaa_ui` owns the one adapter to `OaaColors`. |
| `engine/src/oaa_decode.c` | The only file that does I/O. `oaa_file_*` over dr_libs; no analysis, the caller pushes what it reads. |
| `packages/oaa_engine/lib/src/offline.dart` | The decode-push-read loop. Both the app and the CLI drive files through this one function. |
| `packages/oaa_core/lib/src/report.dart` | `AnalysisReport` and the delivery verdict. Holds no engine handle, so it round-trips through JSON. |
| `cli/bin/oaa.dart` | The `oaa` analyser. Its exit code is the product — see `cli/AGENTS.md`. |
| `lib/src/app/shortcuts.dart` | Every keyboard shortcut, as one table. The bindings, the `?` sheet, `docs/site/keyboard.md` **and the macOS File menu's key equivalents** are all derived from it; `test/shortcuts_test.dart` fails when the page has drifted. |
| `lib/src/app/preset_file.dart` | **The preset as a document.** Which file the canvas came from, whether it still matches that file, and the six File menu commands — one implementation, reached from the keyboard, from the macOS menu bar and from the status bar's own menu. The file dialogs sit behind a seam a test replaces. |
| `lib/src/app/launch_options.dart` | `--config-dir` and `--open-panel`. Both exist to make something else testable — see the file. |
| `packaging/icon/make_icons.dart` | The app mark, **read** from `assets/brand/oaa-logo.svg` and rendered into every container the six platforms want — a rounded tile for the desktops, two layers on a 108dp canvas for Android, and a layered `AppIcon.icon` for macOS and iOS that the system lights itself. It carries a path rasteriser because the mark is a stroked cubic path. It also writes the rest of `assets/brand/`, `packaging/icon/oaa.svg` and `website/public/`'s icons — every one except `website/public/favicon.svg`, which is a browser tab's 16 px and is drawn by hand. It wrote the tile over that file until 0.10.0, and there is a note where the line was. |
| `.tool-versions` | Pins Flutter `3.44.5-stable`. CI pins the same; keep them in step. |

## Subdirectories

| Directory | Purpose | License |
|-----------|---------|---------|
| `engine/` | C11 DSP core. No Dart, no Flutter. | MIT |
| `packages/oaa_engine/` | FFI bindings and the build hook. | MIT |
| `packages/oaa_core/` | Domain model. Pure Dart. | MIT |
| `packages/oaa_wire/` | The remote-display protocol. Pure Dart, no I/O. | MIT |
| `packages/oaa_ui/` | Design tokens and shared primitives. | GPL-3.0-or-later |
| `lib/` | The application. | GPL-3.0-or-later |
| `cli/` | The `oaa` command-line analyser. No Flutter binding. | GPL-3.0-or-later |
| `plugin/` | Headless VST3 / AU. Measures the DAW's audio, streams it to the app. Contains `host/`, the fake DAW that drives it. | **AGPL-3.0-or-later** |
| `docs/` | `PLAN.md`, `METRICS.md`, `WIRE.md`, and `site/`. Everything but `PLAN.md` and `AGENTS.md` is published, unaltered and in place, at `open-audio-analyzer.com/docs`. | |
| `tool/` | Repository scripts. Nothing here ships. | GPL-3.0-or-later |
| `packaging/` | pkg, Windows installer, Linux tarball, AppImage, flatpak, and the app icon they all need. The first three carry the VST3 (and on macOS the AU) and so are built from the plugin job's artefacts, not from the app alone. | GPL-3.0-or-later |
| `assets/` | The fonts the application bundles, and the logo the repository publishes. `brand/oaa-logo.svg` is the one drawing everything else is generated from. Three files here are also compiled into the plugin — two faces and the mark — so renaming one breaks that build; see `assets/AGENTS.md`. | GPL-3.0-or-later; fonts SIL OFL 1.1 |
| `website/` | `open-audio-analyzer.com` — a static Astro site that is also where the documentation is published, rendered from this repository's own Markdown in place. Two Flutter web targets give it its pictures — one photographs a module at a time, the other is a live canvas of eight — and both replay one recording rather than a mock: a Dart CLI measures a real track through the engine, and the `ReplaySource` they share plays it back, so a still and the live demo cannot disagree about what the material did. Built by the `website` job in `ci.yml` on every event and deployed by it on a push to `main`; it was deployed by hand until 0.11.0. | GPL-3.0-or-later; fonts SIL OFL 1.1 |

**`plugin/` is the one AGPL directory**, because JUCE 7 and 8 are
AGPLv3-or-commercial (only JUCE 6 offered GPLv3, which `docs/PLAN.md` still
assumes). Nothing there may be moved into `engine/` or `oaa_core/`, which are
MIT and must stay linkable by people who are not writing free software. The app
is unaffected: it never links JUCE — it talks to the plugin over a socket.

## For AI Agents

### Working In This Directory

- **Never invent a measurement.** A quantity the engine does not compute is
  `NaN` and carries a `OAA_FLAG_*_UNAVAILABLE` flag; the UI renders an em dash.
  Zero is *not* a placeholder — it is a legitimate reading for correlation,
  balance and several dB quantities. If you are tempted to return 0.0 so
  something "looks right", you are about to ship a number nobody measured, and
  a metering tool that does that is worthless.

- **Loudness ships with its conformance test or it does not ship.** K-weighting,
  R128 gating, LRA and true-peak land in the *same change* as the EBU
  R128 / BS.2217 vector suite that proves them. Not the next PR. A loudness
  meter that has never been run against the reference vectors is a number
  generator.

- **Nothing allocates on the frame path.** One FFI call per frame
  (`oaa_snapshot_acquire`), then painters read `Float32List` views built once at
  startup. Specifically, do not:
  - create a `Paint`, `Path`, `TextPainter` or list inside `paint()`;
  - route measurements through Riverpod, a `Stream`, or a `ValueNotifier` that
    widgets rebuild from;
  - give a module its own `Ticker` — there is exactly one, and independent
    tickers drift so that two meters can disagree within a frame. A module that
    must see *every* published measurement rather than every repaint listens to
    `MeterClock.measurements`, which is the same clock unthrottled and marks
    nothing dirty; a `Ticker` of its own is still never the answer;
  - lay out a `ui.Paragraph` when the formatted string has not changed.

- **`engine/` must not learn about Flutter, and `oaa_core` must not learn about
  `dart:ffi`.** Four consumers need the domain vocabulary and three of them have
  no engine — the tablet display reads measurements off a socket. The moment
  `oaa_core` imports `oaa_engine`, all three drag in a native library they never
  call. `lib/src/data/metric_reader.dart` is the *only* place the two meet.

- **A module reads `MeterSource`, never a concrete engine.** There are two
  implementations — `OaaEngine` over native memory, and `WireSnapshot` over a
  socket — and the fourteen modules cannot tell them apart. That is what lets a
  tablet with no engine draw the desktop's meters with the desktop's painters.
  If something cannot be drawn from a `MeterSource`, widen the interface; do not
  write a second painter, because two implementations of a meter are two meters
  that will eventually disagree about what the signal did.

- **`docs/WIRE.md` is normative and its byte tables are frozen per protocol
  version.** They were *derived* from `oaa_snapshot` but they are not tied to
  it: `OAA_ABI_VERSION` is a private matter between the engine and what links
  it, and if an ABI bump silently changed the wire, every display in the field
  would break by drawing wrong numbers rather than by failing. The handshake
  rejects on payload size, which moves exactly when a layout moves; the ABI
  version rides along as information and never refuses a link.

- **`oaa_engine` is not publishable.** `hook/build.dart` reaches out to
  `../../engine` with relative paths, which no published archive would contain.
  It is a workspace package and must stay one.

- **Every spatial value comes from `Space`.** No `EdgeInsets.all(11)`, no
  `SizedBox(height: 20)`. Thirteen modules written over as many weeks drift apart
  one raw number at a time. Same for colour: use `OaaColors`, never a literal.

- **Every number on screen is monospaced with tabular figures.** `OaaType`
  already does this. A readout whose digits change width jitters while you watch
  it.

- **Painted chrome absorbs pointer events unless you stop it.** A
  `CustomPaint` swallows every hit that lands on it, because
  `CustomPainter.hitTest` returns null and `RenderCustomPaint` reads that as
  true; `RenderDecoratedBox` does the same by asking the decoration, and a
  `BoxDecoration` says yes everywhere inside its shape; `RenderParagraph` says
  yes too. The canvas puts a module's drag and selection layers *behind* the
  module, so any of the three makes meters unclickable and undraggable with no
  error anywhere. Module painters extend `MeterPainter`, and inert chrome is
  painted rather than decorated. This cost real debugging time; see the header
  of `packages/oaa_ui/lib/src/module_frame.dart`.

- **Nothing in Open Audio Analyzer uses a `DoubleTapGestureRecognizer`.** It
  calls `gestureArena.hold` on the first tap and releases it only when
  `kDoubleTapTimeout` expires 300 ms later, and a held arena is never swept — so
  every tap recogniser beneath one, anywhere in the subtree, waits a third of a
  second before it can win. Three gestures were double clicks and each delayed
  everything under it: the status bar's zoom made every control in the row late
  on macOS, a tab's rename made switching tabs late, and adding a module on
  empty canvas made clearing the selection late. It presents as an application
  that is slow rather than as a gesture that is waiting, which is why it stood
  for a phase. **Use a long press** — it holds nothing and rejects as soon as
  the pointer lifts early, it works on a tablet, and it can open the same menu
  the secondary click does. A pan may share an arena with the buttons under it
  freely; only the double tap holds.

  **A gesture that is the platform's rather than ours is paired by the
  platform.** The macOS window's top edge is the one double click there is,
  because a Mac window whose title bar ignores one ignores the system — and it
  costs no recogniser: `WindowDragArea` recognises a single *tap*, which holds
  nothing and loses the arena to any control under it, so what crosses the
  channel is a click on the bar itself and never one a button took.
  `MainFlutterWindow.swift` decides which two of those are a pair, and it is the
  only side that can: the interval is the user's "Double-click speed" (half a
  second by default, not Flutter's 300 ms) and the action is their
  "double-click a window's title bar to". **Do not read the count off
  `NSApp.currentEvent`** the way `startDrag` reads the event — a tap resolves in
  Dart and comes back a frame later, by which time any pointer movement has
  replaced it, and `NSEvent.clickCount` raises on an event that is not a mouse
  click.

- **A drag detector takes `supportedDevices: kDragDevices`, always.** The
  companion trap to the one above, and it hides better. A `PanGestureRecognizer`
  filters buttons — `allowedButtonsFilter` defaults to the primary one — but a
  trackpad gesture is not a button press: it arrives as a
  `PointerPanZoomStartEvent`, `isPointerPanZoomAllowed` consults
  `supportedDevices` and nothing else, and the recogniser accepts on the *start*
  event with no slop to cross. So every `onPan*` detector in the application was
  also a two-finger-gesture detector. On macOS a two-finger tap is how a
  trackpad sends a right click, so right-clicking a module's title bar flashed
  the placement grid on screen; a two-finger scroll over one dragged the module,
  and over the status bar it handed the whole window to the compositor. All
  three sites are one constant in `packages/oaa_ui/lib/src/drag_devices.dart`.

- **A panel is built outside the application's `Material`,** because that lives
  under `MaterialApp.home` and a route pushed with `showGeneralDialog` is built
  by the `Navigator`, which sits above it. Every stock widget that draws an ink
  response — `PopupMenuButton`, `TextField` — is then replaced by an error box
  whose *intrinsic width is near 100 000 px*, which surfaces as a `RenderFlex`
  overflow blaming a `Row` that is perfectly fine. `PanelScaffold` provides the
  `Material`; use it and `showOaaPanel` rather than pushing a route by hand.

- **The palette is installed above the `Navigator`, in `MaterialApp.builder`,
  next to the Material theme.** It was under `home` for eight phases, so a panel
  could only be handed a copy of it taken when the panel opened — and Open Audio
  Analyzer's skins are chosen *in* the settings panel. Choosing one repainted
  the canvas, the window chrome and every Material widget inside the panel while
  the panel's own hairlines, fills and text stayed in the previous skin until it
  was closed and reopened: one panel in two skins at once. A palette a route
  cannot see is a palette a route cannot follow. `showOaaPanel` reads it from
  there and falls back to the call site's for a tree that wraps only its home.

- **A panel answers the software keyboard, and asks its own context how far to
  move.** `PanelScaffold` pads its bottom by
  `MediaQuery.viewInsetsOf(context)`, which is the keyboard's height in an
  overlay route and *zero* inside a `Scaffold` body — the default
  `resizeToAvoidBottomInset` has already taken the keyboard out of that body and
  hands it a MediaQuery with the inset removed. Both mountings are real: the
  remote display screen builds `HostPickerPanel` straight into a `Scaffold`, and
  the pairing panel pushes the same widget as a route. Read the *window* instead
  and the route's panel never moves at all, because `View.of` establishes no
  dependency to rebuild on when the metrics change. Only a tablet has a keyboard
  to be hidden behind, so no desktop run shows you any of it: the host picker's
  address field, the last row above its footer, sat under an iPad's keyboard with
  the caret and everything typed into it.

- **Nothing on the settings path may write to disk synchronously,** and nothing
  reads back from disk to find out what the state is. A user action calls a
  controller, the controller updates its state and asks the store to persist it.
  A persistence layer that is also a source of truth is one that can disagree
  with the interface.

- **A `testWidgets` body cannot await real file I/O.** It runs in a fake-async
  zone, and a future completed by the disk is delivered by the real event loop
  that zone never returns to, so the `await` simply never completes and the test
  hangs until the runner kills it — no error, no stack. Alternate
  `tester.runAsync` (to let the I/O progress) with `tester.pump` (to drain the
  continuation); see `_untilStored` in `test/panels_test.dart`.

- **A `BoxDecoration` may not combine `borderRadius` with a non-uniform
  `Border`.** Flutter asserts, the decoration paint aborts, and it silently
  takes the child with it — a correctly sized box containing nothing. Use a
  sibling strip inside a `ClipRRect` instead. This cost real debugging time; see
  `_Notice` in `lib/src/app/oaa_app.dart`.

- **A `ClipRRect` does not round a border — it amputates it.** The corollary of
  the rule above: once a surface is wrapped in a rounded clip, its
  `BoxDecoration` must repeat the *same* radius, or the clip removes the corner
  of the stroke along with everything else outside the arc. The border then runs
  the flat edges, stops dead at each tangent, and leaves four bare arcs. It is
  invisible in a widget test and unmistakable on screen. A *uniform* border may
  be combined with a radius freely; only a non-uniform one asserts. Every panel
  in the application shipped this way — see `PanelScaffold` in
  `packages/oaa_ui/lib/src/panel.dart`.

- **Never draw a `toImageSync` image into the picture that produces the next
  one.** That image is a handle to a display list the engine has not rasterised
  yet, and it holds that display list for its entire life — so frame *n*
  retains the picture that drew it, which retains frame *n−1*, back to the
  first frame. `dispose()` releases the Dart handle and nothing else; the chain
  owns the rest. The spectrogram, phase scope and stereo cloud all accumulated
  this way, which took the application to 266 GB and then killed the raster
  thread, whose destructors recurse once per retained frame and overflowed its
  stack 3,286 deep. **There is no way to accumulate into a GPU surface from
  `dart:ui`** — a display that needs history keeps that history as data, bounded
  by the module's size rather than by the length of the session, and either
  redraws it from scratch (the stereo cloud, through `PointBuckets`) or renders
  it to an RGBA buffer uploaded whole as a *pixel-backed* image per published
  frame (the spectrogram, through `ImageDescriptor.raw` — safe where
  `toImageSync` is not, because a pixel image holds bytes and no display list,
  and each one replaces a predecessor that is disposed on the spot). See the
  header of `lib/src/modules/spectrogram.dart` for how its first design died of
  the chain and its second of real material's run counts.

- **A module that accumulates advances on `engine.generation`, not on `paint`.**
  Paint also runs on a resize or a theme change, and a spectrogram that scrolled
  on those would invent time no audio passed through — convincingly.

- **Run the app and look at a module before calling it finished.** Five real
  defects in the first eleven passed `flutter analyze` and the widget suite and
  were obvious on sight: text offset by its own width twice, a target line
  hidden under the bars precisely when it mattered, arc gaps too small to read,
  a crowded VU face, and two labels printed in the same place. Tests do not
  catch layout that is merely wrong to look at.

  **The plugin has its own version of this, and it is `plugin/host/`.** A
  metering plugin cannot be judged from a unit test either — it has to be fed
  real music by something that moves a playhead. The fake DAW does that with a
  window and a Play button, and with `--headless` it does it in a test. Three
  defects were found by running it, all in code that had shipped and all now
  fixed — see **What it found** in `plugin/host/AGENTS.md`. One of the three
  needed the fake DAW *and* the application running together, which is worth
  knowing: neither suite can be that check.

  **`--open-panel=<name>` opens one of the six panels at startup**, in a debug
  build, which is how a panel gets looked at without clicking through to it:
  `open "build/macos/Build/Products/Debug/Open Audio Analyzer.app" --args --open-panel=settings`.
  **Not `open -a`** — that resolves an application *name* and refuses a relative
  path outright, which reads as "the build is missing" rather than as "the wrong
  flag". Plain `open` takes the path and still forwards `--args`.

  **`screencapture` returns a black frame without screen-recording permission,**
  and macOS grants that per terminal application, so an agent usually cannot
  take one at all. The route that works headless and needs no permission is to
  render the tree in a widget test: a `RepaintBoundary` above `MaterialApp`,
  `boundary.toImage(...)` inside `tester.runAsync`, and the real fonts loaded
  through `FontLoader` — otherwise every glyph is a box. Read the font bytes
  with `readAsBytesSync`; an awaited real read inside a `testWidgets` body never
  completes. Two of the three layout defects found in Phase 8 were found this
  way and by nothing else. Anchor the boundary above `MaterialApp` or the panel,
  which the `Navigator` builds, is not in the picture — and open the panel from
  a context *below* `OaaTheme`, or `showOaaPanel` asserts.

  **A window gesture is checked by synthesising it.** No widget test can see a
  zoom — it is the frame moving, not a pixel changing — and no screenshot can be
  taken. What needs no permission at all is a `swift` script that posts the
  clicks with `CGEvent(mouseEventSource:…)`, setting `.mouseEventClickState` to
  1 and then 2 for a double click, and reads the result out of
  `CGWindowListCopyWindowInfo`: `kCGWindowBounds` is available to anyone, and
  window images and titles are the only things screen recording gates.
  `CGPreflightPostEventAccess()` says up front whether the posting is allowed at
  all, which is what tells a gesture that did nothing apart from a script that
  was denied. The status bar's double-click zoom, the interval that pairs it and
  the drag it shares a detector with were all checked this way.

- **A feature that only fails on the device is a feature nobody tested.** Three
  of Open Audio Analyzer's platforms lie about the network in a way a
  development machine cannot show you. On **iPadOS**, custom multicast needs a
  restricted entitlement Apple grants per team by request — but the **simulator
  is exempt**, so the socket browses perfectly there and finds nothing, ever, on
  the iPad; that shipped, and the tablet now uses the system responder through
  a platform channel of its own. On **macOS**, Local Network
  permission is attributed to the *responsible* process, so the same code is
  allowed inside `open -a "Open Audio Analyzer.app"` and denied under `flutter
  test` or a bare `Open Audio Analyzer.app/Contents/MacOS/Open Audio Analyzer`
  — a discovery test that opens a real socket fails on a machine where the
  feature works, and `EHOSTUNREACH` on a multicast send
  is what that denial looks like from inside. **The same permission is keyed to
  the bundle identifier**, so 0.6.0's move from `dev.openaudioanalyzer.oaa` to
  `com.openaudioanalyzer.oaa` revoked it on every Mac that upgraded and left the
  old grant in System Settings naming an application that no longer exists —
  treat an identifier as a permission grant, and moving one as a release note
  telling users to re-allow every TCC permission the app holds. **"Every" was
  read as "the one this paragraph is about", and it cost a second bug report:**
  the same rename revoked `kTCCServiceAudioCapture`, which is what a Core Audio
  process tap needs, and *that* refusal is silent by Apple's design — every call
  returns `noErr`, the IOProc fires on schedule, and every buffer is zeros, so
  System Output metered digital black with nothing logged anywhere. The grant on
  the developer's own Mac was recorded against `dev.openaudioanalyzer.oaa` two
  hours before the tap was committed, and was orphaned by the rename the next
  morning — so the feature was verified working and then broken by a commit that
  touched neither tap file. When an identifier moves, enumerate the TCC services
  by name and check each one. **A tap also cannot be exercised by an ad-hoc
  signed build**: TCC keys its record to a stable signing identity, and an
  ad-hoc binary's cdhash changes on every rebuild, so a grant does not survive
  the next `flutter run`. On **Android**,
  receiving needs a
  `WifiManager.MulticastLock` — a platform call, now `OaaMulticastLock.kt` — and
  the socket opens, joins and queries perfectly without one while every answer
  is discarded below it; the **emulator cannot show you the fix working**
  either, because its NAT does not carry the LAN's multicast. None of the three
  logs anything. See `lib/src/remote/AGENTS.md` § Platform notes.

  **Android is also the one platform that will not say where a process may
  write.** No `HOME`, and a temporary directory of `/data/local/tmp` that
  belongs to no app, so the trick that finds an iPad's container finds nothing —
  which is why `resolveConfigRoot` takes `getFilesDir()` as an argument and
  `OaaFilesDir.kt` is what answers. It resolved to null there for eight phases
  and the tablet forgot everything at every launch, green suite throughout.

- **A macOS plugin bundle is signed last, and the build verifies it on the spot.**
  Every bundle this repository produced up to 0.4.0 shipped with an invalid code
  signature and nothing said so. JUCE signs the VST3 in the middle of its
  post-build — it has to, because `vst3_helper` then *loads* the bundle — and
  writes `Contents/Resources/moduleinfo.json` afterwards, so the resource seal
  never covered what shipped; and it signs the VST3 only, leaving the AU and the
  Standalone carrying nothing but the linker's Mach-O signature, whose
  CodeDirectory promises a resource seal no `_CodeSignature` directory exists to
  satisfy. On Apple Silicon that is what `auval` refuses an Audio Unit for and
  what makes a plugin absent from a DAW's browser with nothing logged anywhere —
  indistinguishable from having copied it to the wrong folder, which is how it
  stood for four releases. `plugin/CMakeLists.txt` signs each bundle from an
  `OaaPlugin_<format>_signed` target that depends on the format target, then runs
  `codesign --verify --strict`. That verify is the gate and a `ctest` cannot be:
  a test only runs after a build that has already succeeded at producing the
  broken bundle. **`POST_BUILD` is not late enough** — it hangs off the link
  rule, and a `MACOSX_PACKAGE_LOCATION` resource (the Standalone's
  `RecentFilesMenuTemplate.nib`) is copied by a sibling rule that make may run
  afterwards; a target-level dependency is the only ordering CMake guarantees
  across the whole of a target. **Delete `OaaPlugin_artefacts/Release/` and
  rebuild before believing a signing change**: an incremental build hides this
  entire class of failure, because the file that invalidates the seal is already
  present when the seal is computed.

- **A signature is not what gets a downloaded bundle past Gatekeeper — a
  notarisation ticket is,** and the plugin's version of that refusal cannot be
  overridden by the user at all. "Open Anyway" in Privacy & Security is only
  ever populated for a blocked *launch*; a plugin is loaded into a DAW's
  process, which is a library load, so macOS 15 and later put up a modal whose
  only other button is Move to Trash. `packaging/macos/notarize.sh` is the one
  implementation of submit-wait-staple, used by the plugin bundles and the pkg,
  and `ci.yml` runs it **between `Build` and `Archive`** because the ticket is a
  file inside the bundle. Two things that make this easy to get wrong: a
  Developer ID signature needs `--timestamp --options runtime` or Apple rejects
  the submission, and a *secret naming* a credential is not the credential —
  `OAA_SIGNING_IDENTITY` on a runner with an empty keychain and
  `OAA_NOTARY_PROFILE` naming a profile that lives on somebody's Mac both read
  as configured and did nothing. `packaging/macos/keychain.sh` is the missing
  half of the first.

- **The iOS side has no `codesign --verify`, and its rejection arrives after the
  release is published.** `flutter build ipa` exits 0 on an export that fell
  back to *automatic* signing — which on a runner signs with nothing usable —
  because the fallback is a trace-level log message and not an error. And what
  refuses the result is App Store Connect, during an upload `ci.yml` runs after
  `publish` by design, so there is no earlier gate to fail. Three things stand
  in for one: `make_ipa.sh` checks the provisioning profile before it builds
  (bundle id, no provisioned devices, no `get-task-allow`), reads the signing
  authority back off the finished `.xcarchive` after it, and manual signing is
  injected through `ios/Flutter/Release.xcconfig` rather than the project — the
  Runner target stays on automatic signing so `flutter run -d <ipad>` still
  works for a person, and a runner never tries to *create* a distribution
  certificate, which an account caps and which no error message would name.
  **A `workflow_dispatch` builds and signs the IPA without uploading it**, which
  is the only cheap way to check any of this; a tag is not the place to find out.

- **A macOS bundle's architecture and deployment target default to the machine
  that built it.** Both are set at the top of `plugin/CMakeLists.txt`; before
  they were, the released plugin was arm64-only with `minos 26.0`, so it could
  not load on an Intel Mac or on any macOS older than the release runner — and a
  DAW reports a bundle whose slice does not match exactly as it reports one that
  is not installed. `lipo -info` and `otool -l | grep -A3 LC_BUILD_VERSION` on
  the shipped artefact are the check; loading it on the build machine is not.

- **Bump `OAA_ABI_VERSION` when `oaa.h` changes shape,** and regenerate the
  bindings (`cd packages/oaa_engine && dart run ffigen --config ffigen.yaml`).
  The Dart side asserts the version at startup, because a stale library does not
  crash — it reads a reordered struct and displays plausible wrong numbers.

  **`OAA_ABI_VERSION` and `OaaEngine.expectedAbiVersion` move in the same
  commit, always.** The constant is not an independent value; it is an assertion
  *about* the header. Committing one without the other is a build where the
  library says 3 and Dart demands 4, which fails every job on every platform.
  Easy to get wrong when somebody else's uncommitted header makes your half of
  the pair look right locally — verify against committed state with
  `git worktree add --detach <tmp> HEAD` before pushing an ABI change.

### Documentation Sync

**Every change carries the Markdown that describes it, in the same commit.**
Not the next one. A document that is behind the code is worse than no document,
because it is read with the same confidence as a correct one — the reader does
not know which sentence went stale, so the whole file becomes untrustworthy at
once. This repository has twenty-odd Markdown files and its `README.md` is the
design document, so the failure compounds faster here than in most projects.

Before finishing a change, look at what you touched and check the files that
claim something about it:

| You changed | Check |
|---|---|
| A number Open Audio Analyzer reports, or its definition | `docs/METRICS.md` (definition + **Availability**), `CHANGELOG.md` 📐, `README.md` measurement table |
| A metric moving from unavailable to measured | The same three, plus the `OAA_FLAG_*_UNAVAILABLE` comment in `oaa.h` that says whether this build sets it |
| `engine/include/oaa/oaa.h` | `engine/AGENTS.md`, `packages/oaa_engine/AGENTS.md`, and `docs/WIRE.md` **only if the protocol version moved** — the wire tables are frozen per protocol version and deliberately *not* tied to the ABI |
| A file added to or removed from any package | That directory's `AGENTS.md` file table. They are enumerations, not samples; a missing row reads as "this file does not exist" |
| A new directory | Its own `AGENTS.md`, plus the parent's table and `CLAUDE.md`'s Subdirectories table |
| A new dependency | `CLAUDE.md` Dependencies, `README.md`, and the licence column if it is not permissive |
| An installer, or what it installs | `packaging/AGENTS.md` file table and rules, `docs/site/install.md` (the download table **and** the per-platform section), `README.md`'s Installing table, `docs/site/building.md` Installers, `CHANGELOG.md` ✨ or ⚡, and the install page's **blurb** in `website/src/lib/docs.mjs` — it names the formats in prose, nothing regenerates it and no test reads it, so it is the copy that goes stale unseen: it still offered a dmg and an msix after both had been replaced everywhere else, and it moved with the documentation onto the website in 0.10.0 rather than being retired. An installer that gained or lost a checkbox is a user-visible change, not an internal one |
| A test gate, or `.github/workflows/ci.yml` | `CLAUDE.md` Testing Requirements, `README.md` Tests, `.github/AGENTS.md`. **A gate named in a document and absent from `ci.yml` is a lie the whole team believes.** `ci.yml` is the only workflow — tests, docs, installers and the release are jobs in it, gated by event |
| A keyboard shortcut | Nothing by hand — regenerate with `UPDATE_DOCS=1 flutter test test/shortcuts_test.dart` and commit `docs/site/keyboard.md` in the same change. `README.md`'s Layout → Keyboard names a handful of them and is prose, not a list |
| **When** the plugin sets a transport flag, without any byte moving | `docs/WIRE.md`'s prose for that bit, `CHANGELOG.md` 🐛, and a case in `packages/oaa_wire/test/plugin_e2e_test.dart`. The row above covers the wire's *layout*; this is the other half. A consumer depends on when a producer sets a bit as much as on where the bit lives, and none of that is visible in a byte table — the discontinuity bit was being set every block while the transport sat parked, and delivered on almost none of the blocks where it mattered, with the layout perfectly correct throughout |
| The iOS build, its signing, or the TestFlight upload | `packaging/AGENTS.md`, `docs/site/building.md`'s credential table, `.github/AGENTS.md`, and `docs/site/install.md`'s iPadOS section. The IPA is **not** a release asset — if you make it one, `README.md`'s note and the publish step's exclusion both become wrong |
| A switch on the fake DAW | `plugin/host/AGENTS.md`, and `README.md` if it is one of the gestures a person cannot perform on cue. `--help` in `FakeDawOptions.h` is the exhaustive list and the only one that has to be; the other two name the interesting ones and are prose |
| A page the documentation site publishes, or its filename | **Two lists that have to agree**: the manifest in `website/src/lib/docs.mjs` and the pattern in `website/src/content.config.ts`. Neither is a recursive glob over `docs/` — that publishes `PLAN.md` to strangers the day somebody moves it. `docs.mjs` is written out page by page; `content.config.ts` is a scoped list (`docs/site/*.md` plus the three documents named individually), so it loads a superset and `docs.mjs` decides what is published. A renamed document therefore fails the website build instead of silently vanishing from it. The `website` job in `ci.yml` is what runs that build on every event |
| The mark, the logo or the app icon | Nothing by hand — redraw `assets/brand/oaa-logo.svg` and run `dart run packaging/icon/make_icons.dart`, which writes every icon, every vector twin and the README's image. Then `assets/AGENTS.md` if a file appeared or went, `CHANGELOG.md` ⚡, and `npm run og` in `website/` because the card carries the mark. **`packaging/icon/oaa.svg`, `website/public/`'s icons and everything in `assets/brand/` except `oaa-logo.svg` itself are generated: editing one by hand is a change the next run silently reverts.** The one exception is `website/public/favicon.svg`, which a browser tab shows at 16 px where the tile does not read — it is drawn by hand, the generator no longer writes it, and it is the file that taught this rule its exception by being reverted. |
| A version, a stated requirement, an artefact filename, or how a module looks | Not the version: `website/src/lib/app.mjs` reads it out of `pubspec.yaml` at build time, because three typed literals were a release behind within the hour after a tag. The rest is typed and nothing regenerates it — `PLATFORMS` in `website/src/pages/index.astro` carries the minimum macOS and what each installer holds, and the macOS floor moved to 14.2 in the same change that added `website/` while the page still said 11 Big Sur. `npm run modules -- --only <id>` for the photograph. See `website/AGENTS.md` |
| A phase reaching done | `README.md` Roadmap, `CLAUDE.md`'s status line, `docs/PLAN.md` |
| Anything a user sees or configures | `README.md`, and `CHANGELOG.md` under ✨ or ⚡ |

Two rules that are not obvious:

- **A file table in an `AGENTS.md` is exhaustive.** They are read as "here is
  everything in this directory", which is what makes them useful for finding
  the right file without listing it. Adding a file and not the row is how
  `packages/oaa_wire/` existed for a whole phase with no directory note and no
  mention in `packages/AGENTS.md`.

- **Stale future tense is the most common failure, and the least visible.**
  "Phase 6 adds a second implementation", "lands with the FFT", "Phase 5 adds
  the BS.2217 vectors" all read as perfectly good prose after the thing has
  shipped. When a phase completes, grep for its number across `*.md` and fix
  every hit — the sentences do not announce themselves.

The reviewer's version of this: if a diff touches code and no `.md`, that is a
question to answer, not a default to accept.

### CHANGELOG.md Format

`CHANGELOG.md` is written for the person deciding whether to update, not for
the person who wrote the code. Based on Keep a Changelog with one addition that
matters more here than anywhere else — see 📐 below.

**Structure.** Newest first. `## [Unreleased]` always sits at the top, even when
empty. Versions are `## [0.2.0] — 2026-09-01`, semver, em dash, ISO date. Link
definitions go at the bottom. **A released section is never rewritten** — if it
was wrong, correct it in the next release and say so.

**Sections**, in this exact order. Omit any that is empty; never reorder them,
because readers learn the shape and scan by position.

| | Section | Contents |
|---|---|---|
| 📐 | `Measurement` | Anything that changes a number Open Audio Analyzer reports. |
| ✨ | `Added` | New capability that was not there before. |
| ⚡ | `Changed` | Existing behaviour that works differently now. |
| 🐛 | `Fixed` | A defect that is no longer there. |
| 🔥 | `Removed` | Capability that is gone. Deprecations go under `Changed` with the removal version named. |
| 🔒 | `Security` | Anything with a security consequence. |
| 🚧 | `Internal` | Refactors, build, CI, docs. Last, because most readers stop before it. |

**📐 Measurement comes first, and it is not optional.** Users make delivery
decisions from these numbers. If a reading changes — a corrected filter
coefficient, a different gating threshold, a fixed rounding — somebody's
previous master was measured with the old one. Every entry states **the old
behaviour, the new behaviour, and the magnitude**, and says whether a re-measure
is warranted. "Fixed LRA calculation" is not an acceptable entry. This section
also records a metric moving from unavailable to measured.

**Entries.** One line each, starting with a capital and ending with a full stop.
Describe the effect on the user, not the diff. Reference at the end: `(#42)`.
Emoji appear **only in section headings** — never inside an entry, never in a
heading twice, never anywhere else in the file.

```markdown
## [Unreleased]

## [0.2.0] — 2026-09-01

### 📐 Measurement
- LUFS-I, LUFS-M, LUFS-S and LRA are now measured; they previously read as a
  dash. Verified against the EBU R128 conformance vectors to within 0.1 LU. (#31)
- True peak now uses 4× oversampling per BS.1770-4 Annex 2 instead of sample
  peak. Readings rise by up to 1.5 dB on limited material, and a master that
  previously passed a −1 dBTP ceiling may now fail it. Re-measure before
  delivery. (#33)

### ✨ Added
- Audio device capture on macOS, Windows and Linux. (#28)

### ⚡ Changed
- The meter refresh rate defaults to 60 fps and is settable to 30 or 120. (#35)

### 🐛 Fixed
- The elapsed clock no longer resets when a device changes sample rate. (#39)

### 🚧 Internal
- The engine's POSIX feature-test macros are declared in the build hook. (#26)

[unreleased]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.1.0...v0.2.0
```

### Testing Requirements

```sh
flutter analyze                       # whole workspace, must be clean
dart format --output=none --set-exit-if-changed .
                                      # the test job's other reading of the same
                                      # code; nothing else objects to a file
                                      # the formatter would rewrite
flutter test                          # widget and golden tests
dart test packages/oaa_core           # domain, no toolchain needed
dart test packages/oaa_wire           # the wire protocol, including the C++ golden
cd packages/oaa_engine && dart test   # engine, through FFI
cd cli && dart test                   # the `oaa` binary, as a subprocess
cd cli && dart build cli -o build     # the CLI builds the way a release builds it
sh plugin/test/sources_match.sh       # the engine's two build lists agree
cmake -B plugin/build-nojuce -S plugin -DOAA_BUILD_PLUGIN=OFF && \
  cmake --build plugin/build-nojuce && \
  ctest --test-dir plugin/build-nojuce  # the plugin's C++ that needs no JUCE
cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release && \
  cmake --build plugin/build && \
  ctest --test-dir plugin/build       # the VST3, the AU and the fake DAW compile,
                                      # each macOS bundle verifies against its
                                      # own signature, and the plugin answers a
                                      # host that says nothing
dart test packages/oaa_wire           # again, now that a built fake DAW makes
                                      # the end-to-end cases run instead of skip
flutter test test/plugin_to_display_e2e_test.dart
                                      # and the hop after it: DAW → plugin →
                                      # app → display
cd website && npm ci && npm run build  # the website still builds, which is
                                      # what proves every document it publishes
                                      # is still where the manifest says
```

**One suite is deliberately not a gate.**
`packages/oaa_engine/test/vectors_test.dart` runs the official EBU and ITU
vector files — 112 cases — and skips unless `OAA_VECTORS` and `OAA_VECTORS_ITU`
name unzipped copies, because 811 MB that may not be redistributed here cannot
be fetched by the suite that must never be flaky. **Run it by hand after
touching `oaa_loudness.*`, `oaa_kweight.*` or `oaa_truepeak.*`**, and add
whatever it catches to `conformance_test.dart` as well if a generated signal can
express it — those two are the only reason CI would ever see the same defect
again. See `docs/METRICS.md` § Conformance for where the material comes from.

All twelve gates are jobs in `ci.yml`, which is the only workflow. The repeated
`dart test packages/oaa_wire` is not a thirteenth: it is the same suite, run
again where a built plugin turns its end-to-end cases from skipped into real.
The line after it is one file of the `flutter test` suite for the same reason —
`test/plugin_to_display_e2e_test.dart` skips without a built plugin, and it is
the only thing anywhere that runs a DAW's audio through the plugin, the app and
out to a display.

Two of the twelve do not run on a push. `dart build cli` does, and is there
because nothing else builds the CLI the way a release does: `cli/test` runs it with
`dart run`, so `dart compile exe` was broken for an unknown length of time and
was found by tagging a release. **The full plugin build runs only on a release or a manual
run**, because three parallel JUCE builds cost more than a push asks for — so
run it by hand when you touch anything that faces JUCE: the plugin target, the
formats, `plugin/host/`. The framework-free half of that directory does run on
every push, which is the `ctest` line above: the transport box's
delivered-exactly-once test, the wire fixture against its golden, and the source
lists, in five seconds with no JUCE fetched. What the gated job still owns is
the VST3, the AU, the fake DAW, `transport_capture_invents_nothing` — which
hosts the `AudioProcessor` itself, because the two branches it covers are the
ones no plugin format can ask for — and the only runs that drive the plugin end
to end.
Two suites do that driving, both spawning `plugin/host/`'s `oaa-fake-daw
--headless` and both skipping when it is not built:
`packages/oaa_wire/test/plugin_e2e_test.dart` decodes what the plugin sends, and
`test/plugin_to_display_e2e_test.dart` carries it one hop further — through the
app's ingest and its display host to a `DisplayClient`, which is what a tablet
runs — and asserts field by field that the display's readings are the ones the
app got from the plugin. Both want port 47822, so neither can run while the
application does, or while the other one is running.

The engine tests hold the meters against arithmetic: a sine of amplitude *A*
peaks at *A* and has an RMS of *A*/√2, exactly 3.0103 dB lower. If those drift,
the meters are wrong — not the tone.

Two of these fail in a way that looks like something else:

- **`flutter test` is what proves `docs/site/keyboard.md` is current.** It is
  generated from the shortcut table in `lib/src/app/shortcuts.dart`. Change a
  binding and regenerate in the same commit:
  `UPDATE_DOCS=1 flutter test test/shortcuts_test.dart`.
- **`npm run build` in `website/` exits non-zero when a page it publishes has
  been moved or renamed.** That is the failure that actually happens; the site
  loses a page and nothing else complains. The manifest is
  `website/src/lib/docs.mjs`.

### Common Patterns

- Long file-header comments stating *why*, usually naming the failure mode that
  forced the design. Match that register. If a comment could be deleted without
  losing information, delete it.
- C: C11, `oaa_` prefix on everything exported, no globals, no allocation
  outside `oaa_engine_create`.
- Dart: sealed classes with exhaustive `switch` where it fits; Riverpod for
  configuration only; `CustomPainter(repaint:)` for anything that shows a
  measurement.
- Modules are `ModuleFrame` + a painter. A module that owns its own border is a
  module that will drift from the other eleven.

## Dependencies

### Internal

`lib/` → `oaa_ui` → `oaa_core`; `lib/` → `oaa_engine` → `engine/`;
`lib/` → `oaa_wire` → `oaa_core`. `oaa_core` depends on nothing.

`oaa_engine` → `oaa_core` as well, for `MeterSource` and nothing else. The rule
that matters is unchanged and points the other way: **`oaa_core` must never
learn about `dart:ffi`**. Three of the four consumers have no engine, and the
remote display has no native library at all.

### External

- **App:** `flutter_riverpod` for configuration, plus `desktop_drop` and
  `file_selector` for offline analysis. The last two are there because Flutter
  has no built-in way to get a path from a user, and Phase 5 needs one twice —
  to accept a dropped file and to choose where an export goes. Keep the list
  this short: anything else that wants to be a dependency should be weighed
  against writing it, and nothing on the frame path may acquire one at all.

  `mobile_scanner` (MIT) is the fourth and the only one with a native half that
  is not vendored — the camera behind "Scan a QR code" in the host picker. It
  was weighed against writing it and is the one that lost: finding a symbol at
  an angle in a moving camera frame is a research problem, not a closed one.
  The **encoder** on the other side of the same feature *was* written, in
  `packages/oaa_ui/lib/src/qr.dart`, because that half is closed and published.
  It is also the only dependency that does not ship everywhere — Android, iOS
  and macOS have it, Windows and Linux do not — which is what `canScanQrCodes`
  in `lib/src/remote/qr_scanner.dart` exists to say before a row is drawn.
  Adding it costs four platform declarations; they are enumerated under
  **Platform notes** in `lib/src/remote/AGENTS.md`.
- **CLI:** `args`, plus `oaa_core` and `oaa_engine`. **No Flutter binding** —
  that is what keeps `dart build cli` working and the CLI usable in CI. Not
  `dart compile exe` — that refuses a package whose dependencies have build
  hooks, and `oaa_engine` has one.
- **Engine:** `miniaudio` (capture), `pffft` (FFT) and `dr_libs` — `dr_wav`,
  `dr_flac`, `dr_mp3` (file decoding). All vendored under
  `engine/third_party/`, all permissive, all single-header.
- **Website:** `astro` and `wrangler`, plus `lighthouse` for `npm run audit` —
  all three dev-only, and none of them ships in a release. The three typefaces
  the site is set in are **served from the site** rather than from Google Fonts,
  committed under `website/public/fonts/` with their `OFL.txt`; they are the one
  thing in that directory that is not GPL. See `website/AGENTS.md` for why the
  `math` and `symbols` subsets are load-bearing.
- **Build:** `native_toolchain_c`, `hooks`, `code_assets`, `ffigen`.
