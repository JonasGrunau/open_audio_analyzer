# packages/oaa_engine/

Dart bindings for the engine, plus the build hook that compiles it.

| File | Job |
|------|-----|
| `hook/build.dart` | Compiles `../../engine/src/*.c` via `native_toolchain_c` and bundles it as a code asset. The app's only native build description; `engine/CMakeLists.txt` is the same compile for consumers that are not Dart. |
| `ffigen.yaml` | Generates `lib/oaa_engine_bindings_generated.dart` from `oaa.h`. |
| `lib/src/oaa_ffi.dart` | The one hand-written binding: `oaa_snapshot_acquire` with `isLeaf: true`. |
| `lib/oaa_engine.dart` | The `OaaEngine` facade and the zero-copy typed views. Implements `oaa_core`'s `MeterSource`. |
| `lib/src/oaa_file.dart` | `oaa_file_*` as Dart: open a file, read blocks, close. Decoding only — it measures nothing. |
| `lib/src/offline.dart` | `analyseFile` — the decode-push-read loop. Both the app and the CLI drive files through this one function, which is what makes an offline reading and a live reading the same number rather than two numbers that agree. |

## Rules

- **This package is not publishable.** `hook/build.dart` reaches `../../engine`
  with relative paths that no published archive would contain. It is a
  workspace package; keep `publish_to: 'none'`.
- **Add a new C file to `_engineSources` explicitly**, *and* to
  `engine/CMakeLists.txt`. Sources are listed rather than globbed so that adding
  one is a decision somebody made, and there are two builds because a plugin CI
  runner has no Flutter SDK. `plugin/test/sources_match.sh` fails the build if
  the two lists disagree.
- **The hook runs in a pass that asks for nothing, and must return quietly.**
  `flutter run` invokes every build hook once with `buildAssetTypes` empty, and
  `input.config.code` is only meaningful when code assets were requested —
  reading it in that pass throws. Hence the first line of the builder:

  ```dart
  if (!input.config.buildCodeAssets) return;
  ```

  This is worth stating because of how it fails rather than what it is. Neither
  `flutter test` nor `flutter build` makes that pass, so the entire test suite
  stays green while `flutter run` dies before the app opens — and on the pinned
  `code_assets` 1.0.0 it dies as a bare null-check failure inside
  `CodeConfig._fromJson`, naming neither this file nor the reason. Anything else
  added above the `CBuilder` must tolerate the empty pass too.
- **On iOS the engine is compiled as Objective-C, and that is miniaudio's
  doing.** Under `MA_APPLE_MOBILE` `miniaudio.h` includes
  `<AVFoundation/AVFoundation.h>`, because the Core Audio backend configures an
  `AVAudioSession` and iOS gives it no C way to. A C compiler handed that header
  tree emits several hundred errors inside `NSObjCRuntime.h`, `NSZone.h` and
  `NSObject.h` — "unknown type name 'NSString'" — and names no file in this
  repository, so it reads as a broken Xcode installation. `-x objective-c`
  applies to every source that follows it and there is no per-source flag; the
  other eleven translation units are unaffected, since `-std=c11` still picks
  the C dialect.
- **`frameworks:` only reaches the linker when `language:` is
  `Language.objectiveC`.** On macOS the list is inert and the build works
  anyway, because miniaudio `dlopen`s Core Audio there; `MA_APPLE_MOBILE`
  switches runtime linking off, so iOS must link the frameworks or fail with
  undefined symbols. Do not read the macOS entry as evidence that passing
  `frameworks:` is sufficient — `otool -L` on the macOS dylib shows libSystem
  and nothing else.
- **The generated bindings are committed.** `flutter analyze` and the IDE need
  them before any hook has run, and a contributor who only touches Dart should
  never need a C toolchain. Regenerate after every `oaa.h` change.
- **Hand-written `@Native` declarations must name `assetId` explicitly.** A bare
  annotation derives the id from its own library URI, which only happens to be
  right inside the generated file.
- **`isLeaf` is a promise.** The function must never block and never call back
  into the runtime. `oaa_snapshot_acquire` satisfies both by construction. If
  that changes, this becomes a way to hang the UI thread with no diagnostic.
- **The typed lists are windows onto native memory, not copies.** Writing to one
  corrupts the engine's snapshot. They are valid only until `dispose()`.
