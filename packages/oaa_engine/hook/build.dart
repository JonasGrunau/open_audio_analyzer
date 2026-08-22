// Build hook for the Open Audio Analyzer measurement engine.
//
// SPDX-License-Identifier: MIT
//
// This compiles the C in `engine/` and bundles the result as a code asset, so
// that `@Native` lookups resolve without anybody ever calling
// `DynamicLibrary.open`. There is no CMakeLists.txt, no podspec and no
// build.gradle anywhere in this repository, and that is the point: build hooks
// have been the recommended way to ship native code with Flutter since 3.38,
// and one build description that works on five platforms is worth considerably
// more than five that each work on one.
//
// **The relative paths below are load-bearing.** The engine deliberately lives
// at the repository root rather than inside this package, because the CLI and
// the VST3/AU plugin compile the same sources without going anywhere near Dart.
// `CBuilder` resolves `sources` and `includes` against the package root, so
// reaching it means climbing out of `packages/oaa_engine/`. The consequence is
// that this package is **not publishable to pub.dev** — a published archive
// would not contain `engine/`. It is a workspace package and must stay one.
//
// Sources are listed one by one rather than globbed. Adding a file to the
// engine should be a decision somebody made, not a side effect of creating it.

// Supplies the `config.code` extension and the `OS` enum used below.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Everything under `engine/src`, relative to this package's root.
const _engineSources = <String>[
  '../../engine/src/oaa_analysis.c',
  '../../engine/src/oaa_decode.c',
  '../../engine/src/oaa_device.c',
  '../../engine/src/oaa_engine.c',
  '../../engine/src/oaa_kweight.c',
  '../../engine/src/oaa_loudness.c',
  '../../engine/src/oaa_ring.c',
  '../../engine/src/oaa_snapshot.c',
  '../../engine/src/oaa_source.c',
  '../../engine/src/oaa_spectrum.c',
  '../../engine/src/oaa_truepeak.c',

  // Vendored. pffft is one translation unit and has no build system of its
  // own, which is most of why it was chosen over a library that does.
  '../../engine/third_party/pffft/pffft.c',
];

/// Sources built for macOS and nowhere else.
///
/// The engine's only Objective-C. A Core Audio process tap is created from a
/// `CATapDescription`, which is an Objective-C class, and the SDK wraps
/// `AudioHardwareTapping.h` in `#ifdef __OBJC__` — so there is no C spelling of
/// this and there will not be. macOS only because Apple made it so: the tapping
/// header is `API_UNAVAILABLE(ios)`.
///
/// **The comment inside the list is load-bearing.** `plugin/test/sources_match.sh`
/// reads both build descriptions with a regex that expects one quoted source per
/// line, and `dart format` collapses a short list onto a single line — a
/// trailing comma does not stop it. A comment inside the literal does, and it
/// is the only thing keeping this file inside the check that exists to catch a
/// source reaching one of the two builds and not the other.
const _macosSources = <String>[
  // Compiled with `-x objective-c` like everything else on macOS; see
  // [_language].
  '../../engine/src/oaa_tap_macos.m',
];

List<String> _platformSources(OS targetOS) =>
    targetOS == OS.macOS ? _macosSources : const [];

/// Feature-test macros, which must be defined before any system header is
/// included — which is why they are compiler defines rather than `#define`s at
/// the top of one `.c` file. Every translation unit needs them, and
/// `oaa_internal.h` pulls in `<pthread.h>` on its own.
Map<String, String?> _defines(OS targetOS) {
  if (targetOS == OS.windows) {
    // MSVC has no feature-test macro model; the Win32 headers are always
    // visible. Passing these would be noise at best.
    return const {};
  }

  return {
    // POSIX.1-2008: clock_gettime, CLOCK_MONOTONIC, nanosleep, pthreads.
    '_POSIX_C_SOURCE': '200809L',

    // The maths constants — M_PI and friends — are XSI/BSD rather than ISO C,
    // and asking glibc for a specific POSIX level switches off everything it
    // considers "misc", which is where it keeps them. Our own code declares its
    // own pi for exactly this reason, but vendored pffft uses M_PI, and the
    // failure is a compile error on Linux only. Same class of trap as the
    // POSIX line above, found the same way.
    '_DEFAULT_SOURCE': null,

    // Asking for _POSIX_C_SOURCE on Darwin narrows the SDK to exactly POSIX and
    // hides the Apple-specific half of the headers. We do not use any of it
    // today, but the failure mode if we ever do is another "missing
    // declaration" that looks like a compiler bug, so restore it up front.
    if (targetOS == OS.macOS || targetOS == OS.iOS) '_DARWIN_C_SOURCE': null,
  };
}

List<String> _libraries(OS targetOS) => switch (targetOS) {
  OS.linux => const ['dl', 'pthread', 'm'],
  OS.android => const ['dl', 'm'],
  _ => const [],
};

/// On both Apple platforms the engine is Objective-C, for two unrelated
/// reasons that happen to want the same flag.
///
/// **iOS, because miniaudio is.** `miniaudio.h` includes
/// `<AVFoundation/AVFoundation.h>` under `MA_APPLE_MOBILE`: the Core Audio
/// backend configures an `AVAudioSession` there, and iOS offers no C way to do
/// it. Handing that header tree to a C compiler produces several hundred errors
/// inside `NSObjCRuntime.h`, `NSZone.h` and `NSObject.h` — "unknown type name
/// 'NSString'", "expected identifier or '('" — and not one of them names a file
/// in this repository. The failure reads as a broken Xcode installation rather
/// than as a missing compiler flag, which is what makes it expensive.
///
/// **macOS, because `oaa_tap_macos.m` is.** A Core Audio process tap is created
/// from a `CATapDescription`, which is an Objective-C object, so system-output
/// capture cannot be written in C. See [_platformSources].
///
/// Objective-C is a superset of C11 and `-std=c11` still selects the C dialect,
/// so `-x objective-c` (see [_flags]) leaves the other twelve translation units
/// and pffft compiling exactly as they do on every other platform. Verified for
/// vendored miniaudio specifically: it contains no `__OBJC__` conditional at
/// all, so nothing about its desktop build changes.
Language _language(OS targetOS) => targetOS == OS.iOS || targetOS == OS.macOS
    ? Language.objectiveC
    : Language.c;

/// The frameworks the linker needs — **which `CBuilder` emits only when
/// [_language] is [Language.objectiveC]**, which since the process tap landed
/// is both Apple platforms rather than only iOS.
///
/// macOS used to list these as documentation with no effect: miniaudio resolved
/// Core Audio through `dlopen` at runtime and the dylib genuinely linked
/// nothing but libSystem. `oaa_tap_macos.m` calls `AudioHardwareCreateProcessTap`
/// and `AudioObjectGetPropertyData` directly, so they are now load-bearing —
/// and the change is in the direction miniaudio itself recommends, since it
/// warns that runtime linking can fail Apple's notarization.
List<String> _frameworks(OS targetOS) => switch (targetOS) {
  OS.macOS => const [
    // Foundation for NSUUID/NSDictionary in the tap description; CoreAudio for
    // the tap itself.
    'Foundation',
    'CoreFoundation',
    'CoreAudio',
    'AudioToolbox',
  ],
  OS.iOS => const [
    'Foundation',
    'CoreFoundation',
    'CoreAudio',
    'AudioToolbox',
    'AVFoundation',
  ],
  _ => const [],
};

/// GCC/Clang spelling only. MSVC treats `-Wall` as an alias for its own (far
/// noisier) `/Wall` and does not know `-Wextra` at all, so handing it these
/// would trade real warnings for a wall of D9002 noise.
///
/// `-x objective-c` governs every source that *follows* it on the command line,
/// and `CBuilder` emits flags ahead of the source list, so it reaches all of
/// them. On iOS only `oaa_device.c` needs it and on macOS only
/// `oaa_tap_macos.m` does; there is no per-source flag to give it alone, and
/// none is wanted — thirteen files compiled two different ways is a difference
/// somebody would eventually have to debug.
///
/// **macOS carries its own `-mmacos-version-min`, and it is not redundant.**
/// Flutter's native-assets pipeline pins the engine at
/// `-mmacos-version-min=13` and does not read `MACOSX_DEPLOYMENT_TARGET` from
/// `macos/Runner.xcodeproj` — so raising the application's floor moved the
/// application and left the library it loads behind. That matters here more
/// than it would anywhere else: `oaa_tap_macos.m` holds a *strong* reference to
/// `CATapDescription`, so a library built below 14.2 is one dyld cannot resolve
/// on any system, and it also compiled with a page of
/// `-Wunguarded-availability-new` warnings that nobody was reading. `CBuilder`
/// emits its own flag ahead of these, and clang takes the last one, so this
/// wins. `oaa_tap.h` fails the build if it ever stops winning.
List<String> _flags(OS targetOS) => switch (targetOS) {
  OS.windows => const <String>[],
  OS.macOS => const <String>[
    '-Wall',
    '-Wextra',
    '-x',
    'objective-c',
    '-mmacos-version-min=14.2',
  ],
  OS.iOS => const <String>['-Wall', '-Wextra', '-x', 'objective-c'],
  _ => const <String>['-Wall', '-Wextra'],
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    // `flutter run` invokes every build hook once in a pass that asks for no
    // asset types at all, and `input.config.code` is only meaningful when code
    // assets were requested. Reading it in that pass throws — in code_assets
    // 1.0.0 as a bare null-check failure inside `CodeConfig._fromJson`, which
    // names neither this file nor the reason.
    //
    // The symptom is worth stating because it is so misleading: `flutter test`
    // and `flutter build` never make that pass, so the whole suite stays green
    // and only `flutter run` fails — the app will not start while every test
    // says it is fine. Guard, and let the empty pass produce nothing.
    if (!input.config.buildCodeAssets) return;

    final builder = CBuilder.library(
      name: input.packageName,

      // Must match the library URI of the generated bindings, because that is
      // what a bare `@ffi.Native<...>()` annotation resolves against. Hand
      // written bindings elsewhere in this package have to name this asset id
      // explicitly — see lib/src/oaa_ffi.dart.
      assetName: '${input.packageName}_bindings_generated.dart',

      sources: [
        ..._engineSources,
        ..._platformSources(input.config.code.targetOS),
      ],
      includes: [
        '../../engine/include',
        '../../engine/third_party/dr_libs',
        '../../engine/third_party/miniaudio',
        '../../engine/third_party/pffft',
      ],

      // miniaudio dlopen()s the Linux backends at runtime and needs the maths
      // and threading libraries everywhere POSIX. On iOS it cannot: see
      // _frameworks and _language, which are one decision in two places.
      libraries: _libraries(input.config.code.targetOS),
      frameworks: _frameworks(input.config.code.targetOS),
      language: _language(input.config.code.targetOS),

      // The engine uses C11 atomics on every toolchain that has them. Saying so
      // here rather than relying on a compiler default is what keeps the
      // Windows build from silently falling back to C99 and failing inside
      // oaa_atomic.h with an error that points at the wrong place.
      std: 'c11',

      // `-std=c11` asks for strict ISO C, which defines __STRICT_ANSI__, which
      // makes glibc and the Apple SDK hide everything POSIX — including
      // clock_gettime, CLOCK_MONOTONIC, nanosleep and the pthread functions
      // the analysis thread is built on.
      //
      // Declaring the POSIX level we need is the fix, rather than relaxing to
      // gnu11 and depending on whichever extensions a given toolchain happens
      // to leave switched on. This was found the hard way: a local Xcode SDK
      // was lenient enough to compile without it, so the build passed on the
      // development machine and failed on both POSIX CI runners. Windows was
      // green throughout, which is exactly what made it confusing — MSVC never
      // sees any of these declarations.
      defines: _defines(input.config.code.targetOS),

      flags: _flags(input.config.code.targetOS),
    );

    await builder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.ALL
        // The build hook's log goes to the build output; print is how a
        // hook is expected to report progress.
        // ignore: avoid_print
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
