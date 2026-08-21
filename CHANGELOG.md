# Changelog

All notable changes to Open Audio Analyzer are recorded here. The format is
defined in [CLAUDE.md](CLAUDE.md#changelogmd-format); the short version is that
**📐 Measurement always comes first**, because a change to a reported number can
invalidate a decision somebody already made about a master.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.1] — 2026-08-22

### 🐛 Fixed
- The macOS plugin bundles now carry a valid code signature. All three — the
  VST3, the Audio Unit and the Standalone — shipped with an invalid one in every
  release up to 0.4.0: the VST3's resource seal was computed before JUCE wrote
  `moduleinfo.json` into the bundle, and the other two were never bundle-signed
  at all. On Apple Silicon that is enough for a DAW to leave the plugin out of
  its browser without logging anything, and for `auval` to refuse the Audio
  Unit. Each bundle is now signed after everything that writes into it and
  verified on the spot, so the build fails rather than producing a bundle it
  cannot verify. `auval -v aufx OaaM OaaA` passes. **If the plugin never
  appeared in your DAW, this is why** — and on macOS also strip
  `com.apple.quarantine` from a copy you downloaded, which no build can do for
  you.

### ✨ Added
- The documentation site's [Install](https://jonasgrunau.github.io/open_audio_analyzer/install.html)
  page now has an **In a DAW** section: which folder the VST3 and the Audio Unit
  have to be copied into on each platform, the `xattr` line that a downloaded
  copy needs on macOS, and the Ableton Live preference that has to be on before
  Live looks in the folder at all. The page had linked to that section since the
  site was first published, and the section did not exist.

### 🚧 Internal
- `OAA_CODESIGN_IDENTITY` signs the macOS plugin bundles with a Developer ID
  instead of ad-hoc. Releases stay ad-hoc.
- Signing runs from a target that depends on the format target rather than from
  `POST_BUILD`, which is not last: a `MACOSX_PACKAGE_LOCATION` resource is
  copied by a sibling rule that make may run after the link, and on a
  from-scratch build it does. Only visible with the bundle deleted first.

## [0.4.0] — 2026-08-21

### ✨ Added
- An Android tablet now finds hosts on the network by itself, like every other
  platform. It held a multicast socket that never received an answer, because
  Android's Wi-Fi driver discards multicast for an app that is not holding a
  `WifiManager.MulticastLock` — silently, with the search still saying it was
  looking. The lock is held while a search is running and given back when it
  stops, so it costs nothing once a display is attached.
- An Android tablet now remembers its layout, its skin and the host it was last
  attached to. Nothing in an Android process names a directory it may write to,
  so the configuration directory is asked for over a platform channel and lives
  in the app's own `files` directory; every launch before this one started from
  the defaults.
- Metering your Mac's own output no longer needs a loopback driver. On macOS
  14.2 and later, **System Output** is the first entry in the source menu, named
  after the output device it is metering. It is a Core Audio process tap, so
  there is nothing to install, nothing to reroute and no password prompt — the
  audio still reaches your speakers while it is being measured. macOS may ask
  for permission to record system audio the first time. Below 14.2 the entry is
  absent and BlackHole or Loopback is still the answer; Windows and Linux are
  unaffected, since WASAPI loopback and a PipeWire monitor source already appear
  in the list.

### ⚡ Changed
- The wire protocol is at version 3, and a receiver now accepts any version it
  knows rather than only its own. A plugin built against 0.3.0 keeps working
  with a newer app, which under the old equality check it would not have: a
  plugin lives in the DAW's plugin folder and stays there across app upgrades,
  so the mismatch was the ordinary case, and what it looked like from the plugin
  was a port that accepts and hangs up forever — indistinguishable from the
  defect where the port was never bound at all. The rule is one-way on purpose:
  a peer *newer* than this build is still refused, because a later version may
  have moved a table and misreading a measurement table is how a meter draws a
  confident wrong number. **A tablet still running 0.3.0 or earlier will refuse
  a newer desktop** and say so, rather than drawing anything; update both ends.
  Version 3 adds a frame type and moves no byte of any existing table — held by
  a test that decodes the frozen version-2 golden and diffs it against the
  version-3 one, where exactly four bytes differ and all four are version
  fields.
- A host search that is running but cannot receive says so instead of
  "Looking for hosts on this network…", which is the face a search that is about
  to succeed wears.

### 🐛 Fixed
- The plugin's status panel no longer claims a playhead from a host that is not
  giving one. The line was drawn from whether a transport had ever been
  published, and the plugin publishes one for every audio block — the empty one
  that means "this host said nothing" included — so it read as a playhead the
  moment audio started flowing, on precisely the host it exists to warn about.
  It now follows what the host is reporting now, and says "no playhead from
  host" again if a host stops.

### 🚧 Internal
- Groundwork for the Elapsed and Timecode LUFS modes, which are **not yet
  offered by any module** — this is the protocol and the engine underneath them,
  and the modules and their menu are the change after this one. `docs/WIRE.md`
  gains `0x0020 SET_LUFS_MODE`, the first frame that travels from consumer to
  producer, permitted on the ingest port only because that one binds loopback
  where whatever connects is already running as this user; the display port
  binds every interface and stays read-only until somebody designs
  authentication for it. Three implementations moved together, as that file
  requires.
- The engine can reset itself when the signal returns after a silence
  (`oaa_engine_set_silence_reset`, ABI 5), which is what the System mode is made
  of. It lives in `engine/` rather than above it because silence is a property
  of audio and not of a host — one implementation serves a plugin and a sound
  card, where two would eventually disagree about when a track began. The gate
  runs *before* the block it judges, so a track whose loudest sample is in its
  first block keeps that peak rather than having it cleared by its own reset.
  Off by default, and off for file analysis, which must measure a file whole.
  The two transport-driven modes need no engine API at all: they are the
  producer declining to push, so `engine/` still does not learn what a DAW is.
- The plugin's answer to a host that supplies no transport is now held by a
  test. `plugin/test/transport_capture_test.cpp` hosts the `AudioProcessor`
  directly, which is the only way to reach either of the two branches behind it:
  no VST3 or Audio Unit host can express "no playhead" or "no position", so
  neither a DAW nor the fake DAW can ask for them. It runs in the gated plugin
  job's `ctest`, and both it and the transport box's own test were verified by
  breaking the code under them and watching them fail.
- Five documents caught up with protocol version 3's two goldens. `docs/WIRE.md`
  still gave the SNAPSHOT payload size "at protocol version 2" in the one
  document whose header declares version 3; `packages/oaa_wire/AGENTS.md` named
  `wire_v2.bin` as the golden its codec test decodes, when the test reads both
  and `wire_v3.bin` is the one tracking the current serialiser; and two comments
  in `ci.yml` credited the C++ producing side with writing `wire_v2.bin`, which
  it no longer does. The one that could have cost something: the regeneration
  command in `plugin/test/wire_fixture.cpp` still wrote to `wire_v2.bin` — the
  frozen file whose whole purpose is to hold bytes produced before version 3
  promised to move no table. Following it would have destroyed the evidence and
  left every test green.
- Two claims about that branch are corrected here rather than in the 0.3.0
  notes, which are released. It is **not** reached by the Standalone build —
  JUCE 8's `AudioProcessorPlayer` installs a counting playhead whenever the
  processor it is given has none — and it is unreachable through an Audio Unit
  as well, not only through VST3. The plugin's own handling was correct
  throughout; only the note about what exercised it was wrong. `README.md` no
  longer lists it under Known gaps, because it now has a test instead of a
  paragraph.

## [0.3.0] — 2026-08-21

### 📐 Measurement
- The clip indicator now catches clipping. `clip` is the longest run of
  consecutive full-scale samples since the last reset, latched until Reset; it
  was the run still in progress at the block boundary, which is zero for every
  clip that ended inside the block — almost all of them. A run of 40 full-scale
  samples in the middle of a 1024-frame block published 0. The Digital Meter's
  clip lamp is drawn from this, so it was dark for real clipping, which reads as
  proof that nothing clipped. No other reading changes; nothing that was
  reported as clipped is now reported as clean.
- Crest is now taken over the block being measured rather than from the values
  the meters draw. Both operands were the displayed peak and RMS, which carry a
  1.5 s hold and a 300 ms averager, so the figure described the ballistics: a
  single block of DC at 0.9 read 11.6 dB where the answer is 0, and 0.43 s after
  a transient it read 17.8 dB and was still climbing. A steady sine reads
  3.0103 dB either way, which is why the test suite never caught it.
  **Re-measure anything whose crest you recorded from a moving signal** —
  readings on transient material fall, typically by several dB, and were
  previously too high. Multichannel now reports the peakiest channel rather than
  the loudest peak minus the loudest RMS, which could describe no channel at
  all.

### ✨ Added
- A DAW's playhead now reaches a tablet. The desktop decoded the plugin's
  transport frame and kept it: bars, beats, tempo, time signature and timecode
  stopped at the desktop, so a remote display showed a plugin's meters beside no
  position at all. It is relayed to every attached display now — on change
  rather than with every measurement, so a parked session costs nothing, and
  replayed when a display attaches so that one joining a parked session is not
  left blank until somebody presses play. A jump in the playhead survives the
  hop: the flag is an edge delivered once, and a relay publishing thirty times a
  second against a DAW's ninety-odd blocks accumulates it rather than sampling
  it.
- The status bar and a tablet's link bar both show the host's transport: the
  position in the most precise unit the host gave — timecode, else bar and beat,
  else its own clock — with the tempo and time signature where there is room for
  them, and brighter while the transport is rolling than while it is parked. The
  app had been decoding all of it and showing none of it. A value the host did
  not supply is not drawn at all, rather than printed as a plausible zero.
- The app accepts plugin connections. `PluginLink` was written, tested and never
  constructed, so port 47822 was never bound: a VST3 or AU inserted in a DAW
  retried against nothing forever while the README said the desktop app meters
  what the DAW is playing. Inserting a plugin now puts it on the canvas — the
  act of inserting it is the act of choosing it — and removing it hands the
  canvas back to the local source. A port that cannot be bound is reported in
  the window rather than being silent, because the usual cause is a second copy
  of Open Audio Analyzer already running.
- `oaa --target` reads your own delivery targets, not only the six built-in
  ones. The app has always merged `calibrations/*.json` over the built-ins by
  id; the CLI knew nothing about them, so a corrected `atsc-a85.json` changed
  the verdict in the window and left the exit code — the one a release pipeline
  believes — judging against ours. `oaa --list-targets` shows them, and
  `--config-dir` points at a directory other than the default.
- The VST3 and the Audio Unit are published with each release, as one archive
  per platform holding the plugin bundles. They are not bundled inside the
  desktop installers yet.
- The plugin is compiled on Linux, macOS and Windows as part of a release, and
  on demand. Nothing built it before: the only plugin check in CI compared two
  text files and never invoked CMake, so a JUCE dependency fetched by tag, a C++
  wire producer that has to agree with the Dart one byte for byte, and a version
  that moves every release were all held together by whoever last built it by
  hand. It is not built on every push, because three parallel JUCE builds cost
  more than a push asks for.

### ⚡ Changed
- The application is called Open Audio Analyzer everywhere it names itself. The
  window title, the macOS menu bar, the Windows version resource and the Android
  launcher label all said `oaa`, which is the repository's short name and not the
  product's. The executable moves with them: `Open Audio Analyzer.app` on macOS,
  `OpenAudioAnalyzer.exe` on Windows and `open-audio-analyzer` on Linux, where a
  space is not available — the Flutter-generated CMake makes the executable name
  a CMake target name, and CMake rejects one containing a space. The `oaa` CLI
  keeps its name; it is a command, and a command with spaces in it is not one.
  Bundle identifiers are unchanged, so no configuration moves and no host loses
  track of the plugin.
- The plugin's bundle identifier is `dev.openaudioanalyzer.oaa.plugin`. It was
  `io.github.jonasgrunau.bel`: the rename to Open Audio Analyzer moved every
  other identifier and missed this one, because nothing built the plugin to
  notice. A host caches a plugin by that string, so it moves before the first
  published build rather than after.

### 🐛 Fixed
- A relocate is reported once rather than twice. The plugin marks the single
  audio block on which the playhead jumps, and that flag was carried both in the
  accumulator that exists to deliver it exactly once *and* in the transport
  payload, which is sampled — so a machine loaded enough for two frames to leave
  inside one audio block delivered one relocate as two, and a three-lap loop
  reported four. `docs/WIRE.md` lets a consumer count relocations by counting
  flagged frames, so the count was wrong; no reading changes, because nothing
  yet acts on the flag. Held by a new deterministic test rather than by a loaded
  machine.
- The "audio was lost" notice counts the frames the *metered* source discarded.
  It read the local engine's counter while the flag that raises it comes from
  whatever is on the canvas, so a plugin that overran produced "Audio was lost —
  0 frames were discarded": a warning that contradicts itself, about a real loss
  of audio, carrying the number somebody would put in a bug report.
- The remote display no longer reads a destroyed engine. Changing the audio
  source or device while publishing to a tablet left the publish timer holding
  the engine it was built with, acquiring through a freed handle thirty times a
  second and sending 15 kB of returned heap to the tablet as a measurement. The
  service now follows the engine, and lives beside it rather than inside the
  status-bar button — which the status bar drops below 620 px of window width,
  so narrowing the window silently tore down an active session.
- A disposed engine reports itself unavailable instead of reading freed memory.
  Every scalar reading returns NaN, false or zero and `refresh` returns false, so
  a holder that keeps one a frame too long draws em dashes rather than plausible
  numbers. The array views cannot be guarded and are documented as invalid the
  moment `dispose` returns.
- Cancelling a file analysis no longer leaves the previous one running. The
  native cancel flag was freed while the worker isolate was still reading it, so
  the next analysis reallocated those four bytes as zero and the old worker read
  "not cancelled" and went on decoding its whole file — competing for the frame
  budget the isolate exists to protect. The flag is released once the isolate has
  actually exited.
- Resizing a module that a stored layout had left smaller than its own minimum,
  against the right or bottom edge, no longer throws. Rects are now pinned to
  the canvas and to the module's minimum as they are read, whatever wrote them.
- The remote display's advertised name can be cleared, not only replaced.
  Emptying the field restored the previous name, so "use this machine's name"
  was unreachable once a name had been set.
- A file analysis that cannot start no longer leaks its open decoder.
- A preset named `CON`, `AUX`, `NUL`, `PRN`, `COM1`–`COM9` or `LPT1`–`LPT9` can
  be saved on Windows, where those are reserved with any extension.
- Stopping a pushed engine clears its running flag. It never started a thread,
  so `oaa_engine_stop` returned early and the snapshot reported a stopped engine
  as running for the rest of its life.
- A capture device's id is no longer truncated to an odd number of hex digits
  with its terminator landing by luck. Trailing zero bytes are dropped before
  encoding, which keeps every id a real backend produces well inside the field.
- The plugin drops a wrong-length frame rather than sending it. The check was an
  `assert`, and the plugin is built `Release` everywhere including CI, so
  `NDEBUG` removed it from the only build that exercises the C++ producer.
- The plugin no longer tells the app the playhead relocated while the transport
  is parked. A stopped DAW still runs its graph and reports the position it sits
  at, unchanged, every block; the plugin compared that against "one block
  further on" and raised its discontinuity flag on every published frame for as
  long as the transport was stopped — measured at 140 frames out of 140. It is
  now only evaluated while the transport is rolling. Nothing in the application
  consumes the flag yet, so no reading changes today; the Elapsed and Timecode
  LUFS modes are what would have been affected.
- The plugin's name arrives at the app as text rather than as mojibake. The
  HELLO frame's producer name was built with `juce::String`'s `const char*`
  constructor, which reads its argument one byte to one codepoint, so the em
  dash in "Open Audio Analyzer plugin — " was mangled on the way in and
  re-encoded on the way out: the app's title bar read
  `Open Audio Analyzer plugin â<80><94>`. `docs/WIRE.md` specifies that field as
  UTF-8, which makes it a protocol defect rather than a typographical one. JUCE
  asserts on this and the assert is compiled out of the Release build, which is
  why nothing caught it.
- A relocate now reaches the app instead of usually being missed. The flag marks
  the single audio block on which the playhead jumped, and the streaming thread
  samples the transport once per published frame — every second block at a
  512-frame buffer, one in sixteen at 64 — so it was set on one publish and read
  from another: three loop laps in a row delivered it zero times out of 186
  frames. Edge flags now accumulate outside the seqlock and are delivered once
  each, which makes the count independent of buffer size. Verified at 64, 128
  and 512 frames.

### 🚧 Internal
- The plugin's framework-free C++ tests run on every push. `plugin/`'s JUCE fetch
  is conditional now, so `-DOAA_BUILD_PLUGIN=OFF` configures the directory in
  under a second and builds liboaa, the wire fixture and the transport box test
  in three — where the full job takes about ten minutes and, being gated to
  releases and manual runs, had been the only place any of it ran. It closes a
  real hole as well as a slow one: the wire golden is only worth having from both
  ends, and only the decoding half had been checked between releases.
- The fake DAW no longer invents relocates on a slow machine. An offline run
  handed the transport a read-ahead thread, and when that thread falls behind,
  JUCE's buffering source returns silence while the reported playhead stops
  advancing — a host claiming to play with a position that sits still, which is
  a discontinuity by any definition, and the plugin flagged it. The plugin was
  right; the instrument was wrong. Offline runs read the file synchronously now,
  which is what makes their timeline independent of the scheduler; the device
  path keeps its buffer, where a stall is a click rather than a wrong number.
- `resolveConfigRoot`, `ConfigDir`, `ConfigFile` and `slugify` moved from the app
  into `oaa_core`, which is what lets the CLI read the same delivery targets the
  app writes. They are pure functions, so the package keeps its "no I/O" rule.
- A fake DAW, in `plugin/host/`. It plays an audio file through the VST3 or the
  Audio Unit and hands it a transport — tempo, time signature, timecode frame
  rate, loop points, the record flag, and the playhead itself, which can be
  switched off. None of the plugin's playhead handling had ever been run before:
  the only host that could reach it was a real DAW driven by a person. It is
  built by the same CMake run as the plugin and shipped nowhere.
- The plugin is driven end to end by a test. `plugin/host/` also runs headless —
  no window, no sound card — and
  `packages/oaa_wire/test/plugin_e2e_test.dart` spawns it, listens on the port
  the app listens on, and decodes what arrives. It is the only coverage of
  `prepareToPlay`, the FIFO, the playhead, the engine, the streaming thread and
  the socket at once; the byte-for-byte golden beside it is produced by a
  fixture that links no JUCE. It generates its own audio, so nothing in CI
  downloads anything, and it skips rather than fails without a built plugin.
- A DAW's meters are held against what a tablet shows, in one test.
  `test/plugin_to_display_e2e_test.dart` runs the same fake DAW through the
  application's own plugin ingest and display host, attaches a display client —
  which is what a tablet runs — and compares twenty-nine readings field by
  field, plus the playhead: the tempo, the meter, the timecode and the bar the
  host was told to be at. What a display receives is a re-encode of a snapshot
  the app decoded off the plugin's socket, so a field dropped in the middle left
  both halves' suites green and the tablet showing a dash. It skips without a
  built plugin, and CI runs it on the Linux leg of the plugin job.
- One thing the fake DAW found is written down rather than patched, under Known
  gaps in `README.md`: the plugin's "host supplies no transport" branch cannot be
  reached through VST3 at all, because the format has no way to say it. That is a
  property of VST3 rather than a defect, and the branch is reached by the
  Standalone build. The other finding recorded that way on the first run — that
  the discontinuity flag usually did not survive the trip to the app — was
  fixed inside this release instead, and is under Fixed above; it moved a value
  `docs/WIRE.md` describes, which is why it was a decision before it was a fix.
- `tool/fetch_test_audio.dart` downloads the Creative Commons music the
  application is looked at with — a tone produces a spectrogram that is one
  bright line and a stereo cloud that is a dot, both correct and neither
  informative. Two CC BY 3.0 post-rock tracks from Wikimedia Commons, chosen by
  measuring four candidates with `oaa` rather than by reading titles: the
  default is a loud master with a real 10.3 LU range, a true peak above its
  sample peak, and a stereo field that moves. It resumes a partial download,
  verifies the length and signature, writes the attribution the licence asks for
  beside the audio, and is run by hand. No test depends on it.
- One workflow instead of three. `ci.yml` runs the tests, the documentation
  site, the installers and the release as jobs gated by event, so a push
  produces one run rather than two and a tag no longer produces a third that
  names neither. The reason it was split — that packaging must not slow the
  signal everybody waits on — is kept by not running those jobs on a push,
  which is a condition rather than a file. Two things the split had made
  impossible: a release can now depend on the test jobs, so a tag cannot
  publish from a red commit, and `workflow_dispatch` builds every installer
  without publishing anything.

## [0.2.0] — 2026-08-19

### 📐 Measurement

- **The VU meter reads differently, and lower on most material.** It was a
  one-pole smoother over mean square — an RMS meter with a 300 ms time constant.
  It is now what a VU movement actually is: **average-responding and
  RMS-calibrated**, through a second-order mechanism. A steady sine still reads
  its own RMS exactly, so a calibration tone is unchanged; anything peakier now
  reads **lower**, by 9 dB on a signal with a 10% duty cycle and typically 1 to
  4 dB on dense modern masters. If you have been matching levels by VU against
  Open Audio Analyzer's previous readings, re-check them. The needle also
  overshoots by about 1.2% on a transient, which is inside the tolerance the
  standard allows and is most of why a VU feels like a VU.
- **The spectrum is now measured.** 512 log-spaced bands from 20 Hz to 20 kHz,
  from a 4096-point Hann window per channel at a 1024-sample hop, zero-padded
  to a 16384-point transform. A band wide enough to contain bins takes the
  loudest of them rather than their average, so that a narrow resonance
  survives the mapping; a band too narrow to contain one — everything below
  about 216 Hz at 48 kHz — reads the transform between its two nearest bins.
  Levels are window-compensated: a full-scale sine on a bin centre reads
  0.0 dBFS, verified on every push, and one falling between two bin centres
  reads within 0.3 dB of its own level rather than up to 1.4 dB low. Frequency
  resolution is that of the 4096-point window and the padding does not change
  it: two tones closer than 11.7 Hz still merge. What changes is that the
  bottom three octaves are drawn as the curve the transform measured instead
  of as a staircase of up to twenty-five identical bands.
- **Per-band stereo position** and the **raw stereo sample stream** are now
  published, which is what the stereo cloud and the phase scope draw.
- **The short-term loudness distribution is now published**, together with the
  10th and 95th percentiles LRA is the difference of and the relative gate they
  were taken above — the same population the LRA number is computed from, so a
  distribution drawn from it cannot disagree with the number beside it.
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
  to.** Open Audio Analyzer measures the stream the hardware produced;
  resampling in front of the measurement would move inter-sample peaks and shift
  the K-weighted energy, and the resulting numbers would still look plausible.
- An interface wider than 7.1 is **refused** rather than measured eight
  channels at a time and reported as programme loudness.
- An unknown device id **fails** instead of falling back to the default. A
  preset naming an interface that is not plugged in would otherwise silently
  meter the laptop microphone.

- **Files can now be measured, and they read exactly as the live meters do.**
  Analysing a file decodes it and pushes the blocks through the same
  `oaa_analyse` a capture device drives — there is no second DSP path — so the
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
- **The Spectrum Analyzer draws an average of the bands rather than the last
  transform, and it now says which.** The engine publishes about 47 transforms a
  second and the module drew every one untouched, which flickers hard enough
  that the shape of a balance is difficult to read. A new `Response` setting in
  the module's menu chooses Fast — no averaging, exactly what it did before —
  Normal at 120 ms, or Slow at 500 ms; **Normal is the default**, so an existing
  analyser reads calmer than it did and a band's drawn level now lags a change
  by about that much. A short peak reads lower on Normal than it did on the
  frame it happened, by as much as the difference between the peak and what
  surrounds it. Nothing measured changed: the peak-hold line above the curve is
  never averaged at any setting, reports and the wire protocol carry the bands
  as measured, and the spectrogram and stereo cloud draw them as published.

### ✨ Added

- **A remote display.** Turn on publishing in the desktop's status bar and a
  tablet on the same network shows the same meters — the same modules, the same
  layout, the same skin and the same delivery target, rendered by the same
  painters from measurements sent over the network rather than reimplemented.
  Hosts are found by name over mDNS (`_oaa._tcp`), and an address can always be
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
- **A headless VST3 and Audio Unit plugin.** Insert Open Audio Analyzer on any
  track, bus or master and the desktop app meters what the DAW is playing,
  through the same engine and the same painters as a live input — so a plugin
  reading and a device reading of the same audio cannot disagree. The plugin
  draws no meters itself; it measures and streams, and a small status panel says
  whether it is connected. Built for macOS, Windows and Linux, plus a standalone
  target for testing the link without opening a host.
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
  a verdict); a **Histogram** (short-term loudness over time, with the momentary
  window banded above it and everything past the delivery target in the over
  colour); a **Loudness Distribution** (how often the programme sat at each
  loudness, with the two percentiles LRA is the distance between, drawn from the
  same blocks the number is computed from); a **Spectrum Analyzer**; a
  **Spectrogram**; a
  **Phase Scope**; and a **Stereo Cloud** (per-band stereo position, which
  answers *which part* of a mix folds badly rather than only that it does).
- **Open Audio Analyzer opens on a working meter bridge**, with the frequency
  displays on a second tab, instead of six readings on an empty grid.

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
- `OaaSource.push` and `oaa_engine_push()`: audio supplied synchronously by the
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
- **A `oaa` command-line analyser**, so a loudness check can be a step in a
  release pipeline instead of something somebody remembers to do. It runs the
  same engine and the same decoder as the app. `oaa --target streaming-14
  master.wav` **exits 2** when the file misses its delivery spec, 1 on a file it
  cannot read and 0 when all is well, which is what lets a build fail on a
  master that is 2 LU too loud.

- **Open Audio Analyzer remembers what you set up.** The frame rate, the
  delivery target, the skin, the signal source and the arrangement on the canvas
  all survive quitting. The window reopens on the layout it was closed on,
  listening to the device it was listening to.
- **Presets.** Save the arrangement under a name, open it again later, delete
  it. One JSON file per preset in a documented directory, so a preset can be
  sent to somebody, dropped in from a forum post or kept in version control —
  and one corrupt file costs one preset rather than the library. A preset
  optionally carries the delivery target and skin it was saved with; leaving
  either out means "follow whatever is selected", which is what makes a layout
  reusable across jobs.
- **A delivery-target editor.** Any spec Open Audio Analyzer does not ship — a
  label's house standard, a game platform's submission requirement — is now
  twenty seconds of typing rather than a feature request. User targets appear
  beside the built-ins everywhere, and a user file carrying a built-in's id
  replaces that built-in, including in presets that already name it. Deleting
  the file brings the original back.
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
  `~/Library/Containers/dev.openaudioanalyzer.oaa/Data/…` instead of
  `~/Library/Application Support/Open Audio Analyzer`, and stopped
  `OAA_CONFIG_DIR` from pointing anywhere outside that container. Configuration
  you cannot find is configuration you cannot edit, mail to somebody or keep in
  version control, which is most of the point of it being files. Open Audio
  Analyzer gives up Mac App Store eligibility, which was never planned;
  notarising the dmg does not need the sandbox. **If you ran an earlier build,
  your existing configuration is in the container path above — move it across,
  or it will look as though Open Audio Analyzer forgot everything.**
- The settings panel prints the configuration directory as selectable text
  rather than a path you would have to retype.
- The capture device is reopened **by name when its id no longer matches**.
  Device ids are not stable across reboots on any of the three platforms, so an
  id-only lookup silently drops you back to the test tone after a restart with
  no explanation.

- **Keyboard shortcuts, and a sheet that lists them.** Press `?` or `F1`, or the
  `?` in the status bar. Arrow keys nudge the selected module a cell and
  `Shift`+arrows resize it; `Ctrl`/`Cmd` with `N`, `D`, `Z`, `T`, `R`, `O`, `P`
  and `,` add a module, duplicate, undo, open a tab, restart the measurement,
  analyse a file, open presets and open settings. Open Audio Analyzer draws its
  own chrome and so has no menu bar to read a chord off, which is why the sheet
  exists.
- **`--config-dir` names where Open Audio Analyzer keeps settings, presets,
  delivery targets and skins**, and beats the `OAA_CONFIG_DIR` environment
  variable. On macOS it is the only one of the two that works on an installed
  `.app`: passing an environment variable means launching the binary inside the
  bundle, which changes how the system attributes the microphone request, so the
  variable and device capture could not be used in the same run.
- **`--open-panel=<name>` opens one panel once the window is up**, for
  `settings`, `presets`, `calibration`, `report` or `shortcuts`. Debug builds
  only; a release build says so rather than ignoring it.
- **Installers for all four desktop targets** — dmg, msix, AppImage and flatpak
  — plus the `oaa` analyser as a standalone binary, published on every tag.
- **A documentation site**, built from the Markdown in this repository and
  published from `main`. The keyboard page is generated from the same table the
  application binds, and a test fails if it has drifted.
- **An application icon**, at every size the four installers ask for.
- **The icon now covers iOS and Android too.** Both platforms were still
  shipping Flutter's default logo — the blue chevron on white — so the app
  installed on a phone or tablet under somebody else's mark. iOS gets the full
  layered icon described below; Android gets an adaptive icon, so the launcher
  masks it to whatever shape it uses and Android 13's themed home screen has a
  monochrome layer to tint instead of shrinking the icon inside a grey circle.
  There is a Play Store icon in `packaging/android/` for the console to be
  given by hand.
- **The macOS and iOS icon is layered, so the system lights it.** Both
  platforms now get an `AppIcon.icon` document — the graphite ground and the
  bars as separate layers — instead of a folder of pre-composited PNGs. macOS
  26 and iOS 26 render it with their own specular highlight and shadow, and
  derive the dark and tinted appearances from it; on a themed or dark home
  screen the icon now follows instead of staying light. Older systems are
  unaffected: the same document still produces a classic `.icns` back to macOS
  10.15 and flat icons back to iOS 13.

### ⚡ Changed

- **The icon's bars no longer climb in order.** They were 0.34, 0.55, 0.74,
  1.00 — which is the cellular signal glyph, drawn that way in the status bar
  of every phone the icon was about to appear on, and the shape is what the eye
  reads rather than the colour. They are now 0.62, 1.00, 0.44, 0.80: up, peak,
  valley, up, which is a meter. The bars also have slightly rounded corners,
  the tile's ground is a diagonal gradient from `hairline` to `background`
  instead of flat graphite, and the hairline border is gone — it was a
  one-pixel detail that iOS masked off, Android cropped, and 16 px could not
  draw. Every platform's artwork is regenerated from the same change.

- **The application is now called Open Audio Analyzer.** It was Bel. Nothing it
  measures changed — every reading is identical to the previous build — but
  the name it installs under, the directory it keeps your configuration in,
  the command-line binary and the protocol the tablet and the plugin speak
  all moved with it. The four below are the ones that can cost you something.
- **Your settings, presets, delivery targets and skins are not carried across.**
  Configuration now lives in `~/Library/Application Support/Open Audio Analyzer`
  on macOS, in `$XDG_CONFIG_HOME/oaa` or `~/.config/oaa` on Linux, and in the
  matching path on Windows. The old directory is left untouched and is never
  read; copy its contents over before the first launch to keep what you had.
- **This installs beside the previous version rather than over it.** The
  application identifier is now `dev.openaudioanalyzer.oaa`, so every installer
  and package manager treats this as a new application. Remove the old one by
  hand if you do not want both.
- **A tablet or a plugin from an earlier release will not connect.** The wire
  protocol is at version 2: the frame magic spells the new name, and a host
  advertises `_oaa._tcp` rather than `_bel._tcp`. A mismatched peer is refused
  at the handshake rather than drawing wrong numbers, which is the failure
  that matters — but both ends have to be updated together.
- **The command-line analyser is `oaa`, not `bel`.** Any script or CI step that
  calls it needs the new name; its arguments and its exit codes are unchanged.
- The status bar wordmark reads OAA, and the gap between it and the source
  picker is one step tighter. OAA sets about 3.4 px wider than the mark it
  replaced, which on its own was enough to run that row past its edge at
  1000 px with the longest delivery-target name.

- **Every number is set in Google Sans Code instead of JetBrains Mono.** The
  advance is 0.6 em in both faces, so nothing moves and no readout changes
  width; the digits are a little smaller on the body and rounder in the bowls.
  One character the old face carried is missing from the new one — `∞`, which a
  reading only shows if it is not finite, and nothing the engine produces is —
  so it now falls back to Inter, which Open Audio Analyzer already bundles,
  rather than to whatever the host offers. Both faces remain SIL OFL 1.1 and
  their licences still ship with every package.
- **Undo and redo in the tab strip carry a mirrored arrow beside the word.** The
  two words differ by one letter in the middle, and a mirrored pair says which
  way it goes before either has been read — but the arrow alone left the row's
  two most-used controls unnamed, so it now punctuates `UNDO` and `REDO` the way
  the plus punctuates `+ MODULE`. The arrows are drawn, like every other mark in
  Open Audio Analyzer, so they are the same on every platform and cost no
  dependency. The keyboard shortcuts are unchanged.
- **The delivery target in the status bar is built like the buttons beside it,
  one step quieter.** Same height and the same capitals, because it opens a menu
  on a click exactly as the four buttons to its right do and a control that can
  be pressed should look like one. Its border stays the fainter of the two
  hairlines, which is what still tells the thing that reports a setting from the
  four that do something. The target's own name is unchanged everywhere else:
  the menu, the settings panel and every report print it as it was typed.
- **A remote display's modules have no menu button.** The title bars drew one
  and it did nothing, because there is nothing on that screen a viewer is
  allowed to change. It is gone rather than disabled.
- **The stereo cloud's centre line is drawn over the frequency axis.** The three
  horizontal guides crossed in front of it, which broke the one line the module
  exists to mark into what looked like a dashed one.
- **A rule separates the tab strip's two kinds of action.** `UNDO` and `REDO`
  step back and forward through what has been done; `+ MODULE` does something
  new. They were four controls of the same size, colour and weight in one run.
- **A remote display's link bar has room to breathe, and its tabs are beside the
  host's name.** The bar is 48 px rather than 40, so the tab picker and
  Disconnect are not pressed against the rule under them, and the tabs now
  follow the name of the machine being watched instead of sitting in the far
  corner — which on a tablet is the most awkward place on the screen for the
  control the viewer touches most. Disconnect stays on the right, alone, where
  it is not hit by accident.
- **Both pluses in the tab strip are larger.** At the size the words use they
  read as specks rather than as controls. The one beside the tabs is the larger
  of the two, because it is the only symbol in the strip carrying an action with
  no word to help it; the one in `+ MODULE` is set between the two, visible
  without competing with the word it belongs to.
- **The keyboard sheet is one screen again.** Seventeen shortcuts in a single
  narrow column were taller than the panel, so the sheet scrolled and cut the
  line explaining that Ctrl and Cmd are interchangeable in half. It is now two
  columns on a wider panel — Canvas and Measurement on the left, Tabs and
  Configuration on the right — with the rows further apart and the whole list on
  screen at once, down to the smallest window Open Audio Analyzer supports.
  Below that it stacks back into one column rather than clipping. Measurement
  now comes before Tabs on the documentation site's keyboard page as well, which
  is the same ordering.
- **The remote panels are marked rather than only worded.** Sending and
  receiving were two rows of the same shape whose only difference was the
  sentence in them; each now carries a mark — a machine broadcasting, a screen
  on a stand — and a chevron on the rows that open a panel rather than choose in
  place. Every host a search finds wears the broadcast mark too, and it brightens
  under the pointer instead of sitting in the same grey as its address. A note
  that is a warning — the link has no password, this device cannot search the
  network, publishing failed — now has a warning mark in the margin beside it,
  so it is a different kind of line rather than a differently coloured one. The
  marks are drawn rather than typeset, so none of them can arrive as a tofu box
  on a platform whose fonts differ. Sending and receiving also sit further
  apart than the rows of a list do, since they are two directions to choose
  between rather than entries to pick from.
- **A machine's name, its port and the Apply that commits them are one line.**
  They were three stacked rows, so a two-field form read as three separate
  settings and the button that finishes it sat a row below either field. They
  now share a line, which the panel has room for.
- **A segmented control sets its choices in capitals**, like every button beside
  it. Source, refresh rate, the remote update rate and a display's tab picker
  were the only controls in the interface labelled in sentence case, which read
  as a line of prose in a box rather than as something to press. What a menu or
  a field holds — a device, a delivery target, a name somebody typed — is
  unchanged, because that is a value rather than the control's own word.
- **The Histogram's loudness line is always on screen.** It used to be drawn
  only over the columns the programme had reached, so an empty module — before
  the first audio, and for as long as you looked at it after a reset — had
  nothing in it at all, and a part-filled one had a line over part of its width.
  The line now rests on the floor of the scale and runs the full width of the
  plot, rising where the programme starts. Resting is not a reading: the floor
  is the bottom of the scale, nothing is filled beneath it, and it is drawn
  where measured silence would put it.
- **Nothing is a double click any more.** Renaming a tab, adding a module by
  clicking empty canvas, and zooming the window from the status bar were all
  double clicks; the first two are now a long press — which also gives a tablet
  a tab's rename, duplicate and delete for the first time — and the window is
  zoomed with the green window button, as it always could be. See 🐛 Fixed for
  why a double click was worth removing.
- **Moving a module dims the rest of the canvas, and the placement grid now has
  a border.** The grid is ruled inside a rounded border that sits one gutter
  outside the modules, with the same corner radius they have, and for as long as
  the pointer is down every module except the one in hand is washed toward the
  canvas colour. A drop target among a dozen meters that are all still moving
  was something you had to hunt for; the cells, the module being carried and
  where it will land are now the only things at full contrast. Nothing is
  measured differently — the meters underneath keep updating throughout.
- **The phase scope's trail no longer smears.** It was a picture faded and
  redrawn on every frame, so a moving dot was resampled once per frame and
  spread outwards; it is now the last forty frames of samples, each drawn at
  the brightness its age has earned. A dot fades where it was rather than
  blurring, and the decay is exact instead of compounding through the rounding
  of an 8-bit surface — the tail is fractionally longer for the same reason.
- **The stereo cloud is accumulated as numbers rather than as a picture**, in
  cells of two logical pixels, with each band's dot spread across the four
  cells it falls between. The shape, the fade and the brightness are the same;
  a close look finds dots on a two-pixel grid where they were previously at
  arbitrary positions.
- **A module's readings now grow with the module.** The bars, the arcs and the
  VU face have always been sized off the tile they are in; four modules sized
  their *numbers* off a constant instead, so the LUFS meter's LUFS-I and LRA,
  the Super Meter's centre readout, the Alert Meter's value and the Validator's
  measured column stayed the same size whether the module had a corner of a
  laptop screen or a quarter of a 27" one. The labels beside them — a scale's
  ticks, a column heading, PASS and FAIL — deliberately do not scale; they are
  the same size in every module on the canvas.
- **The smallest supported window is now 960x768, up from 720x480** (macOS; the
  other platforms set no minimum). The canvas is a fixed 24x16 cells at every
  window size, so at 480 px tall a two-row module had 12 px of body left after
  its title bar and margin — less than a digit. 768 is the height at which the
  smallest module in the default preset still has room for its number.
- **A module too small to draw in now says so instead of showing an empty
  panel.** The size a module needs is in pixels, not grid cells, so it was
  never something the cell minimums could enforce; each painter checked it
  privately and drew nothing when it failed. The thresholds are now declared on
  `ModuleKind` and the frame substitutes the "too small" placeholder, which is
  what it was always for.
- **The status bar drops items in a stated order as the window narrows**, one
  at a time and each at the width below which the rest stop fitting: first the
  sample-rate readout, then the OAA wordmark, then ANALYSE FILE, then REMOTE,
  then the `?` button. All four buttons keep their keyboard shortcuts, which
  are listed in the `?` sheet and in
  [docs/site/keyboard.md](docs/site/keyboard.md). What never drops is the
  source, the elapsed clock, the delivery target, SETTINGS and RESET. There was
  one gate before this, it was 20 px too generous, and nothing had measured it.
- **The settings panel has been reworked, and every other panel with it.**
  Sections are now ruled off from each other with a hairline instead of by
  whitespace alone, so Signal, Meters, Appearance and Session read as four
  groups rather than one column of grey; a row's explanation runs the full
  width of the panel underneath its control instead of wrapping in whatever
  space the control left over; and the loopback advice under Capture device is
  two lines rather than four. The same changes reach the preset browser, the
  delivery-target editor, the analysis report, the remote-display panel and the
  keyboard sheet, because all six are built from the same primitives.

- **REMOTE now asks which end of the link this machine is.** Pressing it opens
  a chooser — send these meters, or show another machine's — and each answer
  opens its own panel. Publishing used to be the whole of what the button
  offered: turning this screen into a display was a footer button on the
  publishing dialog marked "Use as display", which is the row a panel reserves
  for the ways out of it. The chooser also says whether this machine is already
  publishing and how many displays are attached, so that is answerable without
  opening anything further.

- **The remote display's connect screen is a panel like every other panel.** It
  was the one screen in Open Audio Analyzer that had never been near the design
  system — an unstyled list, a stock text field with a rounded outline and
  Material text buttons, on the hardware the feature exists for. Discovered
  hosts are panel rows now, the typed address is an Open Audio Analyzer field
  with Connect in the footer, and it is the same panel the desktop opens rather
  than a second implementation of it. The strip across the top of a live display
  gets the status bar's fill and hairline, with the tab picker and Disconnect as
  controls rather than as text. Disconnecting returns to the picker instead of
  to a dead screen.

- **Every boxed control in a panel is the same height.** Buttons, menus,
  segmented controls and text fields derived their heights independently and
  came out at 30, 32, 31.4 and 28.9 px, so no two standing side by side in a
  row ever quite lined up. They are all 32 px now.

- **A menu looks like a menu.** The capture-device and delivery-target pickers
  were bordered labels in caption grey — fainter than the buttons beside them,
  which reads as disabled — with nothing to say they opened anything. They now
  carry a caret, show their value in the same weight as the rest of the panel,
  highlight under the pointer, mark the current choice in the open menu, and
  can be reached and opened from the keyboard, which neither of them could
  before. The menu also no longer arrives with a Material drop shadow.

- **The selected skin is visible as selected.** Selection in a panel list was
  carried by a single step of grey on a 1 px border; it is now a raised fill as
  well.

- **The unfilled part of a meter is now visible.** `meter_track` sat at 1.10:1
  against the panel behind it on the dark skin and 1.22:1 on the light one —
  close enough to the surface that a bar showed its own fill and nothing else,
  and the Super Meter's three arcs could only be located by whichever one
  happened to be lit. Both shipped skins now hold it at roughly 1.6:1, and
  still about 2.5:1 below `meter_fill` so the reading stays the figure and the
  track stays the ground. **A user skin that sets `meter_track` keeps its own
  value**; a skin that inherits it gets the new one.

- **Modules have room to breathe, and the same amount of it on every side.**
  The inset between a module's border and its meter went from 8 px to 12 px,
  and the title bar's inset moved with it so the title still starts where the
  meter starts. Meters draw to the edges of what the frame hands them — a
  painter that adds a second inset of its own is a module that sits differently
  from the other eleven.

- **A dB scale no longer reserves more room than it uses.** The gutter beside a
  graticule was a flat 30 px whatever the labels said, so a meter with short
  labels sat visibly off-centre in its module — thirteen pixels of empty
  reserve on the scale side against nothing on the other. It is now measured
  from the labels themselves. Affects the LUFS meter, the digital meter, the
  spectrum analyser and the histogram.

- **The VU dial is sized to the module rather than to a fixed sweep.** The face
  opened 70° whatever shape the tile was, which in a wide tile drew the whole
  instrument across the middle half of the width and left the rest bare. The
  sweep now opens as far as the box allows, between 70° and 110°, and the dial
  is centred on what is actually drawn.

- **The frame rate is no longer in the status bar.** It was a second way to
  reach one setting, sitting in a row otherwise reserved for what changes while
  you work and what a reading has to be read against. It is chosen once for a
  machine; it lives in the settings panel and only there. The delivery target
  stays in the bar, because every `PASS` and `FAIL` on the canvas is a verdict
  against it.

- **A panel that scrolls now says so.** Settings is taller than the 760 px a
  panel is allowed and ended on a row the viewport happened to cut in half,
  with nothing to suggest there was more below it. A scrollbar appears when the
  content overflows and stays hidden when it does not.

- **The `REMOTE` button now looks like the rest of the status bar.** It was the
  one stock Material button in the row — borderless where its four neighbours
  are bordered, Material-sized rather than bar-sized, ink-rippled, and not
  reachable by keyboard. It now carries the same border, padding, type and
  focus ring as `ANALYSE FILE`, `SETTINGS` and `RESET`, and states what it is
  doing on hover. Publishing is shown by the label brightening rather than by
  the signal hue, which in this row means "in spec" and nothing else. The
  panel behind it is built from the same pieces as the other panels.

- **The macOS window has no title bar of its own.** The status bar now runs to
  the top edge of the window, and the close, minimise and zoom buttons sit
  inside it on the same row as the source and the elapsed clock. The strip of
  system grey above a bar of panel grey, and the window title printed in a font
  Open Audio Analyzer does not choose, are both gone. Dragging the status bar
  moves the window and double-clicking it zooms, as dragging and double-clicking
  the title bar did. Windows and Linux are unchanged.
- **A light skin no longer runs under dark window buttons on macOS.** The window
  follows the skin's `light` flag, so Daylight gets light chrome and the two
  stop disagreeing about which way up the room is.
- **The signal hue now means one thing on the canvas.** Teal previously marked
  both "in spec" and "selected", so a selected module was outlined in the same
  colour as a reading that had passed its target, a few pixels from the reading
  itself. Selection is now a brighter, heavier border; the active tab, the
  highlighted menu row, the resize grip, the listening indicator and the drop
  preview all moved to neutral values. Teal now appears on the canvas only when
  something is within its delivery target.
- The em dash that means "not measured" is drawn in a legible colour. It shared
  a value with scale ticks and disabled controls, at 2.81:1 against the panel
  against readings at 15:1 — the one mark in the interface that says a quantity
  was *not* measured was the hardest one to see.
- Selection, hover and focus borders are visible. `hairline_strong` was 1.47:1
  against the panel — a role whose whole purpose is to be seen, set to a value
  that could not be, which is why callers reached past it for the accent. It is
  now roughly 3:1 in both shipped skins. **A user skin that sets
  `hairline_strong` keeps its own value and is unaffected.**
- `RESET` now states its scope on hover: it restarts the measurement, and
  leaves the layout, target and skin alone.
- The meters cap themselves at 30 fps when the system asks for reduced motion,
  and the settings panel says so rather than showing a rate nothing is running
  at. Open Audio Analyzer has no decorative animation to switch off — what moves
  is the measurement — so a lower redraw rate is the only honest reading of that
  preference. No reading is withheld.
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

- **A remote display recovers from a dropped link, instead of showing one frame
  of invented measurement and then never coming back.** A connection that died
  partway through a measurement left the head of that frame in the display's
  frame reader, which nothing cleared — so the retry reassembled the dead
  stream's bytes onto the live one. That splice is exactly the right length to
  decode, so the meters drew a detailed, confident reading nobody took, lost
  sync on whatever followed, and dropped the link again, carrying the leftovers
  into every attempt after that. A tablet that lost a single frame to a Wi-Fi
  hiccup stopped recovering until the app was restarted — Disconnect and
  reattach did not clear it either. Nothing about how Open Audio Analyzer
  measures has changed and no past reading needs re-checking: the desktop and
  the CLI were never on this path.
- **The status bar's controls are one height.** The delivery target read 25.4 px
  tall against 22 px for the four buttons beside it, because each shape derived
  its height from its own text style plus its own padding rather than being
  given one. The borders in the row now start and end on the same pixel.
- **A warning mark sits in the middle of the note it marks.** It was pinned to
  the top of the block, so beside the sending panel's two lines of orange it
  looked as though it belonged to the first line rather than to the warning.
- **A long capture session no longer dies with a bus error.** The sub-block
  ring the loudness measurements are built from carried a write cursor beside
  it, and the store into the ring trusted that cursor. One was found holding a
  float bit pattern after 36 minutes of capture, which turned an ordinary
  100 ms boundary into an 8-byte write 229 GB past the engine and killed the
  process. The row is now derived from the sub-block count where it is used, so
  the write lands inside the ring whatever the counter holds. Every reading is
  unchanged, bit for bit, and the EBU conformance vectors still pass. What put
  a float there has not been identified; this stops the engine turning it into
  a wild store.
- **A capture device is released when the engine fails to start.** If an
  allocation failed after the device had been started — sizing the analysis
  buffer, or the spectrum's transforms — the engine was freed while the
  real-time callback was still writing into the ring inside it, handing that
  callback a dangling pointer into a block the allocator was about to reuse.
  Startup now tears the device down on every failing path.
- **An iPad can now find hosts on the network.** It never could: iOS and iPadOS
  refuse an app the multicast socket Open Audio Analyzer browses with unless it
  carries an entitlement Apple grants per developer on request, so every send
  was rejected and nothing was ever delivered — on the hardware the remote
  display exists for. The tablet now searches through the system's own Bonjour
  responder, which needs no entitlement, and finds the same hosts by the same
  name. Typing an address still works and still always will.
- **A host on a network that hands out a domain is visible again.** Most routers
  give DHCP clients one, which makes the machine's name `studio-mac.fritz.box`
  rather than `studio-mac.local` — and Open Audio Analyzer advertised that whole
  string where DNS-SD allows a single label, so the announcement came out as six
  labels instead of four. Open Audio Analyzer's own browser read it anyway, so
  an Open Audio Analyzer desktop found an Open Audio Analyzer desktop and
  nothing looked wrong; every browser built on the system responder — an iPad,
  `dns-sd`, anything Apple — dropped the record, and the host answered every
  query on the wire while appearing to no one. The instance is now one label
  whatever the machine is called, and the name you read in the list is
  unchanged.
- **Open Audio Analyzer no longer advertises an address record for the machine's
  own name.** The name a Mac answers to belongs to the system responder, which
  defends it: an address record it did not publish, for a name it owns, is a
  conflict, and the loser of a conflict renames itself. On a machine with a
  second network interface the two sets differ, so the loser would have been the
  user's computer. Open Audio Analyzer publishes its own name for the service to
  point at.
- **A search that cannot run says why.** A device that could not search showed
  *Looking for hosts on this network…* indefinitely, which is exactly what a
  network with no hosts on it looks like. It now names the reason where there
  is one to name — a refused Local Network permission on macOS points at
  System Settings — and says plainly that it cannot search where there is not.
- **A laptop in a dock is listed at an address that answers.** A machine with a
  second network interface — an empty dock, a Thunderbolt bridge — announces
  every address it has, and the browser kept whichever arrived last. Half the
  time that was the interface's self-assigned 169.254 address, which nothing on
  the network can reach, so the host appeared in the list and the connection
  timed out. A routable address is now preferred, and a host that moves
  replaces its old address rather than adding to it.
- **A panel follows a change of skin while it is open.** Choosing one in
  Settings → Appearance repainted the canvas, the window chrome and the panel's
  own text fields and menus, but left the panel's surface, hairlines, labels and
  the dimming over the canvas in the previous skin until the panel was closed
  and reopened — so the one place a skin is chosen was the one place it could
  not be seen, and the panel was drawn in two skins at once meanwhile.
- **A two-finger trackpad gesture no longer drags things.** Right-clicking a
  module's title bar on a trackpad flashed the placement grid on screen, because
  a two-finger tap is how macOS sends that click and every drag in the
  application accepted a trackpad gesture as one: a two-finger scroll over a
  title bar moved the module, over the corner grip resized it, and over the
  status bar it started dragging the window. A drag now begins from a button
  press and from nothing else. Clicking and dragging on a trackpad is
  unaffected — that is a mouse as far as the system is concerned.
- **The top of a meter's scale is no longer cut in half.** The `0` on the LUFS
  meter was drawn as its own bottom half, and the same line of code clipped the
  spectrum analyser's top label and the first and last labels on the
  histogram's frequency axis. An end label now sits fully inside the meter; its
  gridline has not moved.
- **The `M` and `S` under the LUFS meter's bars are drawn at all.** They were
  centre-aligned in an unconstrained line box, which put each letter half a
  megapixel to the right of the meter — so the two bars had nothing naming
  them and the space for the names was still reserved beneath them.
- **The LUFS meter's two readings are no longer printed with their last digit
  missing.** They were sized off the module's height alone, so a tall narrow
  meter asked for digits wider than the column under the bar they belong to and
  the reading stopped drawing where it ran out of room: `-17.6` was shown as
  `-17.`, which reads as a different number rather than as a clipped one. Both
  now take the largest size that fits the column as well as the height, and are
  hidden — as they already were on a short module — when that size would be too
  small to read.
- **The super meter's ring names sit beside the arcs they name.** `M`, `S` and
  `I` led their arcs by a fixed angle, which is a fixed fraction of each
  radius, so the outer name stood nearly twice as far from its arc as the inner
  one did from its and the three read as a diagonal drifting off the gauge.
  They are now the same distance from every arc.
- **Buttons no longer take a third of a second to respond.** Every control in
  the status bar on macOS, every tab, and clicking empty canvas to clear the
  selection fired 300 ms after the click that pressed them. Each sat under a
  gesture that also recognised a double click, and Flutter's double-tap
  recogniser holds the gesture arena from the first tap until it times out —
  so the button's own tap could not be resolved until the wait for a second
  click had expired. The double clicks are gone (see ⚡ Changed) and the
  controls answer on release.
- **Open Audio Analyzer crashed after a few minutes with a spectrogram, phase
  scope or stereo cloud on the canvas, and grew without bound until it did.**
  One report showed the application holding 266 GB before macOS stopped it.
  Those three modules accumulated their history into an image taken with
  `toImageSync`, which retains the display list that drew it for as long as the
  image lives — so every frame's image pinned the frame before it, back to the
  first one, and disposing the handle released none of it. The application then
  died on the raster thread when that chain was finally dropped and its
  destructors recursed once per retained frame, 3,286 deep in the report that
  found this. All three now keep their history as data and redraw it, which
  costs memory proportional to the module's size rather than to how long Open
  Audio Analyzer has been open.
- **A spectrogram opened before any audio arrived began with a column of full
  scale, and the stereo cloud with a bright line down its centre.** Both were
  reading the zeroed arrays of a source that has not published yet, which as
  dB is 0 dBFS on every band. A source that has measured nothing now draws
  nothing.
- **The LUFS meter's two readouts sat under the wrong things.** They were laid
  out against the middle of the module, but the bars begin after the scale's
  gutter — so LUFS-I printed under the scale numbers and LRA under the middle
  of the momentary bar. Both now line up with the bars they sit below. No
  reading changed; the two numbers are the same numbers, in the right column.
- **Six Number Boxes rendered as empty panels on a small window.** On anything
  under about 700 px tall a two-row Number Box had less body than a digit is
  tall, and the painter's own size check meant it drew nothing rather than
  saying so. Every module now shows the "too small" placeholder instead, and
  the supported minimum window is large enough that the default preset never
  reaches it.
- **The status bar ran 121 px past the edge of the window** at the smallest
  size the window could be dragged to. In a debug build that is a striped
  overflow warning; in a release build the controls past the edge are simply
  not there.
- **The signal source overflowed its own place in the bar** whenever the name
  of the capture device came close to filling the room the bar had left for it
  — a striped warning across the source label in a debug build, and a name
  clipped without a mark in a release one. The name now shortens with an
  ellipsis to whatever the row can spare, as the delivery target beside it
  already did.
- **The Stereo Cloud looked broken on a mono source.** A built-in laptop
  microphone has one channel, per-band stereo position needs two, and the
  engine reports mono as dead centre — so every band plotted at the middle of
  the display and the module drew one bright vertical line and nothing else,
  which reads as a rendering fault rather than as a mono signal. It now says
  **MONO SOURCE** across the face and leaves the axis empty. No measurement
  changed; a stereo source draws exactly as before.

- **Selecting a capture device did nothing.** Only the source chosen at launch
  ever opened; every change made afterwards — from the status bar or from
  Settings, to a microphone, an interface, a loopback device, Silence or back
  to the test tone — was discarded. The choice was saved and reappeared as
  selected the next time you looked, so the meters looked like the failure:
  they went on showing the previous source, with its label, its channel count
  and its elapsed clock still running, exactly as though no input were
  reaching the machine. Each attempt also opened the device and held it with
  nothing reading it, which is why the system's recording indicator came on
  while the meters stayed on the test tone. Relaunching with the device already
  selected was the only way through, and is no longer needed.

- **Every panel's four corners were missing their border.** The surface is a
  rounded clip over a square border, so the clip removed the corner of the
  hairline along with everything else outside the arc: the border ran the flat
  edges and stopped dead at each tangent, leaving four bare arcs of panel fill
  fading into the barrier. The border now carries the same radius as the clip
  and runs continuously around the corner. Settings, the preset browser, the
  calibration editor, the report, the remote display panel and the shortcuts
  sheet are all built from that one surface, so all six are corrected — as is
  the startup notice, which had the same defect at a smaller radius.

- **The elapsed clock sat two pixels high in the status bar.** It is painted
  rather than built, and it was drawn from the top-left corner of a box taller
  than the line it holds, so every spare pixel fell below the digits and the
  clock rode above the optical centre of every label beside it. It now centres
  its line in its box, which is what a `Text` does with the space it is given.

- **Everything in the tab strip's action row sat a pixel below the tab names**
  — most visibly the `+` that adds a tab, which stands directly beside the last
  one. A tab reserves the height of the active-tab rule whether or not it is
  the active tab, and the buttons reserved nothing, so the two rows of text
  were centred in boxes of different heights. The `+` was low for a second
  reason as well: a lone plus is drawn on the font's math axis, below the
  middle of the band the words around it fill, and it is now raised onto their
  line.

- **The LUFS meter's two bars, and the digital meter's channels, shared one
  background.** The gap between bars was painted in the trough colour, so it
  only showed where one bar's fill had risen past the other's: two channels at
  the same level read as a single wide bar, and two at different levels as one
  bar with a step in it. Each bar now has its own trough and the gap shows the
  module behind it. The scale, the target band and the integrated rule still
  cross it — they belong to the meter, not to either bar.

- **The VU meter's face had four drawing defects.** The needle was drawn from
  behind its own pivot with a tail longer than the cap meant to hide it, so a
  second short needle stuck out of the bottom pointing the other way. At rest
  it lay along the −20 mark and struck that label through — and every reading
  on the lower half of the face had the needle across it, because the labels
  were inside the sweep. The six scale numbers were centred on a common radius
  rather than cleared from the arc by a common gap, so they scattered, with `0`
  hanging below its own tick. And the dial sat high and left in the tile with
  the `VU` badge adrift in the empty corner. The needle now runs outwards only,
  the labels sit outside the arc where nothing can cross them, each one clears
  the arc by the same gap whatever its angle, and the badge sits under the
  pivot where the needle cannot reach. **The ballistics and the scale are
  unchanged — the needle points at the same mark it did before.**

- **Four modules drew their contents in a corner instead of in the box.** A
  Number Box put its reading against the left edge, which on an unavailable
  reading left a single em dash alone in the corner of a four-cell tile,
  looking like a rendering fault rather than "not measured yet". An Alert Meter
  hung its block from the top edge of a module more than twice its height. The
  Super Meter centred itself as though it were a full circle when it opens 120°
  at the bottom, leaving a dead band a fifth of the module deep beneath it. The
  Validator stopped its rows at 34 px each and left the rest of the tile blank.

- **A one-row Number Box drew a title bar and nothing else.** A single grid row
  is about 55 px, and the title bar and the module's inset account for all of
  it, so the reading had no room and the painter returned without drawing —
  blank, rather than the "too small" a module says when it cannot be read. The
  minimum is two rows now, and a stored layout holding a one-row box is
  clamped up rather than rejected.

- **The delivery-target menu did not show which target was selected.** Both
  arms of the ternary that picks the row colour returned the same value, so
  every entry was drawn identically and the active target was indistinguishable
  from the five it was listed with.

- **The right-hand end of the status bar drifted away from the right edge.**
  The elapsed clock, the calibration and the four buttons sat
  progressively further from the window's right side the wider the window got,
  leaving a growing empty stretch of bar beside them. They are now flush with
  the edge at every width.

- **The remote display panel could not be opened.** Pressing `REMOTE` in the
  status bar threw "No OaaTheme in scope" and left the panel unbuilt, in
  release as well as debug — it was pushed with `showDialog`, so the
  `Navigator` built it above the palette the application provides. It is now
  pushed with `showOaaPanel` like the other five, and a test opens it through
  the button.

- **Open Audio Analyzer could not be built for iPadOS at all.** The engine was
  compiled as C on every platform, but miniaudio's Core Audio backend is
  Objective-C on iOS — it configures an `AVAudioSession`, which has no C
  interface — so the build ended in several hundred errors inside Apple's
  `Foundation` headers, none of which named a file in Open Audio Analyzer. The
  iOS build now compiles as Objective-C and links the frameworks miniaudio needs
  there. The tablet build is the remote display, and it now runs on an iPad.
- **The iPad build would have been terminated by iOS the first time an input
  was chosen.** `NSMicrophoneUsageDescription` was missing from the app's
  `Info.plist`, which is not an error the app can catch — the system kills a
  process that touches the microphone without one.

- **An iPad remembered nothing between launches** and opened with "no
  configuration directory". Open Audio Analyzer resolved its configuration from
  `HOME`, which iOS does not set — so every layout, skin and connection was lost
  when the app was closed. iPadOS now keeps its configuration in
  `Library/Application Support/Open Audio Analyzer` inside the app's own
  container, which Open Audio Analyzer locates through the temporary directory
  rather than the environment. An Android tablet still persists nothing, and
  still says so at launch.

- **A module's resize grip was drawn outside the module.** Both ticks ran to
  the corner of the module's slot, which is past the frame's rounded border —
  so they crossed the border and finished in the gutter between modules, and on
  a selected module they cut through the selection outline. They now sit inside
  the panel in both states; the area you can grab is unchanged.
- **Selecting a module broke its own outline in two places.** The rule under
  the title bar ran the full width of the frame and was painted after the
  border, so it printed the dim hairline colour over the bright selection
  border at each end. The rule now stops at the border's inner edge.

- **Nothing in a panel could be reached from the keyboard.** Every control Open
  Audio Analyzer paints itself — buttons, toggles, segmented controls, list
  rows, icon targets — was a bare gesture detector, so none of them took focus,
  none responded to Enter or Space, none drew a focus ring, and none was visible
  to a screen reader. Settings, presets and the delivery-target editor were
  mouse-only with nothing on screen to say so. All of them are now focusable,
  keyboard operable, and announced.

- **Opening the host picker a second time searched a browse that had already
  been shut down.** A tablet's search runs over one channel, and a channel keeps
  one subscription: opening a second picker while the first was still on screen
  — which happens for a frame every time one replaces another — ended the first
  one's browse, and the first one's teardown then ended the second's. The panel
  left on screen said "Looking for hosts on this network…" over nothing that was
  running, found no host however long it was left, and logged "No active stream
  to cancel" when it was closed. The search is now shared: one browse for the
  application, handed to whoever is looking, and stopped when the last of them
  closes.

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
- **Closing the host picker on a tablet while it was still searching threw.**
  Ending the Bonjour browse suspends on the channel, and the rest of the stop —
  which publishes an empty list of hosts — ran after the picker had already
  disposed the notifier it publishes to. It surfaced as "A
  ValueNotifier&lt;List&lt;DiscoveredHost&gt;&gt; was used after being disposed"
  in the log, most reliably on a hot restart. The search is now published as
  ended before anything is awaited, and teardown releases the browse without
  publishing at all.
- **A display leaving mid-frame threw in the host it was leaving.** Closing a
  socket that is still flushing a measurement is a `StateError` in Dart's own
  I/O — "StreamSink is bound to a stream" — and it was raised inside the
  socket's own close notification, where nothing could catch it. Every tablet
  that dropped off at the wrong moment logged what reads as a crash and left
  the connection it was there to give back.
- **Changing the skin, the layout or the delivery target could disconnect a
  display.** The new setting goes out the instant it changes, and a socket
  still flushing a measurement refuses to be written to — which the host could
  only read as "this display has gone", and act on. It was likelier the slower
  the display was. A setting now waits for the frame in front of it and then
  goes, in order.
- **Attaching to another machine flashed the host picker on the way in, and
  started a second search behind it.** The link said it was connecting one turn
  after it began, and a display shows the picker until it does — so a screen
  that had already been told where to attach spent a frame drawing a panel
  asking where to attach, and a picker searches the network as soon as it is
  built.
- **Closing the host picker while it was still opening its socket threw.**
  Binding is real I/O, and the search could be shut down while it was in
  flight: what came back then was written to a notifier that had been disposed,
  and the socket it arrived with was never closed. On macOS the window is as
  long as the Local Network prompt is on screen.
- **A panel row's explanation no longer runs into the control above it.** The
  caption sat two pixels under the row, and a row is as tall as whatever sits on
  its right — so under a bordered control it collided with the bottom edge
  rather than reading as a line of its own. The delivery target showed it worst:
  its note ended directly beneath the target menu and looked like part of it. It
  now clears the control, and still sits half as far from its own row as from
  the next one.
- The documentation site shows the current mark. Its header logo and favicon
  were a hand-copied version of the icon compiled into the site generator, so
  when the mark was redrawn they kept publishing the previous one on every
  page. The generator now reads `assets/brand/oaa-mark.svg` and fails when it
  is missing, so the site cannot hold a mark of its own again.
- The `oaa` CLI is published again. It was built with `dart compile exe`,
  which refuses a package whose dependencies have build hooks — `oaa_engine`
  has one — so no CLI reached a release at all. It is built with `dart build
  cli` now and ships as an archive of the executable and the engine beside it
  rather than as a single file; keep the two together. CI builds it the same
  way and runs the result, which nothing did before.
- The Windows package builds. Its manifest named the application
  `Open Audio Analyzer` where a package identifier is required, which the
  rename from Bel introduced and which fails validation with a line number and
  no mention of the name; the identifier is `Oaa` and the display name is
  unchanged.
- The Linux flatpak builds. Two things stopped it. Installing the runtime used
  a partial reference, which makes flatpak ask which of the matching ones is
  meant — a question `-y` does not answer and a CI runner cannot — so the job
  waited instead of failing. And the scalable icon was read through gdk-pixbuf
  by the AppStream step, which cannot decode an SVG unless librsvg has
  registered a loader; where it has not, a valid file is reported as an
  unrecognised format and the build fails with the package already assembled.
  The flatpak now ships the seven PNG sizes and no scalable icon, which is what
  a launcher uses either way.

### 🚧 Internal

- The install pages name the files a release actually publishes. Every
  installer is built as `Open Audio Analyzer-<version>-…` and GitHub replaces
  the spaces with periods when it attaches it, so the documented names — and
  the two shell commands printed for a reader to paste — matched nothing on the
  releases page. They are dot-separated now, and the difference is explained
  where it appears.
- Every identifier follows the name. The public C ABI is `oaa_*` and `OAA_*` in
  `engine/include/oaa/oaa.h`, the packages are `oaa_core`, `oaa_ui`,
  `oaa_engine` and `oaa_wire`, and the plugin's classes are `Oaa*`.
  `OAA_ABI_VERSION` stays at 4: the header's shape did not move, only its
  spelling.
- The release workflow reads `OAA_SIGNING_IDENTITY`, `OAA_NOTARY_PROFILE`,
  `OAA_WINDOWS_CERT`, `OAA_WINDOWS_CERT_PASS` and `OAA_WINDOWS_PUBLISHER`. The
  repository secrets have to be renamed to match, or every signed artefact
  quietly stops being signed.
- The repository, the documentation site and every download link moved to
  `open_audio_analyzer`.
- The cross-implementation wire golden is now `plugin/test/golden/wire_v2.bin`,
  regenerated from `oaa_wire_fixture`.
- The released sections below describe the application under its former name.
  They were renamed with the rest of the repository rather than left to
  contradict it; nothing else about them was rewritten.

- **Stopping the engine decides whether to join on the flag that tracks the
  thread.** It tested `should_run` — the flag stop itself clears — so anything
  that ever cleared it elsewhere would have turned destroying an engine into a
  free underneath a live analysis thread. It now tests whether a thread was
  started and not yet joined.
- **`PersistenceLayer` is gone, and with it the last `toImageSync` in the
  application.** `PointBuckets` replaces it: marks sorted by the colour they
  are drawn in, so a display of thirty thousand of them is a few dozen calls
  rather than thirty thousand. `test/history_modules_test.dart` fails if any of
  the three modules creates an image between frames again.
- **`packages/oaa_wire`** — the wire protocol, pure Dart and MIT, specified
  byte for byte in `docs/WIRE.md`. Three implementations speak it and none of
  them was written against another: the app's host, the app's display, and the
  plugin's C++ sender. `plugin/test/golden/wire_v2.bin` holds the Dart codec
  against bytes the C++ actually produced, which is the only test that would
  catch the two drifting apart — and the drift is silent, because every frame is
  a fixed length, so a field written into the wrong slot still parses.
- **`MeterSource`** — the interface a meter module reads a measurement out of,
  in `oaa_core`. `OaaEngine` implements it and so does the remote display's
  decoder, which is what lets the twelve modules run unchanged on a tablet with
  no engine in it. `oaa_engine` now depends on `oaa_core` for that one
  interface; the arrow still points away from `dart:ffi`.
- **`MeterClock` decides what is new by comparing generations** rather than by
  trusting what `refresh()` returned. With the remote host refreshing on its own
  timer there are two callers, and a one-shot "is this new" answer is consumed
  by whichever asks first — leaving the other to stop repainting, silently, only
  on the machines where somebody was using both screens at once.
- **`plugin/` is AGPL-3.0-or-later, not GPL-3.0.** JUCE 7 and 8 are
  AGPLv3-or-commercial; only JUCE 6 offered GPLv3, which is what the plan was
  written against. Open Audio Analyzer takes the AGPLv3 option, which changes
  the licence of the plugin binary alone: the engine stays MIT, and the app
  stays GPL-3.0-or-later because it never links JUCE — it talks to the plugin
  over a socket. GPLv3 section 13 expressly permits the combination. One piece
  of good news the plan did not anticipate: Steinberg has relicensed the VST3
  SDK to MIT, so JUCE is the only copyleft dependency and no separate SDK
  checkout is needed.
- `engine/CMakeLists.txt` builds `liboaa` as a static library for consumers that
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
  `oaa_device.c` is what stops miniaudio compiling its own bundled copies of
  the same three and colliding with them at link time — it was already
  load-bearing for measurement correctness and is now load-bearing for the
  build as well.
- MP3 is the last format tried when identifying a file, not the first. dr_mp3
  recognises a file by scanning for something that parses as a frame, and
  arbitrary binary data contains such sequences often enough that, given first
  refusal, it will open a FLAC file and decode noise from it.
- `OAA_ABI_VERSION` is 4. The change is additive — `oaa_snapshot` is byte for
  byte what it was at 3 — and adds only the `oaa_file_*` decoding calls.
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
  out only when a formatted string actually changes, and a buffer of marks
  sorted by the colour they are drawn in, which is how a display made of tens
  of thousands of them stays a few dozen draw calls.
- The accumulating modules advance on the engine's publish counter rather than
  on every paint, so a resize or a theme change cannot scroll a spectrogram
  through time that no audio passed through.
- The canvas placement rules — overlap, clamping, id allocation — are pure
  functions over `TabSpec` in `oaa_core`, so they are covered by tests that need
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
- `.github/workflows/ci.yml` now runs `dart test packages/oaa_wire` and
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
- The project has a logo, in `assets/brand/`: the icon's four bars with the
  tile taken away, and the name set beside them over two lines. It is the same
  mark as the application icon rather than a second one, and the wordmark is
  Inter SemiBold converted to outlines so the file needs no font installed.
  Three files — the lockup for dark backgrounds, the lockup for light ones, and
  the mark on its own. Nothing bundles them; they are for the README, the site
  and anywhere else the project is shown.
- `make_icons.dart` draws the mark in three shapes rather than one, because the
  desktops, iOS and Android each mask it differently, and writes iOS without an
  alpha channel — an icon that has one is refused by the App Store on upload
  rather than at build time.
- The canvas's refusal toast is a provider rather than private widget state, so
  the shortcut layer above the canvas reports "no room for that" through the
  same channel a refused drop does instead of growing a second one.
- The README leads with the application icon, a badge row, a table of contents
  and the documentation site, and it now enumerates the thirteen modules and
  what each one shows — a count it stated and never listed. Presentation only:
  nothing it says about what Open Audio Analyzer measures changed.

## [0.1.0] — 2026-08-15

First release. The architecture is proven end to end and the app runs; most
meters do not exist yet. See the [roadmap](README.md#roadmap).

### 📐 Measurement

- Peak, peak max, RMS, crest factor, inter-channel correlation and stereo
  balance are measured. Peak uses a 1.5 s hold and a 20 dB/s fall; RMS is
  smoothed with a 300 ms time constant.
- **Every loudness quantity is unmeasured and reads as a dash** — LUFS-M,
  LUFS-S, LUFS-I, LRA, true peak, TP max, DR-S, DR-I, PLR and PSR. They are
  `NaN` behind `OAA_FLAG_LOUDNESS_UNAVAILABLE`, never a zero that looks like a
  reading. K-weighting, R128 gating, LRA and true-peak oversampling arrive in
  the same release as the EBU conformance vectors that prove them.
- Open Audio Analyzer does not implement Decibel's proprietary `TrueDyn` and
  will not approximate it. `DR-S` and `DR-I` are defined in
  [docs/METRICS.md](docs/METRICS.md) instead, reproducibly.
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
- Licensing is split: MIT for `engine/`, `oaa_engine` and `oaa_core`;
  GPL-3.0-or-later for the application, UI, CLI and plugin.

[unreleased]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/5f8ef44...v0.2.0
[0.1.0]: https://github.com/JonasGrunau/open_audio_analyzer/commit/5f8ef44
