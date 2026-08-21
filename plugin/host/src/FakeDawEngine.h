/*
 * FakeDawEngine.h — a DAW's audio path, with nothing else attached.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * What it does
 *
 *   file -> transport -> plugin -> monitor
 *
 * and once per block it hands the plugin a playhead, which is the part that
 * matters. Everything a DAW does that Open Audio Analyzer's plugin can observe
 * is in that sentence; everything else a DAW does — tracks, mixing, automation,
 * saving — it cannot observe, so none of it is here.
 *
 * ---------------------------------------------------------------------------
 * Two drivers, one render function
 *
 * `renderBlock` is called either by the audio device or by a plain loop on a
 * background thread with no device at all. The second one is what makes an
 * automated end-to-end test possible: a CI runner has no audio hardware, and a
 * host that can only run at the speed of a sound card is a host that can only
 * be driven by a person.
 *
 * They must stay one function. Two would mean the thing CI exercises and the
 * thing you listen to are different code, and the difference would be where
 * the bug lives.
 *
 * ---------------------------------------------------------------------------
 * How the plugin is swapped without a lock on the audio thread
 *
 * Every mutation that the render path can see — a new plugin, a new track, a
 * different channel count — happens with the device callback *detached*.
 * `AudioDeviceManager::removeAudioCallback` does not return while the callback
 * is running, so afterwards there is provably nobody in `renderBlock` and the
 * members can be replaced outright. That is why there is no `CriticalSection`
 * here and why the settings that *are* atomics (tempo, loop, mute) are exactly
 * the ones that change while rolling.
 *
 * A lock would have been shorter and would have put a mutex on the audio
 * thread of the tool whose only job is to tell you whether the plugin's audio
 * thread is well behaved.
 */

#pragma once

#include <juce_audio_devices/juce_audio_devices.h>
#include <juce_audio_formats/juce_audio_formats.h>
#include <juce_audio_processors/juce_audio_processors.h>

#include <atomic>
#include <memory>

#include "FakeDawPlayHead.h"

namespace oaa::host {

/* The widest layout `OaaAudioProcessor::isBusesLayoutSupported` accepts, which
 * is the engine's own `OAA_MAX_CHANNELS`. Hosting a wider one would mean
 * silently measuring the first eight channels of it. */
inline constexpr int kMaxChannels = 8;

class FakeDawEngine final : public juce::AudioIODeviceCallback {
public:
  FakeDawEngine();
  ~FakeDawEngine() override;

  /* --- the audio device ------------------------------------------------- */

  /*
   * Opens the default output device. Zero inputs, deliberately: asking for one
   * makes macOS prompt for microphone access, and this host has no use for a
   * microphone. Returns an error message, or an empty string.
   */
  juce::String openAudioDevice();
  void closeAudioDevice();

  juce::AudioDeviceManager& devices() noexcept { return devices_; }

  /* --- the track --------------------------------------------------------- */

  juce::String loadTrack(const juce::File& file);
  juce::File   trackFile() const { return trackFile_; }
  double       trackLengthSeconds() const { return trackLengthSeconds_; }
  double       trackSampleRate() const { return trackSampleRate_; }
  int          trackChannels() const { return trackChannels_; }

  /* --- the plugin -------------------------------------------------------- */

  /*
   * `file` is a VST3 bundle or an Audio Unit component. A VST3 loads straight
   * out of the build tree; an Audio Unit does not — see the long note in
   * the .cpp, and the error message this returns for one.
   */
  juce::String loadPluginFromFile(const juce::File& file);
  juce::String loadPlugin(const juce::PluginDescription& description);
  void         unloadPlugin();

  juce::AudioPluginInstance* plugin() const noexcept { return plugin_.get(); }
  juce::PluginDescription    pluginDescription() const { return pluginDescription_; }

  /*
   * Note what is *not* here: any way to tell the plugin where to stream.
   *
   * A DAW delivers a plugin's settings through `setStateInformation`, and it
   * would be the obvious way to pass a port through. It does not work: JUCE's
   * VST3 host wraps a plugin's state in an XML envelope of its own — base64
   * inside `<VST3PluginState><IComponent>` — so handing it the plugin's raw
   * `ValueTree` is silently discarded, and the Audio Unit host wraps state
   * differently again. Writing those envelopes here would mean this host
   * carrying a private copy of two of JUCE's internal formats, in a place where
   * the failure is a plugin that connects to the wrong port and says nothing.
   *
   * So the plugin keeps its own destination: 127.0.0.1:47822 by default, and
   * changed in its own editor, which the fake DAW puts in a window. A test
   * listens on the real port — which is the port the application listens on,
   * so the path under test is the shipping one rather than a variant of it.
   */

  /* Every Open Audio Analyzer plugin in a build tree above this executable, so
   * that the common case needs no file chooser and no system scan. */
  static juce::Array<juce::File> findBuiltPlugins();

  /* Every Open Audio Analyzer plugin installed where the operating system
   * looks. The only way to reach an Audio Unit. */
  juce::Array<juce::PluginDescription> scanInstalledPlugins();

  /* --- the transport ----------------------------------------------------- */

  void   play();
  void   stop();
  bool   isPlaying() const;
  void   setPositionSeconds(double seconds);
  double positionSeconds() const;

  void setTempo(double bpm);
  void setTimeSignature(int numerator, int denominator);
  void setFrameRate(bool supplied, juce::AudioPlayHead::FrameRateType rate);
  void setRecording(bool recording);
  void setLooping(bool looping);
  void setLoopRegion(double startSeconds, double endSeconds);
  void setSupplyPosition(bool supply);
  void setMuted(bool muted);

  double bpm() const { return bpm_.load(std::memory_order_relaxed); }
  bool   isLooping() const { return looping_.load(std::memory_order_relaxed); }
  bool   isRecording() const { return recording_.load(std::memory_order_relaxed); }
  bool   isSupplyingPosition() const { return supplyPosition_.load(std::memory_order_relaxed); }
  bool   isMuted() const { return muted_.load(std::memory_order_relaxed); }
  double loopStartSeconds() const { return loopStart_.load(std::memory_order_relaxed); }
  double loopEndSeconds() const { return loopEnd_.load(std::memory_order_relaxed); }
  int    timeSigNumerator() const;
  int    timeSigDenominator() const;

  /* --- what the screen shows --------------------------------------------- */

  /*
   * Gathered in one call so that every number on screen belongs to the same
   * block. Read individually they would not, and a peak next to a position it
   * did not come from is a readout that lies about the thing being tested.
   */
  struct Readout {
    double       positionSeconds = 0.0;
    bool         playing         = false;
    double       sampleRate      = 0.0;
    int          blockFrames     = 0;
    int          channels        = 0;
    juce::uint64 blocks          = 0;
    float        peak[kMaxChannels] {};
  };
  Readout readout() const;

  /*
   * True once, when the transport has run off the end of the track.
   *
   * The audio thread cannot stop the transport itself:
   * `AudioTransportSource::stop` sleeps until the source acknowledges, and the
   * source is us — so calling it from the render path parks the audio thread
   * for a second and then gives up without stopping anything. The message
   * thread drains this instead.
   */
  bool takeEndOfTrack() noexcept;

  /* --- driving it without a device --------------------------------------- */

  struct OfflineRun {
    double sampleRate  = 0.0;   /* 0 = follow the track */
    int    blockFrames = 512;
    double seconds     = 0.0;   /* 0 = the whole track */
    double speed       = 1.0;   /* 1 = real time, 0 = as fast as it will go */

    /*
     * False renders with the transport stopped.
     *
     * That is not an idle state to skip over: a DAW runs its audio graph
     * whether or not it is playing, so a plugin sees far more parked blocks
     * than rolling ones over a session, and the position it is handed sits
     * still while real time keeps moving. A window reaches this by not pressing
     * Play; without this switch a headless run could not reach it at all.
     */
    bool roll = true;

    /*
     * Seconds after which to stop, park briefly, jump back to the start and
     * play again. Zero never does it.
     *
     * This is the gesture `docs/WIRE.md` names when it explains why the
     * discontinuity bit exists — "plays bars 1-16, stops, drags back to bar 1,
     * plays again" — and it is the one transport move a person cannot be relied
     * on to perform on cue. A loop wrap relocates while rolling; this relocates
     * across a stop, which is a different path through the plugin's
     * continuity test.
     */
    double relocateAtSeconds = 0.0;
  };

  /*
   * Renders `run.seconds` of transport time through the plugin and returns.
   * No device, no window, no monitoring. Called from a background thread so
   * that the message thread stays free — the VST3 host layer needs it.
   */
  void runOffline(const OfflineRun& run, const std::atomic<bool>& shouldStop);

  /* --- AudioIODeviceCallback -------------------------------------------- */

  void audioDeviceIOCallbackWithContext(const float* const* inputChannelData,
                                        int numInputChannels,
                                        float* const* outputChannelData,
                                        int numOutputChannels,
                                        int numSamples,
                                        const juce::AudioIODeviceCallbackContext& context) override;
  void audioDeviceAboutToStart(juce::AudioIODevice* device) override;
  void audioDeviceStopped() override;

private:
  /* Builds the graph for a given rate and block size: the scratch buffer, the
   * transport's source chain, and the plugin's preparation. Both drivers call
   * it, and nothing else may. */
  void prepare(double sampleRate, int blockFrames);
  void unprepare();

  /* One block of audio into `scratch_`, through the plugin, with the playhead
   * set. Returns the number of channels that hold audio. */
  int renderBlock(int numSamples);

  /* `scratch_` out to the device, or silence where there is nothing to send. */
  void monitorBlock(float* const* outputChannelData, int numOutputChannels, int numSamples);

  /* Re-runs `prepare` with the callback detached, so that the render path never
   * observes a half-built graph. A no-op when there is no device open. */
  void reconfigure();

  juce::AudioDeviceManager       devices_;
  juce::AudioFormatManager       audioFormats_;
  juce::AudioPluginFormatManager pluginFormats_;

  /* The read-ahead thread the buffering source needs. Started once; a file
   * source that has to hit the disk from the audio thread is a host that
   * glitches for reasons that are not the plugin's. */
  juce::TimeSliceThread readAhead_ { "oaa fake daw read-ahead" };

  std::unique_ptr<juce::AudioFormatReaderSource> readerSource_;
  juce::AudioTransportSource                     transport_;
  juce::File                                     trackFile_;
  double                                         trackLengthSeconds_ = 0.0;
  double                                         trackSampleRate_    = 0.0;
  int                                            trackChannels_      = 0;

  std::unique_ptr<juce::AudioPluginInstance> plugin_;
  juce::PluginDescription                    pluginDescription_;
  FakeDawPlayHead                            playHead_;
  juce::MidiBuffer                           midi_;

  /* Written by `prepare`, read by the render path. Both happen with the
   * callback detached or on the driving thread itself. */
  juce::AudioBuffer<float> scratch_;
  int                      scratchChannels_ = 0;
  int                      pluginChannels_  = 0;
  double                   preparedRate_    = 0.0;
  int                      preparedFrames_  = 0;
  bool                     prepared_        = false;

  /* Where the transport should be after a rebuild. `setSource` resets the
   * source to zero, so without this every device change would rewind. */
  double pendingPositionSeconds_ = 0.0;

  /* Changed while rolling, so these are the ones that must be atomic. A pair
   * that could tear is packed into one word rather than made two atomics: a
   * block reporting 4/8 because the numerator arrived before the denominator
   * is a bar length that never existed. */
  std::atomic<double>   bpm_ { 120.0 };
  std::atomic<uint32_t> timeSig_ { (4u << 16) | 4u };
  std::atomic<int>      frameRate_ { static_cast<int>(juce::AudioPlayHead::fps25) };
  std::atomic<bool>     haveFrameRate_ { true };
  std::atomic<bool>     recording_ { false };
  std::atomic<bool>     looping_ { false };
  std::atomic<double>   loopStart_ { 0.0 };
  std::atomic<double>   loopEnd_ { 0.0 };
  std::atomic<bool>     supplyPosition_ { true };
  std::atomic<bool>     muted_ { false };

  std::atomic<double>       readPosition_ { 0.0 };
  std::atomic<bool>         readPlaying_ { false };
  std::atomic<juce::uint64> blocks_ { 0 };
  std::atomic<float>        peak_[kMaxChannels] {};
  std::atomic<bool>         endOfTrack_ { false };

  JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(FakeDawEngine)
};

}  // namespace oaa::host
