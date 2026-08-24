/*
 * OaaPluginEditor.h — the plugin's only UI, and it draws no meters.
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
 * Open Audio Analyzer app is not running, or is running on the wrong port, or
 * is behind a firewall, looks *exactly* like a plugin that is working. There is
 * no light, no error, no log the user will find. The only symptom is that the
 * meters in another window do not move, and nothing anywhere connects that to
 * this plugin. That is a support burden with no upper bound.
 *
 * So this window answers precisely the questions you have when it is not
 * working: am I connected, to what, is the host giving me audio, is the host
 * giving me a playhead, and am I dropping anything. Nothing else. It is not a
 * meter and it must not grow into one — the fourteen modules exist once, in
 * Dart, and a fifteenth reimplementation of a LUFS readout in C++ is exactly
 * the drift this architecture is arranged to prevent.
 *
 * ---------------------------------------------------------------------------
 * Why the drawing is a separate component from the editor
 *
 * `StatusPanel` is the whole window; `OaaPluginEditor` is fourteen lines that
 * hand it a `Streamer::Status` ten times a second and pass its two callbacks
 * back to the processor. The split exists so that the drawing can be *seen*
 * without a DAW.
 *
 * Every other surface in this repository can be looked at by something that is
 * not a person: the application's widgets render to an image in a test, the
 * fake DAW drives the plugin's audio path headless, the CLI is a subprocess
 * with an exit code. This window could only be looked at by loading a bundle
 * into a host — and its *interesting* states, the ones it exists for, could
 * only be looked at by arranging for the link to break. So the panel takes a
 * status by value and owns no engine, and `test/editor_snapshot.cpp`
 * photographs all five states into PNGs in about a second.
 *
 * The rule that follows: nothing in `StatusPanel` may reach for a `Streamer`,
 * a processor or a socket. What it draws is the struct it was handed.
 */

#pragma once

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_gui_basics/juce_gui_basics.h>

#include "OaaPluginProcessor.h"

namespace oaa {

/*
 * A button that looks like it belongs to the instrument: a flat rectangle, one
 * hairline, `OaaRadius.sm`, and the panel's own type.
 *
 * A stock `TextButton` is a rounded grey pill in the platform's UI font, and in
 * a rack of plugins that single control is the tell — it is the one element on
 * screen that was not designed. Twenty lines here rather than a `LookAndFeel`
 * subclass, because a LookAndFeel exists to restyle widgets you did not write
 * and this window has exactly one button.
 */
class PanelButton final : public juce::Button {
public:
  explicit PanelButton(const juce::String& text) : juce::Button(text) {
    setButtonText(text);
  }

  void setFont(juce::Font font) { font_ = std::move(font); }

  void paintButton(juce::Graphics&, bool highlighted, bool down) override;

private:
  juce::Font font_{juce::FontOptions{}};
};

/*
 * The window. Everything painted, and the three controls, live here.
 *
 * Constructed with no arguments and no dependencies on purpose — see the note
 * on the snapshot tool above.
 */
class StatusPanel final : public juce::Component {
public:
  /* The window's size, and it is fixed.
   *
   * A DAW gives a plugin whatever size its editor asks for and this one is a
   * legend, a diagram and six readings — there is no content that benefits from
   * being dragged larger, and a resizable window is a window that can be left
   * in a shape the layout was never checked at. */
  static constexpr int kWidth  = 440;
  static constexpr int kHeight = 316;

  StatusPanel();
  ~StatusPanel() override;

  /* What to draw. Cheap to call: the panel repaints only the regions whose
   * content actually moved. */
  void setStatus(const Streamer::Status&);

  /* The address the fields show. Separate from `setStatus` because the user
   * types into these and the streaming thread does not own them. */
  void setDestination(const juce::String& host, int port);

  /* "AU", "VST3", "Standalone", and the host's own name when it identifies
   * itself. Printed in the header because the first question on a bug report
   * is which format in which host, and the second is why nobody wrote it down. */
  void setFormat(const juce::String& format, const juce::String& host);

  /* Both may be null — the snapshot tool sets neither. */
  std::function<void(const juce::String&, int)> onDestinationEdited;
  std::function<void()>                         onResetRequested;

  void paint(juce::Graphics&) override;
  void resized() override;

private:
  void commitDestination();

  /* The stretch of panel the travelling dashes live in, so that a link which is
   * moving frames does not invalidate the whole window ten times a second. */
  juce::Rectangle<int> streamSegmentBounds() const;

  void paintChain(juce::Graphics&, juce::Rectangle<int>);
  void paintMessage(juce::Graphics&, juce::Rectangle<int>);
  void paintCells(juce::Graphics&, juce::Rectangle<int>);

  /* Inter Medium for words, Google Sans Code Medium for numbers, both compiled
   * into the binary. `tracking` is JUCE's extra kerning factor — a proportion
   * of the height rather than a length, so a legend keeps its letter-spacing
   * when the size changes. */
  juce::Font ui(float height, float tracking = 0.0f) const;
  juce::Font mono(float height) const;

  juce::Typeface::Ptr ui_, mono_;

  /* `assets/brand/oaa-mark.svg`, compiled in. The same drawing the icons and
   * the website are generated from, rather than a second copy of the path —
   * a mark that is re-drawn per consumer is a mark that will differ per
   * consumer. */
  std::unique_ptr<juce::Drawable> mark_;

  /* The app icon's tile, in the shape Apple masks one with. Built once: the
   * window does not resize, and a hundred-point path rebuilt ten times a second
   * for a shape that cannot change is work nobody asked for. */
  juce::Path tile_;

  juce::TextEditor hostField_, portField_;
  PanelButton      resetButton_{"Reset measurement"};

  Streamer::Status status_;
  juce::String     format_{"Standalone"};
  juce::String     hostName_;

  /* How far the dashes have travelled, in seconds of measured audio.
   *
   * Not a clock. The phase advances by the change in `elapsedSeconds`, which
   * the engine advances only when a block is actually pushed through it — so
   * the dashes move when frames are moving and stop dead when they are not.
   * A light that is animated by a timer says "this code is running"; one
   * animated by the measurement says "your audio is arriving", and those are
   * different claims about a link that has gone quiet.
   *
   * It is why the same panel photographs with the dashes in different places in
   * `test/editor_snapshot.cpp`: each state carries its own elapsed time.
   */
  double streamPhase_ = 0.0;
  double lastElapsed_ = 0.0;

  JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(StatusPanel)
};

class OaaPluginEditor final : public juce::AudioProcessorEditor,
                              private juce::Timer {
public:
  explicit OaaPluginEditor(OaaAudioProcessor& owner);
  ~OaaPluginEditor() override;

  void resized() override;

private:
  void timerCallback() override;

  OaaAudioProcessor& processor_;
  StatusPanel        panel_;
  Streamer::Status   status_;

  JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(OaaPluginEditor)
};

}  // namespace oaa
