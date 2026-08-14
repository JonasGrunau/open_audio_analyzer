# engine/

The C11 measurement core. **MIT licensed**, and it must stay independently
usable — this is the part of the project with value outside the app.

Three consumers link against it: the Flutter app (through `dart:ffi`), the `bel`
CLI, and the CLAP plugin. None of them may know about the others, and none of
their concerns may leak in here. In particular there is **no Dart, no Flutter,
no UI vocabulary and no file I/O outside `bel_decode.c`**.

| Path | Contents |
|------|----------|
| `include/bel/bel.h` | The entire public ABI. One header. If it is not here, it is not part of the engine. |
| `src/` | Implementation (see `src/AGENTS.md`). |
| `third_party/` | Vendored permissive C libraries. Empty until Phase 1. |
| `test/` | C unit tests and the EBU conformance vectors. Phase 1. |

## Rules

- **Bump `BEL_ABI_VERSION`** whenever the header changes shape, then regenerate
  the Dart bindings. The Dart side asserts it at startup, because a stale
  library does not crash — it reads a reordered struct and shows plausible wrong
  numbers, which is the worst failure a measurement tool has.
- **Only `bel_engine_create` allocates.** Nothing on the analysis path calls
  `malloc`, and nothing at all on the audio path does.
- **Everything exported is prefixed `bel_`.** There are no globals.
- **The snapshot is plain old data.** No pointers, no bitfields, no `bool`,
  fixed-size arrays only, widest members first, new fields appended. `dart:ffi`
  reproduces this struct byte for byte.
- **No measurement is invented.** A quantity this build does not compute is
  `NaN` with a `BEL_FLAG_*_UNAVAILABLE` flag set — never a zero that looks like
  a reading.
