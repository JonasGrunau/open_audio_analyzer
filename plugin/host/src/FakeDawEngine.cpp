/*
 * FakeDawEngine.cpp
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include "FakeDawEngine.h"

#include <cmath>

namespace oaa::host {

namespace {

/* Frames of read-ahead. Large enough that a spinning disk cannot make the
 * render path wait, small enough that a seek is not audibly late. */
constexpr int kReadAheadFrames = 48000;

/* Open Audio Analyzer's Audio Unit, addressed by the four-character codes
 * `plugin/CMakeLists.txt` gives it rather than by a path.
 *
 * An Audio Unit cannot be loaded from a file the way a VST3 can. macOS hands
 * out components from a registry that is populated by scanning the plug-in
 * folders, so a `.component` sitting in a build tree is invisible to
 * `AudioComponentFindNext` no matter what path you hand it — which presents as
 * "the file is right there and the host says it does not exist". The identifier
 * below is what the registry is keyed by: type `aufx` (AU_MAIN_TYPE
 * kAudioUnitType_Effect), subtype `OaaM` (PLUGIN_CODE) and manufacturer `OaaA`
 * (PLUGIN_MANUFACTURER_CODE). If any of those three move in CMakeLists.txt,
 * this moves with them.
 */
constexpr const char* kAudioUnitIdentifier = "AudioUnit:Effects/aufx,OaaM,OaaA";

/* What a built or installed Open Audio Analyzer plugin is called on disk. It is
 * PRODUCT_NAME in plugin/CMakeLists.txt. */
constexpr const char* kProductName = "Open Audio Analyzer";

}  // namespace

FakeDawEngine::FakeDawEngine() {
  audioFormats_.registerBasicFormats();

  /* Not `addDefaultFormats`, which JUCE 8 deleted: the format list now depends
   * on whether the consumer has a UI, and the free function in
   * juce_audio_processors is the one that adds the hosting formats with
   * editors. Calling the deleted member is a compile error rather than a
   * silently empty format list, which is the right way round. */
  juce::addDefaultFormatsToManager(pluginFormats_);

  readAhead_.startThread();
}

FakeDawEngine::~FakeDawEngine() {
  closeAudioDevice();
  readAhead_.stopThread(2000);

  /* The transport before the plugin: the source chain has to stop reading
   * before the thing it feeds is destroyed. */
  transport_.setSource(nullptr);
  plugin_.reset();
}

/* --------------------------------------------------------------------- */
/* The audio device                                                       */
/* --------------------------------------------------------------------- */

juce::String FakeDawEngine::openAudioDevice() {
  /* Zero inputs. Asking for one makes macOS prompt for microphone access on
   * first launch, and this host has no use for a microphone — the audio comes
   * from a file. A permission dialog nobody can explain is how a test tool
   * gets a reputation. */
  const auto error = devices_.initialiseWithDefaultDevices(0, 2);
  if (error.isNotEmpty())
    return error;

  devices_.addAudioCallback(this);
  return {};
}

void FakeDawEngine::closeAudioDevice() {
  devices_.removeAudioCallback(this);
  devices_.closeAudioDevice();
}

void FakeDawEngine::audioDeviceAboutToStart(juce::AudioIODevice* device) {
  const double rate  = device != nullptr ? device->getCurrentSampleRate() : 0.0;
  const int    frames = device != nullptr ? device->getCurrentBufferSizeSamples() : 0;

  prepare(rate > 0.0 ? rate : 48000.0, frames > 0 ? frames : 512);
}

void FakeDawEngine::audioDeviceStopped() {
  unprepare();
}

void FakeDawEngine::audioDeviceIOCallbackWithContext(const float* const*, int,
                                                     float* const* outputChannelData,
                                                     int numOutputChannels,
                                                     int numSamples,
                                                     const juce::AudioIODeviceCallbackContext&) {
  renderBlock(numSamples);
  monitorBlock(outputChannelData, numOutputChannels, numSamples);
}

/* --------------------------------------------------------------------- */
/* The graph                                                              */
/* --------------------------------------------------------------------- */

void FakeDawEngine::prepare(double sampleRate, int blockFrames) {
  unprepare();

  preparedRate_   = sampleRate;
  preparedFrames_ = blockFrames;

  /* The plugin runs at the track's own width, which is what a DAW does — a
   * stereo insert on a stereo track. `OaaAudioProcessor` accepts any symmetric
   * layout from mono to 7.1, so this always succeeds for the plugin this host
   * exists to drive; a third party plugin that refuses will report a different
   * channel count below and the status line will say so. */
  const int wanted = juce::jlimit(1, kMaxChannels, trackChannels_ > 0 ? trackChannels_ : 2);
  pluginChannels_ = wanted;

  if (plugin_ != nullptr) {
    plugin_->setPlayHead(&playHead_);
    plugin_->setPlayConfigDetails(wanted, wanted, sampleRate, blockFrames);
    plugin_->setNonRealtime(false);
    plugin_->prepareToPlay(sampleRate, blockFrames);

    /* What the plugin actually took, not what it was asked for. The buffer
     * handed to `processBlock` has to be as wide as the layout the plugin
     * prepared with, or it reads a channel that is not there — and a plugin
     * reading past the end of a buffer does not fail, it measures whatever is
     * next in memory. */
    pluginChannels_ = juce::jmax(1,
                                plugin_->getTotalNumInputChannels(),
                                plugin_->getTotalNumOutputChannels());
  }

  scratchChannels_ = juce::jlimit(1, kMaxChannels, juce::jmax(pluginChannels_, trackChannels_));
  scratch_.setSize(scratchChannels_, juce::jmax(1, blockFrames), false, true, false);

  transport_.setSource(readerSource_.get(),
                       readerSource_ != nullptr ? kReadAheadFrames : 0,
                       readerSource_ != nullptr ? &readAhead_ : nullptr,
                       trackSampleRate_,
                       scratchChannels_);
  transport_.prepareToPlay(blockFrames, sampleRate);

  /* `setSource` rewinds to zero, so without this every device change, track
   * change and plugin change would send the playhead back to the start. */
  transport_.setPosition(pendingPositionSeconds_);

  prepared_ = true;
}

void FakeDawEngine::unprepare() {
  if (!prepared_)
    return;

  pendingPositionSeconds_ = transport_.getCurrentPosition();

  transport_.setSource(nullptr);
  transport_.releaseResources();

  if (plugin_ != nullptr)
    plugin_->releaseResources();

  prepared_ = false;
}

void FakeDawEngine::reconfigure() {
  if (devices_.getCurrentAudioDevice() == nullptr) {
    /* No device: either nothing is open yet, or this is an offline run that
     * builds its graph itself. Nothing to detach and nothing to rebuild. */
    return;
  }

  const bool wasPlaying = transport_.isPlaying();
  if (wasPlaying)
    transport_.stop();

  /* `removeAudioCallback` does not return while the render path is running, so
   * on the far side of it there is provably nobody in `renderBlock`. That is
   * the whole reason this host needs no lock on the audio thread. */
  devices_.removeAudioCallback(this);
  devices_.addAudioCallback(this);

  if (wasPlaying)
    transport_.start();
}

/* --------------------------------------------------------------------- */
/* The render path                                                        */
/* --------------------------------------------------------------------- */

int FakeDawEngine::renderBlock(int numSamples) {
  if (!prepared_ || numSamples <= 0 || scratch_.getNumSamples() < numSamples)
    return 0;

  /* Before the read, because this is where the block *starts*.
   * `getNextReadPosition` afterwards is where the next one does, and handing
   * the plugin that would report every block one buffer late. */
  const double blockStartSeconds = transport_.getCurrentPosition();

  juce::AudioSourceChannelInfo info(&scratch_, 0, numSamples);
  transport_.getNextAudioBlock(info);

  TransportState state;
  state.sampleRate      = preparedRate_;
  state.positionSeconds = blockStartSeconds;
  state.positionSamples = static_cast<int64_t>(std::llround(blockStartSeconds * preparedRate_));
  state.bpm             = bpm_.load(std::memory_order_relaxed);

  const uint32_t sig = timeSig_.load(std::memory_order_relaxed);
  state.timeSigNumerator   = static_cast<int>(sig >> 16);
  state.timeSigDenominator = static_cast<int>(sig & 0xffffu);

  state.haveFrameRate = haveFrameRate_.load(std::memory_order_relaxed);
  state.frameRate     = static_cast<juce::AudioPlayHead::FrameRateType>(
      frameRate_.load(std::memory_order_relaxed));

  const bool playing = transport_.isPlaying();
  state.playing = playing;

  /* A DAW is only recording while it is rolling. Reporting `isRecording` with
   * the transport parked is a state no host produces. */
  state.recording = playing && recording_.load(std::memory_order_relaxed);

  state.looping          = looping_.load(std::memory_order_relaxed);
  state.loopStartSeconds = loopStart_.load(std::memory_order_relaxed);
  state.loopEndSeconds   = loopEnd_.load(std::memory_order_relaxed);
  state.supplyPosition   = supplyPosition_.load(std::memory_order_relaxed);

  playHead_.setState(state);

  if (plugin_ != nullptr) {
    /* A view of the scratch buffer, not a copy — `AudioBuffer` built over
     * existing pointers allocates nothing, which is the point. */
    float* channels[kMaxChannels];
    const int n = juce::jmin(pluginChannels_, scratch_.getNumChannels(), kMaxChannels);
    for (int ch = 0; ch < n; ++ch)
      channels[ch] = scratch_.getWritePointer(ch);

    juce::AudioBuffer<float> view(channels, n, numSamples);
    midi_.clear();
    plugin_->processBlock(view, midi_);
  }

  for (int ch = 0; ch < kMaxChannels; ++ch)
    peak_[ch].store(ch < scratch_.getNumChannels()
                        ? scratch_.getMagnitude(ch, 0, numSamples)
                        : 0.0f,
                    std::memory_order_relaxed);

  const double afterSeconds = transport_.getCurrentPosition();
  readPosition_.store(afterSeconds, std::memory_order_relaxed);
  readPlaying_.store(playing, std::memory_order_relaxed);
  blocks_.fetch_add(1, std::memory_order_relaxed);

  if (playing) {
    if (looping_.load(std::memory_order_relaxed)) {
      const double start = juce::jmax(0.0, loopStart_.load(std::memory_order_relaxed));
      const double end   = loopEnd_.load(std::memory_order_relaxed);

      /* Block-quantised, like most hosts: the wrap happens at the first block
       * boundary past the loop end, so a few milliseconds beyond it are played.
       * The seek itself takes a lock and wakes the read-ahead thread, which is
       * more than a render path should do — it is a property of this host and
       * not of the plugin, and it happens once per lap. It is also exactly what
       * makes the plugin raise `kDiscontinuity`, which is the point. */
      if (end > start && afterSeconds >= end)
        transport_.setPosition(start);
    } else if (transport_.hasStreamFinished()) {
      endOfTrack_.store(true, std::memory_order_relaxed);
    }
  }

  return scratch_.getNumChannels();
}

void FakeDawEngine::monitorBlock(float* const* outputChannelData,
                                 int numOutputChannels,
                                 int numSamples) {
  if (outputChannelData == nullptr)
    return;

  const bool mute      = muted_.load(std::memory_order_relaxed);
  const int  available = prepared_ ? scratch_.getNumChannels() : 0;

  for (int ch = 0; ch < numOutputChannels; ++ch) {
    auto* out = outputChannelData[ch];
    if (out == nullptr)
      continue;

    /* A mono track goes to every speaker. Sending it only to the left one
     * makes a correctly working host sound broken, which is the last thing
     * this tool should do. */
    const int source = available <= 0 ? -1 : (available == 1 ? 0 : (ch < available ? ch : -1));

    if (mute || source < 0)
      juce::FloatVectorOperations::clear(out, numSamples);
    else
      juce::FloatVectorOperations::copy(out, scratch_.getReadPointer(source), numSamples);
  }
}

/* --------------------------------------------------------------------- */
/* Offline                                                                */
/* --------------------------------------------------------------------- */

void FakeDawEngine::runOffline(const OfflineRun& run, const std::atomic<bool>& shouldStop) {
  const double rate = run.sampleRate > 0.0
                          ? run.sampleRate
                          : (trackSampleRate_ > 0.0 ? trackSampleRate_ : 48000.0);
  const int frames = juce::jlimit(16, 8192, run.blockFrames);

  prepare(rate, frames);

  const double limit = run.seconds > 0.0
                           ? run.seconds
                           : (trackLengthSeconds_ > 0.0 ? trackLengthSeconds_ : 30.0);

  transport_.setPosition(0.0);
  if (run.roll)
    transport_.start();

  const double blockSeconds = frames / rate;
  double       rendered     = 0.0;

  /* Not const: a deliberate stall re-anchors it. See the relocate below. */
  double startedAt = juce::Time::getMillisecondCounterHiRes();

  /* The relocate gesture, as two edges rather than an inner loop.
   *
   * An inner loop was the first shape and it was wrong: the parked blocks
   * bypassed the pacing below, so half a second of transport time went past in
   * microseconds of wall time, the plugin's streaming thread never woke up
   * inside it, and the app was never told the host had stopped. Every block
   * this run renders goes through the same paced iteration, and the state
   * changes happen between iterations. */
  bool   relocated         = false;
  double resumeAtRendered  = -1.0;   /* >= 0 while parked */

  const auto anchorPacing = [&] {
    startedAt = juce::Time::getMillisecondCounterHiRes()
              - (rendered / juce::jmax(1.0e-9, run.speed)) * 1000.0;
  };

  /* Half a second of parked blocks rather than a handful, and the reason is on
   * the plugin's side: its streaming thread drains everything the FIFO holds in
   * one iteration and publishes a single frame for it. So an interval measured
   * in blocks, rendered as fast as this loop can push them, arrives as one
   * frame or none however many blocks it was — the thing that makes it visible
   * is wall time, not block count, and the pacing below is what supplies that.
   * Half a second at any of the speeds used here is comfortably several
   * frames. */
  constexpr double kParkedSeconds = 0.5;

  while (!shouldStop.load(std::memory_order_relaxed) && rendered < limit) {
    renderBlock(frames);
    rendered += blockSeconds;

    if (takeEndOfTrack()) {
      /* Off the end with no loop: a DAW stops. Stopping here rather than
       * spinning out the remaining time keeps the run's length honest. */
      break;
    }

    if (resumeAtRendered >= 0.0) {
      if (rendered >= resumeAtRendered) {
        resumeAtRendered = -1.0;
        transport_.setPosition(0.0);
        transport_.start();
      }
    } else if (run.relocateAtSeconds > 0.0 && !relocated
               && rendered >= run.relocateAtSeconds) {
      relocated = true;

      /* `AudioTransportSource::stop` sets `playing` false immediately and then
       * waits up to a second for the source to acknowledge by rendering a
       * block — and the source is driven by this thread, so nothing
       * acknowledges until we return. The state it sets is already correct when
       * it returns; the wait is the price of using the public API from the
       * thread that also drives it, and it happens once per run.
       *
       * The wait is also why the pacing clock is re-anchored immediately after.
       * The schedule is "wall time since the run began" against "audio rendered
       * so far", and a second and a half of rendering nothing leaves the run
       * permanently behind it — so the wait below is never positive again, the
       * rest of the render happens flat out, and the plugin's FIFO overruns and
       * drops most of it. Measured before this line existed: the second pass of
       * this gesture reached the app as no frames at all. */
      transport_.stop();
      anchorPacing();

      resumeAtRendered = rendered + kParkedSeconds;
    }

    if (run.speed > 0.0) {
      /* Paced against the clock rather than sleeping a block at a time, so
       * that rounding does not accumulate into a run that is measurably
       * shorter than the audio it claims to have played. */
      const double dueMs = (rendered / run.speed) * 1000.0;
      const double nowMs = juce::Time::getMillisecondCounterHiRes() - startedAt;
      const int    waitMs = static_cast<int>(dueMs - nowMs);
      if (waitMs > 0)
        juce::Thread::sleep(juce::jmin(waitMs, 200));
    }
  }

  /* Deliberately not `transport_.stop()`: see the note above. At the end of a
   * run it would spend a second waiting for an acknowledgement that can never
   * arrive, on every headless invocation. `unprepare` calls
   * `setSource(nullptr)`, which clears `playing` under the callback lock and
   * returns at once. */
  unprepare();
}

/* --------------------------------------------------------------------- */
/* The track                                                              */
/* --------------------------------------------------------------------- */

juce::String FakeDawEngine::loadTrack(const juce::File& file) {
  if (!file.existsAsFile())
    return "There is no file at " + file.getFullPathName() + ".";

  std::unique_ptr<juce::AudioFormatReader> reader(audioFormats_.createReaderFor(file));
  if (reader == nullptr) {
    return file.getFileName() + " is not an audio file this host can read. "
           "WAV, AIFF, FLAC and Ogg Vorbis always work; MP3 and the Apple "
           "formats depend on the platform.";
  }

  if (reader->sampleRate <= 0.0 || reader->lengthInSamples <= 0)
    return file.getFileName() + " decodes to nothing.";

  const bool wasPlaying = transport_.isPlaying();
  if (wasPlaying)
    transport_.stop();

  /* The transport has to let go of the old source before it is destroyed, and
   * the destruction has to happen with the render path detached — so the whole
   * swap sits between `removeAudioCallback` and `addAudioCallback`, which is
   * what `reconfigure` brackets. Detaching first, mutating, then rebuilding. */
  devices_.removeAudioCallback(this);

  transport_.setSource(nullptr);

  trackSampleRate_    = reader->sampleRate;
  trackChannels_      = juce::jlimit(1, kMaxChannels, static_cast<int>(reader->numChannels));
  trackLengthSeconds_ = static_cast<double>(reader->lengthInSamples) / reader->sampleRate;
  trackFile_          = file;

  readerSource_ = std::make_unique<juce::AudioFormatReaderSource>(reader.release(), true);

  pendingPositionSeconds_ = 0.0;

  /* The loop region follows the new track rather than keeping the previous
   * one's bounds, which would silently be past the end of a shorter file. */
  loopStart_.store(0.0, std::memory_order_relaxed);
  loopEnd_.store(trackLengthSeconds_, std::memory_order_relaxed);

  devices_.addAudioCallback(this);

  if (wasPlaying)
    transport_.start();

  return {};
}

/* --------------------------------------------------------------------- */
/* The plugin                                                             */
/* --------------------------------------------------------------------- */

juce::Array<juce::File> FakeDawEngine::findBuiltPlugins() {
  juce::Array<juce::File> found;

  /* Walk up from the executable looking for the artefacts directory a JUCE
   * plugin build produces. That is more robust than a path relative to the
   * source tree, because the host is built into the same tree by the same
   * CMake run — wherever that tree is. */
  auto dir = juce::File::getSpecialLocation(juce::File::currentExecutableFile)
                 .getParentDirectory();

  for (int depth = 0; depth < 10 && dir.exists(); ++depth) {
    const auto artefacts = dir.getChildFile("OaaPlugin_artefacts");

    if (artefacts.isDirectory()) {
      /* Files and directories both: a VST3 is a bundle on macOS and Linux and
       * may be either on Windows. */
      const auto what = juce::File::findFilesAndDirectories;

      for (const auto& entry : juce::RangedDirectoryIterator(artefacts, true, "*.vst3", what))
        found.addIfNotAlreadyThere(entry.getFile());

      for (const auto& entry : juce::RangedDirectoryIterator(artefacts, true, "*.component", what))
        found.addIfNotAlreadyThere(entry.getFile());

      break;
    }

    dir = dir.getParentDirectory();
  }

  return found;
}

juce::Array<juce::PluginDescription> FakeDawEngine::scanInstalledPlugins() {
  juce::Array<juce::PluginDescription> found;

  const auto collect = [&](juce::AudioPluginFormat& format, const juce::String& identifier) {
    juce::OwnedArray<juce::PluginDescription> descriptions;
    format.findAllTypesForFile(descriptions, identifier);
    for (auto* description : descriptions)
      found.add(*description);
  };

  for (auto* format : pluginFormats_.getFormats()) {
    if (format == nullptr)
      continue;

    /* The Audio Unit is asked for by its component codes, not found by a scan.
     * Scanning every plug-in folder on the machine means instantiating every
     * plugin the user owns — minutes of work, and one badly behaved one takes
     * the host down with it. We know exactly which component we want. */
    if (format->getName().containsIgnoreCase("AudioUnit")) {
      collect(*format, kAudioUnitIdentifier);
      continue;
    }

    /* A VST3 identifier *is* a path, so the product name filters the list
     * before anything is loaded. */
    const auto candidates = format->searchPathsForPlugins(format->getDefaultLocationsToSearch(),
                                                          true, false);
    for (const auto& candidate : candidates)
      if (candidate.containsIgnoreCase(kProductName))
        collect(*format, candidate);
  }

  return found;
}

juce::String FakeDawEngine::loadPluginFromFile(const juce::File& file) {
  if (!file.exists())
    return "There is nothing at " + file.getFullPathName() + ".";

  juce::OwnedArray<juce::PluginDescription> descriptions;

  for (auto* format : pluginFormats_.getFormats()) {
    if (format != nullptr && format->fileMightContainThisPluginType(file.getFullPathName()))
      format->findAllTypesForFile(descriptions, file.getFullPathName());
  }

  if (descriptions.isEmpty()) {
    if (file.getFileName().endsWithIgnoreCase(".component")) {
      /* The single most likely reason somebody is reading this message. */
      return "macOS will not load an Audio Unit from a build tree: components come "
             "from a system registry, and a bundle that is not in a plug-in folder "
             "is not in it. Install it once and use \"Find installed\":\n\n"
             "  mkdir -p ~/Library/Audio/Plug-Ins/Components\n"
             "  ln -sfn \"" + file.getFullPathName() + "\" \\\n"
             "    ~/Library/Audio/Plug-Ins/Components/\n\n"
             "A symlink is enough, and it keeps pointing at whatever the last build "
             "produced. The VST3 beside it needs none of this.";
    }

    return "No plugin was found in " + file.getFileName() + ".";
  }

  return loadPlugin(*descriptions.getFirst());
}

juce::String FakeDawEngine::loadPlugin(const juce::PluginDescription& description) {
  const double rate   = preparedRate_ > 0.0 ? preparedRate_ : 48000.0;
  const int    frames = preparedFrames_ > 0 ? preparedFrames_ : 512;

  juce::String error;
  auto instance = pluginFormats_.createPluginInstance(description, rate, frames, error);

  if (instance == nullptr)
    return error.isNotEmpty() ? error : "The plugin could not be instantiated.";

  const bool wasPlaying = transport_.isPlaying();
  if (wasPlaying)
    transport_.stop();

  devices_.removeAudioCallback(this);

  plugin_            = std::move(instance);
  pluginDescription_ = description;

  devices_.addAudioCallback(this);

  if (wasPlaying)
    transport_.start();

  return {};
}

void FakeDawEngine::unloadPlugin() {
  const bool wasPlaying = transport_.isPlaying();
  if (wasPlaying)
    transport_.stop();

  devices_.removeAudioCallback(this);
  plugin_.reset();
  pluginDescription_ = {};
  devices_.addAudioCallback(this);

  if (wasPlaying)
    transport_.start();
}

/* --------------------------------------------------------------------- */
/* The transport                                                          */
/* --------------------------------------------------------------------- */

void FakeDawEngine::play() {
  if (readerSource_ == nullptr)
    return;

  /* Off the end, and asked to play again: a DAW returns to the start rather
   * than sitting there doing nothing. */
  if (transport_.getCurrentPosition() >= trackLengthSeconds_ - 1.0e-3)
    transport_.setPosition(0.0);

  transport_.start();
}

void FakeDawEngine::stop() { transport_.stop(); }

bool FakeDawEngine::isPlaying() const { return transport_.isPlaying(); }

void FakeDawEngine::setPositionSeconds(double seconds) {
  pendingPositionSeconds_ = juce::jmax(0.0, seconds);
  transport_.setPosition(pendingPositionSeconds_);
}

double FakeDawEngine::positionSeconds() const {
  return readPosition_.load(std::memory_order_relaxed);
}

void FakeDawEngine::setTempo(double bpm) {
  bpm_.store(juce::jlimit(1.0, 999.0, bpm), std::memory_order_relaxed);
}

void FakeDawEngine::setTimeSignature(int numerator, int denominator) {
  const uint32_t packed = (static_cast<uint32_t>(juce::jlimit(1, 64, numerator)) << 16)
                        | static_cast<uint32_t>(juce::jlimit(1, 64, denominator));
  timeSig_.store(packed, std::memory_order_relaxed);
}

int FakeDawEngine::timeSigNumerator() const {
  return static_cast<int>(timeSig_.load(std::memory_order_relaxed) >> 16);
}

int FakeDawEngine::timeSigDenominator() const {
  return static_cast<int>(timeSig_.load(std::memory_order_relaxed) & 0xffffu);
}

void FakeDawEngine::setFrameRate(bool supplied, juce::AudioPlayHead::FrameRateType rate) {
  frameRate_.store(static_cast<int>(rate), std::memory_order_relaxed);
  haveFrameRate_.store(supplied, std::memory_order_relaxed);
}

void FakeDawEngine::setRecording(bool recording) {
  recording_.store(recording, std::memory_order_relaxed);
}

void FakeDawEngine::setLooping(bool looping) {
  looping_.store(looping, std::memory_order_relaxed);
}

void FakeDawEngine::setLoopRegion(double startSeconds, double endSeconds) {
  loopStart_.store(juce::jmax(0.0, startSeconds), std::memory_order_relaxed);
  loopEnd_.store(juce::jmax(0.0, endSeconds), std::memory_order_relaxed);
}

void FakeDawEngine::setSupplyPosition(bool supply) {
  supplyPosition_.store(supply, std::memory_order_relaxed);
}

void FakeDawEngine::setMuted(bool muted) {
  muted_.store(muted, std::memory_order_relaxed);
}

/* --------------------------------------------------------------------- */
/* Readout                                                                */
/* --------------------------------------------------------------------- */

FakeDawEngine::Readout FakeDawEngine::readout() const {
  Readout out;
  out.positionSeconds = readPosition_.load(std::memory_order_relaxed);
  out.playing         = readPlaying_.load(std::memory_order_relaxed);
  out.sampleRate      = preparedRate_;
  out.blockFrames     = preparedFrames_;
  out.channels        = scratchChannels_;
  out.blocks          = blocks_.load(std::memory_order_relaxed);

  for (int ch = 0; ch < kMaxChannels; ++ch)
    out.peak[ch] = peak_[ch].load(std::memory_order_relaxed);

  return out;
}

bool FakeDawEngine::takeEndOfTrack() noexcept {
  return endOfTrack_.exchange(false, std::memory_order_relaxed);
}

}  // namespace oaa::host
