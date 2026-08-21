/*
 * FakeDawComponent.h — the window.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * This deliberately draws no meters
 *
 * It would be easy, and it would be the same mistake `plugin/AGENTS.md`
 * describes: a second implementation of every measurement's presentation, in a
 * place nobody looks, disagreeing with the application. The one number this
 * window shows is the peak of what it sent, and that is here for a single
 * diagnostic purpose — to tell "the plugin is not receiving audio" apart from
 * "the plugin is receiving audio and not reporting it", which are the two
 * things you cannot distinguish from the app alone.
 *
 * Everything the plugin measures is read in the application. That is the
 * architecture, and this window is the thing that feeds it.
 */

#pragma once

#include <juce_audio_utils/juce_audio_utils.h>   // AudioDeviceSelectorComponent
#include <juce_gui_extra/juce_gui_extra.h>

#include <memory>

#include "FakeDawEngine.h"
#include "FakeDawOptions.h"

namespace oaa::host {

class FakeDawComponent final : public juce::Component,
                               private juce::Timer,
                               public juce::FileDragAndDropTarget {
public:
  explicit FakeDawComponent(FakeDawEngine& engine);
  ~FakeDawComponent() override;

  /* Applies whatever the command line asked for, and reports what it could not
   * do in the window rather than on a terminal nobody is watching. */
  void applyOptions(const Options& options);

  /* Something went wrong before the window existed — a device that would not
   * open, usually. It belongs on screen: a person who double-clicked the app
   * has no terminal to read. */
  void reportProblem(const juce::String& message);

  void paint(juce::Graphics& g) override;
  void resized() override;
  bool keyPressed(const juce::KeyPress& key) override;

  bool isInterestedInFileDrag(const juce::StringArray& files) override;
  void filesDropped(const juce::StringArray& files, int x, int y) override;

private:
  void timerCallback() override;

  void chooseTrack();
  void choosePlugin();
  void findBuiltPlugin();
  void findInstalledPlugin();
  void togglePluginWindow();
  void showAudioSettings();

  void loadTrack(const juce::File& file);
  void loadPlugin(const juce::File& file);
  void closePluginWindow();

  void pushTempoFromEditors();
  void pushLoopFromEditors();
  void refreshPluginLabel();
  void refreshTrackLabel();
  void say(const juce::String& message, bool isError);

  FakeDawEngine& engine_;

  juce::Label       heading_;
  juce::Label       pluginLabel_;
  juce::TextButton  loadPluginButton_    { "Load plugin..." };
  juce::TextButton  findBuiltButton_     { "Find built" };
  juce::TextButton  findInstalledButton_ { "Find installed" };
  juce::TextButton  pluginWindowButton_  { "Plugin window" };

  juce::Label      trackLabel_;
  juce::TextButton loadTrackButton_ { "Open track..." };

  juce::TextButton playButton_ { "Play" };
  juce::TextButton stopButton_ { "Stop" };
  juce::Slider     positionSlider_;
  juce::Label      timeLabel_;

  juce::Label        bpmCaption_;
  juce::TextEditor   bpmEditor_;
  juce::Label        sigCaption_;
  juce::TextEditor   sigNumeratorEditor_;
  juce::TextEditor   sigDenominatorEditor_;
  juce::Label        frameRateCaption_;
  juce::ComboBox     frameRateBox_;

  juce::ToggleButton loopButton_    { "Loop" };
  juce::Label        loopCaption_;
  juce::TextEditor   loopStartEditor_;
  juce::TextEditor   loopEndEditor_;

  juce::ToggleButton recordButton_   { "Recording flag" };
  juce::ToggleButton playheadButton_ { "Supply playhead" };
  juce::ToggleButton muteButton_     { "Mute output" };
  juce::TextButton   audioSettingsButton_ { "Audio device..." };

  juce::Label transportLabel_;
  juce::Label deviceLabel_;
  juce::Label messageLabel_;

  /* Where the peak strip is drawn, so that a level moving fifty times a second
   * does not repaint two dozen widgets with it. */
  juce::Rectangle<int> meterBounds_;
  float                peak_[kMaxChannels] {};

  std::unique_ptr<juce::FileChooser>  chooser_;
  std::unique_ptr<juce::DocumentWindow> pluginWindow_;
  std::unique_ptr<juce::DialogWindow>   audioWindow_;

  /* The timer writes the slider and the slider writes the transport; without
   * this they write each other. */
  bool updatingFromTimer_ = false;

  JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(FakeDawComponent)
};

}  // namespace oaa::host
