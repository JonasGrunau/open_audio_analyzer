# engine/CMakeLists.txt — liboaa for the consumers that are not Dart.
#
# SPDX-License-Identifier: MIT
#
# ---------------------------------------------------------------------------
# Why this file exists at all, when build.dart already builds the same sources
#
# It is a stated goal of this repository that there is one native build
# description. `packages/oaa_engine/hook/build.dart` is it, and for the Flutter
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
#   Here, and in `_engineSources` in packages/oaa_engine/hook/build.dart.
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

project(oaa
  VERSION 0.11.0
  DESCRIPTION "The Open Audio Analyzer measurement engine"
  LANGUAGES C
)

option(OAA_BUILD_DECODE "Compile the file-decoding sources (dr_libs)." ON)

# ---------------------------------------------------------------------------
# Sources
#
# Listed one by one rather than globbed, for the reason build.dart gives:
# adding a file to the engine should be a decision somebody made, not a side
# effect of creating it. A glob would also defeat the CI check above by keeping
# the two lists trivially in step while hiding whether anyone meant it.

set(OAA_SOURCES
  src/oaa_analysis.c
  src/oaa_device.c
  src/oaa_engine.c
  src/oaa_kweight.c
  src/oaa_loudness.c
  src/oaa_ring.c
  src/oaa_snapshot.c
  src/oaa_source.c
  src/oaa_spectrum.c
  src/oaa_truepeak.c

  # Vendored. One translation unit, no build system of its own.
  third_party/pffft/pffft.c
)

if(OAA_BUILD_DECODE)
  list(APPEND OAA_SOURCES src/oaa_decode.c)
endif()

# The engine's only Objective-C, and the only source that is not built
# everywhere. A Core Audio process tap is created from a `CATapDescription`,
# which is an Objective-C object — the SDK wraps AudioHardwareTapping.h in
# `#ifdef __OBJC__`, so there is no C spelling of this. Apple restricts it to
# macOS (the tapping header is API_UNAVAILABLE(ios)), which is why the guard is
# not a plain `if(APPLE)`.
#
# `enable_language(OBJC)` is what makes CMake compile a `.m` at all; without it
# the file is handed to the C compiler and fails inside <Foundation/Foundation.h>
# with several hundred errors that name no file in this repository.
#
# build.dart reaches the same place differently — it has no per-source language,
# so it compiles the whole macOS engine with `-x objective-c`. Both produce the
# same object; see the comment on `_language` there.
if(APPLE AND NOT IOS)
  enable_language(OBJC)
  list(APPEND OAA_SOURCES src/oaa_tap_macos.m)
endif()

add_library(oaa STATIC ${OAA_SOURCES})
add_library(oaa::oaa ALIAS oaa)

# ---------------------------------------------------------------------------
# Include paths
#
# `include/` is PUBLIC because oaa.h is the entire contract and every consumer
# needs it. The vendored directories are PRIVATE: miniaudio and pffft are
# implementation, and a plugin that could `#include "miniaudio.h"` because it
# happened to link the engine is a plugin that will eventually do it.

target_include_directories(oaa
  PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio
          ${CMAKE_CURRENT_SOURCE_DIR}/third_party/pffft
)

if(OAA_BUILD_DECODE)
  target_include_directories(oaa PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/dr_libs)
endif()

target_compile_features(oaa PUBLIC c_std_11)

# `-std=c11` is strict ISO C, which hides everything POSIX behind
# __STRICT_ANSI__. See the long comment on `_defines` in build.dart: this was
# found the hard way, by a local SDK being lenient enough to compile without it
# while both POSIX CI runners failed.
set_target_properties(oaa PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  C_EXTENSIONS OFF

  # Objective-C is a superset of C, and oaa_tap_macos.m is the one source that
  # uses it. Saying c11 here too keeps it the same dialect as its twelve
  # neighbours rather than whatever the toolchain defaults to. Ignored on every
  # platform where OBJC was never enabled.
  OBJC_STANDARD 11
  OBJC_STANDARD_REQUIRED ON
  OBJC_EXTENSIONS OFF

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
  target_compile_definitions(oaa PRIVATE
    _POSIX_C_SOURCE=200809L
    _DEFAULT_SOURCE
  )
  if(APPLE)
    # Asking for a specific _POSIX_C_SOURCE level on Darwin narrows the SDK to
    # exactly POSIX and hides the Apple half of the headers.
    target_compile_definitions(oaa PRIVATE _DARWIN_C_SOURCE)
  endif()
  target_compile_options(oaa PRIVATE -Wall -Wextra)
endif()

# ---------------------------------------------------------------------------
# Platform libraries
#
# miniaudio dlopen()s the Linux backends at runtime and needs the maths and
# threading libraries everywhere POSIX. On Apple platforms it talks to
# CoreAudio directly and will not tell you the frameworks are missing until the
# link step. These are PUBLIC because the consumer does the final link.
#
# Foundation is not miniaudio's: oaa_tap_macos.m builds the tap and aggregate
# descriptions out of NSUUID, NSString, NSArray and NSDictionary.

if(APPLE)
  target_link_libraries(oaa PUBLIC
    "-framework Foundation"
    "-framework CoreFoundation"
    "-framework CoreAudio"
    "-framework AudioToolbox"
  )
elseif(UNIX)
  find_package(Threads REQUIRED)
  target_link_libraries(oaa PUBLIC ${CMAKE_DL_LIBS} Threads::Threads m)
endif()
