/*
 * FakeDawComponent.cpp
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include "FakeDawComponent.h"

#include <cmath>

namespace oaa::host {

namespace {

constexpr int kRowHeight = 26;
constexpr int kGap       = 6;
constexpr int kMargin    = 12;

juce::String formatSeconds(double seconds) {
  if (!std::isfinite(seconds) || seconds < 0.0)
    seconds = 0.0;

  const int minutes = static_cast<int>(seconds) / 60;
  const double rest = seconds - minutes * 60.0;

  return juce::String(minutes) + ":" + juce::String(rest, 1).paddedLeft('0', 4);
}

/* The frame-rate menu, in the order a person expects to read it rather than
 * the order the enum happens to be in. Item ids start at 1 because a ComboBox
 * uses 0 for "nothing selected". */
struct FrameRateChoice {
  const char*                        label;
  bool                               supplied;
  juce::AudioPlayHead::FrameRateType rate;
};

const FrameRateChoice kFrameRates[] = {
  { "23.976 fps", true,  juce::AudioPlayHead::fps23976    },
  { "24 fps",     true,  juce::AudioPlayHead::fps24       },
  { "25 fps",     true,  juce::AudioPlayHead::fps25       },
  { "29.97 fps",  true,  juce::AudioPlayHead::fps2997     },
  { "29.97 drop", true,  juce::AudioPlayHead::fps2997drop },
  { "30 fps",     true,  juce::AudioPlayHead::fps30       },
  { "30 drop",    true,  juce::AudioPlayHead::fps30drop   },
  { "60 fps",     true,  juce::AudioPlayHead::fps60       },
  { "60 drop",    true,  juce::AudioPlayHead::fps60drop   },
  { "none",       false, juce::AudioPlayHead::fps25       },
};

void styleNumberEditor(juce::TextEditor& editor, const juce::String& text) {
  editor.setMultiLine(false);
  editor.setReturnKeyStartsNewLine(false);
  editor.setJustification(juce::Justification::centredRight);
  editor.setInputRestrictions(8, "0123456789.");
  editor.setText(text, false);
}

void styleCaption(juce::Label& label, const juce::String& text) {
  label.setText(text, juce::dontSendNotification);
  label.setJustificationType(juce::Justification::centredRight);
  label.setMinimumHorizontalScale(1.0f);
}

}  // namespace

/* --------------------------------------------------------------------- */
/* The plugin's own window                                                */
/* --------------------------------------------------------------------- */

namespace {

/*
 * `setContentOwned` is correct here even though the processor created the
 * editor: `AudioProcessorEditor`'s destructor calls `editorBeingDeleted` on its
 * processor, so the plugin learns about it either way. What is *not* safe is
 * outliving the plugin — every path that replaces or unloads one closes this
 * window first.
 */
class PluginWindow final : public juce::DocumentWindow {
public:
  PluginWindow(juce::AudioPluginInstance& plugin, std::function<void()> onClose)
      : juce::DocumentWindow(plugin.getName(),
                             juce::Colours::black,
                             juce::DocumentWindow::closeButton),
        onClose_(std::move(onClose)) {
    setUsingNativeTitleBar(true);

    if (auto* editor = plugin.createEditorAndMakeActive()) {
      setContentOwned(editor, true);
      setResizable(editor->isResizable(), false);
    } else {
      auto* notice = new juce::Label({}, "This plugin has no editor.");
      notice->setJustificationType(juce::Justification::centred);
      notice->setSize(320, 120);
      setContentOwned(notice, true);
    }

    centreWithSize(getWidth(), getHeight());
    setVisible(true);
  }

  void closeButtonPressed() override {
    if (onClose_)
      onClose_();
  }

private:
  std::function<void()> onClose_;
};

}  // namespace

/* --------------------------------------------------------------------- */
/* Construction                                                           */
/* --------------------------------------------------------------------- */

FakeDawComponent::FakeDawComponent(FakeDawEngine& engine) : engine_(engine) {
  heading_.setText("Fake DAW", juce::dontSendNotification);
  heading_.setFont(juce::FontOptions(18.0f, juce::Font::bold));
  addAndMakeVisible(heading_);

  pluginLabel_.setJustificationType(juce::Justification::centredLeft);
  addAndMakeVisible(pluginLabel_);
  addAndMakeVisible(loadPluginButton_);
  addAndMakeVisible(findBuiltButton_);
  addAndMakeVisible(findInstalledButton_);
  addAndMakeVisible(pluginWindowButton_);

  loadPluginButton_.onClick    = [this] { choosePlugin(); };
  findBuiltButton_.onClick     = [this] { findBuiltPlugin(); };
  findInstalledButton_.onClick = [this] { findInstalledPlugin(); };
  pluginWindowButton_.onClick  = [this] { togglePluginWindow(); };

  trackLabel_.setJustificationType(juce::Justification::centredLeft);
  addAndMakeVisible(trackLabel_);
  addAndMakeVisible(loadTrackButton_);
  loadTrackButton_.onClick = [this] { chooseTrack(); };

  addAndMakeVisible(playButton_);
  addAndMakeVisible(stopButton_);
  playButton_.onClick = [this] {
    if (engine_.isPlaying())
      engine_.stop();
    else
      engine_.play();
  };
  stopButton_.onClick = [this] {
    engine_.stop();
    engine_.setPositionSeconds(0.0);
  };

  positionSlider_.setSliderStyle(juce::Slider::LinearHorizontal);
  positionSlider_.setTextBoxStyle(juce::Slider::NoTextBox, true, 0, 0);
  positionSlider_.setRange(0.0, 1.0, 0.001);
  positionSlider_.onValueChange = [this] {
    if (!updatingFromTimer_)
      engine_.setPositionSeconds(positionSlider_.getValue());
  };
  addAndMakeVisible(positionSlider_);

  timeLabel_.setJustificationType(juce::Justification::centredRight);
  addAndMakeVisible(timeLabel_);

  styleCaption(bpmCaption_, "Tempo");
  addAndMakeVisible(bpmCaption_);
  styleNumberEditor(bpmEditor_, "120");
  bpmEditor_.onReturnKey  = [this] { pushTempoFromEditors(); };
  bpmEditor_.onFocusLost  = [this] { pushTempoFromEditors(); };
  addAndMakeVisible(bpmEditor_);

  styleCaption(sigCaption_, "Time sig");
  addAndMakeVisible(sigCaption_);
  styleNumberEditor(sigNumeratorEditor_, "4");
  styleNumberEditor(sigDenominatorEditor_, "4");
  sigNumeratorEditor_.onReturnKey   = [this] { pushTempoFromEditors(); };
  sigNumeratorEditor_.onFocusLost   = [this] { pushTempoFromEditors(); };
  sigDenominatorEditor_.onReturnKey = [this] { pushTempoFromEditors(); };
  sigDenominatorEditor_.onFocusLost = [this] { pushTempoFromEditors(); };
  addAndMakeVisible(sigNumeratorEditor_);
  addAndMakeVisible(sigDenominatorEditor_);

  styleCaption(frameRateCaption_, "Timecode");
  addAndMakeVisible(frameRateCaption_);
  for (int i = 0; i < juce::numElementsInArray(kFrameRates); ++i)
    frameRateBox_.addItem(kFrameRates[i].label, i + 1);
  frameRateBox_.setSelectedId(3, juce::dontSendNotification);  // 25 fps
  frameRateBox_.onChange = [this] {
    const int index = frameRateBox_.getSelectedId() - 1;
    if (juce::isPositiveAndBelow(index, juce::numElementsInArray(kFrameRates)))
      engine_.setFrameRate(kFrameRates[index].supplied, kFrameRates[index].rate);
  };
  addAndMakeVisible(frameRateBox_);

  addAndMakeVisible(loopButton_);
  loopButton_.onClick = [this] { engine_.setLooping(loopButton_.getToggleState()); };

  styleCaption(loopCaption_, "region");
  addAndMakeVisible(loopCaption_);
  styleNumberEditor(loopStartEditor_, "0");
  styleNumberEditor(loopEndEditor_, "0");
  loopStartEditor_.onReturnKey = [this] { pushLoopFromEditors(); };
  loopStartEditor_.onFocusLost = [this] { pushLoopFromEditors(); };
  loopEndEditor_.onReturnKey   = [this] { pushLoopFromEditors(); };
  loopEndEditor_.onFocusLost   = [this] { pushLoopFromEditors(); };
  addAndMakeVisible(loopStartEditor_);
  addAndMakeVisible(loopEndEditor_);

  addAndMakeVisible(recordButton_);
  recordButton_.onClick = [this] { engine_.setRecording(recordButton_.getToggleState()); };

  playheadButton_.setToggleState(true, juce::dontSendNotification);
  playheadButton_.setTooltip("Off makes the host report no transport at all, "
                             "which is the case the plugin answers with dashes.");
  addAndMakeVisible(playheadButton_);
  playheadButton_.onClick = [this] { engine_.setSupplyPosition(playheadButton_.getToggleState()); };

  addAndMakeVisible(muteButton_);
  muteButton_.onClick = [this] { engine_.setMuted(muteButton_.getToggleState()); };

  addAndMakeVisible(audioSettingsButton_);
  audioSettingsButton_.onClick = [this] { showAudioSettings(); };

  transportLabel_.setJustificationType(juce::Justification::centredLeft);
  addAndMakeVisible(transportLabel_);

  deviceLabel_.setJustificationType(juce::Justification::centredLeft);
  addAndMakeVisible(deviceLabel_);

  messageLabel_.setJustificationType(juce::Justification::topLeft);
  addAndMakeVisible(messageLabel_);

  refreshPluginLabel();
  refreshTrackLabel();

  setWantsKeyboardFocus(true);
  setSize(720, 470);
  startTimerHz(30);
}

FakeDawComponent::~FakeDawComponent() {
  stopTimer();
  closePluginWindow();
  audioWindow_.reset();
}

/* --------------------------------------------------------------------- */
/* The command line                                                       */
/* --------------------------------------------------------------------- */

void FakeDawComponent::applyOptions(const Options& options) {
  engine_.setTempo(options.bpm);
  engine_.setTimeSignature(options.timeSigNumerator, options.timeSigDenominator);
  engine_.setFrameRate(options.haveFrameRate, options.frameRate);
  engine_.setRecording(options.record);
  engine_.setSupplyPosition(options.supplyPosition);
  engine_.setMuted(options.mute);

  /* Read back rather than echoed: the engine clamps, and a field showing 1500
   * next to a transport running at 999 is a readout that disagrees with the
   * thing being tested. */
  bpmEditor_.setText(juce::String(engine_.bpm(), 2), false);
  sigNumeratorEditor_.setText(juce::String(engine_.timeSigNumerator()), false);
  sigDenominatorEditor_.setText(juce::String(engine_.timeSigDenominator()), false);
  recordButton_.setToggleState(options.record, juce::dontSendNotification);
  playheadButton_.setToggleState(options.supplyPosition, juce::dontSendNotification);
  muteButton_.setToggleState(options.mute, juce::dontSendNotification);

  for (int i = 0; i < juce::numElementsInArray(kFrameRates); ++i) {
    if (kFrameRates[i].supplied == options.haveFrameRate
        && (!options.haveFrameRate || kFrameRates[i].rate == options.frameRate)) {
      frameRateBox_.setSelectedId(i + 1, juce::dontSendNotification);
      break;
    }
  }

  if (options.track != juce::File())
    loadTrack(options.track);

  if (options.plugin != juce::File())
    loadPlugin(options.plugin);
  else
    findBuiltPlugin();

  const double end = options.loopEnd >= 0.0 ? options.loopEnd : engine_.trackLengthSeconds();
  engine_.setLoopRegion(options.loopStart, end);
  engine_.setLooping(options.loop);
  loopButton_.setToggleState(options.loop, juce::dontSendNotification);
  loopStartEditor_.setText(juce::String(options.loopStart, 2), false);
  loopEndEditor_.setText(juce::String(end, 2), false);

  if (options.play)
    engine_.play();
}

/* --------------------------------------------------------------------- */
/* Loading                                                                */
/* --------------------------------------------------------------------- */

void FakeDawComponent::chooseTrack() {
  chooser_ = std::make_unique<juce::FileChooser>(
      "Choose a track to play",
      engine_.trackFile() != juce::File() ? engine_.trackFile().getParentDirectory()
                                          : juce::File::getSpecialLocation(juce::File::userMusicDirectory),
      "*.wav;*.aiff;*.aif;*.flac;*.ogg;*.mp3;*.m4a");

  chooser_->launchAsync(juce::FileBrowserComponent::openMode
                            | juce::FileBrowserComponent::canSelectFiles,
                        [this](const juce::FileChooser& chooser) {
                          const auto file = chooser.getResult();
                          if (file.existsAsFile())
                            loadTrack(file);
                        });
}

void FakeDawComponent::choosePlugin() {
  chooser_ = std::make_unique<juce::FileChooser>(
      "Choose a VST3 or an installed Audio Unit",
      juce::File(),
      "*.vst3;*.component");

  /* Both formats are directories on macOS, so the chooser has to be willing to
   * return one. Without `canSelectDirectories` a .vst3 bundle can be opened but
   * never picked, which looks like the file being rejected. */
  chooser_->launchAsync(juce::FileBrowserComponent::openMode
                            | juce::FileBrowserComponent::canSelectFiles
                            | juce::FileBrowserComponent::canSelectDirectories,
                        [this](const juce::FileChooser& chooser) {
                          const auto file = chooser.getResult();
                          if (file != juce::File())
                            loadPlugin(file);
                        });
}

void FakeDawComponent::findBuiltPlugin() {
  const auto built = FakeDawEngine::findBuiltPlugins();

  if (built.isEmpty()) {
    say("No built plugin found above this executable. Build one with "
        "`cmake --build plugin/build`, or load it with the button.", true);
    return;
  }

  /* The VST3 in preference to the Audio Unit: it loads out of the build tree,
   * and the component does not. */
  for (const auto& file : built) {
    if (file.getFileName().endsWithIgnoreCase(".vst3")) {
      loadPlugin(file);
      return;
    }
  }

  loadPlugin(built.getFirst());
}

void FakeDawComponent::findInstalledPlugin() {
  const auto installed = engine_.scanInstalledPlugins();

  if (installed.isEmpty()) {
    say("Nothing installed. An Audio Unit has to be in a plug-in folder before "
        "macOS will hand it over:\n"
        "  ln -sfn <build>/OaaPlugin_artefacts/Release/AU/\"Open Audio Analyzer.component\" \\\n"
        "    ~/Library/Audio/Plug-Ins/Components/", true);
    return;
  }

  closePluginWindow();
  const auto error = engine_.loadPlugin(installed.getFirst());
  refreshPluginLabel();

  if (error.isNotEmpty())
    say(error, true);
  else
    say("Loaded " + installed.getFirst().name + " (" + installed.getFirst().pluginFormatName + ").", false);
}

void FakeDawComponent::loadTrack(const juce::File& file) {
  const auto error = engine_.loadTrack(file);
  refreshTrackLabel();

  if (error.isNotEmpty()) {
    say(error, true);
    return;
  }

  positionSlider_.setRange(0.0, juce::jmax(1.0, engine_.trackLengthSeconds()), 0.001);
  engine_.setLoopRegion(0.0, engine_.trackLengthSeconds());
  loopStartEditor_.setText("0.00", false);
  loopEndEditor_.setText(juce::String(engine_.trackLengthSeconds(), 2), false);
  say({}, false);
}

void FakeDawComponent::loadPlugin(const juce::File& file) {
  closePluginWindow();

  const auto error = engine_.loadPluginFromFile(file);
  refreshPluginLabel();

  if (error.isNotEmpty())
    say(error, true);
  else
    say("Loaded " + file.getFileName() + ".", false);
}

void FakeDawComponent::closePluginWindow() {
  pluginWindow_.reset();
}

void FakeDawComponent::togglePluginWindow() {
  if (pluginWindow_ != nullptr) {
    closePluginWindow();
    return;
  }

  auto* plugin = engine_.plugin();
  if (plugin == nullptr) {
    say("No plugin is loaded.", true);
    return;
  }

  pluginWindow_ = std::make_unique<PluginWindow>(*plugin, [this] { closePluginWindow(); });
}

void FakeDawComponent::showAudioSettings() {
  if (audioWindow_ != nullptr) {
    audioWindow_->toFront(true);
    return;
  }

  auto selector = std::make_unique<juce::AudioDeviceSelectorComponent>(
      engine_.devices(),
      /*minInputChannels*/ 0, /*maxInputChannels*/ 0,
      /*minOutputChannels*/ 1, /*maxOutputChannels*/ kMaxChannels,
      /*showMidiInputOptions*/ false, /*showMidiOutputSelector*/ false,
      /*showChannelsAsStereoPairs*/ true, /*hideAdvancedOptions*/ false);
  selector->setSize(500, 380);

  juce::DialogWindow::LaunchOptions launch;
  launch.content.setOwned(selector.release());
  launch.dialogTitle = "Audio device";
  launch.componentToCentreAround = this;
  launch.escapeKeyTriggersCloseButton = true;
  launch.useNativeTitleBar = true;
  launch.resizable = true;

  audioWindow_.reset(launch.create());
  if (audioWindow_ != nullptr)
    audioWindow_->setVisible(true);
}

/* --------------------------------------------------------------------- */
/* Editors                                                                */
/* --------------------------------------------------------------------- */

void FakeDawComponent::pushTempoFromEditors() {
  engine_.setTempo(bpmEditor_.getText().getDoubleValue());
  engine_.setTimeSignature(sigNumeratorEditor_.getText().getIntValue(),
                           sigDenominatorEditor_.getText().getIntValue());

  /* Written back, so that a rejected value shows what was actually taken
   * rather than leaving the field claiming something the transport is not
   * doing. */
  bpmEditor_.setText(juce::String(engine_.bpm(), 2), false);
  sigNumeratorEditor_.setText(juce::String(engine_.timeSigNumerator()), false);
  sigDenominatorEditor_.setText(juce::String(engine_.timeSigDenominator()), false);
}

void FakeDawComponent::pushLoopFromEditors() {
  engine_.setLoopRegion(loopStartEditor_.getText().getDoubleValue(),
                        loopEndEditor_.getText().getDoubleValue());

  loopStartEditor_.setText(juce::String(engine_.loopStartSeconds(), 2), false);
  loopEndEditor_.setText(juce::String(engine_.loopEndSeconds(), 2), false);
}

void FakeDawComponent::refreshPluginLabel() {
  const auto description = engine_.pluginDescription();

  if (engine_.plugin() == nullptr) {
    pluginLabel_.setText("No plugin loaded", juce::dontSendNotification);
    return;
  }

  pluginLabel_.setText(description.name + "  -  " + description.pluginFormatName
                           + "  -  " + description.manufacturerName,
                       juce::dontSendNotification);
}

void FakeDawComponent::refreshTrackLabel() {
  const auto file = engine_.trackFile();

  if (file == juce::File()) {
    trackLabel_.setText("No track loaded  -  drop an audio file here",
                        juce::dontSendNotification);
    return;
  }

  trackLabel_.setText(file.getFileName() + "  -  "
                          + juce::String(engine_.trackSampleRate() / 1000.0, 1) + " kHz, "
                          + juce::String(engine_.trackChannels()) + " ch, "
                          + formatSeconds(engine_.trackLengthSeconds()),
                      juce::dontSendNotification);
}

void FakeDawComponent::reportProblem(const juce::String& message) {
  say(message, true);
}

void FakeDawComponent::say(const juce::String& message, bool isError) {
  messageLabel_.setText(message, juce::dontSendNotification);
  messageLabel_.setColour(juce::Label::textColourId,
                          isError ? juce::Colours::orangered : juce::Colours::lightgreen);
}

/* --------------------------------------------------------------------- */
/* Files dropped on the window                                            */
/* --------------------------------------------------------------------- */

bool FakeDawComponent::isInterestedInFileDrag(const juce::StringArray& files) {
  for (const auto& name : files) {
    if (name.endsWithIgnoreCase(".vst3") || name.endsWithIgnoreCase(".component"))
      return true;
    if (juce::File(name).existsAsFile())
      return true;
  }
  return false;
}

void FakeDawComponent::filesDropped(const juce::StringArray& files, int, int) {
  for (const auto& name : files) {
    if (name.endsWithIgnoreCase(".vst3") || name.endsWithIgnoreCase(".component"))
      loadPlugin(juce::File(name));
    else
      loadTrack(juce::File(name));
  }
}

/* --------------------------------------------------------------------- */
/* Keyboard                                                               */
/* --------------------------------------------------------------------- */

bool FakeDawComponent::keyPressed(const juce::KeyPress& key) {
  /* Space, because every DAW uses space. Not a shortcut table: there is one
   * shortcut. */
  if (key == juce::KeyPress::spaceKey) {
    if (engine_.isPlaying())
      engine_.stop();
    else
      engine_.play();
    return true;
  }

  return false;
}

/* --------------------------------------------------------------------- */
/* The frame                                                              */
/* --------------------------------------------------------------------- */

void FakeDawComponent::timerCallback() {
  const auto readout = engine_.readout();

  if (engine_.takeEndOfTrack()) {
    /* The render path asked for this: it cannot stop the transport itself
     * without parking the audio thread. See FakeDawEngine::takeEndOfTrack. */
    engine_.stop();
    engine_.setPositionSeconds(0.0);
  }

  playButton_.setButtonText(readout.playing ? "Pause" : "Play");

  if (!positionSlider_.isMouseButtonDown()) {
    updatingFromTimer_ = true;
    positionSlider_.setValue(readout.positionSeconds, juce::dontSendNotification);
    updatingFromTimer_ = false;
  }

  timeLabel_.setText(formatSeconds(readout.positionSeconds) + " / "
                         + formatSeconds(engine_.trackLengthSeconds()),
                     juce::dontSendNotification);

  /* Bar and beat from the same two functions the playhead uses, so what is on
   * screen is what the plugin was told. */
  const double bpm       = engine_.bpm();
  const int    numerator = engine_.timeSigNumerator();
  const int    denominator = engine_.timeSigDenominator();
  const double ppq       = ppqFromSeconds(readout.positionSeconds, bpm);
  const double barLength = barLengthInQuarterNotes(numerator, denominator);
  const double bars      = std::floor(ppq / barLength);
  const double beat      = (ppq - bars * barLength) * denominator / 4.0;

  transportLabel_.setText(
      juce::String(engine_.isSupplyingPosition() ? "playhead" : "playhead withheld")
          + "   bar " + juce::String(static_cast<int>(bars) + 1)
          + " beat " + juce::String(static_cast<int>(beat) + 1)
          + "   ppq " + juce::String(ppq, 3)
          + "   " + juce::String(bpm, 2) + " bpm "
          + juce::String(numerator) + "/" + juce::String(denominator)
          + (readout.playing ? "   rolling" : "   stopped")
          + (engine_.isRecording() ? " + rec" : "")
          + (engine_.isLooping() ? " + loop" : ""),
      juce::dontSendNotification);

  deviceLabel_.setText(
      readout.sampleRate > 0.0
          ? juce::String(readout.sampleRate / 1000.0, 1) + " kHz, "
                + juce::String(readout.blockFrames) + " frames, "
                + juce::String(readout.channels) + " ch to the plugin, "
                + juce::String(readout.blocks) + " blocks rendered"
          : juce::String("No audio device"),
      juce::dontSendNotification);

  bool changed = false;
  for (int ch = 0; ch < kMaxChannels; ++ch) {
    if (std::abs(peak_[ch] - readout.peak[ch]) > 1.0e-4f) {
      peak_[ch] = readout.peak[ch];
      changed = true;
    }
  }
  if (changed)
    repaint(meterBounds_);
}

void FakeDawComponent::paint(juce::Graphics& g) {
  g.fillAll(getLookAndFeel().findColour(juce::ResizableWindow::backgroundColourId));

  const auto readout = engine_.readout();
  const int  channels = juce::jlimit(1, kMaxChannels, readout.channels);

  g.setColour(juce::Colours::black.withAlpha(0.35f));
  g.fillRect(meterBounds_);

  auto strip = meterBounds_.reduced(2);
  const int laneHeight = juce::jmax(3, strip.getHeight() / channels);

  for (int ch = 0; ch < channels; ++ch) {
    auto lane = strip.removeFromTop(laneHeight).reduced(0, 1);

    /* The peak of what was sent to the plugin, not a measurement — see the
     * header. Plain magnitude, so 1.0 fills the lane. */
    const float level = juce::jlimit(0.0f, 1.0f, peak_[ch]);

    g.setColour(level >= 0.999f ? juce::Colours::orangered : juce::Colours::mediumseagreen);
    g.fillRect(lane.withWidth(juce::roundToInt(static_cast<float>(lane.getWidth()) * level)));
  }

  g.setColour(juce::Colours::white.withAlpha(0.4f));
  g.drawRect(meterBounds_, 1);
}

void FakeDawComponent::resized() {
  auto area = getLocalBounds().reduced(kMargin);

  heading_.setBounds(area.removeFromTop(kRowHeight));
  area.removeFromTop(kGap);

  {
    auto row = area.removeFromTop(kRowHeight);
    pluginWindowButton_.setBounds(row.removeFromRight(110));
    row.removeFromRight(kGap);
    findInstalledButton_.setBounds(row.removeFromRight(110));
    row.removeFromRight(kGap);
    findBuiltButton_.setBounds(row.removeFromRight(90));
    row.removeFromRight(kGap);
    loadPluginButton_.setBounds(row.removeFromRight(110));
    row.removeFromRight(kGap);
    pluginLabel_.setBounds(row);
  }

  area.removeFromTop(kGap);

  {
    auto row = area.removeFromTop(kRowHeight);
    loadTrackButton_.setBounds(row.removeFromRight(110));
    row.removeFromRight(kGap);
    trackLabel_.setBounds(row);
  }

  area.removeFromTop(kGap);

  {
    auto row = area.removeFromTop(kRowHeight);
    playButton_.setBounds(row.removeFromLeft(80));
    row.removeFromLeft(kGap);
    stopButton_.setBounds(row.removeFromLeft(70));
    row.removeFromLeft(kGap);
    timeLabel_.setBounds(row.removeFromRight(130));
    row.removeFromRight(kGap);
    positionSlider_.setBounds(row);
  }

  area.removeFromTop(kGap);

  {
    auto row = area.removeFromTop(kRowHeight);
    bpmCaption_.setBounds(row.removeFromLeft(60));
    row.removeFromLeft(kGap);
    bpmEditor_.setBounds(row.removeFromLeft(60));
    row.removeFromLeft(kGap * 2);
    sigCaption_.setBounds(row.removeFromLeft(78));
    row.removeFromLeft(kGap);
    sigNumeratorEditor_.setBounds(row.removeFromLeft(42));
    row.removeFromLeft(kGap / 2);
    sigDenominatorEditor_.setBounds(row.removeFromLeft(42));
    row.removeFromLeft(kGap * 2);
    frameRateCaption_.setBounds(row.removeFromLeft(88));
    row.removeFromLeft(kGap);
    frameRateBox_.setBounds(row.removeFromLeft(120));
  }

  area.removeFromTop(kGap);

  {
    auto row = area.removeFromTop(kRowHeight);
    loopButton_.setBounds(row.removeFromLeft(70));
    row.removeFromLeft(kGap);
    loopCaption_.setBounds(row.removeFromLeft(60));
    row.removeFromLeft(kGap);
    loopStartEditor_.setBounds(row.removeFromLeft(70));
    row.removeFromLeft(kGap / 2);
    loopEndEditor_.setBounds(row.removeFromLeft(70));
    row.removeFromLeft(kGap * 2);
    recordButton_.setBounds(row.removeFromLeft(140));
  }

  area.removeFromTop(kGap);

  {
    auto row = area.removeFromTop(kRowHeight);
    playheadButton_.setBounds(row.removeFromLeft(150));
    row.removeFromLeft(kGap);
    muteButton_.setBounds(row.removeFromLeft(120));
    row.removeFromLeft(kGap);
    audioSettingsButton_.setBounds(row.removeFromLeft(130));
  }

  area.removeFromTop(kGap * 2);

  meterBounds_ = area.removeFromTop(48);
  area.removeFromTop(kGap);

  transportLabel_.setBounds(area.removeFromTop(kRowHeight));
  deviceLabel_.setBounds(area.removeFromTop(kRowHeight));
  area.removeFromTop(kGap);
  messageLabel_.setBounds(area);
}

}  // namespace oaa::host
