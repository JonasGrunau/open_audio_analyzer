# plugin/host/CMakeLists.txt — the fake DAW.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# ---------------------------------------------------------------------------
# What this builds
#
# A plugin host: it plays an audio file through Open Audio Analyzer's VST3 or
# Audio Unit, gives it a transport, and either shows you the controls or renders
# offline for a test. It exists because the plugin's playhead handling — the
# fourteen separately-optional values in `captureTransport`, the discontinuity
# on a relocate, the branch where a host supplies no position at all — could
# only be exercised by opening a DAW by hand, which meant it was written against
# the specification and never run.
#
# Nothing here ships. It is not in any installer and the release attaches no
# artefact from this directory.
#
# ---------------------------------------------------------------------------
# Licensing
#
# AGPL-3.0-or-later, like the rest of `plugin/`, and for the same reason: it
# links JUCE. It also links no part of the plugin — it loads it the way a DAW
# does, through the format's own entry point — except `src/OaaPluginState.h`,
# which is the one thing both ends have to agree on. See its header.
#
# ---------------------------------------------------------------------------
# Why it builds by default
#
# A development tool nobody builds is a development tool that stops compiling
# and nobody notices for a phase. `cmake --build plugin/build` builds it, so
# anybody working in `plugin/` finds out immediately; the CI job that compiles
# this directory runs on a release or a manual dispatch rather than on every
# push, so the extra JUCE target costs pushes nothing.
#
# Turn it off with -DOAA_BUILD_HOST=OFF when you want the plugin alone.

# Plugin *hosting*, which is a different set of JUCE sources from plugin
# building and off by default. VST3 works from a path on all three platforms;
# AU is asked for on macOS only, because JUCE links CoreAudioKit and AudioUnit
# for it and neither exists elsewhere.
set(OAA_HOST_ARGS "")
if(APPLE)
  list(APPEND OAA_HOST_ARGS PLUGINHOST_AU TRUE)
endif()

juce_add_gui_app(OaaFakeDaw
  # Deliberately a shell-friendly name with no spaces: a test spawns this
  # binary, and `plugin/build/OaaFakeDaw_artefacts/Release/oaa-fake-daw` is a
  # path you can write down. The window is titled from
  # `JUCEApplication::getApplicationName`, so the ugly filename costs nothing on
  # screen.
  PRODUCT_NAME    "oaa-fake-daw"
  COMPANY_NAME    "Open Audio Analyzer"
  COMPANY_WEBSITE "https://github.com/JonasGrunau/open_audio_analyzer"
  BUNDLE_ID       "com.openaudioanalyzer.oaa.fakedaw"
  ${OAA_HOST_ARGS}
)

target_sources(OaaFakeDaw PRIVATE
  src/FakeDawEngine.cpp
  src/FakeDawComponent.cpp
  src/FakeDawMain.cpp
)

# `src/OaaPluginState.h` is reached with a relative include rather than by
# adding the plugin's source directory to the search path, so that it stays
# obvious in the source that this host reaches into `plugin/src` for exactly
# one file and not for the processor.
target_compile_definitions(OaaFakeDaw PRIVATE
  JUCE_WEB_BROWSER=0
  JUCE_USE_CURL=0

  # VST3 hosting. The SDK is vendored by JUCE and MIT-licensed, so this adds no
  # dependency and no second copyleft — the same good news that made the plugin
  # itself possible without a separate SDK checkout.
  JUCE_PLUGINHOST_VST3=1

  # Note: JUCE_USE_MP3AUDIOFORMAT is deliberately NOT set. JUCE's own MP3
  # decoder carries a "seek your own independent advice" disclaimer about
  # third-party intellectual property, and that is the project owner's call to
  # make rather than a convenience to switch on here. FLAC, WAV, AIFF and Ogg
  # read everywhere; macOS and Windows read MP3 through their platform formats
  # regardless. `tool/fetch_test_audio.dart` downloads FLAC for this reason.
  # A Linux developer who wants MP3 adds JUCE_USE_MP3AUDIOFORMAT=1 here.
)

target_link_libraries(OaaFakeDaw
  PRIVATE
    juce::juce_audio_utils      # devices, formats, processors, and the device selector
    juce::juce_gui_extra
  PUBLIC
    juce::juce_recommended_config_flags
    juce::juce_recommended_warning_flags
)

target_link_libraries(OaaFakeDaw PUBLIC
  $<$<CONFIG:Release>:juce::juce_recommended_lto_flags>)
