# packages/bel_engine/

Dart bindings for the engine, plus the build hook that compiles it.

| File | Job |
|------|-----|
| `hook/build.dart` | Compiles `../../engine/src/*.c` via `native_toolchain_c` and bundles it as a code asset. The only native build description in the repo. |
| `ffigen.yaml` | Generates `lib/bel_engine_bindings_generated.dart` from `bel.h`. |
| `lib/src/bel_ffi.dart` | The one hand-written binding: `bel_snapshot_acquire` with `isLeaf: true`. |
| `lib/bel_engine.dart` | The `BelEngine` facade and the zero-copy typed views. |

## Rules

- **This package is not publishable.** `hook/build.dart` reaches `../../engine`
  with relative paths that no published archive would contain. It is a
  workspace package; keep `publish_to: 'none'`.
- **Add a new C file to `_engineSources` explicitly.** Sources are listed rather
  than globbed so that adding one is a decision somebody made.
- **The generated bindings are committed.** `flutter analyze` and the IDE need
  them before any hook has run, and a contributor who only touches Dart should
  never need a C toolchain. Regenerate after every `bel.h` change.
- **Hand-written `@Native` declarations must name `assetId` explicitly.** A bare
  annotation derives the id from its own library URI, which only happens to be
  right inside the generated file.
- **`isLeaf` is a promise.** The function must never block and never call back
  into the runtime. `bel_snapshot_acquire` satisfies both by construction. If
  that changes, this becomes a way to hang the UI thread with no diagnostic.
- **The typed lists are windows onto native memory, not copies.** Writing to one
  corrupts the engine's snapshot. They are valid only until `dispose()`.
