# engine/

The C11 measurement core. **MIT licensed**, and it must stay independently
usable — this is the part of the project with value outside the app.

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

**A new `.c` file goes in two places** — `CMakeLists.txt` and
`packages/oaa_engine/hook/build.dart`. Sources are listed rather than globbed so
that adding one is a decision somebody made. `plugin/test/sources_match.sh`
fails the build when the two lists disagree.

## Rules

- **Bump `OAA_ABI_VERSION`** whenever the header changes shape, then regenerate
  the Dart bindings. The Dart side asserts it at startup, because a stale
  library does not crash — it reads a reordered struct and shows plausible wrong
  numbers, which is the worst failure a measurement tool has.
- **Only `oaa_engine_create` allocates.** Nothing on the analysis path calls
  `malloc`, and nothing at all on the audio path does.
- **Everything exported is prefixed `oaa_`.** There are no globals.
- **The snapshot is plain old data.** No pointers, no bitfields, no `bool`,
  fixed-size arrays only, widest members first, new fields appended. `dart:ffi`
  reproduces this struct byte for byte.
- **No measurement is invented.** A quantity this build does not compute is
  `NaN` with a `OAA_FLAG_*_UNAVAILABLE` flag set — never a zero that looks like
  a reading.
