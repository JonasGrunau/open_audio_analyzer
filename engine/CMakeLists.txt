# engine/CMakeLists.txt — libbel for the consumers that are not Dart.
#
# SPDX-License-Identifier: MIT
#
# ---------------------------------------------------------------------------
# Why this file exists at all, when build.dart already builds the same sources
#
# It is a stated goal of this repository that there is one native build
# description. `packages/bel_engine/hook/build.dart` is it, and for the Flutter
# app it remains it — nothing here is on the app's build path.
#
# But a VST3 and an Audio Unit are C++ bundles produced by JUCE's CMake API, and
# JUCE links libraries, not Dart code assets. There is no way to hand a JUCE
# target the output of a Flutter build hook, and there should not be: the plugin
# has to build on a machine with no Flutter SDK at all, because that is what a
# plugin CI runner looks like.
#
# So there are now two descriptions of the same compile, and the honest thing to
# do is say so loudly rather than pretend otherwise:
#
#   **If you add a file to engine/src, add it in BOTH places.**
#   Here, and in `_engineSources` in packages/bel_engine/hook/build.dart.
#
# The two are checked against each other by `plugin/test/sources_match.sh`,
# which is wired into CI. A source file that reaches only one of them produces
# an undefined symbol at link time in whichever consumer was forgotten, and
# that is a confusing failure to debug from scratch — the test turns it into a
# one-line diff.
#
# Everything below — the source list, the include paths, the feature-test
# macros, the platform libraries — is a transcription of build.dart's choices,
# and the comments there explain *why* each one is required. They are not
# repeated here; read that file. The one thing that is genuinely different is
# POSITION_INDEPENDENT_CODE, and that is commented where it appears.

cmake_minimum_required(VERSION 3.22)

project(bel
  VERSION 0.1.0
  DESCRIPTION "The Bel measurement engine"
  LANGUAGES C
)

option(BEL_BUILD_DECODE "Compile the file-decoding sources (dr_libs)." ON)

# ---------------------------------------------------------------------------
# Sources
#
# Listed one by one rather than globbed, for the reason build.dart gives:
# adding a file to the engine should be a decision somebody made, not a side
# effect of creating it. A glob would also defeat the CI check above by keeping
# the two lists trivially in step while hiding whether anyone meant it.

set(BEL_SOURCES
  src/bel_analysis.c
  src/bel_device.c
  src/bel_engine.c
  src/bel_kweight.c
  src/bel_loudness.c
  src/bel_ring.c
  src/bel_snapshot.c
  src/bel_source.c
  src/bel_spectrum.c
  src/bel_truepeak.c

  # Vendored. One translation unit, no build system of its own.
  third_party/pffft/pffft.c
)

if(BEL_BUILD_DECODE)
  list(APPEND BEL_SOURCES src/bel_decode.c)
endif()

add_library(bel STATIC ${BEL_SOURCES})
add_library(bel::bel ALIAS bel)

# ---------------------------------------------------------------------------
# Include paths
#
# `include/` is PUBLIC because bel.h is the entire contract and every consumer
# needs it. The vendored directories are PRIVATE: miniaudio and pffft are
# implementation, and a plugin that could `#include "miniaudio.h"` because it
# happened to link the engine is a plugin that will eventually do it.

target_include_directories(bel
  PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio
          ${CMAKE_CURRENT_SOURCE_DIR}/third_party/pffft
)

if(BEL_BUILD_DECODE)
  target_include_directories(bel PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/dr_libs)
endif()

target_compile_features(bel PUBLIC c_std_11)

# `-std=c11` is strict ISO C, which hides everything POSIX behind
# __STRICT_ANSI__. See the long comment on `_defines` in build.dart: this was
# found the hard way, by a local SDK being lenient enough to compile without it
# while both POSIX CI runners failed.
set_target_properties(bel PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  C_EXTENSIONS OFF

  # The one genuine difference from build.dart.
  #
  # A VST3 or an Audio Unit is a shared object, and this static library is
  # linked into it wholesale. Static archives default to non-PIC on Linux, so
  # without this the plugin fails at link time with "recompile with -fPIC" —
  # after the engine itself has already compiled cleanly, which points the
  # blame at the wrong project. macOS and Windows do not care; setting it
  # unconditionally is free and keeps the three platforms describable in one
  # sentence.
  POSITION_INDEPENDENT_CODE ON
)

if(NOT MSVC)
  target_compile_definitions(bel PRIVATE
    _POSIX_C_SOURCE=200809L
    _DEFAULT_SOURCE
  )
  if(APPLE)
    # Asking for a specific _POSIX_C_SOURCE level on Darwin narrows the SDK to
    # exactly POSIX and hides the Apple half of the headers.
    target_compile_definitions(bel PRIVATE _DARWIN_C_SOURCE)
  endif()
  target_compile_options(bel PRIVATE -Wall -Wextra)
endif()

# ---------------------------------------------------------------------------
# Platform libraries
#
# miniaudio dlopen()s the Linux backends at runtime and needs the maths and
# threading libraries everywhere POSIX. On Apple platforms it talks to
# CoreAudio directly and will not tell you the frameworks are missing until the
# link step. These are PUBLIC because the consumer does the final link.

if(APPLE)
  target_link_libraries(bel PUBLIC
    "-framework CoreFoundation"
    "-framework CoreAudio"
    "-framework AudioToolbox"
  )
elseif(UNIX)
  find_package(Threads REQUIRED)
  target_link_libraries(bel PUBLIC ${CMAKE_DL_LIBS} Threads::Threads m)
endif()
