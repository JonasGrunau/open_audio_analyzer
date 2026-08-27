# oaa_engine

Dart bindings for Open Audio Analyzer's C measurement engine, and the build hook
that compiles it. **GPL-3.0-or-later**, like the engine itself. Anybody can read
and audit the measurement code, and anybody embedding it takes on the same
licence.

This package is **not publishable**. `hook/build.dart` reaches out to
`../../engine` with relative paths that no published archive would contain; it
is a workspace package and must stay one. See `AGENTS.md` for the rules that
are not obvious from the code.

## What is in here

| Path | Job |
|------|-----|
| `hook/build.dart` | Compiles `../../engine/src/*.c` through `native_toolchain_c` and bundles the result as a code asset. No podspec, no `build.gradle`, no per-platform CMake. |
| `ffigen.yaml` | Generates `lib/oaa_engine_bindings_generated.dart` from `engine/include/oaa/oaa.h`. |
| `lib/oaa_engine.dart` | The `OaaEngine` facade, the zero-copy typed views, and the ABI assertion. |
| `lib/src/oaa_ffi.dart` | The one hand-written binding: `oaa_snapshot_acquire`, declared `isLeaf: true`. |
| `lib/src/oaa_file.dart` | File decoding — `oaa_file_open` / `read` / `seek` / `close`. Measures nothing. |
| `lib/src/offline.dart` | `analyseFile`: the decode-push-read loop the app and the `oaa` CLI both drive files through. |

## Reading a measurement

The engine publishes into a seqlock-protected snapshot in native memory. The
Dart side acquires it once per frame and reads `Float32List` views that were
built **once at startup** over memory that never moves — no copy into the Dart
heap, no allocation per frame.

```dart
final engine = OaaEngine.start(
  source: OaaSource.testTone,
  sampleRate: 48000,
  channels: 2,
);
engine.refresh();          // one FFI call: atomic load, memcpy, atomic load
print(engine.lufsIntegrated);
engine.dispose();          // the typed views are invalid after this
```

The typed lists are **windows onto native memory, not copies.** Writing to one
corrupts the engine's snapshot, and every one of them dangles after `dispose()`.

`OaaEngine` implements `oaa_core`'s `MeterSource`, which is the interface the
fourteen meter modules read. The remote display's `WireSnapshot` implements the
same interface over a socket, so a module cannot tell an engine from a network
link — that is what lets a tablet with no engine draw the desktop's meters with
the desktop's painters.

## Regenerating the bindings

After **every** change to `engine/include/oaa/oaa.h`:

```sh
cd packages/oaa_engine
dart run ffigen --config ffigen.yaml
```

The generated file is committed on purpose: `flutter analyze` and the IDE need
it before any build hook has run, and a contributor who only touches Dart should
never need a C toolchain.

**`OAA_ABI_VERSION` and `OaaEngine.expectedAbiVersion` move in the same commit,
always.** The Dart constant is not an independent value — it is an assertion
*about* the header, checked at startup. A stale library does not crash; it reads
a reordered struct and displays plausible wrong numbers, which is the worst
failure a measurement tool has.

## Tests

```sh
cd packages/oaa_engine && dart test
```

Plain `dart test` — it drives `hook/build.dart` itself, so there is no separate
native build step. The suite holds the meters against arithmetic (a sine of
amplitude *A* peaks at *A* and has an RMS of *A*/√2, exactly 3.0103 dB lower),
runs the EBU Tech 3341/3342 conformance cases, checks the spectrum against a
full-scale sine on a bin centre, and asserts that decoding a file does not
change a reading. CI runs all of it on Linux, macOS and Windows on every push.
