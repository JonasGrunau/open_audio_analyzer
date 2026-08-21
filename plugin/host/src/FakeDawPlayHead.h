/*
 * FakeDawPlayHead.h — the transport reading a DAW would hand the plugin.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Why the fake DAW exists at all
 *
 * `OaaAudioProcessor::captureTransport` reads fourteen separately-optional
 * playhead values and turns them into presence bits, and the note in
 * `plugin/AGENTS.md` about a missing value not being zero is the whole reason
 * that code is shaped the way it is. Until this file existed, the only way to
 * exercise any of it was to open Logic or Reaper by hand — so the branch where
 * a host supplies *no* position, the branch where it supplies a frame rate the
 * wire has no code for, and the relocate that raises `kDiscontinuity` were all
 * written against the specification and never run.
 *
 * This is a host that can be told to do each of those on purpose.
 *
 * ---------------------------------------------------------------------------
 * Two things this deliberately does not do
 *
 * It does not override `canControlTransport`. A host that claims a plugin can
 * start its transport and then ignores the call is worse than one that says no,
 * and Open Audio Analyzer's plugin never asks — it is a sensor.
 *
 * It does not lock. `setState` runs on the audio thread once per block and
 * `getPosition` is called by the plugin from inside its own `processBlock`,
 * which is that same thread. Atomics here would be a claim about threading
 * that is not true, and would read as though somebody else might be looking.
 */

#pragma once

#include <juce_audio_basics/juce_audio_basics.h>

#include <cmath>
#include <cstdint>

namespace oaa::host {

/* Quarter notes elapsed at `seconds`. One implementation, used by the playhead
 * that the plugin reads and by the bar/beat readout on screen — two would
 * eventually disagree, and the screen is how you check the wire. */
inline double ppqFromSeconds(double seconds, double bpm) noexcept {
  return seconds * bpm / 60.0;
}

/* A bar's length in quarter notes. 6/8 is three quarter notes, not six. */
inline double barLengthInQuarterNotes(int numerator, int denominator) noexcept {
  return denominator > 0 ? numerator * 4.0 / denominator : 4.0;
}

/*
 * Everything the host knows about where the transport is, for one block.
 */
struct TransportState {
  double  sampleRate      = 0.0;
  double  positionSeconds = 0.0;
  int64_t positionSamples = 0;

  double bpm                = 120.0;
  int    timeSigNumerator   = 4;
  int    timeSigDenominator = 4;

  /* False means the host reports no timecode rate at all, which is a real
   * thing hosts do and which must leave the plugin's `kHasTimecode` clear
   * rather than defaulting to something plausible. */
  bool                               haveFrameRate = true;
  juce::AudioPlayHead::FrameRateType frameRate     = juce::AudioPlayHead::fps25;

  bool   playing          = false;
  bool   recording        = false;
  bool   looping          = false;
  double loopStartSeconds = 0.0;
  double loopEndSeconds   = 0.0;

  /* False makes `getPosition()` return nothing — the offline-renderer case the
   * plugin handles by publishing an empty transport so the display shows
   * dashes. There is no other way to reach that branch on purpose. */
  bool supplyPosition = true;
};

class FakeDawPlayHead final : public juce::AudioPlayHead {
public:
  /* Audio thread, once per block, immediately before the plugin runs. */
  void setState(const TransportState& next) noexcept { state_ = next; }

  juce::Optional<PositionInfo> getPosition() const override {
    if (!state_.supplyPosition)
      return juce::nullopt;

    PositionInfo info;

    info.setTimeInSeconds(state_.positionSeconds);
    info.setTimeInSamples(state_.positionSamples);
    info.setBpm(state_.bpm);
    info.setTimeSignature(TimeSignature{state_.timeSigNumerator, state_.timeSigDenominator});

    /* Zero, and reported rather than omitted: this host places the track at
     * the start of its timeline, so the file's first sample and bar one are
     * the same instant. A DAW with the clip dragged rightwards would report
     * the offset here. */
    info.setEditOriginTime(0.0);

    if (state_.haveFrameRate)
      info.setFrameRate(FrameRate(state_.frameRate));

    const double ppq = ppqFromSeconds(state_.positionSeconds, state_.bpm);
    info.setPpqPosition(ppq);

    const double barLength = barLengthInQuarterNotes(state_.timeSigNumerator,
                                                     state_.timeSigDenominator);
    const double bars = std::floor(ppq / barLength);
    info.setPpqPositionOfLastBarStart(bars * barLength);
    info.setBarCount(static_cast<int64_t>(bars));

    info.setIsPlaying(state_.playing);
    info.setIsRecording(state_.recording);
    info.setIsLooping(state_.looping);

    /* Loop points only while looping. A host that reports a stale loop region
     * with the loop switched off is indistinguishable, on the wire, from one
     * that is looping over it. */
    if (state_.looping)
      info.setLoopPoints(LoopPoints{ppqFromSeconds(state_.loopStartSeconds, state_.bpm),
                                    ppqFromSeconds(state_.loopEndSeconds, state_.bpm)});

    return info;
  }

private:
  TransportState state_;
};

}  // namespace oaa::host
