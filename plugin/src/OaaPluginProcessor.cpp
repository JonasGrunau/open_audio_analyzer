/*
 * OaaPluginProcessor.cpp
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include "OaaPluginProcessor.h"

#include "OaaPluginEditor.h"

namespace oaa {

namespace {

/*
 * JUCE 8's `FrameRate` carries a base rate plus drop and pull-down flags, which
 * is a better model than the flat enum it replaced. The wire carries the flat
 * enum anyway, so that a Dart consumer can switch on a `u32` rather than
 * reimplement the class — see the table in OaaWire.h.
 *
 * Anything not in the table is "unknown" rather than a nearest guess. A
 * timecode display showing 30 fps for a session running at 23.976 is off by
 * a quarter of a second per second, and it looks entirely correct while it
 * does it.
 */
uint32_t toWireFrameRate(juce::AudioPlayHead::FrameRate rate) {
  const int  base     = rate.getBaseRate();
  const bool drop     = rate.isDrop();
  const bool pullDown = rate.isPullDown();

  switch (base) {
    case 24: return pullDown ? 0u : 1u;               // 23.976 : 24
    case 25: return drop || pullDown ? 99u : 2u;      // 25 has no drop variant
    case 30:
      if (pullDown) return drop ? 5u : 3u;            // 29.97 drop : 29.97
      return drop ? 6u : 4u;                          // 30 drop    : 30
    case 60:
      if (pullDown) return 99u;                       // no 59.94 code exists
      return drop ? 8u : 7u;                          // 60 drop    : 60
    default: return wire::kFrameRateUnknown;
  }
}

}  // namespace

OaaAudioProcessor::OaaAudioProcessor()
    : juce::AudioProcessor(
          BusesProperties()
              .withInput("Input", juce::AudioChannelSet::stereo(), true)
              .withOutput("Output", juce::AudioChannelSet::stereo(), true)) {}

OaaAudioProcessor::~OaaAudioProcessor() = default;

/* --------------------------------------------------------------------- */
/* Buses                                                                  */
/* --------------------------------------------------------------------- */

bool OaaAudioProcessor::isBusesLayoutSupported(const BusesLayout& layouts) const {
  const auto& in  = layouts.getMainInputChannelSet();
  const auto& out = layouts.getMainOutputChannelSet();

  if (in.isDisabled() || in != out)
    return false;

  /* The engine's graph is channel-count agnostic up to 7.1, which is what the
   * Digital Meter renders, so that is the ceiling here too. Accepting a wider
   * layout would mean silently measuring only the first eight channels of it. */
  return in.size() >= 1 && in.size() <= static_cast<int>(OAA_MAX_CHANNELS);
}

/* --------------------------------------------------------------------- */
/* Lifecycle                                                              */
/* --------------------------------------------------------------------- */

void OaaAudioProcessor::prepareToPlay(double sampleRate, int maximumExpectedSamplesPerBlock) {
  /* Everything that allocates happens here, because the host guarantees this
   * does not run concurrently with processBlock — and because nothing that
   * allocates is allowed to happen there. */
  streamer_.prepare(sampleRate, getTotalNumInputChannels(),
                    maximumExpectedSamplesPerBlock);
}

void OaaAudioProcessor::releaseResources() {
  streamer_.release();
}

/* --------------------------------------------------------------------- */
/* The audio thread                                                       */
/* --------------------------------------------------------------------- */

void OaaAudioProcessor::captureTransport(int numFrames) noexcept {
  wire::Transport t;
  t.hostFrames = static_cast<uint32_t>(numFrames);

  /* Only legal to call from here, and only for this block. */
  auto* playHead = getPlayHead();
  if (playHead == nullptr) {
    /* A host that supplies no playhead at all is a normal thing — offline
     * renderers and some validation harnesses do not. Publishing the empty
     * transport is what tells the display to show dashes rather than leaving
     * it drawing whatever the last host said. */
    streamer_.transport().publish(t);
    return;
  }

  const auto position = playHead->getPosition();
  if (!position.hasValue()) {
    streamer_.transport().publish(t);
    return;
  }

  if (position->getIsPlaying())   t.flags |= wire::kPlaying;
  if (position->getIsRecording()) t.flags |= wire::kRecording;
  if (position->getIsLooping())   t.flags |= wire::kLooping;

  /* Each of these is separately optional and hosts genuinely differ in which
   * they fill in. A value that is absent stays zero and its presence bit stays
   * clear — see the long note in OaaWire.h on why a missing value must not
   * arrive as a plausible-looking zero. */
  if (const auto v = position->getTimeInSeconds()) {
    t.timeSeconds = *v;
    t.flags |= wire::kHasTimeSeconds;
  }
  if (const auto v = position->getTimeInSamples()) {
    t.timeSamples = *v;
    t.flags |= wire::kHasTimeSamples;
  }
  if (const auto v = position->getPpqPosition()) {
    t.ppqPosition = *v;
    t.flags |= wire::kHasPpq;
  }
  if (const auto v = position->getPpqPositionOfLastBarStart()) {
    t.ppqBarStart = *v;
    t.flags |= wire::kHasBarStart;
  }
  if (const auto v = position->getBpm()) {
    t.bpm = *v;
    t.flags |= wire::kHasBpm;
  }
  if (const auto v = position->getTimeSignature()) {
    t.timeSigNumerator   = static_cast<uint32_t>(v->numerator);
    t.timeSigDenominator = static_cast<uint32_t>(v->denominator);
    t.flags |= wire::kHasTimeSig;
  }
  if (const auto v = position->getFrameRate()) {
    t.frameRate = toWireFrameRate(*v);
    if (t.frameRate != wire::kFrameRateUnknown)
      t.flags |= wire::kHasTimecode;
  }
  if (const auto v = position->getEditOriginTime()) {
    t.editOriginSeconds = *v;
  }
  if (const auto v = position->getLoopPoints()) {
    t.loopStartPpq = v->ppqStart;
    t.loopEndPpq   = v->ppqEnd;
    t.flags |= wire::kHasLoopPoints;
  }

  /*
   * Did the playhead arrive where the last block left it?
   *
   * Ordinary playback advances by exactly one block. Anything else — a
   * relocate, a loop wrapping round, a scrub — means the audio the engine is
   * about to be handed does not continue the audio it was handed last time,
   * and an integrated reading taken across that boundary averages two
   * different passes of the same music into one number.
   *
   * The tolerance is half a block rather than a sample: hosts report the
   * position at block start with their own rounding, and a strict comparison
   * would raise this flag on every callback of a perfectly normal playback.
   * A relocate worth noticing moves considerably further than that.
   */
  if (t.flags & wire::kHasTimeSeconds) {
    const double blockSeconds = getSampleRate() > 0.0
        ? numFrames / getSampleRate()
        : 0.0;

    if (havePreviousPosition_) {
      const double expected = previousTimeSeconds_ + previousBlockSeconds_;
      const double tolerance = juce::jmax(blockSeconds, previousBlockSeconds_) * 0.5;
      if (std::abs(t.timeSeconds - expected) > tolerance)
        t.flags |= wire::kDiscontinuity;
    }

    previousTimeSeconds_  = t.timeSeconds;
    previousBlockSeconds_ = blockSeconds;
    havePreviousPosition_ = true;
  } else {
    // A host that stops reporting a position has not moved the playhead — it
    // has stopped saying. Forgetting the last one keeps the next report from
    // being compared against something arbitrarily old.
    havePreviousPosition_ = false;
  }

  streamer_.transport().publish(t);
}

void OaaAudioProcessor::processBlock(juce::AudioBuffer<float>& buffer,
                                     juce::MidiBuffer&) {
  juce::ScopedNoDenormals noDenormals;

  const int numIn  = getTotalNumInputChannels();
  const int numOut = getTotalNumOutputChannels();

  /* Output channels the host did not also give us as inputs hold whatever was
   * in them last time round. JUCE reuses the buffer, so leaving them is not
   * "silence by default" — it is the previous block, played again. */
  for (int ch = numIn; ch < numOut; ++ch)
    buffer.clear(ch, 0, buffer.getNumSamples());

  captureTransport(buffer.getNumSamples());
  streamer_.pushAudio(buffer);

  /* And that is the whole of it. The buffer is not touched again: see the
   * header on why a meter that alters the signal is measuring itself. */
}

/* --------------------------------------------------------------------- */
/* State                                                                  */
/* --------------------------------------------------------------------- */

void OaaAudioProcessor::getStateInformation(juce::MemoryBlock& destData) {
  juce::ValueTree state("OaaPluginState");
  state.setProperty("host", streamer_.destinationHost(), nullptr);
  state.setProperty("port", streamer_.destinationPort(), nullptr);

  juce::MemoryOutputStream stream(destData, false);
  state.writeToStream(stream);
}

void OaaAudioProcessor::setStateInformation(const void* data, int sizeInBytes) {
  if (data == nullptr || sizeInBytes <= 0)
    return;

  const auto state = juce::ValueTree::readFromData(data, static_cast<size_t>(sizeInBytes));
  if (!state.isValid() || !state.hasType("OaaPluginState"))
    return;

  const auto host = state.getProperty("host", "127.0.0.1").toString();
  const int  port = static_cast<int>(state.getProperty("port", kDefaultPort));

  /* A port outside the legal range means the state is from a different plugin
   * or a corrupted session. Falling back is better than asking the socket
   * layer to connect to nonsense on every retry for the life of the session. */
  streamer_.setDestination(host.isEmpty() ? "127.0.0.1" : host,
                           (port > 0 && port < 65536) ? port : kDefaultPort);
}

juce::AudioProcessorEditor* OaaAudioProcessor::createEditor() {
  return new OaaPluginEditor(*this);
}

}  // namespace oaa

/*
 * The host's entry point. Everything above is in `namespace oaa`; this must not
 * be, because JUCE looks it up unqualified.
 */
juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter() {
  return new oaa::OaaAudioProcessor();
}
