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
All thirteen modules measure something. Loudness and true peak are held against
the EBU conformance cases in CI, and the spectrum against a sine of known
amplitude. Layouts, settings, delivery targets and skins persist as JSON under
the platform's configuration directory. Files are analysed offline by the app
and by the `oaa` CLI, a tablet mirrors the canvas over the wire protocol, and a
headless VST3 / AU plugin streams the DAW's audio and transport to the app. The
canvas is driven from the keyboard, there is a dmg, an msix, an AppImage and a
flatpak, and the documentation site is generated from this repository. See the
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
| `packages/oaa_ui/lib/src/tokens.dart` | `Space`, `OaaControl`, `OaaRadius`, `OaaStroke`, `OaaColors`, `OaaType`. Nothing outside this file invents a spatial or colour value. |
| `packages/oaa_ui/lib/src/scale.dart` | `MeterScale` and `ScaleGraticule`. Five modules draw a dB scale; two side by side whose ticks disagree look like a rendering bug. |
| `packages/oaa_ui/lib/src/point_buckets.dart` | Marks sorted by the colour they are drawn in, one call per colour. What lets the spectrogram and the stereo cloud redraw their whole history every published frame instead of accumulating it into an image. |
| `engine/src/oaa_spectrum.h` | The Hann STFT: a 4096-point window, zero-padded into a 16384-point transform. The two lengths are not the same thing and the header says why. One set of transforms serves all three frequency modules. |
| `lib/src/canvas/module_host.dart` | The only place that knows which `ModuleKind`s exist as code. Exhaustive switch, no default arm. |
| `packages/oaa_core/lib/src/layout.dart` | `ModuleSpec` / `TabSpec` / `PresetSpec` — the serialised layout model. |
| `packages/oaa_core/lib/src/meter_source.dart` | `MeterSource` — everything a module is allowed to read. `OaaEngine` implements it; so does the remote display's decoder. |
| `docs/WIRE.md` | The wire protocol, normative. Three implementations, none written against another. |
| `ios/Runner/OaaBonjour.swift` | The only platform channel in the application. iOS refuses an app the multicast socket every other platform browses with, so a tablet searches through the system's Bonjour responder instead; `lib/src/remote/mdns/host_discovery.dart` is where the two meet. |
| `packages/oaa_core/lib/src/grid.dart` | Every rule about where a module may go, as pure functions. No pixels. |
| `lib/src/canvas/grid_canvas.dart` | The canvas: drag, resize, selection, the preview overlay. |
| `lib/src/canvas/workspace.dart` | The one path every layout edit takes, and the undo history. |
| `lib/src/storage/config_store.dart` | Every read and write of the user's configuration. Atomic, never throws, and the only code in the app that touches the filesystem. |
| `lib/src/data/providers.dart` | Settings, and the libraries of targets, skins and presets. One direction only: state is written to disk, never read back from it. |
| `packages/oaa_ui/lib/src/panel.dart` | The chrome every panel is built from, and `showOaaPanel`. |
| `packages/oaa_core/lib/src/skin.dart` | The thirteen colour roles a skin names, as data. `oaa_ui` owns the one adapter to `OaaColors`. |
| `engine/src/oaa_decode.c` | The only file that does I/O. `oaa_file_*` over dr_libs; no analysis, the caller pushes what it reads. |
| `packages/oaa_engine/lib/src/offline.dart` | The decode-push-read loop. Both the app and the CLI drive files through this one function. |
| `packages/oaa_core/lib/src/report.dart` | `AnalysisReport` and the delivery verdict. Holds no engine handle, so it round-trips through JSON. |
| `cli/bin/oaa.dart` | The `oaa` analyser. Its exit code is the product — see `cli/AGENTS.md`. |
| `lib/src/app/shortcuts.dart` | Every keyboard shortcut, as one table. The bindings, the `?` sheet and `docs/site/keyboard.md` are all derived from it; `test/shortcuts_test.dart` fails when the page has drifted. |
| `lib/src/app/launch_options.dart` | `--config-dir` and `--open-panel`. Both exist to make something else testable — see the file. |
| `tool/docs.dart` | The documentation site. No dependencies, so the `docs` job needs a Dart SDK and nothing else. The page list is written out, never globbed, and the mark is read from `assets/brand/oaa-mark.svg` rather than held — it was held once and went stale. |
| `packaging/icon/make_icons.dart` | The app mark as geometry, rendered into every container the six platforms want — a rounded tile for the desktops, two layers on a 108dp canvas for Android, and a layered `AppIcon.icon` for macOS and iOS that the system lights itself. `oaa.svg` and `assets/brand/` are its vector twins and follow it, never the reverse. |
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
| `plugin/` | Headless VST3 / AU. Measures the DAW's audio, streams it to the app. | **AGPL-3.0-or-later** |
| `docs/` | `PLAN.md`, `METRICS.md`, `WIRE.md`, and `site/` — the pages with no other home. | |
| `tool/` | Repository scripts. Nothing here ships. | GPL-3.0-or-later |
| `packaging/` | dmg, msix, AppImage, flatpak, and the app icon they all need. | GPL-3.0-or-later |
| `assets/` | The fonts the application bundles, and the logo the repository publishes. | GPL-3.0-or-later; fonts SIL OFL 1.1 |

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
    tickers drift so that two meters can disagree within a frame;
  - lay out a `ui.Paragraph` when the formatted string has not changed.

- **`engine/` must not learn about Flutter, and `oaa_core` must not learn about
  `dart:ffi`.** Four consumers need the domain vocabulary and three of them have
  no engine — the tablet display reads measurements off a socket. The moment
  `oaa_core` imports `oaa_engine`, all three drag in a native library they never
  call. `lib/src/data/metric_reader.dart` is the *only* place the two meet.

- **A module reads `MeterSource`, never a concrete engine.** There are two
  implementations — `OaaEngine` over native memory, and `WireSnapshot` over a
  socket — and the thirteen modules cannot tell them apart. That is what lets a
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

- **Nothing in Open Audio Analyzer recognises a double tap.**
  `DoubleTapGestureRecognizer` calls `gestureArena.hold` on the first tap and
  releases it only when `kDoubleTapTimeout` expires 300 ms later, and a held
  arena is never swept — so every tap recogniser beneath one, anywhere in the
  subtree, waits a third of a second before it can win. Three gestures were
  double clicks and each delayed everything under it: the status bar's zoom made
  every control in the row late on macOS, a tab's rename made switching tabs
  late, and adding a module on empty canvas made clearing the selection late. It
  presents as an application that is slow rather than as a gesture that is
  waiting, which is why it stood for a phase. **Use a long press** — it holds
  nothing and rejects as soon as the pointer lifts early, it works on a tablet,
  and it can open the same menu the secondary click does. A pan may share an
  arena with the buttons under it freely; only the double tap holds.

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
  `dart:ui`** — a display that needs history keeps that history as data and
  redraws it from scratch, bounded by the module's size rather than by the
  length of the session. See the header of `lib/src/modules/spectrogram.dart`,
  and `PointBuckets` for what makes redrawing tens of thousands of marks cheap
  enough to do every frame.

- **A module that accumulates advances on `engine.generation`, not on `paint`.**
  Paint also runs on a resize or a theme change, and a spectrogram that scrolled
  on those would invent time no audio passed through — convincingly.

- **Run the app and look at a module before calling it finished.** Five real
  defects in the first eleven passed `flutter analyze` and the widget suite and
  were obvious on sight: text offset by its own width twice, a target line
  hidden under the bars precisely when it mattered, arc gaps too small to read,
  a crowded VU face, and two labels printed in the same place. Tests do not
  catch layout that is merely wrong to look at.

  **`--open-panel=<name>` opens one of the five panels at startup**, in a debug
  build, which is how a panel gets looked at without clicking through to it:
  `open -a build/macos/Build/Products/Debug/oaa.app --args --open-panel=settings`.

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

- **A feature that only fails on the device is a feature nobody tested.** Three
  of Open Audio Analyzer's platforms lie about the network in a way a
  development machine cannot show you. On **iPadOS**, custom multicast needs a
  restricted entitlement Apple grants per team by request — but the **simulator
  is exempt**, so the socket browses perfectly there and finds nothing, ever, on
  the iPad; that shipped, and the tablet now uses the system responder through
  the one platform channel in the application. On **macOS**, Local Network
  permission is attributed to the *responsible* process, so the same code is
  allowed inside `open -a oaa.app` and denied under `flutter test` or a bare
  `oaa.app/Contents/MacOS/oaa` — a discovery test that opens a real socket fails
  on a machine where the feature works, and `EHOSTUNREACH` on a multicast send
  is what that denial looks like from inside. On **Android**, receiving needs a
  `MulticastLock` Dart cannot take and the socket opens happily without one.
  None of the three logs anything. See `lib/src/remote/AGENTS.md` § Platform
  notes.

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
| A test gate, or `.github/workflows/ci.yml` | `CLAUDE.md` Testing Requirements, `README.md` Tests, `.github/AGENTS.md`. **A gate named in a document and absent from `ci.yml` is a lie the whole team believes.** `ci.yml` is the only workflow — tests, docs, installers and the release are jobs in it, gated by event |
| A keyboard shortcut | Nothing by hand — regenerate with `UPDATE_DOCS=1 flutter test test/shortcuts_test.dart` and commit `docs/site/keyboard.md` in the same change. `README.md`'s Layout → Keyboard names a handful of them and is prose, not a list |
| A page the documentation site publishes, or its filename | The page list in `tool/docs.dart`. It is written out rather than globbed, so a renamed document fails the docs job instead of silently vanishing from the site |
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
flutter test                          # widget and golden tests
dart test packages/oaa_core           # domain, no toolchain needed
dart test packages/oaa_wire           # the wire protocol, including the C++ golden
cd packages/oaa_engine && dart test   # engine, through FFI
cd cli && dart test                   # the `oaa` binary, as a subprocess
cd cli && dart build cli -o build     # the CLI builds the way a release builds it
sh plugin/test/sources_match.sh       # the engine's two build lists agree
cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release && \
  cmake --build plugin/build && \
  ctest --test-dir plugin/build       # the VST3 and AU compile, and the C++ wire golden
dart run tool/docs.dart               # the documentation site still builds
```

All ten are jobs in `ci.yml`, which is the only workflow — but two of them do
not run on a push. `dart build cli` does, and is there because nothing else
builds the CLI the way a release does: `cli/test` runs it with `dart run`, so
`dart compile exe` was broken for an unknown length of time and was found by
tagging a release. **The plugin build runs only on a release or a manual run**,
because three parallel JUCE builds cost more than a push asks for — so run it
by hand when you touch `plugin/` or `engine/`. It is the only thing that
compiles the VST3 and the AU, and the only thing that runs the C++ side of the
wire golden. The engine tests hold the meters against arithmetic: a
sine of amplitude *A* peaks at *A* and has an RMS of *A*/√2, exactly 3.0103 dB
lower. If those drift, the meters are wrong — not the tone.

Two of these fail in a way that looks like something else:

- **`flutter test` is what proves `docs/site/keyboard.md` is current.** It is
  generated from the shortcut table in `lib/src/app/shortcuts.dart`. Change a
  binding and regenerate in the same commit:
  `UPDATE_DOCS=1 flutter test test/shortcuts_test.dart`.
- **`dart run tool/docs.dart` exits non-zero when a page it publishes has been
  moved or renamed.** That is the failure that actually happens; the site loses
  a page and nothing else complains.

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
- **CLI:** `args`, plus `oaa_core` and `oaa_engine`. **No Flutter binding** —
  that is what keeps `dart build cli` working and the CLI usable in CI. Not
  `dart compile exe` — that refuses a package whose dependencies have build
  hooks, and `oaa_engine` has one.
- **Engine:** `miniaudio` (capture), `pffft` (FFT) and `dr_libs` — `dr_wav`,
  `dr_flac`, `dr_mp3` (file decoding). All vendored under
  `engine/third_party/`, all permissive, all single-header.
- **Build:** `native_toolchain_c`, `hooks`, `code_assets`, `ffigen`.
