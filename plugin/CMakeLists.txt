# plugin/CMakeLists.txt — the headless VST3 / Audio Unit metering plugin.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# ---------------------------------------------------------------------------
# What this builds, and why it is nearly empty
#
# The plugin's entire job is three lines of real work: take the DAW's buffer,
# get it to `oaa_engine_push`, and stream the resulting snapshot and the DAW's
# transport position to the Open Audio Analyzer app over a socket. It draws no
# meters. Flutter cannot be a plugin GUI, and rewriting twelve meter modules a
# second time in C++ so that the plugin could draw them itself is precisely the
# outcome this architecture exists to avoid — there would then be two
# implementations of every measurement's *presentation*, and they would drift.
#
# So the plugin is a sensor and the app is the display, and the socket between
# them is the whole design.
#
# ---------------------------------------------------------------------------
# Licensing — this differs from docs/PLAN.md, deliberately, and it matters
#
# The plan says "Built with JUCE under its GPL-3.0 option". That was true of
# JUCE 6. **JUCE 7 and 8 are AGPLv3 or commercial, not GPLv3.** We take the
# AGPLv3 option, which is available to us and costs nothing we were not already
# giving away, but it does change what this directory is licensed as:
#
#   engine/            MIT             unchanged; the plugin links it, so MIT
#                                      flows in without obligation
#   packages/oaa_core  MIT             unchanged, not involved here
#   lib/ (the app)     GPL-3.0-or-later  unchanged — the app never links JUCE.
#                                      It talks to this plugin over a socket,
#                                      which is not linking, so nothing about
#                                      JUCE reaches it
#   plugin/ (here)     AGPL-3.0-or-later  because it combines with JUCE
#
# GPLv3 section 13 expressly permits combining a GPLv3 work with AGPLv3 code,
# and the app being "GPL-3.0-**or-later**" is what makes the combination clean
# rather than merely arguable. The practical consequence of AGPL over GPL is its
# network clause, and since Open Audio Analyzer publishes all of its source
# anyway, that clause asks us for nothing we were not already doing.
#
# One piece of good news the plan did not anticipate: **Steinberg relicensed the
# VST3 SDK to MIT**, and JUCE 8 vendors it (in juce_audio_processors_headless).
# So there is no second copyleft dependency and no separate SDK checkout. JUCE
# is the only reason this directory is AGPL.
#
# ---------------------------------------------------------------------------
# Building
#
#   cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build build
#
# Products land in build/OaaPlugin_artefacts/. Nothing is installed into a
# system plugin folder unless you ask for it — see COPY_PLUGIN_AFTER_BUILD.

cmake_minimum_required(VERSION 3.22)

# ---------------------------------------------------------------------------
# What a downloaded macOS bundle has to be able to run on
#
# Neither of these was set until this comment was written, and CMake's default
# for both is whatever machine did the build. The plugin in every release up to
# 0.5.0 was therefore built by a `macos-latest` runner as arm64 alone, with
# `minos 26.0` in its load commands — a bundle that cannot load on an Intel Mac
# and cannot load on any macOS older than the runner's, while `README.md`
# promised "macOS 11+, universal" one table above. `lipo -info` and
# `otool -l | grep -A3 LC_BUILD_VERSION` on the shipped artefact are how that
# was eventually seen; a DAW shows you nothing, because a bundle whose slice
# does not match and a bundle that is not there are the same event to a host.
#
# 11.0 because that is what the app's dmg claims, and because it is the first
# macOS with Apple silicon. `engine/src/oaa_tap_macos.m` already expects a
# target far below the 14.2 its Core Audio process tap needs — its `@available`
# guard and the weak linking that guard protects are written for exactly this,
# and were doing nothing while the target was the runner's own OS.
#
# The cost is a compile of both architectures, roughly doubling a job that only
# runs on a release. Pass `-DCMAKE_OSX_ARCHITECTURES=arm64` for a local build
# you are only going to load on this machine.
#
# **`FORCE`, and the emptiness test rather than `NOT DEFINED`.** CMake creates
# both of these as *empty* cache entries of its own on Apple. A plain
# `set(... CACHE ...)` therefore does nothing at all once a build directory
# exists — and does the right thing in a fresh one, which is the worst of the
# two: a first build that is universal and every rebuild after it single-arch,
# from a line that reads correctly. `if(NOT <var>)` is true for both the empty
# default and the undefined case, and false for a value somebody passed on the
# command line, which is the one thing that has to win.
if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING
    "macOS architectures for the plugin bundles. Ignored off Apple." FORCE)
endif()
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING
    "Oldest macOS the plugin bundles load on. Ignored off Apple." FORCE)
endif()

project(oaa_plugin
  VERSION 0.5.0
  DESCRIPTION "Open Audio Analyzer — headless metering plugin"
  LANGUAGES C CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# JUCE, and the one build that does without it
#
# **`-DOAA_BUILD_PLUGIN=OFF` configures this directory with no JUCE at all**: no
# fetch, no framework compile, no plugin, no fake DAW. What is left is `liboaa`
# and the two test executables beside it, which link neither — about a second of
# work from a cold build directory against roughly ten minutes for the framework.
#
# That difference is the whole point of the switch, and it is a correctness
# argument rather than a convenience one. The full plugin job runs only on a
# release or a manual dispatch, because three parallel JUCE builds cost more than
# a push asks for — so for a day, two C++ tests that need no framework were also
# only running then. One of them existed *because* a defect had reached CI
# unnoticed. A gate that only runs when you remember to ask for it is a gate that
# finds things late: with the plugin off, every push runs `ctest` here.
#
# What it cannot recover is the part that genuinely needs the framework — the
# VST3, the AU, the fake DAW, and every end-to-end case that drives them. Those
# stay on the release side of the line, and `.github/AGENTS.md` says what that
# costs.
option(OAA_BUILD_PLUGIN "Build the VST3/AU plugin, and fetch JUCE for it." ON)

# ---------------------------------------------------------------------------
# JUCE
#
# Pinned, not floating. A framework this large moving underneath a build is a
# class of failure that costs an afternoon to even identify, and "it worked last
# week" is not a diagnosis. Bumping this is a deliberate one-line decision.
#
# 8.0.15 rather than 9.x: it is the final release of the mature 8 line, the
# AudioPlayHead and CMake APIs this plugin is written against are stable there,
# and a metering plugin gains nothing from 9's new features. Revisit when
# there is a reason, not on a schedule.
set(OAA_JUCE_TAG "8.0.15" CACHE STRING "JUCE release tag to build against.")

# A checkout at plugin/third_party/JUCE wins if it is there, so that a working
# tree that already paid the ~110 MB download does not pay it again, and so
# that an offline build is possible at all. Otherwise fetch it.
#
# Inside the guard, not outside it: `FetchContent_MakeAvailable` is the ten
# minutes and the 110 MB, so a build that wants neither must not reach this at
# all. Nothing below the plugin section refers to a JUCE target.
if(OAA_BUILD_PLUGIN)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/third_party/JUCE/CMakeLists.txt")
    message(STATUS "Open Audio Analyzer: using vendored JUCE at third_party/JUCE")
    add_subdirectory(third_party/JUCE EXCLUDE_FROM_ALL)
  else()
    message(STATUS "Open Audio Analyzer: fetching JUCE ${OAA_JUCE_TAG}")
    include(FetchContent)
    FetchContent_Declare(JUCE
      GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
      GIT_TAG        ${OAA_JUCE_TAG}
      GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(JUCE)
  endif()
else()
  message(STATUS "Open Audio Analyzer: no JUCE — building liboaa and its tests only")
endif()

# ---------------------------------------------------------------------------
# liboaa
#
# Built from source rather than located as an installed package. The plugin and
# the engine are versioned together in one repository and there is no scenario
# where you want this plugin against a different engine than the one beside it
# — that is exactly the stale-library case oaa.h's ABI assertion exists to
# catch, and not creating the opportunity is better than catching it.
#
# The plugin never opens a file: the DAW hands it audio. So the decode sources
# and their dr_libs dependency are switched off, which is a couple of hundred
# kilobytes of vendored MP3 and FLAC decoders that would otherwise be linked
# into every plugin bundle to do nothing.
set(OAA_BUILD_DECODE OFF CACHE BOOL "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../engine ${CMAKE_CURRENT_BINARY_DIR}/engine)

# ---------------------------------------------------------------------------
# The plugin itself, and everything that needs the framework
#
# One `if` around the lot rather than one per target: every line between here and
# the wire fixture below touches a `juce::` target, and a build with
# `-DOAA_BUILD_PLUGIN=OFF` has none of them defined.
if(OAA_BUILD_PLUGIN)

# ---------------------------------------------------------------------------
# Formats
#
# AU is an Apple technology and its build requires the macOS SDK, so asking for
# it elsewhere is not a portability problem to solve — it is a request that
# cannot be honoured. Standalone is built everywhere because it is how you test
# the socket path without opening a DAW.
set(OAA_FORMATS VST3 Standalone)
if(APPLE)
  list(APPEND OAA_FORMATS AU)
endif()

juce_add_plugin(OaaPlugin
  PRODUCT_NAME              "Open Audio Analyzer"
  COMPANY_NAME              "Open Audio Analyzer"
  COMPANY_WEBSITE           "https://github.com/JonasGrunau/open_audio_analyzer"
  # The application is `com.openaudioanalyzer.oaa`; this is that identity
  # with the format bundles hanging off it. It said
  # `io.github.jonasgrunau.bel` until the plugin was first published —
  # the rename to Open Audio Analyzer moved every other identifier and
  # missed this one, because nothing built the plugin to notice. A host
  # caches a plugin by this string, so it moves now or it never moves.
  BUNDLE_ID                 "com.openaudioanalyzer.oaa.plugin"

  # Four characters each, at least one uppercase — an Audio Unit requirement,
  # not a JUCE one, and a lowercase-only code fails validation at load time in
  # Logic rather than at build time here.
  PLUGIN_MANUFACTURER_CODE  OaaA
  PLUGIN_CODE               OaaM

  FORMATS                   ${OAA_FORMATS}

  IS_SYNTH                  FALSE
  NEEDS_MIDI_INPUT          FALSE
  NEEDS_MIDI_OUTPUT         FALSE
  IS_MIDI_EFFECT            FALSE

  # The DAW's audio is the measurement; the plugin must not alter it. Declaring
  # this lets a host place the plugin on a bus without reserving a separate
  # output buffer, and documents the intent to the next reader.
  VST3_CATEGORIES           "Analyzer" "Tools"
  AU_MAIN_TYPE              kAudioUnitType_Effect

  EDITOR_WANTS_KEYBOARD_FOCUS FALSE

  # Off deliberately. A build that silently writes into ~/Library/Audio/Plug-Ins
  # means the DAW you have open is now running a binary you did not knowingly
  # install, which is a genuinely bad surprise while iterating on the audio
  # thread. Install explicitly, or flip this in your own local cache.
  COPY_PLUGIN_AFTER_BUILD   FALSE
)

target_sources(OaaPlugin PRIVATE
  src/OaaPluginProcessor.cpp
  src/OaaPluginEditor.cpp
  src/OaaStreamer.cpp
  src/OaaWire.cpp
)

target_compile_definitions(OaaPlugin PUBLIC
  JUCE_WEB_BROWSER=0
  JUCE_USE_CURL=0

  # This plugin has no VST2 ancestor to replace, and claiming otherwise makes
  # hosts substitute it for an unrelated plugin that happens to share an ID.
  JUCE_VST3_CAN_REPLACE_VST2=0

  # Lets the editor report the format it is loaded in, which is the first thing
  # you want to know when a bug reproduces in one host and not another.
  JUCE_VST3_HOST_CROSS_PLATFORM_UUID=1

  # Note: JUCE_DISPLAY_SPLASH_SCREEN is deliberately NOT set. JUCE 8 removed
  # the splash screen, and defining the flag only earns a compiler warning
  # saying so.
)

target_link_libraries(OaaPlugin
  PRIVATE
    oaa::oaa
    juce::juce_audio_utils   # pulls in audio_basics / devices / processors
    juce::juce_gui_basics
  PUBLIC
    juce::juce_recommended_config_flags
    juce::juce_recommended_warning_flags
)

# Link-time optimisation on release builds only. It is worth having on the
# analysis path and it makes a debug build considerably slower to produce for
# no benefit at all.
target_link_libraries(OaaPlugin PUBLIC
  $<$<CONFIG:Release>:juce::juce_recommended_lto_flags>)

# ---------------------------------------------------------------------------
# Signing the macOS bundles, after everything that writes into them
#
# Every macOS bundle this directory has ever produced shipped with an invalid
# code signature, and neither the build nor CI said a word. `codesign --verify`
# on the v0.2.0 release asset, and on a Release build made the day before this
# was written:
#
#   Open Audio Analyzer.vst3: a sealed resource is missing or invalid
#   file added: Contents/Resources/moduleinfo.json
#
#   Open Audio Analyzer.component: code has no resources but signature
#   indicates they must be present
#
# Two different causes, one fix.
#
# **The VST3 is signed and then modified.** JUCE's post-build order is: link,
# copy PkgInfo, run `checkBundleSigning.cmake` — which ad-hoc signs the bundle,
# because the next step has to *load* it — and then run `vst3_helper` to write
# `Contents/Resources/moduleinfo.json`. That file lands inside a bundle whose
# resource seal was computed without it, so the seal cannot match what ships.
# JUCE's step is not wrong; it just cannot be the last one, and nothing was
# after it.
#
# **The AU and the Standalone are not bundle-signed at all.** `checkBundleSigning`
# runs only for the VST3, since only the VST3 is loaded during the build. What
# the other two carry is the ad-hoc signature the linker applies to the Mach-O
# on arm64, whose CodeDirectory declares a resource seal that no `_CodeSignature`
# directory exists to satisfy — hence the second message, from a `.component`
# whose `Contents` holds nothing but `Info.plist`, `MacOS` and `PkgInfo`.
#
# On Apple Silicon none of this is cosmetic. An invalid signature is what
# `auval` and Logic refuse an Audio Unit for, and a bundle extracted from a
# downloaded archive also carries `com.apple.quarantine`, which is Gatekeeper's
# cue to consult a signature that does not verify. It is one half of "the plugin
# does not appear in my DAW"; the other half is which folder it was copied into,
# and `README.md`'s **In a DAW** now says.
#
# `--verify --strict` on the line after the signing is the part that keeps this
# fixed. Signing a bundle that a later step invalidates is precisely the failure
# above, and it is invisible unless something asks — so the build asks on every
# build, and fails rather than producing a bundle it cannot verify. That check
# is the gate; there is no ctest for it, because a test can only run after a
# build that has already succeeded at shipping the broken thing.
#
# **`POST_BUILD` is not last, and finding that out is why this is a target.**
# The first version of this signed each bundle from `add_custom_command(TARGET
# ... POST_BUILD)`, which is genuinely after everything JUCE does — and the
# Standalone still failed its own verify, but only on a build where the bundle
# did not already exist:
#
#   Open Audio Analyzer.app: a sealed resource is missing or invalid
#   file added: Contents/Resources/RecentFilesMenuTemplate.nib
#
# A `MACOSX_PACKAGE_LOCATION` source is copied by its *own* Makefile rule, and
# that rule is a sibling of the link rule under the target's `build`
# dependency — not something the link rule contains. POST_BUILD hangs off the
# link, so make is free to copy the nib afterwards, and on a from-scratch build
# it does. The only ordering CMake guarantees across the whole of a target is a
# target-level dependency, so signing is a target that depends on the format
# rather than a command bolted to its link. It cost one deleted build directory
# to see, which is the argument for deleting one.
#
# The consequence to know: `cmake --build . --target OaaPlugin_VST3` builds the
# bundle without signing it, because the signing target is a separate one. The
# documented build — `cmake --build <dir>`, which is also what CI runs — builds
# `all` and therefore signs.
#
# Ad-hoc is the default because it is what an unnotarised free plugin can
# honestly claim. `-DOAA_CODESIGN_IDENTITY=<identity>` signs with a Developer ID
# instead; the release does not, and `README.md` says so rather than letting
# somebody discover it from Gatekeeper.
# Declared on every platform so that one `cmake` line in `ci.yml` can pass it
# to all three runners without CMake warning that nobody read it.
set(OAA_CODESIGN_IDENTITY "-" CACHE STRING
  "codesign identity for the macOS bundles. \"-\" is ad-hoc. Ignored off Apple.")

if(APPLE)
  # A secure timestamp and the hardened runtime are both *required* for
  # notarisation and neither is a default. Apple rejects a submission missing
  # either one by name, which is the good case; the bad case is what happened
  # here for four releases, where nothing was ever submitted and so nothing
  # ever objected. Ad-hoc gets neither — `--timestamp` asks Apple's timestamp
  # authority to countersign a signature with no certificate in it, and fails
  # the build of anybody who has no Developer ID and wanted a plugin.
  set(oaa_codesign_options)
  if(NOT OAA_CODESIGN_IDENTITY STREQUAL "-")
    list(APPEND oaa_codesign_options --timestamp --options runtime)
  endif()

  foreach(oaa_format IN LISTS OAA_FORMATS)
    if(TARGET OaaPlugin_${oaa_format})
      add_custom_target(OaaPlugin_${oaa_format}_signed ALL
        COMMAND codesign --force ${oaa_codesign_options}
                --sign "${OAA_CODESIGN_IDENTITY}"
                "$<TARGET_BUNDLE_DIR:OaaPlugin_${oaa_format}>"
        COMMAND codesign --verify --strict
                "$<TARGET_BUNDLE_DIR:OaaPlugin_${oaa_format}>"
        VERBATIM
        COMMENT "Signing and verifying the ${oaa_format} bundle")
      add_dependencies(OaaPlugin_${oaa_format}_signed OaaPlugin_${oaa_format})
    endif()
  endforeach()
endif()

# ---------------------------------------------------------------------------
# The fake DAW
#
# A host that plays a file through this plugin and gives it a transport, so that
# the playhead handling in OaaPluginProcessor.cpp can be exercised — by a person
# with a window, and by a test with `--headless`. See host/CMakeLists.txt for
# why it is on by default, and host/AGENTS.md for how to drive it.
#
# It is the only other thing in this repository that builds against JUCE, and it
# roughly doubles the framework compile in this directory. -DOAA_BUILD_HOST=OFF
# when you want the plugin alone.
option(OAA_BUILD_HOST "Build the fake DAW that hosts this plugin." ON)

if(OAA_BUILD_HOST)
  add_subdirectory(host)
endif()

# ---------------------------------------------------------------------------
# The transport capture test
#
# The two branches of `captureTransport` that no host can reach through a plugin
# format — a host with no playhead, and a playhead with no position. Both were
# written against the specification and never run, because neither VST3 nor an
# Audio Unit can express them and so neither a DAW nor the fake DAW can ask for
# them. See the header of test/transport_capture_test.cpp.
#
# It links `OaaPlugin` — the shipping bundle's own shared-code library — rather
# than compiling the plugin's four sources a second time. That matters beyond
# the build time it saves: the objects this test drives are the objects inside
# the VST3 and the Audio Unit, so a difference in flags between a test build and
# a plugin build cannot hide anything here.
#
# It does pay for its own copy of JUCE, which is a third framework compile in
# this directory. Linking a JUCE module adds the module's sources to the
# consuming target and there is no way to take the headers and the platform
# libraries without them. The bill lands in the gated job that already builds
# the framework twice, and the alternative — leaving the branches unrun, or
# reaching into the fake DAW, which deliberately links no part of the plugin —
# is worse than the minutes.
#
# Inside the OAA_BUILD_PLUGIN guard because it hosts an `AudioProcessor`, which
# is a JUCE class: with -DOAA_BUILD_PLUGIN=OFF there is no framework to host it
# with. The framework-free half of test/ runs on every push regardless.
add_executable(oaa_transport_capture_test test/transport_capture_test.cpp)

target_link_libraries(oaa_transport_capture_test PRIVATE
  OaaPlugin
  oaa::oaa
  juce::juce_audio_utils
  juce::juce_gui_basics
)

target_include_directories(oaa_transport_capture_test PRIVATE src)

endif()  # OAA_BUILD_PLUGIN

# ---------------------------------------------------------------------------
# The wire fixture
#
# Writes a frame pair with known values so that the C++ and Dart implementations
# of the protocol can be held against the same bytes. See the header of
# test/wire_fixture.cpp for why a cross-implementation golden is the only test
# that catches the failure that matters here.
#
# Links liboaa and nothing else — no JUCE. That is deliberate: it means the
# fixture builds on a machine with no framework, in about a second, so CI can
# run the byte-layout check without paying for a plugin build.
add_executable(oaa_wire_fixture
  test/wire_fixture.cpp
  src/OaaWire.cpp
)
target_link_libraries(oaa_wire_fixture PRIVATE oaa::oaa)
target_include_directories(oaa_wire_fixture PRIVATE src)

# The transport box's one property that a running system almost never
# contradicts: an edge is delivered exactly once. It took a loaded CI runner to
# show that it was not — see the header of test/transport_box_test.cpp — and the
# reduction to a deterministic test is two reads with no publish between them.
#
# No JUCE here either. The box is a header over `wire::Transport`, so this
# builds and runs in about a second beside the fixture.
add_executable(oaa_transport_box_test
  test/transport_box_test.cpp
  src/OaaWire.cpp
)
target_link_libraries(oaa_transport_box_test PRIVATE oaa::oaa)
target_include_directories(oaa_transport_box_test PRIVATE src)

enable_testing()

add_test(NAME transport_box_delivers_edges_once
  COMMAND oaa_transport_box_test
)

# Both halves of "the host said nothing", which is the one thing about the
# plugin's transport handling that no host can demonstrate — see the header of
# test/transport_capture_test.cpp. Only defined when there is a framework to
# host an `AudioProcessor` with.
if(TARGET oaa_transport_capture_test)
  add_test(NAME transport_capture_invents_nothing
    COMMAND oaa_transport_capture_test
  )
endif()

add_test(NAME wire_fixture_matches_golden
  COMMAND ${CMAKE_COMMAND}
    -DFIXTURE=$<TARGET_FILE:oaa_wire_fixture>
    -DGOLDEN=${CMAKE_CURRENT_SOURCE_DIR}/test/golden/wire_v3.bin
    -DSCRATCH=${CMAKE_CURRENT_BINARY_DIR}/wire_v3.actual.bin
    -P ${CMAKE_CURRENT_SOURCE_DIR}/test/compare_golden.cmake
)

add_test(NAME engine_sources_match
  COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/test/sources_match.sh
)
