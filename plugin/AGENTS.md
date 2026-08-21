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
| `src/OaaTransportBox.h` | Seqlock handing one transport reading from the audio thread to the streaming thread, and the edge accumulator beside it — the only place a one-block flag may live. |
| `src/OaaStreamer.h/.cpp` | Owns the engine. Drains the FIFO, measures, serialises, sends, reconnects. |
| `src/OaaPluginProcessor.h/.cpp` | The `AudioProcessor`. Real-time path and playhead capture. |
| `src/OaaPluginEditor.h/.cpp` | A status panel. Not a meter, and must not become one. |
| `test/wire_fixture.cpp` | Writes `test/golden/wire_v3.bin`, the golden the Dart codec is held against. `wire_v2.bin` beside it is frozen and is not regenerated. |
| `test/transport_box_test.cpp` | That an edge is delivered exactly once, and that only a host which says something is reported as saying it. No DAW, no socket, no thread, no JUCE. |
| `test/transport_capture_test.cpp` | That a host which says nothing has nothing invented for it. Hosts the `AudioProcessor` directly, because no plugin format can express either half of it. Needs JUCE. |
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
  and the streaming thread that had shipped, running the host beside the
  application found a third, and running them on a *loaded* CI runner found a
  fourth — see **What it found** in `host/AGENTS.md`. The lesson is the one in
  that file: the transport path is cheap to reason about wrongly and cheap to
  measure.

- **An edge lives in exactly one place, and it is never the payload.**
  `kDiscontinuity` describes a single audio block rather than a state, so
  `TransportBox` keeps it in the `sticky_` accumulator, which is *claimed* by a
  reader, and strips it out of the seqlock payload, which is *sampled*. Both
  halves have failed in production and in opposite directions: with no
  accumulator, three loop laps delivered the flag zero times in 186 frames;
  with the flag also left in the payload, a jump block sampled twice delivered
  one relocate as two, and a three-lap loop reported four. The second only
  appears on a machine loaded enough that the streaming thread gets two turns
  inside one audio block, which is why it reached CI and not a desk.

  The test for it is deterministic and does not involve a DAW at all:
  `test/transport_box_test.cpp` publishes a jump, reads twice, and requires the
  second read to be clean. Anything else added to `kStickyFlags` inherits both
  rules — accumulate it, and keep it out of the payload.

- **A host that says nothing must have nothing invented for it, and only a test
  can show that.** `captureTransport` answers two questions before reading a
  value — is there a playhead, and does it have a position — and a "no" to
  either publishes an empty transport, which is what puts dashes on screen
  instead of bar 1 at 120 bpm. **Neither answer can be produced through VST3 or
  an Audio Unit.** JUCE's VST3 host turns both into the same zeroed
  `ProcessContext` with a valid sample rate and no validity flags, and the
  plugin's own wrapper reads a position back out of it unconditionally; the AU
  wrapper scopes a playhead around every render. A plugin loaded as either
  format is therefore told *parked at zero, nothing else valid* where the host
  said nothing at all — the right reading of what the format delivered, and not
  these branches.

  So they were written against the specification and never run, and `README.md`
  carried that as a known gap. `test/transport_capture_test.cpp` closes it by
  hosting the processor as the C++ object it is and asserting on the transport it
  published, with a third playhead that *does* answer so that "the struct is
  empty" cannot pass by the processor having stopped publishing. It links
  `OaaPlugin` rather than recompiling these sources, so what it drives is the
  objects the shipping bundle contains.

  **The second half of the same problem was in the box.** `hostReportsPosition()`
  is what the editor's "no playhead from host" line is drawn from, and it used to
  mean *has anything ever been published* — which, since every block publishes,
  became true the moment audio started flowing, on exactly the host the line
  exists to report. It now reports whether the most recent publication carried
  any state flag, sticky bits masked out, so an edge is not mistaken for a
  position and a host that stops reporting stops being claimed.

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

It is the only thing in CI that compiles the *plugin*. Every push does now
configure this directory with `-DOAA_BUILD_PLUGIN=OFF` — no JUCE, no fetch, no
framework compile — and run the part of `ctest` that needs none: the transport
box's tests, the wire fixture against the golden, and the source lists. Five
seconds.

The remaining `ctest` case is only defined when there *is* a framework, because
it hosts an `AudioProcessor`: `transport_capture_invents_nothing`, which is the
one thing about this plugin that neither a DAW nor the fake DAW can demonstrate.
See the bullet below.

So **run the block above by hand before pushing anything that touches JUCE** —
the plugin target, the formats, `host/`. Between releases nothing else will tell
you that *those* still build, and nothing else drives the plugin end to end.

Products land in `plugin/build/OaaPlugin_artefacts/Release/`. Nothing is
installed into a system plugin folder: a build that silently writes into
`~/Library/Audio/Plug-Ins` means the DAW you have open is now running a binary
you did not knowingly install, which is a genuinely bad surprise while iterating
on the audio thread.

JUCE is fetched, not vendored. A checkout at `third_party/JUCE` is used if
present; otherwise CMake clones the pinned tag. Either way it is gitignored.

**Anything that writes into a macOS bundle must run before the signing step, and
the signing step is last on purpose.** Every bundle this directory produced up
to 0.4.0 shipped with an invalid code signature and nothing said so. Two causes:
JUCE ad-hoc signs the VST3 mid-post-build — it has to, because `vst3_helper`
then *loads* the bundle — and writes `Contents/Resources/moduleinfo.json`
afterwards, so the resource seal never covered what shipped; and
`checkBundleSigning.cmake` runs for the VST3 only, so the AU and the Standalone
carried nothing but the linker's Mach-O signature, whose CodeDirectory promises a
resource seal that no `_CodeSignature` directory exists to satisfy. On Apple
Silicon that is what `auval` rejects an Audio Unit for and what makes a plugin
absent from a DAW's browser with nothing logged. `plugin/CMakeLists.txt` now
signs each bundle from an `OaaPlugin_<format>_signed` target that *depends* on
the format target, and runs `codesign --verify --strict` on the line after —
**that verify is the gate, not a ctest**, because a test can only run after a
build that has already succeeded at producing the broken bundle.

**A target, not `POST_BUILD`.** The first attempt used `POST_BUILD`, which is
after everything JUCE does, and the Standalone still failed — but only once the
bundle was deleted first, because a `MACOSX_PACKAGE_LOCATION` source
(`RecentFilesMenuTemplate.nib`) is copied by its own rule, a *sibling* of the
link rule rather than something the link rule contains, so make is free to run
it after the link's POST_BUILD and on a from-scratch build it does. A
target-level dependency is the only ordering CMake guarantees across the whole
of a target. **Delete `OaaPlugin_artefacts/Release/` and rebuild before
believing a signing change** — an incremental build hides this entire class of
failure, because the file that invalidates the seal is already there when the
seal is computed.

One consequence: `cmake --build . --target OaaPlugin_VST3` produces an unsigned
bundle, since the signing target is a different one. `cmake --build <dir>` —
the documented command, and what CI runs — builds `all` and signs.

Signing is ad-hoc (`OAA_CODESIGN_IDENTITY`, default `-`). A copy extracted from a
downloaded archive additionally carries `com.apple.quarantine`, which no build
can remove; `README.md`'s **In a DAW** tells a user to strip it.

The Dart half of the protocol test is
`packages/oaa_wire/test/plugin_golden_test.dart`, and the app-side ingest is
covered by `test/plugin_link_test.dart`. Both read the same golden this
directory generates, which is what makes them a cross-implementation check
rather than each end agreeing with itself.
