# tool/

Repository scripts. Nothing here ships. GPL-3.0-or-later.

| File | Purpose |
|------|---------|
| `bench_spectrogram.dart` | The measurements behind the figures in `lib/src/modules/spectrogram.dart`: the run-length strategy against a rect per run, and the run counts on realistic band jitter that retired it in favour of the pixel path. `flutter test tool/bench_spectrogram.dart`. |
| `bench_material.dart` | The measurement the three benchmarks drive, and the one place that knows the wire. It encodes through `SnapshotWire.encode` and decodes through `WireSnapshot` rather than writing offsets by hand, because a harness that reimplements the layout drifts from it — this one did, at protocol version 4, and went on reporting plausible timings for a window that drew nothing. Not a benchmark itself. |
| `bench_wire.dart` | What a remote display pays to decode a 15,056-byte snapshot: the bulk path against the accessor-per-element loop it replaced, and the encode cost on the desktop end. `flutter test tool/bench_wire.dart`. |
| `bench_gpu.dart` | The same fourteen modules on a **real GPU**, read off `FrameTiming` in a profile build: `flutter run -d macos --profile -t tool/bench_gpu.dart`. `bench_modules.dart` rasterises in software and overstated the phase scope 2.5x, so this is the one whose numbers are quoted. Measure one module at a time with `--dart-define=only=<id>` — a full sweep throttles. |
| `bench_modules.dart` | What each of the fourteen modules costs per published frame, recording and rasterising separately, driven through a `WireSnapshot` so the figures are a tablet's arithmetic. This is what cleared the wire and named the phase scope. `flutter test tool/bench_modules.dart`. |
| `fetch_test_audio.dart` | Downloads the Creative Commons music the application is looked at with. `dart run tool/fetch_test_audio.dart`. Writes to `test_audio/`, which is gitignored. |

## Rules

- **`fetch_test_audio.dart` downloads what a *person* looks at, and no test
  depends on it.** Nothing in `ci.yml` runs it: a gate that fetches 35 MB of
  music from somebody else's CDN to prove a socket carries frames is a gate that
  fails for reasons unrelated to this repository. That is not hypothetical — the
  first host this script used, archive.org, stopped serving the item for hours
  at a stretch while the rest of the site stayed up, which is why the manifest
  now points at `upload.wikimedia.org`. The end-to-end test in
  `packages/oaa_wire/` generates its own signal for that reason and takes
  `OAA_TEST_TRACK` when somebody wants the real thing. What the download is for
  is the judgement a tone cannot support: a spectrogram fed a sine is one bright
  line, and a stereo cloud fed one is a dot.

- **The track was chosen by measuring candidates, not by reading titles.** Four
  permissive ones were fetched and run through `oaa`; the manifest's default won
  on numbers — a loud master at −8.6 LUFS, a real 10.3 LU range, a true peak
  *above* its sample peak, and a correlation that moves between −0.11 and 1.00.
  The rejected ones failed on exactly the properties a tone also lacks: one had
  a correlation pinned at 1.00, so the stereo cloud drew a line. The header of
  the script records the figures.

- **It sets `exitCode` rather than returning one.** `Future<int> main()`
  compiles and the value is discarded, so the script exited 0 after a failed
  download. That was the first version, and it is the shape of bug that makes a
  CI step green for a year.

- **The licence travels with the files.** The audio is CC BY, the files are
  gitignored, so nothing in the repository would record where they came from —
  the script writes `ATTRIBUTION.md` beside them, for the tracks it actually
  produced rather than the ones it was asked for.

- **A benchmark reports how many pixels it inked, and that is not decoration.**
  `bench_modules.dart` fails a module that inked fewer than 500 and
  `bench_gpu.dart` prints `DREW NOTHING` beside it. Both exist because the
  harness once stopped drawing entirely — a protocol change moved the offsets it
  was writing by hand — and neither the timings nor the exit code noticed: a
  window that draws nothing still lays out, still presents frames, and still
  reports figures that are low, stable and completely plausible. It was caught
  by somebody glancing at the window. A benchmark that cannot see what it
  measured is a random number generator, so every figure is published beside the
  evidence that there was something there to measure.

- **The three benchmarks are run by hand, and none of them is a gate.** Written
  as a `flutter test` file because `dart:ui` needs an engine, not because it
  tests anything: `flutter test` with no arguments globs `test/`, so this never
  runs in CI, and it asserts nothing about a timing. A stopwatch in the gate
  fails on a loaded runner, a flaky gate gets deleted, and a deleted benchmark
  is how the figure it backs became unfalsifiable the last time — an earlier
  "205 µs" was quoted here for a phase after its benchmark was gone, and turned
  out to be a recording cost being read as a frame cost. Do not add it to
  `ci.yml`, and do not describe it anywhere as something CI checks.
