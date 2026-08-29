# engine/

The C11 measurement core. **GPL-3.0-or-later**, and it must stay independently
usable — this is the part of the project with value outside the app. Independent
of the app, not of the licence: embedding it obliges you to the same terms.

Three consumers link against it: the Flutter app (through `dart:ffi`), the `oaa`
CLI, and the headless VST3/AU plugin. None of them may know about the others,
and none of their concerns may leak in here. In particular there is **no Dart, no Flutter,
no UI vocabulary and no file I/O outside `oaa_decode.c`**.

| Path | Contents |
|------|----------|
| `include/oaa/oaa.h` | The entire public ABI. One header. If it is not here, it is not part of the engine. |
| `src/` | Implementation (see `src/AGENTS.md`). |
| `third_party/` | Vendored permissive C libraries: `miniaudio` (capture), `pffft` (FFT), `dr_libs` (file decoding). |
| `CMakeLists.txt` | `liboaa` as a static library, for consumers that are not Dart — the plugin, and a CI runner with no Flutter SDK. |

**There is no `test/` here, deliberately.** The engine is tested through FFI
from `packages/oaa_engine/test/` — the arithmetic cases, the EBU Tech 3341/3342
conformance suite, the spectrum against a known sine, and the assertion that
decoding a file does not change a reading. One suite that CI already runs on
three platforms beats two suites where the second is the one nobody runs
locally. A C-only test would need `ctest` in the loop to prove anything the
Dart suite does not already prove.

**A new source goes in two places** — `CMakeLists.txt` and
`packages/oaa_engine/hook/build.dart`. Sources are listed rather than globbed so
that adding one is a decision somebody made. `plugin/test/sources_match.sh`
fails the build when the two lists disagree, and it reads `.m` as well as `.c`
because the one source that is not built everywhere is the one most likely to
reach a single list.

## Rules

- **The engine has exactly one notion of a LUFS time mode, and it is not a
  mode.** `oaa_engine_set_silence_reset` restarts the integrating measurements
  when signal returns after a silence, which is what the app calls System. The
  other three modes are decided above the engine — Continuous is the absence of
  a rule, and Elapsed and Timecode are the *producer declining to push*, which
  needs no API here at all. That asymmetry is deliberate and it is what keeps
  the rule below true: a playhead field, or a "set the mode" call taking a
  transport, is the moment `engine/` learns what a DAW is, and it does not get
  to. See `docs/WIRE.md` `0x0020`.

- **Bump `OAA_ABI_VERSION`** whenever the header changes shape, then regenerate
  the Dart bindings. The Dart side asserts it at startup, because a stale
  library does not crash — it reads a reordered struct and shows plausible wrong
  numbers, which is the worst failure a measurement tool has.
- **`scope` is a window of four blocks, not the block just measured.** A
  snapshot is a seqlock with one slot and its readers run at the display's
  rate, so a publish nobody read before the next is gone — at 96 kHz that is
  one in three, and an engine catching up after a stall publishes back to
  back. A one-block scope handed every such reader the second block and lost
  the first, which the oscilloscope drew as silence. `OAA_SCOPE_FRAMES` holds
  four so the missed block is still there; `scope_frames` counts what is
  audio, packed from index 0, and a reader takes the newest pairs that
  `elapsed_seconds` says it is owed. `OAA_SCOPE_POINTS` is still one block —
  the most a push adds, and what a plugin sends per frame.
- **Only `oaa_engine_create` allocates.** Nothing on the analysis path calls
  `malloc`, and nothing at all on the audio path does.
- **Everything exported is prefixed `oaa_`.** Two file-static globals exist and
  no more, both of them lists of things this *process* owns rather than state
  any measurement reads: the live engines that `oaa_engine_reset_all` reclaims
  (`oaa_engine.c`) and the aggregate devices a tap built, which enumeration has
  to leave out (`oaa_tap_macos.m`). Each is guarded by a mutex, and neither is
  touched by the analysis thread or an audio callback. Anything on the
  measurement path stays reachable through the handle.
- **The tap's aggregate device is not a capture device, and enumeration says
  so.** A process tap is read through a private aggregate, and private means
  private to every process but the one that made it — which is the process
  drawing the source menu. miniaudio enumerates it as an ordinary input, so
  every running tap offered the user "Open Audio Analyzer System Capture"
  underneath the System Output entry that had built it. `oaa_tap_owns_device_uid`
  is what `oaa_devices_enumerate` asks; it compares UIDs, because the name is a
  string we chose and a user may have chosen it too.
- **Nothing here is freed when a process outlives the code that owns it, so
  `oaa_engine_reset_all` exists.** A Flutter hot restart discards the Dart
  isolate and re-runs `main` in the same process: no `dispose`, no finalizer,
  and this library plus every thread it started carries on. The orphaned engine
  meters forever and keeps a Core Audio tap alive with it. The call is for an
  entry point and nowhere else — it dangles every handle its caller holds, which
  is harmless only because a fresh isolate holds none.
- **The snapshot is plain old data.** No pointers, no bitfields, no `bool`,
  fixed-size arrays only, widest members first, new fields appended. `dart:ffi`
  reproduces this struct byte for byte.
- **No measurement is invented.** A quantity this build does not compute is
  `NaN` with a `OAA_FLAG_*_UNAVAILABLE` flag set — never a zero that looks like
  a reading.
- **The spectrum is five band sets from one pass, and a set a source cannot
  make is NaN per band, not the floor.** `spectrum` is the loudest bin across
  every channel; `spectrum_left` and siblings are the front pair's left, right,
  mid and side, appended in ABI 6 with a peak hold each and read through
  `oaa_snapshot_spectrum_of`. A one-channel engine has a left and nothing else,
  and its right, mid and side read NaN throughout: the floor is silence, which
  is a measurement, and these are the absence of one. The flag stays one flag
  because the five sets come from one analysis pass and are unavailable
  together; what differs per source is said per band.

- **A source that has stopped producing is a state, not a silence.** The
  analysis thread paces itself against a monotonic clock, so an empty ring
  changes nothing about how often it publishes: every meter holds its last
  reading, `generation` keeps incrementing, and a consumer has no way to tell a
  device that is delivering digital silence from a device that has gone. It
  stood that way for eight phases and presented as an application that freezes
  and can only be revived by choosing a different source. `oaa_device_running`
  is asked four times a second, `OAA_FLAG_SOURCE_STOPPED` carries the answer,
  and `oaa_device_revive` puts back what can be put back at the same format.

  **Ask the source about itself; never time its output.** "No frames for a
  second" is a perfectly healthy state for real devices — a macOS output device
  with nothing playing through it has an idle clock and its tap receives
  *nothing at all*, which is measured and pinned by a test in
  `packages/oaa_engine/test/oaa_engine_test.dart`. A watchdog built on a timeout
  would rebuild a healthy Core Audio aggregate four times a second on a quiet
  machine and charge every rebuild to `dropped_frames` as lost audio, which is a
  worse bug than the one being fixed.

  **A format that moved is also a source that has stopped.** It is not enough
  for the producer to be delivering; it has to be delivering what the engine was
  built for. A Bluetooth output device changes its own sample rate without ever
  ceasing to be the default output, and the tap went on delivering 24 kHz audio
  into a graph whose filters, oversampler and spectrum axis were all built for
  48 kHz — every number wrong by an octave, meters moving convincingly, elapsed
  time running at half speed. Nothing downstream can adopt a new rate, so
  reporting it stopped and letting the consumer open a new engine is the only
  honest answer.

  **Reproducing one takes a script, not a unit test.** The suite cannot
  reconfigure the machine's audio. What works is a small Swift program over
  `AudioObjectSetPropertyData` — `kAudioHardwarePropertyDefaultOutputDevice` to
  move the default output, `kAudioDevicePropertyNominalSampleRate` to move a
  rate — with something playing a silent file so the output device's clock stays
  alive, and a test that prints `elapsedSeconds` and the flag twice a second.
  **Do not set a rate on a device this engine currently taps**: doing so wedged
  the whole HAL for every process on the machine, and only `sudo killall
  coreaudiod` cleared it. Move the *default output* between devices at different
  rates instead, which reproduces the same failure and unwinds cleanly.
