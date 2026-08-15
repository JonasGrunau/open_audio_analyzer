# Changelog

All notable changes to Bel are recorded here. The format is defined in
[CLAUDE.md](CLAUDE.md#changelogmd-format); the short version is that
**📐 Measurement always comes first**, because a change to a reported number can
invalidate a decision somebody already made about a master.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### 📐 Measurement

- **The VU meter reads differently, and lower on most material.** It was a
  one-pole smoother over mean square — an RMS meter with a 300 ms time
  constant. It is now what a VU movement actually is: **average-responding and
  RMS-calibrated**, through a second-order mechanism. A steady sine still reads
  its own RMS exactly, so a calibration tone is unchanged; anything peakier now
  reads **lower**, by 9 dB on a signal with a 10% duty cycle and typically 1 to
  4 dB on dense modern masters. If you have been matching levels by VU against
  Bel's previous readings, re-check them. The needle also overshoots by about
  1.2% on a transient, which is inside the tolerance the standard allows and is
  most of why a VU feels like a VU.
- **The spectrum is now measured.** 512 log-spaced bands from 20 Hz to 20 kHz,
  from a 4096-point Hann transform per channel at a 1024-sample hop, taking the
  loudest FFT bin in each band rather than their average so that a narrow
  resonance survives the mapping. Levels are window-compensated: a full-scale
  sine on a bin centre reads 0.0 dBFS, verified on every push. A tone between
  two bin centres reads up to 1.4 dB low, which is inherent to reading a peak
  bin and is not corrected.
- **Per-band stereo position** and the **raw stereo sample stream** are now
  published, which is what the stereo cloud and the phase scope draw.
- **The short-term loudness distribution is now published**, together with the
  10th and 95th percentiles LRA is the difference of and the relative gate they
  were taken above — the same population the LRA number is computed from, so
  the histogram and the number cannot disagree.
- LRA itself is unchanged. It is now computed *through* the published
  percentiles rather than beside them, which is a refactor, not a new number.

- **Loudness is now measured.** LUFS-M, LUFS-S, LUFS-I and LRA previously read
  as a dash and now report real values, verified against the EBU Tech 3341
  cases within the standard's ±0.1 LU on every push, on all three desktop
  platforms. K-weighting follows ITU-R BS.1770-4 with coefficients designed at
  the stream's own sample rate, so 44.1, 88.2, 96 and 192 kHz are correct rather
  than approximately correct.
- **True peak is now measured**, with the 4× polyphase oversampler from
  BS.1770-4 Annex 2. It reads **higher than sample peak** — by up to about
  3 dB on dense, limited material — because that is what the signal actually
  reaches between samples. **A master that previously passed a −1 dBTP ceiling
  on sample peak alone may now fail it. Re-measure before delivery.**
- DR-S, DR-I, PLR and PSR are now defined, being differences of the above. See
  [docs/METRICS.md](docs/METRICS.md) for the formulas; none of them is
  Decibel's proprietary TrueDyn and none pretends to be.
- LFE is excluded from loudness and surround channels are weighted +1.5 dB, per
  BS.1770-4. Channel layout is inferred from the channel count, and the
  four-channel case is read as quad (L R Ls Rs) rather than L R C LFE — see
  METRICS.md, and expect this to be replaced by real layout metadata when a
  device or file source can supply it.

- **A device's own sample rate and channel count are adopted, not converted
  to.** Bel measures the stream the hardware produced; resampling in front of
  the measurement would move inter-sample peaks and shift the K-weighted
  energy, and the resulting numbers would still look plausible.
- An interface wider than 7.1 is **refused** rather than measured eight
  channels at a time and reported as programme loudness.
- An unknown device id **fails** instead of falling back to the default. A
  preset naming an interface that is not plugged in would otherwise silently
  meter the laptop microphone.

- **Files can now be measured, and they read exactly as the live meters do.**
  Analysing a file decodes it and pushes the blocks through the same
  `bel_analyse` a capture device drives — there is no second DSP path — so the
  numbers are identical rather than merely close. A test asserts that equality
  on the same samples analysed both ways, to the bit. A file is measured at its
  own sample rate and channel count; nothing resamples or remixes, because a
  converter in front of a measurement changes the measurement.
- **A file report states maxima, not final values.** Momentary and short-term
  loudness, correlation and per-channel peak describe an instant, so reading
  them once at the end would report the fade-out and call it the programme.
  They are watched across the whole file instead. Integrated loudness, LRA and
  the "max since reset" peaks are integrating quantities and are read at the
  end, which is correct for them.
- Sample values are **not clamped** on the way out of the decoder. A float WAV
  may legitimately hold values beyond ±1.0, and those are precisely the
  overshoots true-peak metering exists to find.

### ✨ Added

- **A remote display.** Turn on publishing in the desktop's status bar and a
  tablet on the same network shows the same meters — the same modules, the same
  layout, the same skin and the same delivery target, rendered by the same
  painters from measurements sent over the network rather than reimplemented.
  Hosts are found by name over mDNS (`_bel._tcp`), and an address can always be
  typed instead, because multicast is the first thing a guest network blocks.
- **A remote display says when it has stopped being current.** Two seconds
  without a measurement and every reading becomes a dash and the link is marked
  stale, rather than leaving the last picture on screen. A frozen meter is
  indistinguishable from a quiet passage, so a display left running after its
  host slept would otherwise show a confident, detailed reading of a signal that
  had stopped existing.
- **The display is watch-only, and off until switched on.** It cannot reset,
  retarget or reconfigure the machine it is watching, and the port is closed
  until a human opens it. There is no password on the connection; anyone who can
  reach the port can read the measurements and the layout, which is why it is
  offered rather than assumed.
- **A headless VST3 and Audio Unit plugin.** Insert Bel on any track, bus or
  master and the desktop app meters what the DAW is playing, through the same
  engine and the same painters as a live input — so a plugin reading and a
  device reading of the same audio cannot disagree. The plugin draws no meters
  itself; it measures and streams, and a small status panel says whether it is
  connected. Built for macOS, Windows and Linux, plus a standalone target for
  testing the link without opening a host.
- **The DAW's transport reaches the app**: play and record state, playhead in
  seconds, samples and quarter-notes, tempo, time signature, loop points and
  SMPTE timecode with its frame rate. Every field carries a "the host supplied
  this" flag, because hosts differ enormously in what they report and a missing
  tempo arriving as zero is indistinguishable from a real one — an absent value
  renders as an em dash rather than a plausible number. **The Elapsed and
  Timecode LUFS modes are not built yet**; this is the measurement they will be
  counted from, and no module offers them today.
- The plugin reports when the playhead **jumps** — a relocate, a loop, a scrub.
  Anything integrating across that boundary is averaging two passes of the same
  music into one number and nothing about the result looks wrong, so it is
  stated rather than inferred. Acting on it — restarting an integration when the
  transport moves — needs an app-to-plugin control frame, and so wire protocol 2.
- The app listens for plugins on port 47822, loopback only. Several inserts may
  be connected at once; the most recently connected is the one shown, on the
  grounds that inserting a plugin *is* the act of selecting it.
- **All twelve modules.** The eleven that said `NOT BUILT YET` now measure
  something: a **LUFS Meter** (momentary and short-term as bars, integrated as a
  rule they pass through, the target as a band); a **Digital Meter** (per
  channel to 7.1, RMS as the column and peak as a floating tick, so the gap
  between them is the crest factor); a **Super Meter** (the three integrations
  on concentric arcs); a **VU Meter** (0 VU at the calibration's reference
  level, not at digital full scale); an **Alert Meter** (one metric with its
  worst reading latched until reset); a **Validator** (three delivery checks and
  a verdict); a **Histogram** (the short-term loudness distribution with the
  LRA percentiles drawn on it); a **Spectrum Analyzer**; a **Spectrogram**; a
  **Phase Scope**; and a **Stereo Cloud** (per-band stereo position, which
  answers *which part* of a mix folds badly rather than only that it does).
- **Bel opens on a working meter bridge**, with the frequency displays on a
  second tab, instead of six readings on an empty grid.

- **The canvas is arrangeable.** A 24-column by 16-row grid: drag a module by
  its title bar to move it, drag the corner grip to resize, alt-drag to
  duplicate, right-click or double-click empty space to add one, right-click a
  module for its options. Modules may not overlap and an illegal drop is
  refused rather than nudged elsewhere, with the target cells shown live while
  the pointer is down.
- **Tabs**, with rename, duplicate and delete, switchable with the number keys.
- **Undo and redo**, over every layout edit, from the keyboard or the tab strip.
- **A Number Box shows any of the sixteen measurements**, chosen per module
  from its menu.
- Inter and JetBrains Mono are **bundled** instead of requested from the system,
  so digit width and tracking are identical on macOS, Windows and Linux. Both
  are SIL OFL 1.1 and their licences ship alongside them.
- **Capture from real audio devices.** Inputs are enumerated and selectable
  from the source menu in the status bar. On Windows, WASAPI loopback meters
  system output with no setup; on macOS and Linux a virtual loopback device
  (BlackHole, a PipeWire monitor) appears in the same list — see the README.
- `BelSource.push` and `bel_engine_push()`: audio supplied synchronously by the
  caller, with no thread and no clock. It makes the engine a pure function of
  the samples it was given, which is what the conformance suite needs and what
  file analysis will be built on.
- **Lost audio is reported rather than hidden.** If analysis falls behind, the
  capture callback drops frames and the count is published; the app shows a
  warning saying the integrated reading can no longer be trusted. Integrated
  loudness averages every block since the reset, so dropped audio does not make
  it stale — it makes it an average of a different programme than the one that
  played.
- **Offline file analysis.** Drop a file on the analysis panel, or pick one, and
  it is measured end to end: WAV, AIFF, RF64, Wave64, FLAC and MP3. The run
  happens on a worker isolate so the live meters keep their frame budget, it
  reports progress, and it can be cancelled — cleanly, releasing the engine and
  the open file rather than leaking them.
- **A report panel**, showing the source, every programme-wide measurement, a
  short-term loudness graph with the integrated level marked, and the delivery
  verdict against the selected target.
- **Reports export as text, JSON and CSV.** Text is the human summary; JSON
  carries every measurement, the target and the verdict under stable field
  names; CSV is the loudness timeline, one row per point, for a spreadsheet or
  a plot. An unmeasured value is an em dash, a `null` and an empty cell
  respectively — never a zero, which is a legitimate reading for correlation
  and several dB quantities and so cannot double as "no data".
- **A `bel` command-line analyser**, so a loudness check can be a step in a
  release pipeline instead of something somebody remembers to do. It runs the
  same engine and the same decoder as the app. `bel --target streaming-14
  master.wav` **exits 2** when the file misses its delivery spec, 1 on a file it
  cannot read and 0 when all is well, which is what lets a build fail on a
  master that is 2 LU too loud.

- **Bel remembers what you set up.** The frame rate, the delivery target, the
  skin, the signal source and the arrangement on the canvas all survive
  quitting. The window reopens on the layout it was closed on, listening to the
  device it was listening to.
- **Presets.** Save the arrangement under a name, open it again later, delete
  it. One JSON file per preset in a documented directory, so a preset can be
  sent to somebody, dropped in from a forum post or kept in version control —
  and one corrupt file costs one preset rather than the library. A preset
  optionally carries the delivery target and skin it was saved with; leaving
  either out means "follow whatever is selected", which is what makes a layout
  reusable across jobs.
- **A delivery-target editor.** Any spec Bel does not ship — a label's house
  standard, a game platform's submission requirement — is now twenty seconds of
  typing rather than a feature request. User targets appear beside the built-ins
  everywhere, and a user file carrying a built-in's id replaces that built-in,
  including in presets that already name it. Deleting the file brings the
  original back.
- **Skins.** The palette is thirteen named roles in a JSON file. A skin may set
  as few as one of them and inherit the rest, so changing the accent colour is a
  three-line file. Ships with Precision Instrument and **Daylight**, a light
  palette for a room with a window in it. "Duplicate for editing" writes the
  active palette out in full as a starting point, and "Reload from disk" picks
  up an edit without a restart.
- **A settings panel**, reachable from the status bar: signal and capture
  device, refresh rate and delivery target, skins, and whether the last layout
  is restored at launch. It also names the directory everything is kept in.
- The remote display's name, port and frame rate are remembered. **Whether it
  is publishing is not**, deliberately: configuration is worth remembering, and
  the decision to open a port with no password on it is worth asking for every
  session — a laptop carried somewhere else must not start advertising itself
  because somebody enabled it once at home.
- **The macOS build is no longer sandboxed.** It was, which put your settings,
  presets, skins and delivery targets inside
  `~/Library/Containers/dev.belmeter.bel/Data/…` instead of
  `~/Library/Application Support/Bel`, and stopped `BEL_CONFIG_DIR` from
  pointing anywhere outside that container. Configuration you cannot find is
  configuration you cannot edit, mail to somebody or keep in version control,
  which is most of the point of it being files. Bel gives up Mac App Store
  eligibility, which was never planned; notarising the dmg does not need the
  sandbox. **If you ran an earlier build, your existing configuration is in the
  container path above — move it across, or it will look as though Bel forgot
  everything.**
- The settings panel prints the configuration directory as selectable text
  rather than a path you would have to retype.
- The capture device is reopened **by name when its id no longer matches**.
  Device ids are not stable across reboots on any of the three platforms, so an
  id-only lookup silently drops you back to the test tone after a restart with
  no explanation.

- **Keyboard shortcuts, and a sheet that lists them.** Press `?` or `F1`, or
  the `?` in the status bar. Arrow keys nudge the selected module a cell and
  `Shift`+arrows resize it; `Ctrl`/`Cmd` with `N`, `D`, `Z`, `T`, `R`, `O`, `P`
  and `,` add a module, duplicate, undo, open a tab, restart the measurement,
  analyse a file, open presets and open settings. Bel draws its own chrome and
  so has no menu bar to read a chord off, which is why the sheet exists.
- **`--config-dir` names where Bel keeps settings, presets, delivery targets
  and skins**, and beats the `BEL_CONFIG_DIR` environment variable. On macOS it
  is the only one of the two that works on an installed `.app`: passing an
  environment variable means launching the binary inside the bundle, which
  changes how the system attributes the microphone request, so the variable and
  device capture could not be used in the same run.
- **`--open-panel=<name>` opens one panel once the window is up**, for
  `settings`, `presets`, `calibration`, `report` or `shortcuts`. Debug builds
  only; a release build says so rather than ignoring it.
- **Installers for all four desktop targets** — dmg, msix, AppImage and flatpak
  — plus the `bel` analyser as a standalone binary, published on every tag.
- **A documentation site**, built from the Markdown in this repository and
  published from `main`. The keyboard page is generated from the same table the
  application binds, and a test fails if it has drifted.
- **An application icon**, at every size the four installers ask for.

### ⚡ Changed

- The main view is an arrangeable canvas instead of a fixed wall showing every
  metric at once. It opens on six readings — LUFS-M, LUFS-S, LUFS-I, LRA, TP
  Max and Peak Max — and the rest of the canvas is yours.
- A module's default measurement now follows its kind rather than always being
  integrated loudness, so a freshly placed Alert Meter watches true peak — which
  is what an alert is for. A saved layout that omitted the key reads back
  differently for alert meters.
- The signal source is a persisted setting rather than something the status bar
  holds. Two controls can change it now — the bar and the settings panel — and
  both write to the same place, which is also what lets the next launch reopen
  it.
- The interface no longer has a single compile-time palette. Everything that
  draws takes its colours from the active skin.
- The delivery-target menu lists the user's own targets alongside the built-in
  ones.
- The DAW plugin ships as **VST3 and Audio Unit** rather than the CLAP the plan
  named. CLAP's SDK is the nicest of the three, but Ableton Live does not host
  CLAP, and a metering plugin that cannot be inserted in Live is one most
  people cannot use.

- **Keyboard shortcuts work wherever focus is.** They were installed inside the
  canvas and stopped working the moment focus left it — clicking the source
  picker was enough to silently disable undo. They now wrap the whole
  workspace.
- The tab strip's `+` sits beside the last tab and scrolls with the tabs,
  rather than being carried to the far end of the strip.

### 🐛 Fixed

- Changing the signal source could replace every meter on the canvas with a red
  error box reading "A MeterClock was used after being disposed". The old clock
  was torn down before the new one was installed, so any painter still mounted
  for that frame — which is all of them — tried to attach to a disposed
  notifier. Disposal now happens after the frame that replaces it.

- **Tabs were clipped off the end of the strip while it was visibly half
  empty.** The tab area and the gap before the action buttons were two flex
  children of equal weight, so the strip gave half its free width to the gap.
  Three tabs in an 800 px window were enough to lose one.
- **Renaming a tab from its context menu opened a field that would not accept
  typing.** The menu's route restored focus to the canvas after the field had
  claimed it. Double-clicking a tab was never affected, which is what made this
  hard to see: the two ways in behaved differently.
- **Every keyboard shortcut stopped working after a text field closed**, until
  something was clicked. Focus fell back to the navigator's scope, which sits
  above the bindings, and a key event travels up from the focused node — so
  there was nothing below it to reach.

### 🚧 Internal

- **`packages/bel_wire`** — the wire protocol, pure Dart and MIT, specified
  byte for byte in `docs/WIRE.md`. Three implementations speak it and none of
  them was written against another: the app's host, the app's display, and the
  plugin's C++ sender. `plugin/test/golden/wire_v1.bin` holds the Dart codec
  against bytes the C++ actually produced, which is the only test that would
  catch the two drifting apart — and the drift is silent, because every frame is
  a fixed length, so a field written into the wrong slot still parses.
- **`MeterSource`** — the interface a meter module reads a measurement out of,
  in `bel_core`. `BelEngine` implements it and so does the remote display's
  decoder, which is what lets the twelve modules run unchanged on a tablet with
  no engine in it. `bel_engine` now depends on `bel_core` for that one
  interface; the arrow still points away from `dart:ffi`.
- **`MeterClock` decides what is new by comparing generations** rather than by
  trusting what `refresh()` returned. With the remote host refreshing on its own
  timer there are two callers, and a one-shot "is this new" answer is consumed
  by whichever asks first — leaving the other to stop repainting, silently, only
  on the machines where somebody was using both screens at once.
- **`plugin/` is AGPL-3.0-or-later, not GPL-3.0.** JUCE 7 and 8 are
  AGPLv3-or-commercial; only JUCE 6 offered GPLv3, which is what the plan was
  written against. Bel takes the AGPLv3 option, which changes the licence of the
  plugin binary alone: the engine stays MIT, and the app stays GPL-3.0-or-later
  because it never links JUCE — it talks to the plugin over a socket. GPLv3
  section 13 expressly permits the combination. One piece of good news the plan
  did not anticipate: Steinberg has relicensed the VST3 SDK to MIT, so JUCE is
  the only copyleft dependency and no separate SDK checkout is needed.
- `engine/CMakeLists.txt` builds `libbel` as a static library for consumers that
  are not Dart. There are now two descriptions of the same compile, because a
  plugin CI runner has no Flutter SDK and a build hook cannot be handed to JUCE;
  `plugin/test/sources_match.sh` fails the build if they drift apart.
- The C++ and Dart implementations of the wire protocol are held against a
  committed golden that the plugin's own serialiser generates, rather than each
  end round-tripping against itself. A field transcribed into the wrong slot
  still parses — every frame is a fixed length — so the app would draw a
  spectrum out of the scope buffer and look entirely plausible doing it. The
  golden asserts NaN and negative infinity survive unchanged, both being bit
  patterns a careless serialiser normalises.
- JUCE 8.0.15 is pinned and fetched rather than vendored, so the repository does
  not grow by 110 MB to record a version number.
- miniaudio v0.11.25 vendored under `engine/third_party/` (public domain /
  MIT-0), with everything but the device layer compiled out.
- dr_wav 0.14.6, dr_flac 0.13.4 and dr_mp3 0.7.4 vendored under
  `engine/third_party/dr_libs/` (public domain / MIT-0), compiled in one
  translation unit separate from the device layer. `MA_NO_DECODING` in
  `bel_device.c` is what stops miniaudio compiling its own bundled copies of
  the same three and colliding with them at link time — it was already
  load-bearing for measurement correctness and is now load-bearing for the
  build as well.
- MP3 is the last format tried when identifying a file, not the first. dr_mp3
  recognises a file by scanning for something that parses as a frame, and
  arbitrary binary data contains such sequences often enough that, given first
  refusal, it will open a FLAC file and decode noise from it.
- `BEL_ABI_VERSION` is 4. The change is additive — `bel_snapshot` is byte for
  byte what it was at 3 — and adds only the `bel_file_*` decoding calls.
- File paths reach the decoder as UTF-8 and are widened to UTF-16 on Windows.
  dr_libs' plain `_init_file` calls go through `fopen`, which reads the path in
  the process's ANSI code page; an umlaut in a user name is enough to make a
  file unopenable on one platform only, with an error that says nothing about
  encoding.
- Cancelling an analysis goes through a flag in native memory rather than by
  killing the worker isolate, which would leak the engine and the open decoder
  it was holding. A message cannot reach an isolate busy in a decode loop that
  never yields to its event queue; a pointer both isolates can read can.
- The conformance suite generates its own signals rather than reading WAV
  fixtures, so it runs on a headless runner with no network and no decoder.
- Loudness is asserted to be independent of both sample rate and push block
  size — properties the standard does not state but which catch two classes of
  error that 48 kHz single-block tests cannot.
- pffft vendored under `engine/third_party/` (FFTPACK licence, permissive), and
  the maths-constant feature macro added to the build hook's POSIX defines —
  `M_PI` is XSI rather than ISO C, and asking glibc for a POSIX level hides it.
  Linux-only compile failure, the same shape as the Phase 0 `clock_gettime` one.
- One set of transforms feeds the analyser, the spectrogram and the stereo
  cloud. Three modules running their own FFT over the same audio would cost
  three times as much and could disagree about where a peak is.
- Three primitives came out of writing the modules rather than being guessed at
  in advance: a shared dB scale and graticule, a paragraph cache that re-lays
  out only when a formatted string actually changes, and a persistence layer
  that owns the `toImageSync` ping-pong **and its disposal** — a dropped GPU
  texture leaks video memory on a machine that reports plenty of free memory.
- The accumulating modules advance on the engine's publish counter rather than
  on every paint, so a resize or a theme change cannot scroll a spectrogram
  through time that no audio passed through.
- The canvas placement rules — overlap, clamping, id allocation — are pure
  functions over `TabSpec` in `bel_core`, so they are covered by tests that need
  no window, and so the remote display cannot come to a different conclusion
  about where a module goes than the app did.
- The canvas and workspace tests build their own sparse layouts instead of
  reading geometry off the default preset. What the app opens with is a product
  decision, and a drag test that measured itself against it failed the day the
  default improved.
- Dragging a module rebuilds nothing. The module stays where it is and one
  painter draws where it would land, so pointer movement cannot stall a canvas
  of live meters.
- Module painters now extend a `MeterPainter` base and the module frame's
  chrome is painted rather than decorated. `CustomPainter.hitTest` and
  `BoxDecoration` both absorb pointer events by default, which left every
  meter's face unclickable with nothing reported anywhere.
- `.github/workflows/ci.yml` now runs `dart test packages/bel_wire` and
  `plugin/test/sources_match.sh`. Both were named as gates in `CLAUDE.md` and
  `README.md` for a phase before either was wired in, which is the worst state
  for a gate to be in: everybody believes it is running.
- `.github/workflows/release.yml` builds the four installers and the CLI on a
  tag and on demand. On demand matters — an installer built only at release
  time is one whose script has been broken for weeks by the time anyone finds
  out.
- `.github/workflows/docs.yml` builds the documentation site on every pull
  request and publishes it from `main`.
- `tool/docs.dart` generates the site with no dependencies, so the docs job is
  a Dart SDK and no Flutter. The page list is written out rather than globbed,
  so `docs/PLAN.md` cannot be published to users by accident.
- `packaging/icon/make_icons.dart` describes the mark once as geometry and
  renders every size the installers want. Exported by hand, thirty-odd files
  across four containers drift.
- The canvas's refusal toast is a provider rather than private widget state, so
  the shortcut layer above the canvas reports "no room for that" through the
  same channel a refused drop does instead of growing a second one.

## [0.1.0] — 2026-08-15

First release. The architecture is proven end to end and the app runs; most
meters do not exist yet. See the [roadmap](README.md#roadmap).

### 📐 Measurement

- Peak, peak max, RMS, crest factor, inter-channel correlation and stereo
  balance are measured. Peak uses a 1.5 s hold and a 20 dB/s fall; RMS is
  smoothed with a 300 ms time constant.
- **Every loudness quantity is unmeasured and reads as a dash** — LUFS-M,
  LUFS-S, LUFS-I, LRA, true peak, TP max, DR-S, DR-I, PLR and PSR. They are
  `NaN` behind `BEL_FLAG_LOUDNESS_UNAVAILABLE`, never a zero that looks like a
  reading. K-weighting, R128 gating, LRA and true-peak oversampling arrive in
  the same release as the EBU conformance vectors that prove them.
- Bel does not implement Decibel's proprietary `TrueDyn` and will not
  approximate it. `DR-S` and `DR-I` are defined in [docs/METRICS.md](docs/METRICS.md)
  instead, reproducibly.
- All dB readings clamp to a −144.0 floor rather than negative infinity, so that
  differences between them stay finite.

### ✨ Added

- A C11 measurement engine with a lock-free snapshot, published by a dedicated
  analysis thread and read once per frame over FFI with no allocation.
- A built-in 1 kHz test signal, so the engine is measurable on a machine with no
  audio hardware.
- The Precision Instrument design system: one spacing scale, one border weight,
  no shadows, tabular figures on every number.
- A domain model with a 24-column grid layout, delivery-target calibrations for
  streaming, podcast, EBU R 128, ATSC A/85 and CD, and forward-compatible preset
  serialisation that skips module kinds a build does not have.
- Number Box module and the application shell.

### 🐛 Fixed

- The analysis loop no longer runs progressively slower than real time on a
  loaded machine. `nanosleep` only guarantees *at least* the delay requested, so
  every block overshoots slightly under contention; the loop discarded that
  error on each iteration instead of absorbing it, and on an oversubscribed
  host it settled at about a third of real speed. Lateness up to 250 ms is now
  made up one block at a time, and only a longer stall — a laptop waking from
  sleep, a debugger — resynchronises.

### 🚧 Internal

- Native code builds through a Dart build hook on all five platforms. There is
  no `CMakeLists.txt`, podspec or `build.gradle` for it anywhere.
- POSIX feature-test macros are declared in the build hook. Without them
  `-std=c11` hides `clock_gettime` and `nanosleep`, which built cleanly on the
  development machine and failed on both POSIX CI runners.
- CI runs analysis, formatting, and the domain, widget and engine suites, with
  the engine built on Linux, macOS and Windows.
- Licensing is split: MIT for `engine/`, `bel_engine` and `bel_core`;
  GPL-3.0-or-later for the application, UI, CLI and plugin.

[unreleased]: https://github.com/JonasGrunau/open_music_analyzer/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/JonasGrunau/open_music_analyzer/releases/tag/v0.1.0
