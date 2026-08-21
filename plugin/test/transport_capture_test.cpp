/*
 * transport_capture_test.cpp — the two ways a host can say nothing.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * The branch no host can ask for
 *
 * `OaaAudioProcessor::captureTransport` answers two questions before it reads
 * a single value: is there a playhead at all, and does it have a position? A
 * "no" to either publishes an empty transport, which is what makes the
 * application draw dashes instead of bar 1 beat 1 at 120 bpm.
 *
 * **Neither answer can be produced through VST3 or an Audio Unit,** and that
 * includes the fake DAW, which loads the shipping bundle the way a DAW does.
 * JUCE's VST3 host maps a host with no playhead and a playhead with no position
 * onto the same thing — `toProcessContext` zeroes a `ProcessContext`, sets its
 * sample rate and leaves every validity flag clear — and the plugin's own VST3
 * wrapper then reports `timeInSamples` and `timeInSeconds` from it
 * unconditionally. So a plugin loaded as a format is told *parked at zero,
 * tempo unknown* where the host said nothing at all, which is the correct
 * reading of what the format delivered and is not this branch. The Audio Unit
 * wrapper scopes a playhead around every render and answers `getPosition()`
 * unconditionally too, so it cannot say either thing.
 *
 * That left both guards written against the specification and never run, which
 * `README.md` carried as a known gap. This is what closes it: the processor is
 * hosted as the C++ object it is, with no format wrapper in between, because
 * that is the only place either branch exists at all.
 *
 * ---------------------------------------------------------------------------
 * Why it asserts on the box rather than on a socket
 *
 * `TransportBox` is the plugin's own hand-off from the audio thread to the
 * streaming thread, and reading it needs no network, no second process and no
 * timing at all. What a socket carried is
 * `packages/oaa_wire/test/plugin_e2e_test.dart`'s business, for every case a
 * format can actually express.
 *
 * The third case is a control. Two tests asserting that a struct is empty pass
 * just as well when the processor has stopped publishing anything, so one
 * playhead here answers, and the same assertions have to see it.
 */

#include <cstdio>
#include <cstdlib>

#include "OaaPluginProcessor.h"

namespace {

int failures = 0;

void check(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

constexpr double kSampleRate  = 48000.0;
constexpr int    kBlockFrames = 512;

/* There, and with nothing to say. An offline renderer does this, and so does a
 * validation harness; JUCE's `Optional` return exists for exactly this. */
class SilentPlayHead final : public juce::AudioPlayHead {
public:
  juce::Optional<PositionInfo> getPosition() const override { return juce::nullopt; }
};

/* The control: a host that answers. Three values and their presence, which is
 * the least a real host reports. */
class TalkingPlayHead final : public juce::AudioPlayHead {
public:
  juce::Optional<PositionInfo> getPosition() const override {
    PositionInfo info;
    info.setTimeInSamples(static_cast<juce::int64>(kSampleRate));
    info.setTimeInSeconds(1.0);
    info.setBpm(120.0);
    info.setIsPlaying(true);
    return info;
  }
};

/* One block's worth of what the plugin says about its host: the transport it
 * published, and the one line its own status panel draws from it. */
struct Published {
  oaa::wire::Transport transport;
  bool                 hostGivesTransport = false;
};

/*
 * One block through the processor, and the transport it published for it.
 *
 * The returned value starts as nonsense rather than as a default `Transport`,
 * because every assertion below is about a field being *absent*: a `read` that
 * loses its race leaves its argument untouched, and a zeroed struct would pass
 * the empty cases while proving nothing at all.
 */
Published publishedFor(juce::AudioPlayHead* playHead) {
  oaa::OaaAudioProcessor processor;

  /* Nowhere, deliberately. Constructing the processor starts its streaming
   * thread, which would otherwise reach for the real port and attach to
   * whatever application the developer has open — a test that quietly connects
   * to a running program can be affected by it. Port 1 is refused immediately
   * on every platform this builds for. */
  processor.streamer().setDestination("127.0.0.1", 1);

  processor.setPlayHead(playHead);
  processor.setPlayConfigDetails(2, 2, kSampleRate, kBlockFrames);
  processor.prepareToPlay(kSampleRate, kBlockFrames);

  juce::AudioBuffer<float> buffer(2, kBlockFrames);
  buffer.clear();
  juce::MidiBuffer midi;
  processor.processBlock(buffer, midi);

  Published published;
  published.transport.flags       = 0xffffffffu;
  published.transport.hostFrames  = 0xffffffffu;
  published.transport.timeSeconds = -1.0;
  published.transport.bpm         = -1.0;

  check(processor.streamer().transport().read(published.transport),
        "the processor published a transport for the block it ran");

  /* Read from the same place the plugin's editor reads it, after a block has
   * run: the panel's "no playhead from host" line has to describe the host
   * rather than describe the fact that audio is flowing. */
  published.hostGivesTransport = processor.streamer().status().hostGivesTransport;

  processor.releaseResources();
  return published;
}

void aHostWithNoPlayHeadIsNotFilledIn() {
  const auto [transport, hostGivesTransport] = publishedFor(nullptr);

  check(transport.flags == 0u, "no playhead: not one value is claimed present");
  check(transport.timeSeconds == 0.0, "no playhead: and no value is carried");
  check(transport.bpm == 0.0, "no playhead: including the tempo");

  /* The one thing that is still true, and the reason this is an empty transport
   * rather than no transport: the plugin knows how long the block was, because
   * it was handed it. */
  check(transport.hostFrames == static_cast<uint32_t>(kBlockFrames),
        "no playhead: the block is still described");

  check(!hostGivesTransport, "no playhead: and the plugin's panel says so");
}

void aPlayHeadWithNoPositionIsNotFilledIn() {
  SilentPlayHead playHead;
  const auto [transport, hostGivesTransport] = publishedFor(&playHead);

  check(transport.flags == 0u, "no position: not one value is claimed present");
  check(transport.timeSeconds == 0.0, "no position: and no value is carried");
  check(transport.bpm == 0.0, "no position: including the tempo");
  check(transport.hostFrames == static_cast<uint32_t>(kBlockFrames),
        "no position: the block is still described");

  check(!hostGivesTransport, "no position: and the plugin's panel says so");
}

void aPlayHeadThatAnswersIsReported() {
  TalkingPlayHead playHead;
  const auto [transport, hostGivesTransport] = publishedFor(&playHead);

  check((transport.flags & oaa::wire::kHasTimeSeconds) != 0u,
        "a position is reported as present");
  check((transport.flags & oaa::wire::kHasBpm) != 0u, "so is a tempo");
  check((transport.flags & oaa::wire::kPlaying) != 0u, "so is rolling");
  check(transport.timeSeconds == 1.0, "and the position is the one given");
  check(transport.bpm == 120.0, "and the tempo is the one given");

  /* Nothing was invented in the other direction either: this playhead reports
   * no time signature, and the wire must not claim one. */
  check((transport.flags & oaa::wire::kHasTimeSig) == 0u,
        "a value the host did not give is still absent");

  /* And the control for the two assertions above: the panel's line is about the
   * host, so it has to move when the host does. */
  check(hostGivesTransport, "a host that answers is reported as giving one");
}

}  // namespace

int main() {
  /* An `AudioProcessor` outside a plugin bundle still expects JUCE to be
   * running: the streaming thread, the leak detector and `juce::String`'s pools
   * all belong to it. */
  const juce::ScopedJuceInitialiser_GUI juce;

  aHostWithNoPlayHeadIsNotFilledIn();
  aPlayHeadWithNoPositionIsNotFilledIn();
  aPlayHeadThatAnswersIsReported();

  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return EXIT_FAILURE;
  }

  std::printf("transport_capture: OK\n");
  return EXIT_SUCCESS;
}
