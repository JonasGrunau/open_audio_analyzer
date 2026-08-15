/*
 * BelPluginEditor.cpp
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The palette below duplicates four values from
 * `packages/bel_ui/lib/src/tokens.dart`, and the duplication is not an
 * oversight — that file is Dart and this is C++, and there is no import that
 * crosses between them. Four constants in one small window is the cheapest
 * honest answer; the rule that no *Flutter* widget invents a colour is
 * unaffected, because nothing here is a Flutter widget.
 *
 * If the tokens move, these should follow. If this window ever needs a fifth
 * colour, that is the signal it has started becoming a meter, and it should not.
 */

#include "BelPluginEditor.h"

#include <cmath>

namespace bel {

namespace {

const juce::Colour kBackground{0xff0b0c0e};
const juce::Colour kPanel     {0xff121417};
const juce::Colour kHairline  {0xff1f2328};
const juce::Colour kText      {0xffe6e9ec};
const juce::Colour kDim       {0xff6b7278};
const juce::Colour kAccent    {0xff35e0c4};
const juce::Colour kWarn      {0xfff2b01e};
const juce::Colour kOver      {0xffff4d4d};

constexpr int kWidth  = 380;
constexpr int kHeight = 232;
constexpr int kMargin = 16;
constexpr int kRow    = 26;

/* Ten a second. The link state and the dropped count are the only things here
 * that change, and neither is a measurement anybody reads off at speed — this
 * window exists to answer "is it working", not to be watched. */
constexpr int kRefreshHz = 10;

juce::Font monoFont(float height) {
  return juce::Font(juce::FontOptions(juce::Font::getDefaultMonospacedFontName(),
                                      height, juce::Font::plain));
}

/*
 * True when two readings would render identically, NaN included.
 *
 * `NaN != NaN` is correct arithmetic and the wrong question here. Integrated
 * loudness is NaN whenever the DAW is not playing, which is most of the time a
 * plugin window is open, so a plain comparison reports "it changed" ten times a
 * second forever and repaints a window whose contents are identical.
 */
bool sameReading(float a, float b) {
  if (std::isnan(a) && std::isnan(b)) return true;
  return juce::approximatelyEqual(a, b);
}

/* An unmeasured value is an em dash, never a number. */
juce::String formatLufs(float value) {
  if (std::isnan(value))
    return juce::String::fromUTF8("—");
  if (std::isinf(value))
    return juce::String::fromUTF8("−∞ LUFS");
  return juce::String(value, 1) + " LUFS";
}

juce::String formatElapsed(double seconds) {
  const auto total = static_cast<int64_t>(seconds);
  return juce::String::formatted("%02d:%02d:%02d",
                                 static_cast<int>(total / 3600),
                                 static_cast<int>((total / 60) % 60),
                                 static_cast<int>(total % 60));
}

}  // namespace

BelPluginEditor::BelPluginEditor(BelAudioProcessor& processor)
    : juce::AudioProcessorEditor(&processor), processor_(processor) {
  auto configureLabel = [this](juce::Label& label, const juce::String& text) {
    label.setText(text, juce::dontSendNotification);
    label.setFont(monoFont(12.0f));
    label.setColour(juce::Label::textColourId, kDim);
    addAndMakeVisible(label);
  };

  auto configureField = [this](juce::TextEditor& field, const juce::String& text) {
    field.setText(text, false);
    field.setFont(monoFont(13.0f));
    field.setColour(juce::TextEditor::backgroundColourId, kPanel);
    field.setColour(juce::TextEditor::outlineColourId, kHairline);
    field.setColour(juce::TextEditor::focusedOutlineColourId, kAccent);
    field.setColour(juce::TextEditor::textColourId, kText);
    field.onReturnKey  = [this] { applyDestination(); };
    field.onFocusLost  = [this] { applyDestination(); };
    addAndMakeVisible(field);
  };

  configureLabel(hostLabel_, "Bel app host");
  configureLabel(portLabel_, "Port");
  configureField(hostField_, processor_.streamer().destinationHost());
  configureField(portField_, juce::String(processor_.streamer().destinationPort()));

  resetButton_.setColour(juce::TextButton::buttonColourId, kPanel);
  resetButton_.setColour(juce::TextButton::textColourOffId, kText);
  resetButton_.onClick = [this] { processor_.streamer().requestReset(); };
  addAndMakeVisible(resetButton_);

  setSize(kWidth, kHeight);
  startTimerHz(kRefreshHz);
}

BelPluginEditor::~BelPluginEditor() {
  stopTimer();
}

void BelPluginEditor::applyDestination() {
  const auto host = hostField_.getText().trim();
  const int  port = portField_.getText().getIntValue();

  if (host.isEmpty() || port <= 0 || port >= 65536) {
    /* Put the working values back rather than accepting nonsense. A field that
     * silently keeps an invalid entry looks like it was applied. */
    hostField_.setText(processor_.streamer().destinationHost(), false);
    portField_.setText(juce::String(processor_.streamer().destinationPort()), false);
    return;
  }

  processor_.streamer().setDestination(host, port);
}

void BelPluginEditor::timerCallback() {
  const auto next = processor_.streamer().status();

  /* Repaint only when something actually changed. A plugin window that
   * invalidates itself ten times a second forever is a measurable cost in a
   * session with several instances open, for no visible difference. */
  const bool changed =
      next.connected           != status_.connected ||
      next.everConnected       != status_.everConnected ||
      next.droppedFrames       != status_.droppedFrames ||
      next.sampleRate          != status_.sampleRate ||
      next.channels            != status_.channels ||
      next.hostGivesTransport  != status_.hostGivesTransport ||
      static_cast<int>(next.elapsedSeconds) != static_cast<int>(status_.elapsedSeconds) ||
      !sameReading(next.lufsIntegrated, status_.lufsIntegrated);

  status_ = next;
  if (changed)
    repaint();
}

void BelPluginEditor::resized() {
  auto area = getLocalBounds().reduced(kMargin);
  area.removeFromTop(kRow * 4);  // the painted status block

  auto row = area.removeFromTop(kRow);
  hostLabel_.setBounds(row.removeFromLeft(96));
  hostField_.setBounds(row.reduced(0, 2));

  area.removeFromTop(6);
  row = area.removeFromTop(kRow);
  portLabel_.setBounds(row.removeFromLeft(96));
  portField_.setBounds(row.removeFromLeft(80).reduced(0, 2));

  area.removeFromTop(10);
  resetButton_.setBounds(area.removeFromTop(kRow));
}

void BelPluginEditor::paint(juce::Graphics& g) {
  g.fillAll(kBackground);

  auto area = getLocalBounds().reduced(kMargin);

  g.setFont(monoFont(15.0f));
  g.setColour(kText);
  g.drawText("Bel", area.removeFromTop(kRow), juce::Justification::centredLeft);

  /* The link light. Three states and not two: "never connected" is a different
   * problem from "was connected and dropped", and telling them apart is most
   * of what somebody needs in order to know where to look. */
  const juce::Colour linkColour = status_.connected  ? kAccent
                                : status_.everConnected ? kWarn
                                                        : kDim;
  const juce::String linkText = status_.connected
      ? "connected"
      : (status_.everConnected ? "reconnecting" : "waiting for the Bel app");

  auto row = area.removeFromTop(kRow);
  g.setColour(linkColour);
  g.fillEllipse(static_cast<float>(row.getX()),
                static_cast<float>(row.getCentreY() - 4), 8.0f, 8.0f);
  g.setFont(monoFont(12.0f));
  g.drawText(linkText, row.withTrimmedLeft(16), juce::Justification::centredLeft);

  /* What the host is actually giving us. A session where the numbers look
   * wrong is very often a session where the plugin is on a bus carrying
   * nothing, and this is the line that says so. */
  row = area.removeFromTop(kRow);
  g.setColour(kDim);
  const juce::String format = status_.sampleRate > 0
      ? juce::String(static_cast<int>(status_.sampleRate)) + " Hz, "
            + juce::String(static_cast<int>(status_.channels)) + " ch"
      : juce::String("no audio yet");
  g.drawText(format + "   " + formatElapsed(status_.elapsedSeconds), row,
             juce::Justification::centredLeft);

  row = area.removeFromTop(kRow);
  g.setColour(status_.droppedFrames > 0 ? kOver : kDim);
  juce::String detail = "LUFS-I " + formatLufs(status_.lufsIntegrated);
  if (!status_.hostGivesTransport)
    detail += "   no playhead from host";
  if (status_.droppedFrames > 0)
    detail = juce::String(static_cast<int>(status_.droppedFrames))
        + " frames dropped — integrated reading is not trustworthy";
  g.drawText(detail, row, juce::Justification::centredLeft);

  g.setColour(kHairline);
  g.drawHorizontalLine(area.getY(), static_cast<float>(area.getX()),
                       static_cast<float>(area.getRight()));
}

}  // namespace bel
