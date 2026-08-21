# plugin/host/ — the fake DAW

## What this is

A plugin host. It plays an audio file through Open Audio Analyzer's VST3 or
Audio Unit, hands it a transport once per block, and either shows you the
controls or renders offline for a test.

It exists because the plugin's playhead handling could not be exercised. Look at
`OaaPluginProcessor::captureTransport`: fourteen separately-optional values, a
presence bit each, a frame-rate table with an "unknown" code, and a
discontinuity test with a half-block tolerance. All of it was written against
`docs/WIRE.md` and the JUCE documentation, and none of it had ever run — the
only host that could reach it was a real DAW, driven by a person, and a person
does not remember to loop a bar to see whether a relocate is noticed.

**Nothing here ships.** No installer contains it, no release attaches it, and it
is not in the licence table users read.

## Licensing

AGPL-3.0-or-later, like everything in `plugin/`, and for the same reason: it
links JUCE. It links no part of the plugin — it loads it through the format's
own entry point, exactly as a DAW does.

## Files

| File | Purpose |
|------|---------|
| `CMakeLists.txt` | One `juce_add_gui_app`, VST3 hosting on every platform and AU on macOS. Why it is on by default is in the header. |
| `src/FakeDawPlayHead.h` | The `AudioPlayHead` the plugin reads, and the two functions that turn seconds into bars. |
| `src/FakeDawEngine.h/.cpp` | file → transport → plugin → monitor, and the two drivers that run it. |
| `src/FakeDawOptions.h` | The command line. Every switch exists so something can be automated. |
| `src/FakeDawComponent.h/.cpp` | The window. Draws no meters, and must not start. |
| `src/FakeDawMain.cpp` | Both lifetimes: with a window, and headless. |

## Building and running

```sh
cmake -B plugin/build -S plugin -DCMAKE_BUILD_TYPE=Release
cmake --build plugin/build
```

The executable is `oaa-fake-daw`, under
`plugin/build/host/OaaFakeDaw_artefacts/Release/` — inside an `.app` bundle on
macOS. `-DOAA_BUILD_HOST=OFF` skips it.

```sh
open plugin/build/host/OaaFakeDaw_artefacts/Release/oaa-fake-daw.app
```

With no arguments it finds the VST3 in the build tree above itself, so the only
thing left to do is open a track and press Play (or space). `--help` lists the
rest.

Three of the switches exist because a person cannot perform the gesture on cue:

| | |
|---|---|
| `--no-playhead` | Withhold the transport: this host's `getPosition()` returns nothing. What the plugin then receives is a position parked at zero with no other value valid, because that is as close to "not saying" as VST3 gets — see the finding below. |
| `--parked` | Headless: render with the transport stopped, which is the state a session spends most of its time in. |
| `--relocate-at=<s>` | Headless: play, stop, park, jump to the start, play again — the gesture `docs/WIRE.md` names as the reason the discontinuity bit exists. |

`dart run tool/fetch_test_audio.dart` downloads music worth looking at — two
CC BY 3.0 tracks from Wikimedia Commons, chosen by measuring candidates with
`oaa`. The script's header records the figures and why they matter; the short
version is that a tone gives a correlation of exactly 1.00, one spectrum bin, an
LRA of zero and a true peak that never exceeds its sample peak, so it exercises
none of the modules that need real material.

## Rules

- **Start the app first.** The plugin streams to `127.0.0.1:47822` and the app
  listens there. Without it the plugin's status panel says "not connected",
  which is correct and is not a bug in this host.

- **There is no `--port`, and that is a decision.** A DAW passes a plugin its
  settings through `setStateInformation`, and it looks like the obvious way to
  aim the plugin at another listener. It does not work: JUCE's VST3 host wraps
  plugin state in an XML envelope of its own — base64 inside
  `<VST3PluginState><IComponent>` — so the plugin's raw `ValueTree` is
  *silently discarded*, and the Audio Unit host wraps state differently again.
  Writing those envelopes here would put a private copy of two of JUCE's
  internal formats in a test tool, where the failure mode is a plugin connecting
  to the wrong port without saying so. The plugin's own editor has host and port
  fields, and this host puts that editor in a window.

- **An Audio Unit cannot be loaded from the build tree.** macOS serves
  components from a registry populated by scanning the plug-in folders, so
  `AudioComponentFindNext` cannot see a bundle that is not in one — no matter
  what path it is handed. It presents as "the file is right there and the host
  says it does not exist". Install it once, then use **Find installed**:

  ```sh
  mkdir -p ~/Library/Audio/Plug-Ins/Components
  ln -sfn "$PWD/plugin/build/OaaPlugin_artefacts/Release/AU/Open Audio Analyzer.component" \
    ~/Library/Audio/Plug-Ins/Components/
  ```

  A symlink keeps pointing at whatever the last build produced. The VST3 needs
  none of this. `plugin/CMakeLists.txt` deliberately refuses to install
  anything itself — see `COPY_PLUGIN_AFTER_BUILD` there for why.

- **The two drivers must stay one render function.** `renderBlock` is called by
  the audio device and by a loop on a background thread. If they ever diverge,
  the thing CI exercises and the thing you listen to are different code, and the
  difference is where the bug will be.

- **An offline run reads the file synchronously, and a device run reads ahead.**
  `prepare` gives the transport a `BufferingAudioSource` and a read-ahead thread
  only when a device is driving it. Offline there is no deadline, so the buffer
  buys nothing — and it costs the one property a test host has to have. When the
  read-ahead thread falls behind, `BufferingAudioSource` hands out silence and
  the position `AudioTransportSource` reports **stops advancing**, so this host
  claims to be playing while its playhead sits still. That is a genuine
  discontinuity as far as any plugin can tell, and Open Audio Analyzer's raises
  the relocate flag on every stalled block — correctly. A host whose timeline
  depends on whether a background thread was scheduled cannot be used to test
  anybody's playhead handling. See **What it found**.

- **Nothing that the render path can see is mutated without detaching the
  callback.** `AudioDeviceManager::removeAudioCallback` does not return while
  the callback is running, so on the far side of it there is provably nobody in
  `renderBlock` — which is why this host has no lock on the audio thread. A
  mutex in the tool whose job is to tell you whether the plugin's audio thread
  is well behaved would be a poor joke.

- **The audio thread cannot stop the transport.**
  `AudioTransportSource::stop` sleeps until the source acknowledges, and the
  source is us: calling it from `renderBlock` parks the audio thread for a
  second and then gives up without stopping anything. End of track is published
  as a flag and the message thread acts on it.

- **This window draws no meters and must not start.** It shows the peak of what
  it sent, and only so that "the plugin is not receiving audio" can be told
  apart from "the plugin is receiving audio and not reporting it" — the one
  thing the application cannot tell you. Everything else is the app's job. A
  second implementation of a measurement's presentation is the outcome the whole
  socket architecture exists to avoid.

## What it found

Six things, all of which had been unobservable. Five were defects in code that
had shipped, and all five are fixed. The last of them is in this directory
rather than in the plugin: the instrument was inventing the very thing it exists
to measure.

- **A parked transport was reported as a relocate, continuously.** *Fixed.*
  A stopped DAW still runs its graph and reports the position it sits at,
  unchanged, on every block. `captureTransport` compared that against a
  prediction of one block further on, which is a mismatch of exactly one block
  and clears the half-block tolerance — so `kDiscontinuity` was raised on every
  published frame for as long as the transport sat still: **140 frames out of
  140**. Nothing had relocated, and the audio was not discontinuous either.
  The continuity test is now only evaluated while the transport is rolling, and
  the prediction is carried *across* a stop rather than rebuilt from the parked
  position — which is what makes the case `docs/WIRE.md` names ("plays bars
  1–16, stops, drags back to bar 1, plays again") detectable at all.

- **A relocate usually never reached the app.** *Fixed.* The flag marks the one
  block on which the playhead jumped, and the streaming thread reads the
  transport once per published frame — every second block at a 512-frame buffer,
  one in sixteen at 64. So it was set on one publish and read from another:
  **three loop laps delivered it zero times out of 186 frames**. `TransportBox`
  now accumulates edge flags in an atomic outside the seqlock and hands them
  over once each, and `Streamer` clears them after a successful send. Measured
  after: exactly one flagged frame per lap, at 64, 128 and 512 frames.

  The consequence of missing it was the exact failure the flag exists to
  prevent: an integrated reading that silently spans two passes of the same
  music.

- **And then a relocate reached the app twice.** *Fixed.* The sequel to the one
  above, on the same bit, and it was half-hidden by the fix for it: the
  accumulator that stopped edges being *missed* left them in the sampled payload
  as well. `publish` stored the block's flags verbatim, so `read` could find
  `kDiscontinuity` sitting in a payload whose edge it had already handed over.
  The streaming thread normally publishes less often than the audio thread does,
  so a jump block is sampled once and the duplicate never appears — but on a
  **loaded** machine the two rates cross, two frames leave inside one audio
  block, and one relocate arrives as two. Measured: **a three-lap loop reported
  four flagged frames**, and `docs/WIRE.md` lets a consumer count relocations by
  counting them.

  Found on the first manual dispatch after this directory landed, on the macOS
  runner — the plugin job runs only on a release or a manual run, so that was
  the first time these cases had ever executed there — and reproduced locally at
  about one run in six with every core busy, which is the only reason it could
  be diagnosed rather than argued about. The payload now carries state only;
  `sticky_` is the one place an edge lives.
  `../test/transport_box_test.cpp` reduces the whole thing to two reads with no
  publish in between, which is the loaded runner with the timing taken out.

- **And this host was fabricating relocates all by itself.** *Fixed, here.* The
  same two macOS failures survived the fix above, with different numbers: the
  second flagged frame had moved a whole second away from the first. A second is
  `kReadAheadFrames`.

  An offline run was still handing the transport a `BufferingAudioSource` and a
  read-ahead thread. When that thread falls behind — a slow, virtualised, cold
  runner, a second after a seek emptied the buffer — the source returns silence
  and `AudioTransportSource::getCurrentPosition` stops advancing. This host then
  reports a playhead that sits still while `isPlaying` is true, which is a
  discontinuity by any definition, and the plugin flagged it. **The plugin was
  right every time.** The instrument was wrong.

  Confirmed rather than argued: shrinking `kReadAheadFrames` to 1024 freezes the
  playhead at one position for *dozens* of consecutive frames and flags every one
  of them, on this machine, every run. With the read-ahead removed from the
  offline path the same experiment at 16 frames produces exactly one flagged
  frame, because the constant is no longer reachable from a run without a
  device.

  Two lessons, and the second is the uncomfortable one. A test host's timeline
  must not depend on the scheduler. And a suite that had been green on three
  platforms for a day was measuring a tool that invented the thing it was
  measuring — on any machine slow enough, which was never this one.

- **The producer name reached the app as mojibake.** *Fixed.* This one needed
  the fake DAW and the application running as a pair, which is a check neither
  test suite can be: the e2e drives a socket with no app on the far end, and the
  app's own ingest test replays bytes from a golden file. Run together, the
  application's title bar read `Open Audio Analyzer plugin â<80><94>`.

  `Streamer::ensureConnected` built the HELLO frame's name with
  `juce::String`'s `const char*` constructor, which reads one byte per
  codepoint, so an em dash went on the wire as six bytes instead of three. The
  consumer was innocent — it decoded faithfully, which is what made the fault
  visible at all. `docs/WIRE.md` specifies that field as UTF-8, so it was a
  protocol defect rather than a typographical one. See the `juce::String` rule
  in `../AGENTS.md`.

- **The plugin's "host supplies no position" branch is unreachable from here,
  and from any DAW.** *Not a defect in either end.* `--no-playhead` makes this
  host's `getPosition()` return nothing, and no plugin format can carry that.
  JUCE's VST3 host maps it — and a host holding no playhead at all, which is the
  same bytes — onto a zeroed `ProcessContext` with a valid sample rate and no
  validity flags; the plugin's own VST3 wrapper then reads `timeInSamples` and
  `timeInSeconds` back out of it unconditionally, because the format has no bit
  for "not saying". So the plugin sees a host *parked at zero with nothing else
  valid* rather than a host that is not saying, and reporting that is the
  correct reading of what arrived. The Audio Unit wrapper scopes a playhead
  around every render and answers unconditionally too, so it says no more.

  What this means for the fake DAW is worth stating plainly: **it cannot reach
  `captureTransport`'s two empty-transport guards, and neither can a DAW.** They
  are covered instead by `plugin/test/transport_capture_test.cpp`, which hosts
  the processor as the C++ object it is, with no format wrapper in the way —
  `ctest -R transport_capture`, in the same gated run as everything else here.
  Until that test existed this was written down as a known gap in `README.md`,
  along with a claim that the Standalone build reached the branch: it does not,
  because JUCE 8's `AudioProcessorPlayer` installs a counting playhead whenever
  the processor it is given has none.

  Writing the test found something the branch had been hiding: the plugin's own
  status panel drew "no playhead from host" from whether a transport had *ever*
  been published, so it stopped saying it as soon as audio flowed — on the one
  host it was there to describe. Fixed in `TransportBox`, and held by the
  framework-free test beside it.

The two transport defects are held by
`packages/oaa_wire/test/plugin_e2e_test.dart`, which asserts one flagged frame
per observed lap rather than a constant: the flag marks a relocate, so a flagged
frame and a lap are the same event counted two ways.

The third is not held by anything, and that is worth saying plainly. No
automated check in this repository renders the application's chrome and reads
it, so a string arriving mangled is caught by a person looking at a window. That
is the argument for **running the pair by hand after touching either end** —
`open` the app, then `open` the fake DAW — rather than trusting a green suite.

## The automated end to end

`packages/oaa_wire/test/plugin_e2e_test.dart` spawns this host with
`--headless`, listens on 47822, and decodes what arrives with the Dart half of
the protocol. It is the only test that covers `prepareToPlay`, the FIFO, the
playhead, the engine, the streaming thread and the socket at once —
`plugin_golden_test.dart` covers the codec against bytes on disk and nothing
else.

It generates its own audio rather than using the download: a CI runner fetching
35 MB of music from somebody else's CDN to prove that a socket carries frames is a
gate that fails for reasons unrelated to this repository. `OAA_TEST_TRACK` runs
the same cases against a real file.

A second suite spawns it: `test/plugin_to_display_e2e_test.dart`, in the
application, which carries the same run one hop further. It accepts the plugin
on 47822 with the app's own `PluginLink`, hands the session's snapshot to the
app's own `DisplayHost`, attaches a `DisplayClient` — a tablet, in every respect
that is code — and asserts that what the display shows is what the app
got from the plugin: twenty-nine readings field by field, and the playhead — the
tempo, the meter and the timecode this host was told to report. Neither half's
suite could see that join: what a display receives is a *re-encode* of a snapshot
the app decoded, so a field dropped in the middle leaves both halves green and
the tablet showing a dash. That is not hypothetical — the transport was the field
dropped in the middle, for as long as the display existed.

Both need port 47822, so **the application cannot be running while they do**,
and neither can run at the same time as the other. Both skip with that
explanation rather than failing on a bind error.

```sh
dart test packages/oaa_wire                     # skips the e2e cases without a build
flutter test test/plugin_to_display_e2e_test.dart   # skips without one too
```

`ci.yml`'s `plugin` job runs the first, which means on a release or a manual
dispatch — so **run both by hand after touching `plugin/` or this directory**.
