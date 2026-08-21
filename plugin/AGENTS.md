# plugin/ — the headless VST3 and Audio Unit

## What this is

A metering plugin that draws nothing. It takes the DAW's buffer, pushes it into
`liboaa`, and streams the resulting snapshot and the host's transport position
to the Open Audio Analyzer desktop app over a TCP socket. The app draws.

That division is not a limitation being worked around. Flutter cannot be a
plugin GUI, and the alternative — reimplementing thirteen meter modules in C++ so
the plugin could draw them itself — would give this project two implementations
of every measurement's *presentation*, which would drift, and one of them would
be wrong in a way nobody noticed for months.

## Licensing — read this before adding a dependency

**This directory is AGPL-3.0-or-later. The rest of the repository is not.**

JUCE 7 and 8 are AGPLv3-or-commercial (JUCE 6 was GPLv3; `docs/PLAN.md` was
written against the older terms and is out of date on this point). Open Audio
Analyzer takes the AGPLv3 option, so anything linked into the plugin binary is
AGPL.

| | |
|---|---|
| `engine/` | MIT. The plugin links it; MIT flows in without obligation. |
| `lib/` (the app) | GPL-3.0-or-later. **Never links JUCE** — it talks to this plugin over a socket, which is not linking. |
| `plugin/` | AGPL-3.0-or-later, because it combines with JUCE. |
| VST3 SDK | MIT. Steinberg relicensed it; JUCE vendors it. No second copyleft dependency. |

GPLv3 §13 expressly permits combining a GPLv3 work with AGPLv3 code, and the
app being GPL-3.0-**or-later** is what makes that clean rather than merely
arguable.

The practical consequence of AGPL over GPL is its network clause, and since Open
Audio Analyzer publishes all its source anyway, that clause asks for nothing
new. But it does mean **nothing in `plugin/` may be moved into `engine/` or
`oaa_core/`** without rewriting it, because those are MIT and must stay linkable
by people who are not writing free software.

## Files

| File | Purpose |
|------|---------|
| `CMakeLists.txt` | JUCE, `liboaa`, and the three formats. The pinned JUCE tag is one line; bumping it is a decision. |
| `src/OaaWire.h/.cpp` | The wire protocol, producer side. No JUCE include — deliberately, so it is testable without a framework. |
| `src/OaaTransportBox.h` | Seqlock handing one transport reading from the audio thread to the streaming thread. |
| `src/OaaStreamer.h/.cpp` | Owns the engine. Drains the FIFO, measures, serialises, sends, reconnects. |
| `src/OaaPluginProcessor.h/.cpp` | The `AudioProcessor`. Real-time path and playhead capture. |
| `src/OaaPluginEditor.h/.cpp` | A status panel. Not a meter, and must not become one. |
| `test/wire_fixture.cpp` | Writes the golden the Dart codec is held against. |
| `host/` | The fake DAW: a host that plays a file through this plugin and gives it a transport. Its own `AGENTS.md`. Nothing there ships. |

## Working in here

- **`processBlock` allocates nothing, locks nothing, and calls no syscall.**
  It copies channel-wise into a `juce::AbstractFifo`, publishes the transport
  through a seqlock, and returns. Everything else — the FFT, the true-peak
  oversampling, the socket write — is on the streaming thread. `oaa_engine_push`
  runs the entire DSP graph synchronously and must never be called from the
  audio thread: it works fine at a 512-frame buffer on the machine you are
  testing on and produces dropouts at 64 frames in somebody else's session.

- **The buffer leaves `processBlock` bit-identical.** A metering insert that
  alters the signal changes the thing it is reporting on.

- **The plugin has no `AudioProcessorParameter`s, and this is deliberate.**
  Parameters are automatable and get written into the session: a "reset"
  parameter would be recorded and re-fire on playback, silently clearing an
  integrated measurement mid-pass. Connection settings live in
  `getStateInformation` instead, which no host will ever automate.

- **`juce::String("…")` mangles a non-ASCII literal; `juce::String::fromUTF8("…")`
  does not.** The `const char*` constructor reads its argument through
  `CharPointer_ASCII` — one byte, one codepoint — while `operator+=` on the same
  type reads UTF-8. So appending a literal with an em dash in it is correct and
  constructing from one is not, which is a difference nothing in the code makes
  visible. JUCE asserts on bytes above 127 in that constructor, and the plugin
  is built with NDEBUG, so the check is compiled out of every build anybody
  runs. It reached a user: the HELLO frame's producer name arrived at the app as
  `Open Audio Analyzer plugin â<80><94>`, and `docs/WIRE.md` says that field is
  UTF-8, so it was a protocol defect rather than a typographical one.

  What made it *visible* was the consumer decoding those bytes faithfully rather
  than refusing them — see the note on `allowMalformed` in
  `packages/oaa_wire/lib/src/hello.dart`. A decoder hardened to reject the frame
  would have hidden this for as long as nobody read the bytes.

- **`docs/WIRE.md` is the protocol's specification; this is one implementation.**
  The Dart implementation in `packages/oaa_wire/` is another, written against
  the same page without having seen this code. If they disagree, the document is
  right. Never fix a mismatch by editing only one side.

- **Only the public C ABI.** `oaa.h` says that what is not declared there is not
  part of the engine, and that applies here even though `engine/src` is two
  directories away. There is a perfectly good SPSC ring in `oaa_ring.h`; the
  plugin uses `juce::AbstractFifo` instead precisely so that it is not reaching
  into engine internals.

- **A missing transport value is not zero.** JUCE's `PositionInfo` getters each
  return an `Optional` and hosts differ enormously in which they fill in. Every
  field has a presence bit; a bit clear means the display shows an em dash.
  "Bar 1, beat 1, 00:00:00:00" is a plausible-looking readout to show somebody
  while the host is parked at bar 57.

  **Drive it with `host/` rather than reasoning about it.** The fake DAW can be
  told to withhold the transport, to report a frame rate the wire has no code
  for, to loop a one-second region, to sit parked, and to play-stop-relocate-play
  on cue. Running those the first time found two defects in `captureTransport`
  and the streaming thread that had shipped — see **What it found** in
  `host/AGENTS.md`. The lesson is the one in that file: the transport path is
  cheap to reason about wrongly and cheap to measure.

- **NaN and −∞ go on the wire unchanged.** NaN means nobody measured it, −∞
  means digital silence. Both have bit patterns a careless serialiser normalises
  — NaN through arithmetic, −∞ through a clamp — and both are asserted in the
  golden test for that reason.

- **Adding a file to `engine/src` means adding it in two places**, here in
  `engine/CMakeLists.txt` and in `packages/oaa_engine/hook/build.dart`. There
  are two build descriptions because a plugin CI runner has no Flutter SDK.
  `test/sources_match.sh` fails the build if they drift.

## Building and testing

```sh
cmake -B plugin/build -S plugin -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build plugin/build
ctest --test-dir plugin/build --output-on-failure
```

That also builds `host/`, the fake DAW, and `dart test packages/oaa_wire` then
drives the whole path through it — file, plugin, socket, decoder — with no
window and no sound card. Between releases nothing else does; see
`host/AGENTS.md`.

`ci.yml`'s `plugin` job runs exactly that on Linux, macOS and Windows — VST3 on
all three, AU where JUCE builds one — **on a tag or a manual run, not on every
push**, because three parallel JUCE builds is the most expensive thing in that
workflow by an order of magnitude. The release attaches the bundles as one
archive per platform. They are not inside the desktop installers yet.

It is the only thing in CI that compiles this directory: `test/sources_match.sh`
compares two text files and never invokes CMake. So **run the block above by
hand before pushing anything in here** — between releases nothing else will
tell you that this directory still builds, and nothing else runs the `ctest`
below, which is the producing half of the wire golden.

Products land in `plugin/build/OaaPlugin_artefacts/Release/`. Nothing is
installed into a system plugin folder: a build that silently writes into
`~/Library/Audio/Plug-Ins` means the DAW you have open is now running a binary
you did not knowingly install, which is a genuinely bad surprise while iterating
on the audio thread.

JUCE is fetched, not vendored. A checkout at `third_party/JUCE` is used if
present; otherwise CMake clones the pinned tag. Either way it is gitignored.

The Dart half of the protocol test is
`packages/oaa_wire/test/plugin_golden_test.dart`, and the app-side ingest is
covered by `test/plugin_link_test.dart`. Both read the same golden this
directory generates, which is what makes them a cross-implementation check
rather than each end agreeing with itself.
