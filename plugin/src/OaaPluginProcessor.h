/*
 * OaaPluginProcessor.h — the plugin itself.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * This plugin measures and does not process
 *
 * `processBlock` leaves the buffer bit-identical. That is not an implementation
 * detail to be careful about later, it is the contract: a metering insert that
 * alters the signal changes the thing it is reporting on, and every reading
 * downstream of it becomes a reading of the meter rather than of the mix.
 *
 * It also has no parameters.
 *
 * That is a deliberate refusal rather than an omission. It is tempting to
 * expose the connection settings, or the reset button, or the readings
 * themselves as `AudioProcessorParameter`s — hosts display them for free, and
 * meter-as-parameter is a common trick. All three are wrong here:
 *
 *   - Parameters are automatable and get written into the session by the host.
 *     A "reset" parameter would be recorded, and then re-fire on playback,
 *     silently clearing an integrated measurement mid-pass.
 *   - Parameters are smoothed and rate-limited by hosts. A LUFS reading routed
 *     through one is no longer the number the engine computed.
 *   - Every parameter is part of the plugin's public state forever; removing
 *     one breaks saved sessions.
 *
 * Connection settings live in the plugin's opaque state instead, which is what
 * `getStateInformation` is for and which no host will ever automate.
 */

#pragma once

#include <juce_audio_processors/juce_audio_processors.h>

#include "OaaStreamer.h"

namespace oaa {

class OaaAudioProcessor final : public juce::AudioProcessor {
public:
  OaaAudioProcessor();
  ~OaaAudioProcessor() override;

  void prepareToPlay(double sampleRate, int maximumExpectedSamplesPerBlock) override;
  void releaseResources() override;
  bool isBusesLayoutSupported(const BusesLayout& layouts) const override;
  void processBlock(juce::AudioBuffer<float>&, juce::MidiBuffer&) override;

  juce::AudioProcessorEditor* createEditor() override;
  bool hasEditor() const override { return true; }

  const juce::String getName() const override { return "Open Audio Analyzer"; }

  bool acceptsMidi() const override  { return false; }
  bool producesMidi() const override { return false; }
  bool isMidiEffect() const override { return false; }

  /* Zero, and it must stay zero. The plugin does not delay the signal, and a
   * host told otherwise would compensate for a latency that is not there —
   * shifting this track against every other one in the session. */
  double getTailLengthSeconds() const override { return 0.0; }

  int getNumPrograms() override { return 1; }
  int getCurrentProgram() override { return 0; }
  void setCurrentProgram(int) override {}
  const juce::String getProgramName(int) override { return "Default"; }
  void changeProgramName(int, const juce::String&) override {}

  void getStateInformation(juce::MemoryBlock& destData) override;
  void setStateInformation(const void* data, int sizeInBytes) override;

  Streamer& streamer() noexcept { return streamer_; }

private:
  /* Reads the host's playhead and publishes it for the streaming thread.
   * Audio thread; real-time safe. */
  void captureTransport(int numFrames) noexcept;

  Streamer streamer_;

  /* Where the previous block's playhead was, and its length, so that a jump can
   * be told from ordinary forward motion. Audio thread only. */
  double previousTimeSeconds_ = 0.0;
  double previousBlockSeconds_ = 0.0;
  bool   havePreviousPosition_ = false;

  JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(OaaAudioProcessor)
};

}  // namespace oaa
