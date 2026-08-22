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

- **The suite here is two suites, and only one of them gates.**
  `test/conformance_test.dart` generates its signals and runs everywhere;
  `test/vectors_test.dart` reads the official EBU and ITU vector files and skips
  unless `OAA_VECTORS` and `OAA_VECTORS_ITU` name unzipped copies — 811 MB that
  may not be redistributed here. Run the second one after any change to the
  engine's loudness, K-weighting or true-peak code:

  ```sh
  OAA_VECTORS=~/ebu-loudness-test-set OAA_VECTORS_ITU=~/bs2217 \
    dart test test/vectors_test.dart
  ```

  It found two defects on its first run, so treat a green gated suite as
  necessary rather than sufficient. Anything it catches that a generated signal
  can also express belongs in `conformance_test.dart` too — nothing in CI can
  see these files.
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
- **On both Apple platforms the engine is compiled as Objective-C, for two
  unrelated reasons.** On iOS it is miniaudio's doing: under `MA_APPLE_MOBILE`
  `miniaudio.h` includes `<AVFoundation/AVFoundation.h>`, because the Core Audio
  backend configures an `AVAudioSession` and iOS gives it no C way to. A C
  compiler handed that header tree emits several hundred errors inside
  `NSObjCRuntime.h`, `NSZone.h` and `NSObject.h` — "unknown type name
  'NSString'" — and names no file in this repository, so it reads as a broken
  Xcode installation. On macOS it is `oaa_tap_macos.m`: a Core Audio process tap
  is created from a `CATapDescription`, an Objective-C object, so system-output
  capture cannot be written in C. `-x objective-c` applies to every source that
  follows it and there is no per-source flag; the other twelve translation units
  are unaffected, since `-std=c11` still picks the C dialect, and vendored
  miniaudio contains no `__OBJC__` conditional at all.
- **macOS carries `-mmacos-version-min=14.2` in `_flags`, and it is not
  redundant.** Flutter's native-assets pipeline compiles this hook's sources
  with `-mmacos-version-min=13` and never reads `MACOSX_DEPLOYMENT_TARGET` from
  `macos/Runner.xcodeproj`, so raising the application's floor moves the
  application and leaves the library it loads behind. That is not a portability
  nicety here: `oaa_tap_macos.m` holds a *strong* reference to
  `CATapDescription`, so a library built below 14.2 is one dyld cannot resolve,
  and what fails is the load of the whole engine — the application dies at
  launch rather than losing a feature. The old floor also compiled with five
  `-Wunguarded-availability-new` diagnostics that nobody was reading.
  `CBuilder` emits its own flag first and clang takes the last, so this one
  wins; `engine/src/oaa_tap.h` fails the build if it ever stops winning.

- **`frameworks:` only reaches the linker when `language:` is
  `Language.objectiveC`** — which is now both Apple platforms, so on both the
  list is load-bearing. It was not always: macOS used to build as C and the
  entry was inert documentation, because miniaudio `dlopen`s Core Audio there
  and `otool -L` on the dylib showed libSystem and nothing else. `oaa_tap_macos.m`
  calls `AudioHardwareCreateProcessTap` and `AudioObjectGetPropertyData`
  directly, so the frameworks are linked for real now — and that is the
  direction miniaudio itself recommends, since it warns that runtime linking can
  fail Apple's notarization. **Adding a macOS framework and leaving `language:`
  as `Language.c` would still be silently inert**, which is the trap this rule
  is really about.
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
