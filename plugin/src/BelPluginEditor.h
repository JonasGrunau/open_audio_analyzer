/*
 * BelPluginEditor.h — the plugin's only UI, and it draws no meters.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Why a headless plugin has an editor at all
 *
 * Because "headless" means the app draws the meters, not that the plugin is
 * allowed to be undiagnosable.
 *
 * The alternative — `hasEditor() == false` — gives you a plugin that, when the
 * Bel app is not running, or is running on the wrong port, or is behind a
 * firewall, looks *exactly* like a plugin that is working. There is no light,
 * no error, no log the user will find. The only symptom is that the meters in
 * another window do not move, and nothing anywhere connects that to this
 * plugin. That is a support burden with no upper bound.
 *
 * So this window answers precisely the questions you have when it is not
 * working: am I connected, to what, is the host giving me audio, is the host
 * giving me a playhead, and am I dropping anything. Nothing else. It is not a
 * meter and it must not grow into one — the twelve modules exist once, in
 * Dart, and a thirteenth reimplementation of a LUFS readout in C++ is exactly
 * the drift this architecture is arranged to prevent.
 */

#pragma once

#include <juce_audio_processors/juce_audio_processors.h>

#include "BelPluginProcessor.h"

namespace bel {

class BelPluginEditor final : public juce::AudioProcessorEditor,
                              private juce::Timer {
public:
  explicit BelPluginEditor(BelAudioProcessor&);
  ~BelPluginEditor() override;

  void paint(juce::Graphics&) override;
  void resized() override;

private:
  void timerCallback() override;
  void applyDestination();

  BelAudioProcessor& processor_;

  juce::Label      hostLabel_, portLabel_;
  juce::TextEditor hostField_, portField_;
  juce::TextButton resetButton_{"Reset measurement"};

  Streamer::Status status_;

  JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(BelPluginEditor)
};

}  // namespace bel
