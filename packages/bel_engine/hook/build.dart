// Build hook for the Bel measurement engine.
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
// the CLAP plugin compile the same sources without going anywhere near Dart.
// `CBuilder` resolves `sources` and `includes` against the package root, so
// reaching it means climbing out of `packages/bel_engine/`. The consequence is
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
  '../../engine/src/bel_analysis.c',
  '../../engine/src/bel_engine.c',
  '../../engine/src/bel_snapshot.c',
  '../../engine/src/bel_source.c',
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    final builder = CBuilder.library(
      name: input.packageName,

      // Must match the library URI of the generated bindings, because that is
      // what a bare `@ffi.Native<...>()` annotation resolves against. Hand
      // written bindings elsewhere in this package have to name this asset id
      // explicitly — see lib/src/bel_ffi.dart.
      assetName: '${input.packageName}_bindings_generated.dart',

      sources: _engineSources,
      includes: ['../../engine/include'],

      // The engine uses C11 atomics on every toolchain that has them. Saying so
      // here rather than relying on a compiler default is what keeps the
      // Windows build from silently falling back to C99 and failing inside
      // bel_atomic.h with an error that points at the wrong place.
      std: 'c11',

      // GCC/Clang spelling only. MSVC treats `-Wall` as an alias for its own
      // (far noisier) `/Wall` and does not know `-Wextra` at all, so handing it
      // these would trade real warnings for a wall of D9002 noise.
      flags: input.config.code.targetOS == OS.windows
          ? const <String>[]
          : const <String>['-Wall', '-Wextra'],
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
