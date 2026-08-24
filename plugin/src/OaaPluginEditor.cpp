/*
 * OaaPluginEditor.cpp
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Why this window is drawn in the application's palette and the application's
 * type, rather than in something approximately like them
 *
 * A plugin window sits in a rack beside FabFilter, iZotope and whatever else is
 * on the master bus, and the user's question about it is not "is this pretty" —
 * it is "is this the same tool as the one drawing my meters". A window that
 * *nearly* matches the application answers that question wrongly: it reads as
 * something bolted on, and a diagnostic surface nobody trusts is a diagnostic
 * surface nobody reads.
 *
 * So the values below are `OaaColors.precisionInstrument` from
 * `packages/oaa_ui/lib/src/tokens.dart`, transcribed. That file is Dart and
 * this is C++ and there is no import that crosses between them; the
 * transcription is the cheapest honest answer. **If the tokens move, these
 * follow.**
 *
 * The previous version of this comment said that a fifth colour here would mean
 * the window had started becoming a meter. That was the right worry attached to
 * the wrong measurement — it had eight, and the count was never what protected
 * it. What protects it is the actual rule, so it is written plainly: **this
 * window draws no quantity as a length, an angle or a position over time.** It
 * draws a topology, a state, and four readings as text. A bar would be a meter.
 * A history would be a meter. A palette is a palette.
 *
 * ---------------------------------------------------------------------------
 * Why the two faces are compiled in
 *
 * `OaaType` bundles Inter and Google Sans Code with the application, and says
 * why: falling through to the platform's own faces means the digit width, the
 * tracking and the cap height all differ between macOS, Windows and Linux, so a
 * layout tuned on one is subtly wrong on the other two. That argument does not
 * stop at the application's edge, and this window was the counter-example —
 * `Font::getDefaultMonospacedFontName()` is Menlo here, Consolas there and
 * DejaVu Sans Mono on the third, and every row of it was set in whichever one
 * the machine happened to have.
 *
 * Two faces, not five. Inter Medium for every word and Google Sans Code Medium
 * for every number, which is `OaaType`'s split — prose and labels proportional,
 * numbers monospaced so that a readout does not change width as its digits
 * change. Weight carries no hierarchy here; size, colour and tracking do, which
 * is how a silkscreened panel does it too.
 *
 * They cost about 516 KB in a bundle whose binary is 8.4 MB, and they come from
 * `assets/fonts/` rather than a copy — see the note in `assets/AGENTS.md`.
 */

#include "OaaPluginEditor.h"

#include <array>
#include <cmath>

#include "OaaAssets.h"

namespace oaa {

namespace {

/* --- the palette, from OaaColors.precisionInstrument --------------------- */

const juce::Colour kBackground    {0xff0b0c0e};
const juce::Colour kPanel         {0xff121417};
const juce::Colour kPanelRaised   {0xff171a1e};
const juce::Colour kHairline      {0xff1f2328};
const juce::Colour kHairlineStrong{0xff5a646e};
const juce::Colour kText          {0xffe6e8eb};
const juce::Colour kMuted         {0xff8a9199};
const juce::Colour kFaint         {0xff565e67};
const juce::Colour kAccent        {0xff35e0c4};
const juce::Colour kWarn          {0xfff2b01e};
const juce::Colour kOver          {0xffff4d4d};

/* --- geometry ------------------------------------------------------------ */

/* `Space` from tokens.dart, as far as this window uses it. Nothing below is a
 * raw number for the same reason nothing in the application is: a window laid
 * out from arbitrary values drifts one pixel at a time and reads as amateur
 * long before anybody can point at which value is wrong. */
/* `Space.xxs`. tokens.dart reserves it for the gap between a value and its unit
 * "and nowhere else", which is a rule about the application's readouts; this is
 * the plugin's one other use of it, and it is here because four pixels under a
 * field legend read as too much and two read as right. */
constexpr int kXxs = 2;
constexpr int kXs  = 4;
constexpr int kSm  = 8;
constexpr int kSmd = 12;
constexpr int kMd  = 16;
constexpr int kLg  = 24;

constexpr float kRadius  = 4.0f;   // OaaRadius.sm
constexpr float kHair    = 1.0f;   // OaaStroke.hairline
constexpr float kMark    = 1.5f;   // OaaStroke.mark
constexpr float kEmphasis = 2.0f;  // OaaStroke.emphasis

constexpr int kHeaderRow   = 14;
constexpr int kChainBlock  = 84;
constexpr int kMessageRow  = 26;
constexpr int kCellBlock   = 52;
constexpr int kLegendRow   = 11;
constexpr int kControlRow  = 28;

/* Everything drawn on a *recessed* surface — the readout strip, the
 * annunciator, the two fields — insets its content by this much, so those three
 * share one column rather than each choosing its own. Chrome that sits on the
 * ground plane keeps the margin; see the field legends, which take a four-pixel
 * nudge off it and nothing like this. */
constexpr int kInset = kSmd;

/*
 * Thirty a second, and the number is chosen against the engine's rate rather
 * than picked as a round one.
 *
 * Ten was right while everything here was text: the fastest thing on screen was
 * the elapsed clock, which moves once a second. It is wrong for the travelling
 * dashes — the phase advances by however much audio the engine measured since
 * the last poll, so at 10 Hz it jumped 3.4 px every 100 ms and read as a
 * stutter rather than a flow.
 *
 * **Not 60.** `OaaStreamer` publishes at the engine's own ~47 Hz, so a 60 Hz
 * poll finds nothing new about a fifth of the time and the dashes stall for a
 * frame whenever it does — visibly worse than a slower cadence that is even.
 * Thirty sits below the publish rate, so every tick has new audio to move on.
 *
 * The cost is bounded by what a tick actually invalidates: the clock still
 * takes the whole window once a second, and everything between it repaints a
 * strip about 190 x 24 and nothing else.
 */
constexpr int kRefreshHz = 30;

/* The dashes on the socket segment advance this far per second of audio the
 * engine has measured. Slow enough to read as a flow rather than a flicker at
 * thirty frames a second, fast enough that a glance catches it. A dash period
 * passes in about a quarter of a second. */
/*
 * The app icon's shape, and it is not a rounded rectangle.
 *
 * `_Tile` in `packaging/icon/make_icons.dart` carries these two numbers and the
 * story behind them: they were *measured* off this machine rather than looked
 * up, by rendering Calculator, Notes and Maps through `NSWorkspace.icon` at
 * 1024 px, thresholding the alpha and fitting the corner of
 * `(dx/r)^n + (dy/r)^n = 1` to the silhouette. macOS 26 draws a rounder tile
 * than the 22.37%-on-a-curve-of-4 that iOS 7 introduced and that everybody
 * still quotes, and an icon built to the remembered number is visibly squarer
 * than the ones beside it in the Dock.
 *
 * Two numbers rather than the generated path, and the distinction matters:
 * `assets/AGENTS.md` forbids hand-transcribing the *mark*, which is three
 * hundred control points that `make_icons.dart` writes, and the mark is still
 * compiled in from that file rather than redrawn here. A corner radius and an
 * exponent are parameters, not artwork — the same class of thing as the palette
 * transcribed above. **If Apple changes the shape a third time, the measurement
 * is redone in `_Tile` and these follow it.**
 */
constexpr float kTileCorner   = 1.0f / 3.0f;
constexpr float kTileSquircle = 2.7f;

/* The wave occupies three quarters of the icon's square — that proportion is
 * baked into `oaa-mark.svg`, whose 1024 viewBox is the icon's own canvas, and
 * is reproduced here because `drawWithin` fits the path's bounding box and
 * throws the viewBox's padding away. */
constexpr float kTileArtInset = 0.125f;

constexpr float kTileSide = 38.0f;

/* `OaaType.reading` sets -0.5 px of letter-spacing on the numeric face and it
 * is not decoration: Google Sans Code's advance is generous, and a readout set
 * at its natural tracking reads as spaced out rather than as a number. JUCE's
 * kerning factor is a proportion of the height, so this is that -0.5 at the
 * 17 px the cells use. */
constexpr float kMonoTracking = -0.03f;

/* The dashes on the socket segment advance this far per second of audio the
 * engine has measured. Slow enough to read as a flow rather than a flicker at
 * ten frames a second, fast enough that a glance catches it. */
constexpr double kDashPixelsPerSecond = 34.0;
constexpr double kDashPeriod          = 9.0;
constexpr double kDashLength          = 4.5;

/* --- formatting ---------------------------------------------------------- */

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
    return juce::String::fromUTF8("−∞");
  return juce::String(value, 1);
}

juce::String formatElapsed(double seconds) {
  const auto total = static_cast<int64_t>(seconds);
  return juce::String::formatted("%02d:%02d:%02d",
                                 static_cast<int>(total / 3600),
                                 static_cast<int>((total / 60) % 60),
                                 static_cast<int>(total % 60));
}

/*
 * "48k · 2ch", the way an engineer says it out loud, and "44.1k" rather than
 * the "44k" that integer division produces — a rate reported as a rate it is
 * not is the same class of wrong as a measurement nobody took.
 */
juce::String formatInput(const Streamer::Status& s) {
  if (s.sampleRate == 0)
    return juce::String::fromUTF8("—");

  const juce::String rate = s.sampleRate % 1000 == 0
      ? juce::String(static_cast<int>(s.sampleRate) / 1000)
      : juce::String(static_cast<double>(s.sampleRate) / 1000.0, 1);

  return rate + juce::String::fromUTF8("k · ")
      + juce::String(static_cast<int>(s.channels)) + "ch";
}

/* Grouped from five digits, because "20480 frames dropped" and "2048 frames
 * dropped" differ by one glyph and by an order of magnitude — and not below
 * that, where a separator in a four-digit number is noise. A thin space rather
 * than a comma or a full stop, which mean opposite things either side of the
 * Atlantic. */
juce::String formatCount(uint32_t value) {
  const juce::String digits(static_cast<int>(value));
  if (digits.length() < 5)
    return digits;

  juce::String out;
  for (int i = 0; i < digits.length(); ++i) {
    if (i > 0 && (digits.length() - i) % 3 == 0)
      out += juce::String::fromUTF8("\xe2\x80\x89");
    out += digits[i];
  }
  return out;
}

/* --- drawing ------------------------------------------------------------- */

/*
 * One strand of the chain: a run of cable that is either carrying something or
 * is not.
 *
 * Solid means present, dashed means absent, and `phase` slides the dashes along
 * so that a link with frames moving through it looks different from one that is
 * merely open. Everything about the state is in the colour and the motion; the
 * geometry never changes, so the diagram does not reflow as the session does.
 */
void drawStrand(juce::Graphics& g, float x1, float x2, float y, float thickness,
                juce::Colour colour, bool solid, double phase) {
  g.setColour(colour);

  if (solid) {
    g.drawLine(x1, y, x2, y, thickness);
    return;
  }

  const auto offset = static_cast<float>(std::fmod(phase, kDashPeriod));
  for (float x = x1 + offset - static_cast<float>(kDashPeriod); x < x2;
       x += static_cast<float>(kDashPeriod)) {
    const float a = juce::jmax(x, x1);
    const float b = juce::jmin(x + static_cast<float>(kDashLength), x2);
    if (b > a)
      g.drawLine(a, y, b, y, thickness);
  }
}

/*
 * A square with superelliptical corners, in the shape Apple masks an app icon
 * with. Sampled rather than fitted with cubics: `make_icons.dart` needs six
 * Bézier segments per corner because it writes an SVG somebody else rasterises
 * at any size, and this one is drawn at 38 px into a path JUCE antialiases —
 * twenty steps a corner is under a thousandth of a pixel of chord error there,
 * and it is the formula itself rather than an approximation of it.
 */
juce::Path squirclePath(float side) {
  constexpr int kSteps = 20;

  const float r = kTileCorner * side;

  /* One corner as offsets from the bounding box's corner, running from the
   * point where the curve leaves an edge to where it meets the next. */
  std::array<juce::Point<float>, kSteps + 1> arc{};
  for (int i = 0; i <= kSteps; ++i) {
    const double u = static_cast<double>(i) / kSteps;
    const double k = std::pow(1.0 - std::pow(u, kTileSquircle), 1.0 / kTileSquircle);
    arc[static_cast<size_t>(i)] = {static_cast<float>(r * (1.0 - k)),
                                   static_cast<float>(r * (1.0 - u))};
  }

  juce::Path p;
  p.startNewSubPath(0.0f, r);

  const auto corner = [&](bool reversed,
                          juce::Point<float> (*place)(juce::Point<float>, float)) {
    for (int i = 0; i <= kSteps; ++i) {
      const auto& q = arc[static_cast<size_t>(reversed ? kSteps - i : i)];
      const auto pt = place(q, side);
      p.lineTo(pt.x, pt.y);
    }
  };

  corner(false, [](juce::Point<float> q, float) { return q; });
  p.lineTo(side - r, 0.0f);
  corner(true, [](juce::Point<float> q, float s) {
    return juce::Point<float>(s - q.x, q.y);
  });
  p.lineTo(side, side - r);
  corner(false, [](juce::Point<float> q, float s) {
    return juce::Point<float>(s - q.x, s - q.y);
  });
  p.lineTo(r, side);
  corner(true, [](juce::Point<float> q, float s) {
    return juce::Point<float>(q.x, s - q.y);
  });

  p.closeSubPath();
  return p;
}

}  // namespace

/* ------------------------------------------------------------------------- */

void PanelButton::paintButton(juce::Graphics& g, bool highlighted, bool down) {
  auto bounds = getLocalBounds().toFloat().reduced(0.5f);

  g.setColour(down ? kPanelRaised : kPanel);
  g.fillRoundedRectangle(bounds, kRadius);

  g.setColour(highlighted || down ? kHairlineStrong : kHairline);
  g.drawRoundedRectangle(bounds, kRadius, kHair);

  if (hasKeyboardFocus(false)) {
    g.setColour(kText);
    g.drawRoundedRectangle(bounds.reduced(1.5f), kRadius - 1.0f, kHair);
  }

  g.setColour(highlighted || down ? kText : kMuted);
  g.setFont(font_);
  g.drawText(getButtonText(), getLocalBounds(), juce::Justification::centred);
}

/* ------------------------------------------------------------------------- */

namespace {

/*
 * Where everything goes, computed once so that `paint` and `resized` cannot
 * disagree.
 *
 * They disagreed in the previous version — `resized` skipped `kRow * 4` to step
 * over "the painted status block" and `paint` counted the same four rows out
 * again independently, so moving one row meant editing two arithmetic
 * expressions in two functions and finding out from the screen if you missed
 * one.
 */
struct Layout {
  juce::Rectangle<int> header, chain, message, cells, addressLegend,
      addressRow, rule;

  static Layout of(juce::Rectangle<int> bounds) {
    Layout l;
    auto area = bounds.reduced(kMd);

    l.header = area.removeFromTop(kHeaderRow);
    area.removeFromTop(kSm);
    l.rule = area.removeFromTop(1);
    area.removeFromTop(kSmd);

    l.chain = area.removeFromTop(kChainBlock);
    area.removeFromTop(kMd);
    l.cells = area.removeFromTop(kCellBlock);
    area.removeFromTop(kSmd);

    /* The annunciator sits under the readings and above the Reset button,
     * because the one message that asks for an action is the dropped frame
     * count and the action is that button. A warning at the top of a window and
     * its remedy at the bottom are two things the reader has to connect;
     * adjacent, they are one. */
    l.message = area.removeFromTop(kMessageRow);

    l.addressRow = area.removeFromBottom(kControlRow);
    area.removeFromBottom(kXs);  // between a legend and the thing it labels
    l.addressLegend = area.removeFromBottom(kLegendRow);
    return l;
  }
};

}  // namespace

StatusPanel::StatusPanel() {
  ui_ = juce::Typeface::createSystemTypefaceFor(OaaAssets::InterMedium_ttf,
                                                OaaAssets::InterMedium_ttfSize);
  mono_ = juce::Typeface::createSystemTypefaceFor(
      OaaAssets::GoogleSansCodeMedium_ttf, OaaAssets::GoogleSansCodeMedium_ttfSize);

  mark_ = juce::Drawable::createFromImageData(OaaAssets::oaamark_svg,
                                              OaaAssets::oaamark_svgSize);
  /* White, like the shipped icon's wave. What the node does *not* take is the
   * icon's ground: that ramp passes exactly through `OaaColors.accent`, which in
   * this window means "something is travelling down this run of cable" and may
   * not also mean "this is the product". So the tile is an outline rather than a
   * fill — the icon drawn as line art, in one ink, spending no hue at all. */
  if (mark_ != nullptr)
    mark_->replaceColour(juce::Colours::white, kText);

  tile_ = squirclePath(kTileSide);

  auto configureField = [this](juce::TextEditor& field, const juce::String& hint) {
    field.setFont(mono(12.0f));
    field.setJustification(juce::Justification::centredLeft);
    field.setIndents(kInset, 0);
    field.setColour(juce::TextEditor::backgroundColourId, kPanel);
    field.setColour(juce::TextEditor::outlineColourId, kHairline);
    field.setColour(juce::TextEditor::focusedOutlineColourId, kText);
    field.setColour(juce::TextEditor::textColourId, kText);
    field.setColour(juce::TextEditor::highlightColourId, kHairlineStrong);
    field.setColour(juce::TextEditor::highlightedTextColourId, kText);
    field.setColour(juce::CaretComponent::caretColourId, kAccent);
    field.setTextToShowWhenEmpty(hint, kFaint);
    field.onReturnKey = [this] { commitDestination(); };
    field.onFocusLost = [this] { commitDestination(); };
    addAndMakeVisible(field);
  };

  configureField(hostField_, "127.0.0.1");
  configureField(portField_, "47822");

  resetButton_.setFont(ui(11.0f));
  resetButton_.onClick = [this] {
    if (onResetRequested) onResetRequested();
  };
  addAndMakeVisible(resetButton_);

  setSize(kWidth, kHeight);
}

StatusPanel::~StatusPanel() = default;

juce::Font StatusPanel::ui(float height, float tracking) const {
  return juce::Font(juce::FontOptions(ui_).withHeight(height))
      .withExtraKerningFactor(tracking);
}

juce::Font StatusPanel::mono(float height) const {
  return juce::Font(juce::FontOptions(mono_).withHeight(height))
      .withExtraKerningFactor(kMonoTracking);
}

void StatusPanel::setDestination(const juce::String& host, int port) {
  hostField_.setText(host, false);
  portField_.setText(juce::String(port), false);
}

void StatusPanel::setFormat(const juce::String& format, const juce::String& host) {
  format_   = format;
  hostName_ = host;
  repaint();
}

void StatusPanel::commitDestination() {
  const auto host = hostField_.getText().trim();
  const int  port = portField_.getText().getIntValue();

  if (host.isEmpty() || port <= 0 || port >= 65536 || !onDestinationEdited) {
    /* Nothing is applied and the fields say so on their own: the caller puts
     * the working values back. A field that silently keeps an invalid entry
     * looks like it was applied. */
    if (onDestinationEdited) onDestinationEdited({}, 0);
    return;
  }

  onDestinationEdited(host, port);
}

juce::Rectangle<int> StatusPanel::streamSegmentBounds() const {
  const auto chain = Layout::of(getLocalBounds()).chain;
  return chain.withTrimmedLeft(chain.getWidth() / 2)
      .withTrimmedTop(kLg)
      .withTrimmedBottom(kChainBlock - kLg - kLg);
}

void StatusPanel::setStatus(const Streamer::Status& next) {
  /*
   * Three kinds of change, and only one of them is worth the whole window.
   *
   * A plugin window that invalidates itself thirty times a second forever is a
   * measurable cost in a session with several instances open. The clock ticks
   * once a second and takes the whole window with it; the dashes move on the
   * other twenty-nine and take a strip about 190 × 24 with them.
   */
  const bool structural =
      next.connected           != status_.connected ||
      next.everConnected       != status_.everConnected ||
      next.droppedFrames       != status_.droppedFrames ||
      next.sampleRate          != status_.sampleRate ||
      next.channels            != status_.channels ||
      next.hostGivesTransport  != status_.hostGivesTransport ||
      !sameReading(next.lufsIntegrated, status_.lufsIntegrated);

  const bool tick = static_cast<int>(next.elapsedSeconds)
                 != static_cast<int>(status_.elapsedSeconds);

  const double advanced = juce::jmax(0.0, next.elapsedSeconds - lastElapsed_);
  lastElapsed_ = next.elapsedSeconds;
  if (next.connected && advanced > 0.0)
    streamPhase_ += advanced * kDashPixelsPerSecond;

  status_ = next;

  if (structural || tick)
    repaint();
  else if (advanced > 0.0 && next.connected)
    repaint(streamSegmentBounds());
}

void StatusPanel::resized() {
  const auto l = Layout::of(getLocalBounds());

  auto row = l.addressRow;
  hostField_.setBounds(row.removeFromLeft(168));
  row.removeFromLeft(kSm);
  portField_.setBounds(row.removeFromLeft(62));
  row.removeFromLeft(kSmd);
  resetButton_.setBounds(row);
}

void StatusPanel::paint(juce::Graphics& g) {
  g.fillAll(kBackground);

  const auto l = Layout::of(getLocalBounds());

  /* --- the legend bar ---------------------------------------------------
   *
   * Silkscreen, not a logo: the wordmark is set small, tracked wide and in
   * muted ink, because on a real panel the maker's name is the quietest thing
   * on it and the readings are the loudest. The mark itself is spent once, in
   * the middle of the chain below, where it is carrying meaning rather than
   * decorating a corner. */
  g.setFont(ui(9.5f, 0.22f));
  g.setColour(kMuted);
  g.drawText("OPEN AUDIO ANALYZER", l.header, juce::Justification::centredLeft);

  /* Which format, in which host. The first two facts on a bug report, and the
   * two nobody writes down — `JUCE_VST3_HOST_CROSS_PLATFORM_UUID` was switched
   * on in CMakeLists.txt so the editor could report this, and then no editor
   * ever did. */
  juce::String provenance = format_;
  if (hostName_.isNotEmpty())
    provenance += juce::String::fromUTF8(" · ") + hostName_;
  g.setFont(ui(9.5f, 0.10f));
  g.setColour(kMuted);
  g.drawText(provenance, l.header, juce::Justification::centredRight);

  g.setColour(kHairline);
  g.fillRect(l.rule);

  paintChain(g, l.chain);
  paintMessage(g, l.message);
  paintCells(g, l.cells);

  /* --- the wiring -------------------------------------------------------
   *
   * Below the readings and under their own legends, because this is the part
   * you touch once and then never again. */
  /* A nudge, so the legend is not flush with the border of the field directly
   * beneath it.
   *
   * Deliberately *not* `kInset`, which would set it over the field's own text
   * and on the same column as the readout strip's legends. That is the tidier
   * argument on paper and it is wrong on screen: a label carried that far in
   * stops reading as attached to the box under it and starts reading as a gap.
   * Four was tried and is still too much. Two breaks the alignment with the
   * border below without the label letting go of it. */
  auto legend = l.addressLegend;
  g.setFont(ui(9.0f, 0.18f));
  g.setColour(kMuted);
  g.drawText("ADDRESS", legend.removeFromLeft(168).withTrimmedLeft(kXxs),
             juce::Justification::bottomLeft);
  legend.removeFromLeft(kSm);
  g.drawText("PORT", legend.removeFromLeft(62).withTrimmedLeft(kXxs),
             juce::Justification::bottomLeft);
}

/*
 * The chain, and it is the one drawing in this window.
 *
 * Everything else here is a label or a number; this is the only element that
 * says something no sentence says as fast — *where* the failure is. The window
 * exists because a plugin whose link is down is indistinguishable from one that
 * is working, and there are exactly three places the path can be broken:
 *
 *   the host is not giving this plugin audio        left segment, upper strand
 *   the host is not giving this plugin a playhead   left segment, lower strand
 *   the app is not on the other end of the socket   right segment
 *
 * So there are three runs of cable, each lit or not, and the eye lands on the
 * dark one. Two strands on the left rather than one because the host hands over
 * two different things and either can be missing without the other — a session
 * metering perfectly with a parked transport is not a broken link, and a
 * one-strand diagram would have to call it one.
 *
 * The middle node is the icon a DAW shows in its plugin browser, drawn as line
 * art in the one ink, so the thing you picked off a list and the thing in the
 * diagram are the same object.
 *
 * The dashes on the socket segment travel while frames are being sent, and they
 * are the only moving thing in the window. It is also the only claim here a
 * static indicator cannot make: a link that came up and whose thread has since
 * stopped looks exactly like a healthy one until something moves.
 */
void StatusPanel::paintChain(juce::Graphics& g, juce::Rectangle<int> area) {
  /* The outer nodes sit 70 in from the margins so that a caption centred on one
   * is exactly as wide as the space beside it — `STUDIO ONE` and `PRO TOOLS`
   * fit, and a longer name is elided rather than drawn off the window. */
  const float inset   = 70.0f;
  const float cy      = static_cast<float>(area.getY()) + 28.0f;
  const float leftX   = static_cast<float>(area.getX()) + inset;
  const float rightX  = static_cast<float>(area.getRight()) - inset;
  const float centreX = static_cast<float>(area.getCentreX());

  const bool audio    = status_.sampleRate > 0;
  const bool playhead = status_.hostGivesTransport;
  const bool linked   = status_.connected;

  const juce::Colour socket = linked          ? kAccent
                            : status_.everConnected ? kWarn
                                                    : kFaint;

  /* --- the two strands the host feeds ---------------------------------- */
  /* The strands run right up to the outline's outer edge and stop there. A gap
   * would make the tile a picture sitting near the diagram; touching, it is a
   * node in it. */
  const float markHalf = kTileSide * 0.5f + kEmphasis * 0.5f;
  drawStrand(g, leftX + 6.0f, centreX - markHalf, cy - 5.0f, kMark,
             audio ? kAccent : kFaint, audio, 0.0);
  drawStrand(g, leftX + 6.0f, centreX - markHalf, cy + 5.0f, kHair,
             playhead ? kAccent : kFaint, playhead, 0.0);

  g.setFont(ui(8.0f, 0.20f));
  g.setColour(audio ? kMuted : kFaint);
  g.drawText("AUDIO",
             juce::Rectangle<float>(leftX, cy - 24.0f, centreX - markHalf - leftX, 10.0f)
                 .toNearestInt(),
             juce::Justification::centred);
  g.setColour(playhead ? kMuted : kFaint);
  g.drawText("PLAYHEAD",
             juce::Rectangle<float>(leftX, cy + 14.0f, centreX - markHalf - leftX, 10.0f)
                 .toNearestInt(),
             juce::Justification::centred);

  /* --- the socket ------------------------------------------------------ */
  drawStrand(g, centreX + markHalf, rightX - 6.0f, cy, kMark, socket, false,
             streamPhase_);

  /* --- the nodes ------------------------------------------------------- */
  auto node = [&g](float x, float y, juce::Colour colour, bool filled) {
    const juce::Rectangle<float> dot(x - 4.0f, y - 4.0f, 8.0f, 8.0f);
    if (filled) {
      g.setColour(colour);
      g.fillEllipse(dot);
    } else {
      g.setColour(colour);
      g.drawEllipse(dot, kHair);
    }
  };

  node(leftX, cy, audio || playhead ? kAccent : kFaint, audio || playhead);
  node(rightX, cy, socket, linked);

  /* --- the plugin itself, as the icon a DAW shows in its browser -------- */
  const juce::Rectangle<float> tile(centreX - kTileSide * 0.5f,
                                    cy - kTileSide * 0.5f, kTileSide, kTileSide);

  /* Stroked on the path rather than around it, so what the outline's centreline
   * traces is the measured icon shape itself.
   *
   * `kEmphasis` because the wave's own line measures 1.88 pt where this draws
   * it — the flat lead-in bar is 38.6 units of ribbon plus a 14-unit stroke in
   * `oaa-mark.svg`'s 1024 canvas, scaled to a 28.5 pt glyph — and 2 pt is the
   * nearest thing on `OaaStroke`. A frame heavier than its contents reads as a
   * box with a drawing in it; the same weight reads as one drawing. */
  g.setColour(kText);
  g.strokePath(tile_, juce::PathStrokeType(kEmphasis),
               juce::AffineTransform::translation(tile.getX(), tile.getY()));

  if (mark_ != nullptr)
    mark_->drawWithin(g, tile.reduced(kTileSide * kTileArtInset),
                      juce::RectanglePlacement::centred, 1.0f);

  /* --- what each end is, and how it is doing --------------------------- */
  const auto caption = [&](float x, const juce::String& name,
                           const juce::String& state, juce::Colour stateColour) {
    const auto half = static_cast<int>(inset);
    const juce::Rectangle<int> box(static_cast<int>(x) - half,
                                   static_cast<int>(cy) + 26, half * 2, 12);
    g.setFont(ui(9.0f, 0.18f));
    g.setColour(kMuted);
    g.drawText(name, box, juce::Justification::centred);

    g.setFont(ui(11.0f, 0.0f));
    g.setColour(stateColour);
    g.drawText(state, box.translated(0, 14), juce::Justification::centred);
  };

  caption(leftX, hostName_.isNotEmpty() ? hostName_.toUpperCase() : "HOST",
          audio ? "receiving" : "no audio", audio ? kAccent : kFaint);

  caption(rightX, "ANALYZER APP",
          linked ? "linked" : (status_.everConnected ? "reconnecting" : "not linked"),
          socket);
}

/*
 * One sentence, and there is always one.
 *
 * The previous version put the loudness reading, the missing playhead and the
 * dropped-frame count on the same row, so a dropped frame *erased* the reading
 * it was a warning about. Those are two different kinds of statement: a reading
 * is a number and belongs in the strip above, and this is the window telling you
 * something. Worst first, one at a time.
 *
 * **The calm case says something too, and it is the most important line in the
 * window.** A metering plugin that draws no meters is a genuinely confusing
 * object the first time somebody inserts one — it loads, it reports itself
 * healthy, and nothing happens, because the meters it made are in another
 * window on the same screen. Every other line here answers a question the user
 * knew they had; this one answers the question they did not know to ask, and
 * leaving the row empty because nothing is wrong would spend the calmest, most
 * readable moment in the window on nothing.
 *
 * The coloured edge appears only when something is wrong, so the strip is a
 * lamp rather than a caption box.
 */
void StatusPanel::paintMessage(juce::Graphics& g, juce::Rectangle<int> area) {
  juce::String text;
  juce::Colour colour = kMuted;
  bool         alarm  = true;

  if (status_.droppedFrames > 0) {
    colour = kOver;
    text   = formatCount(status_.droppedFrames)
        + " frames dropped. Reset the measurement — the integrated reading has a hole in it.";
  } else if (!status_.connected && status_.everConnected) {
    colour = kWarn;
    text   = "The link dropped. Retrying every few seconds.";
  } else if (!status_.connected) {
    alarm  = false;
    text   = "Start the Open Audio Analyzer app to see the meters.";
  } else if (!status_.hostGivesTransport) {
    alarm  = false;
    text   = (hostName_.isNotEmpty() ? hostName_ : juce::String("This host"))
        + " sends no playhead, so the app cannot follow the transport.";
  } else if (status_.sampleRate == 0) {
    alarm  = false;
    text   = "Linked. Waiting for the host to send audio.";
  } else {
    alarm  = false;
    text   = "Measuring. The meters are in the Open Audio Analyzer app.";
  }

  const auto strip = area.reduced(0, 1);

  g.setColour(kPanel);
  g.fillRect(strip);

  if (alarm) {
    g.setColour(colour);
    g.fillRect(strip.withWidth(static_cast<int>(kEmphasis)));
  }

  g.setFont(ui(11.0f, 0.0f));
  g.setColour(colour);
  g.drawText(text, strip.withTrimmedLeft(kInset), juce::Justification::centredLeft);
}

/*
 * The readings, in a recessed strip.
 *
 * Depth in this design comes from a background step and a hairline, never from
 * a shadow — a shadow implies a card floating over a page, and this is a panel
 * milled into another panel. Three cells because there are three facts, and
 * they are the three a support thread asks for in its first reply: what the
 * host is handing over, how long it has been handing it over, and what came
 * out.
 */
void StatusPanel::paintCells(juce::Graphics& g, juce::Rectangle<int> area) {
  const auto box = area.toFloat().reduced(0.5f);

  g.setColour(kPanel);
  g.fillRoundedRectangle(box, kRadius);
  g.setColour(kHairline);
  g.drawRoundedRectangle(box, kRadius, kHair);

  struct Cell {
    const char*  legend;
    juce::String value;
    juce::Colour colour;
  };

  const Cell cells[] = {
      {"INPUT", formatInput(status_), status_.sampleRate > 0 ? kText : kMuted},
      {"ELAPSED", formatElapsed(status_.elapsedSeconds),
       status_.elapsedSeconds > 0.0 ? kText : kMuted},
      {"LUFS-I", formatLufs(status_.lufsIntegrated),
       std::isnan(status_.lufsIntegrated) ? kMuted : kText},
  };

  const int count = static_cast<int>(std::size(cells));
  const int width = area.getWidth() / count;

  for (int i = 0; i < count; ++i) {
    auto cell = area.withX(area.getX() + i * width).withWidth(width);

    if (i > 0) {
      g.setColour(kHairline);
      g.fillRect(cell.getX(), cell.getY() + kSm, 1, cell.getHeight() - 2 * kSm);
    }

    cell = cell.reduced(kInset, kSm);

    g.setFont(ui(8.5f, 0.20f));
    g.setColour(kMuted);
    g.drawText(cells[i].legend, cell.removeFromTop(10), juce::Justification::topLeft);

    cell.removeFromTop(kXs);
    g.setFont(mono(17.0f));
    g.setColour(cells[i].colour);
    g.drawText(cells[i].value, cell, juce::Justification::topLeft);
  }
}

/* ------------------------------------------------------------------------- */

OaaPluginEditor::OaaPluginEditor(OaaAudioProcessor& owner)
    : juce::AudioProcessorEditor(&owner), processor_(owner) {
  panel_.setDestination(processor_.streamer().destinationHost(),
                        processor_.streamer().destinationPort());

  /*
   * **`getHostDescription()` says "Unknown" rather than nothing**, and it is not
   * a null it can be tested for — JUCE returns that literal for any host whose
   * executable name is not in its table, which is most of them. Printed
   * straight through it produced a header reading `VST3 · Unknown` and a node
   * captioned `UNKNOWN`, which is a window confidently naming the DAW as a
   * program called Unknown. Found by loading the built bundle and looking at
   * it; no test could have, because the string depends on who loaded you.
   */
  const juce::PluginHostType hostType;
  const char* const described = hostType.getHostDescription();
  juce::String hostName = described == nullptr ? juce::String()
                                               : juce::String(described);
  if (hostName == "Unknown")
    hostName = {};

  panel_.setFormat(
      juce::AudioProcessor::getWrapperTypeDescription(processor_.wrapperType),
      hostName);

  panel_.onResetRequested = [this] { processor_.streamer().requestReset(); };

  panel_.onDestinationEdited = [this](const juce::String& host, int port) {
    if (host.isEmpty() || port <= 0) {
      /* Rejected. Put the working values back rather than leaving nonsense on
       * screen looking applied. */
      panel_.setDestination(processor_.streamer().destinationHost(),
                            processor_.streamer().destinationPort());
      return;
    }
    processor_.streamer().setDestination(host, port);
  };

  addAndMakeVisible(panel_);
  setSize(StatusPanel::kWidth, StatusPanel::kHeight);
  startTimerHz(kRefreshHz);
}

OaaPluginEditor::~OaaPluginEditor() {
  stopTimer();
}

void OaaPluginEditor::resized() {
  panel_.setBounds(getLocalBounds());
}

void OaaPluginEditor::timerCallback() {
  panel_.setStatus(processor_.streamer().status());
}

}  // namespace oaa
