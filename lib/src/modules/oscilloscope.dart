// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Amplitude against time: the signal itself, one lane per channel.
///
/// The other thirteen modules answer a question about the audio. This one shows
/// the audio, which is a different job and the reason it is worth having — a
/// number tells you a transient was 3 dB louder, and the waveform tells you it
/// was a click.
///
/// ---------------------------------------------------------------------------
/// One control, two displays, and why that is not two controls
///
/// [ScopeTimeBase] sets how much time the width holds, and that alone decides
/// how the window is found. Below 200 ms the display is **triggered**: the
/// module looks back through the samples it has kept for the most recent rising
/// zero crossing and draws forward from there, so a periodic signal stands
/// still and can be read. Above it the display **rolls**, scrolling right to
/// left the way a DAW draws a waveform.
///
/// Neither works at the other's end of the range. A rolling display advances by
/// one published measurement at a time — 21 ms of audio — so at 200 ms a fifth
/// of the width lands at once and the picture lurches rather than scrolls; and
/// a triggered display has to hold its whole span in memory plus somewhere to
/// search before it, which is not a thing to do with five seconds of audio at
/// 192 kHz. Making the fold automatic is the same call a scope's roll mode
/// makes, for the same reason.
///
/// Independently of that, a column of the display is drawn as a min/max pair
/// when more than one sample lands in it and as a plain trace when fewer than
/// one does. That is arithmetic rather than a mode: at 5 ms across 600 pixels
/// there are 0.4 samples per pixel and the honest picture is the line between
/// them; at 1 s there are eighty, and drawing one of the eighty would be
/// choosing a sample to believe.
///
/// ---------------------------------------------------------------------------
/// It needs nothing from the engine, and that costs it one thing from the clock
///
/// `oaa_snapshot.scope` already carries the newest stereo frames measured —
/// four analysis blocks of them, oldest first — and [MeterSource.scopeFrames]
/// says how many hold audio. Everything below is built on that buffer, so the
/// module works unchanged on a tablet reading a socket, where the buffer is a
/// window of the runs the link carried rather than of the blocks an engine
/// published.
///
/// **What is new is worked out from time, never from the buffer.**
/// [MeterSource.elapsedSeconds] is the engine's own count of measured frames
/// divided by the sample rate, so the difference between two reads is exactly
/// how much audio arrived in between, and that many of the newest pairs are
/// this measurement's — the rest was already seen. A device hands over
/// whatever has arrived, usually fewer than a block; a plugin pushes whole
/// blocks; a relay sends what elapsed. Fewer pairs held than time says arrived
/// means the rest was measured and is gone — a link that dropped a frame, or a
/// source that outran a four-block window — and those become blank columns.
/// They are not filled in with what happens to still be sitting in the buffer.
///
/// **A publish nobody reads is gone, and the four blocks are why that is
/// survivable.** `oaa_snapshot_acquire` is a seqlock with one slot, and every
/// reader runs at the display's rate: at 96 kHz a block is 10.7 ms against a
/// 16.7 ms tick, an engine catching up after a stall publishes back to back,
/// and a plugin at a 2048-frame host buffer sends two frames per callback,
/// microseconds apart. While the buffer held one block, each of those handed
/// this module the second block and lost the first — which it drew, correctly
/// and uselessly, as a block of silence: a waveform in bursts, with a gap
/// between every pair. The window keeps the missed block ahead of the one that
/// was read, and the arithmetic above takes both.
///
/// The module still consumes from `MeterClock.measurements`, which is
/// unthrottled, and paints on the throttled notification like everything
/// else. What that buys now is smaller and still real: a column's colour is
/// the spectrum of the block it came from, and a reader at 30 fps folding two
/// blocks per look would colour both by one.
///
/// ---------------------------------------------------------------------------
/// Two lanes by default, and never two hues
///
/// Left over right, each around its own centre line, is what the module opens
/// on: two traces around one line are one thick trace until somebody has been
/// told otherwise, and at a second across the width they turn into mud.
/// [ScopeStereo] offers the overlaid arrangement anyway, because at 5 ms it is
/// the one that answers the question — what is the *difference* between the
/// channels — and it buys the trace twice the height. The two are told apart
/// by weight and never by hue: a skin moves the hues, and a picture that
/// depends on one stops working in a skin somebody chose.
///
/// A mono source draws one trace either way, because `oaa_scope_append` copies
/// the left channel into both and two identical traces would be a stereo image
/// nobody has.
///
/// [ColorRamp.rgb] does not change that rule, and it is worth being exact about
/// which question a colour answers here. What it colours is the **balance of a
/// column's audio across three bands** — red is its bass, green its mids, blue
/// its highs, so a kick is red, a hat is blue and a full-spectrum hit is white,
/// which is how DJ software has drawn a waveform for twenty years. It is taken
/// from the spectrum the engine published for the same block the column's
/// samples came from, and recorded *with* the column, so a beat two seconds ago
/// keeps the colour it had rather than being repainted by whatever is playing
/// now. Both channels are drawn through the one palette and the second of an
/// overlaid pair is still the dimmer one: a colour in this module names a set of
/// frequencies, never a channel.
///
/// [ScopeZoom] scales what is drawn and nothing that is measured. Anything that
/// reached full scale is drawn in the over colour whatever the zoom is set to,
/// so a clipped passage is visible as a red band rather than as a flat top
/// somebody has to notice — and a trace running off the lane is a trace that is
/// zoomed, which is a different thing and looks like one.
///
/// **That mark says less at [ColorRamp.rgb], and it is left alone anyway.** Red
/// there is what a bass-heavy column is drawn in, so the clip band no longer
/// stands out by colour — what still distinguishes it is that a clipped column
/// runs the full height of the lane. The alternative is a second colour for
/// clipping, and there is no colour left to spend: a three-band mix reaches all
/// of them. `over` is the one ink on this canvas that means "past a limit" and
/// it is not worth making it mean two things in one module.
///
/// ---------------------------------------------------------------------------
/// The sweep, which is the third way this module finds a window
///
/// [ScopeTrigger.transient] replaces both of the displays above with one that
/// waits: armed, drawing nothing new, until the signal rises through
/// [ScopeThreshold]; from that sample forward across the whole width once; then
/// holding what it drew until the next crossing. It is what a bench scope's
/// Normal mode is for and what the other two cannot do — a rolling display puts
/// a drum hit somewhere different every pass and a zero-crossing trigger locks
/// to the *pitch* of whatever is loudest, neither of which lets you look at the
/// attack.
///
/// Three properties of it are decisions rather than consequences.
///
///   - **The trigger is found in the audio as it arrives, not searched for
///     backwards.** [ScopeTrigger.auto] can search, because at 200 ms its whole
///     window plus somewhere to look sits in a third of a second of kept
///     samples; a five-second window does not, and never will. So the sweep is
///     written forward from the sample that fired it, into the same columns the
///     rolling display uses, and needs no raw ring at all.
///   - **Nothing is blanked between triggers.** The last capture is the
///     picture, and a display that cleared itself while waiting would flash
///     rather than hold. A sweep overwrites its predecessor in place, which is
///     the same call [ScopeSync.tempo] makes and for the same reason.
///   - **A threshold nothing reaches leaves the screen alone.** That is the
///     mode working, not failing: the number is printed beside the slider and
///     the level is drawn across the lane, so where the trigger sits relative
///     to the signal is on screen rather than inferred.
///
/// ---------------------------------------------------------------------------
/// Three of the settings are controls on the module, and only here
///
/// The height and the trigger level are dragged, in a strip along the bottom of
/// the plot, because both are chosen by looking: you move them until the
/// picture is right, and a menu that closes over the picture on every step
/// cannot be used for that. They are the only module settings in the
/// application whose value is a number rather than one of a handful of named
/// things.
///
/// [ScopeFront] is the third, and it is a named choice that is still not a menu
/// row — the one exception in the application. It is set by clicking the legend
/// at the leading edge of the strip, which is the same argument: which overlaid
/// trace you want in front is whichever one you are looking at, and it changes
/// between one glance and the next. Making the legend the control also puts it
/// somewhere a pointer can reach — a legend painted into the plot is
/// unreachable by pointer, by keyboard and by every screen reader, because
/// `MeterPainter` deliberately takes no hits.
///
/// The strip's other end carries the span. It is not a control and it is here
/// for the reader rather than for the pointer: a number that names the width of
/// the x axis reads better on the row under that axis than printed over the
/// waveform it is describing.
///
/// The strip is chrome and behaves like the rest of the module's chrome: it is
/// dropped when there is no room for it, on the same principle that drops the
/// graticule and the lane letters, because what a small module keeps is the
/// signal. Its two end cells go one step earlier, and what they are dropped
/// *to* is the corners of the plot, where both were drawn before there was a
/// strip. The strip is also absent wherever there is nothing to write a setting
/// *to* — a remote display draws this module from the same painters and changes
/// nothing about the layout it was sent, so it draws the legend and the span
/// where the painter has always drawn them.
class OscilloscopeModule extends StatefulWidget {
  const OscilloscopeModule({
    required this.engine,
    required this.clock,
    this.timeBase = ScopeTimeBase.s1,
    this.sync = ScopeSync.free,
    this.division = ScopeDivision.bar1,
    this.grid = ScopeGrid.straight,
    this.stereo = ScopeStereo.lanes,
    this.front = ScopeFront.left,
    this.trigger = ScopeTrigger.auto,
    this.threshold = ScopeThreshold.defaultDb,
    this.autoThreshold = false,
    this.zoom = ScopeZoom.defaultScale,
    this.ramp = ColorRamp.skin,
    this.onOption,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// How much time the width holds. See [ScopeTimeBase] — it also decides
  /// whether the window is triggered or rolling.
  final ScopeTimeBase timeBase;

  /// What the window is locked to. See [ScopeSync].
  final ScopeSync sync;

  /// The musical width, when [sync] is [ScopeSync.tempo]. See [ScopeDivision].
  final ScopeDivision division;

  /// Straight, triplet or dotted, applied to [division]. See [ScopeGrid].
  final ScopeGrid grid;

  /// Two lanes or one. See [ScopeStereo].
  final ScopeStereo stereo;

  /// Which of two overlaid traces is drawn in front, and which is dimmed
  /// behind it. See [ScopeFront] — it is read only at [ScopeStereo.overlay],
  /// where the two share a centre line and so hide one another.
  final ScopeFront front;

  /// What starts the window when [sync] is [ScopeSync.free]. See
  /// [ScopeTrigger].
  final ScopeTrigger trigger;

  /// The level [ScopeTrigger.transient] fires at, in dBFS. See
  /// [ScopeThreshold].
  final double threshold;

  /// Whether that level follows the loudest transient instead of being
  /// dragged. See [_AutoLevel] and [ScopeThreshold.autoAt].
  final bool autoThreshold;

  /// How tall full scale is drawn, as a multiplier. See [ScopeZoom].
  final double zoom;

  /// Which colours the trace is drawn in. See [ColorRamp] — at
  /// [ColorRamp.skin] it is the accent hue at one weight per channel, which is
  /// what this module has always drawn; at [ColorRamp.rgb] each column takes the
  /// colour of its own balance of bass, mids and highs.
  final ColorRamp ramp;

  /// Writes one of this module's own settings back to the layout.
  ///
  /// **Null is what a surface with no editable layout looks like**, and it is
  /// the same signal `ModuleFrame.onMenu` uses: no callback, no control drawn.
  /// A remote display is that surface — it renders the layout it was sent and
  /// has nothing to change it with — so the strip is not built there rather
  /// than built and ignored.
  final void Function(String key, Object? value)? onOption;

  @override
  State<OscilloscopeModule> createState() => _OscilloscopeModuleState();
}

/// Vertical graticule divisions across the width, the scope convention.
const int _divisions = 10;

/// The most beats a tempo-locked window is divided into. Four bars of 4/4 is
/// sixteen lines; past that they are hatching rather than a graticule, and the
/// width check below drops them anyway.
const int _maxBeatDivisions = 16;

/// A division narrower than this is a hatch pattern rather than a graticule.
const double _minDivision = Space.lg;

/// Lane height below which the half-scale lines are more clutter than scale.
const double _halfScaleAbove = Space.xxl;

/// Lane height below which the channel letter has nowhere to sit.
const double _laneLabelAbove = Space.lg;

/// The weight the second of two overlaid channels is drawn at.
///
/// Alpha and not a hue — see [ScopeStereo]. Enough of a step that the two
/// traces are separable where they cross, and not so much that the right
/// channel reads as a shadow of the left.
const double _dim = 0.55;

/// Steps each of the three band weights is quantised into at [ColorRamp.rgb].
///
/// A column's colour is a mix of its low, mid and high content — see
/// `ColorRamp.mixAt` — and the display is drawn as one `drawRawPoints` per
/// colour, through [PointBuckets], so the palette has to be a closed set. Five
/// steps per channel is 125 of them, of which only the faces where one channel
/// is full are reachable; what is actually drawn per frame is the handful of
/// colours the material is making, because a bucket nobody filled costs nothing.
///
/// Five and not more because these are *weights*, not levels: the eye reads
/// "mostly bass with some air" off a colour and never reads it to a quarter of a
/// band. Nothing about the audio is quantised — only the ink.
const int _mixSteps = 5;

/// Colours in the scope's palette, and the index of the one that is not a mix.
///
/// **A slice with no spectrum behind it is not given a colour.** A source that
/// publishes no bands has made no statement about balance, so the trace stays
/// the accent — the same ink the whole module uses at [ColorRamp.skin] — rather
/// than being handed the middle of a palette, which would be a colour claiming
/// a mix nobody measured.
const int _mixColors = _mixSteps * _mixSteps * _mixSteps;
const int _noMix = _mixColors;

/// How far under the loudest of the three bands a band stops counting.
///
/// The mix is taken in **decibels relative to the loudest band**, and this is
/// the window. In linear power a kick sits 25 dB over a hat, so a mix weighted
/// by power is red on every piece of music ever made — the first version of this
/// was, and it looked like a fault. Twenty-four decibels is wide enough that a
/// hat under a kick still tints the column and narrow enough that the noise
/// floor between beats does not.
const double _mixRangeDb = 24;

/// The floor a band has to clear to count at all.
///
/// The spectrogram's own floor, for the same reason it has one: below this a
/// band is the room rather than the programme.
const double _mixFloorDb = -84;

/// What the plot keeps for itself before the strip may have its sixteen pixels.
///
/// Deliberately above `ModuleKind.oscilloscope.minBodyHeight`, which is where a
/// waveform stops being one: a strip that took the plot down *to* its floor
/// would spend the picture on a control whose whole job is to improve the
/// picture. At this height two lanes are still 30 px each. Chrome goes first
/// when there is not enough — the same order the graticule, the half-scale
/// lines and the lane letters already go in.
const double _plotAbove = Space.xxl + Space.md;

/// Room for `THRESHOLD`, which is 68 px of the label face, measured.
///
/// What the threshold control's *box* is sized against rather than a cell the
/// word sits in — the words are drawn tight and flush left. See
/// [_ScopeControl] for where the difference between two labels ends up.
const double _longestLabel = Space.xxxl + Space.sm;

/// Room for `HEIGHT`, which is 43 px of the same face.
///
/// Sized against its own word rather than the longest one, because these two
/// controls stand side by side: a height control in a box cut for `THRESHOLD`
/// ends 29 px past its own last glyph, and that slack lands in the gutter
/// between the pair. One px over the measurement rather than one under — the
/// label clips rather than wrapping, so a fallback face costs a glyph.
const double _heightLabel = Space.xl + Space.smd;

/// The threshold's reading: eight glyphs of the tick face, which is `-60.0 dB`.
///
/// Measured rather than derived — the first guess was this face's nominal
/// advance times eight, and it printed `-12.0 dE`.
const double _readingColumn = Space.xxl + Space.sm;

/// The height's reading: five glyphs, which is `32.0x`.
///
/// Its own column for the same reason it has its own label column — the
/// difference between the widest reading a control can print and the widest
/// one in the strip is slack, and side by side the slack is the gutter. A
/// glyph of room over the five, because [_readingColumn] is a measurement and
/// five-eighths of it is not.
const double _zoomReading = Space.xl + Space.xs;

/// The `AUTO` box and its word, which only the threshold control has.
///
/// Taken on that control alone. It was once reserved blank on the height
/// control too, to keep the two tracks the same length — but the length is the
/// caller's `track`, which is one number handed to both, so the cell never did
/// that job. What it did was park 48 px of nothing at the height control's
/// right-hand end, which is the gutter between the two.
const double _autoColumn = Space.xxl;

/// How many traces there are to draw.
///
/// One for a mono source whatever the arrangement says: `oaa_scope_append`
/// copies the left channel into both, and two identical traces are not a stereo
/// image. Asked here rather than in each of the three places that need it — the
/// painter's lanes, the strip's legend and the painter's own — because a legend
/// naming two channels over one trace is exactly the mismatch this returns the
/// same answer to avoid.
int _channelsOf(MeterSource engine) => engine.channels >= 2 ? 2 : 1;

/// Whether there is a tempo to lock a window to.
///
/// A sound card has no playhead and neither does a DAW that never mentions one.
/// See the painter, which asks the same question of the same snapshot to decide
/// what it draws while the strip asks it to decide what it prints.
bool _hasTempoOf(MeterSource engine) {
  final transport = engine.transport;
  return transport.hasBpm && transport.bpm > 0 && transport.hasPpq;
}

/// Everything in a control that is not the track.
double _controlChrome({
  required double label,
  required double reading,
  required bool auto,
}) => label + reading + Space.sm * 2 + (auto ? _autoColumn + Space.sm : 0);

/// The least track worth drawing. Below it a control is a readout with a
/// hairline beside it.
const double _trackMin = Space.xl;

/// The most track that is drawn, however wide the module is. See the strip.
const double _trackMax = Space.xxxl * 2 + Space.sm;

/// Room for the legend: two glyphs of the tick face, the seam between them and
/// the box around the pair.
///
/// Its own column at the leading edge of the strip, which is where the module's
/// chrome has always started — the lane letters sat at exactly this x when they
/// were painted in the plot. See [_ScopeKey].
const double _keyColumn = Space.xl;

/// Room for the span, which is eight glyphs at its longest: `4 bars T`.
///
/// The same measurement [_readingColumn] is, for the same face and the same
/// count, and deliberately not that constant: one is what a *reading* is
/// printed in and this is what a label is, and a change to either has no
/// business moving the other.
const double _spanColumn = Space.xxl + Space.sm;

/// Room left at the right-hand end of the strip for the canvas's resize grip.
///
/// The grip is drawn over the module's bottom-right corner and its *touch*
/// target is twice the size of the ink; both are above this module in the
/// canvas's stack, so a slider that ran to the right-hand edge would end
/// underneath them. See `_ModuleSlot` in `lib/src/canvas/grid_canvas.dart`.
///
/// **It is taken from controls and from nothing else.** The span is a label:
/// it takes no gesture, so there is nothing for the grip to steal from it, and
/// the ticks themselves are drawn in the frame's padding rather than in the
/// body — the touch target is the only thing that reaches in. So the span runs
/// to the body's right-hand edge, which is where the axis it measures ends,
/// and the strip pays this only where the last thing in the row is a slider.
const double _gripClearance = Space.lg;

/// Where a segment the painter is not using is parked.
///
/// The buffers handed to `drawRawPoints` are always passed whole, because
/// `Float32List.sublistView` would allocate a view per call per lane on the
/// paint path. The entries past the last real one are filled with this
/// instead: both ends of the segment are the same point, which draws nothing
/// at all, and the point is outside the module, which draws nothing twice.
const double _parked = -1;

class _OscilloscopeModuleState extends State<OscilloscopeModule> {
  final _ScopeHistory _history = _ScopeHistory();

  /// The height and the level as they are *being* dragged.
  ///
  /// The slider reports continuously and commits once, and this is the half in
  /// between: what the painter is handed while the pointer is down. Writing
  /// each pointer event to the layout instead would spend an undo entry, a JSON
  /// encoding and a wire frame per pixel of travel — see `OaaSlider`. Seeded
  /// from the widget and re-seeded whenever it changes, so a preset load, an
  /// undo or the commit at the end of the drag all arrive the same way.
  late double _zoom = widget.zoom;
  late double _threshold = widget.threshold;

  /// The loudest the trigger's own quantity has been, for `AUTO`.
  final _AutoLevel _auto = _AutoLevel();

  /// The two things about the *source* that the strip has to know, and the
  /// painter reads off the engine every frame.
  ///
  /// Whether there are two channels decides whether there is a front to choose,
  /// and whether the host is offering a tempo decides which of two labels the
  /// corner prints. A painter can ask both questions in `paint`; a widget has
  /// to be rebuilt, and a strip built from `widget` alone would say `1 bar`
  /// under a free window for as long as it took something else to rebuild the
  /// tree after a DAW went away.
  ///
  /// **Folded in on the measurement channel, which is why they cannot drift.**
  /// `MeterClock` notifies it from inside its ticker callback, so a `setState`
  /// here is built in the same frame as the paint that follows — the label in
  /// the strip and the window above it are read from one snapshot.
  late int _channels = _channelsOf(widget.engine);
  late bool _hasTempo = _hasTempoOf(widget.engine);

  /// The columns sorted by the hue they are drawn in, at [ColorRamp.rgb].
  ///
  /// Kept here rather than in the painter because [PointBuckets] grows its
  /// buffers to the widest frame it has been asked for and then reuses them, and
  /// a painter is rebuilt every time the height slider moves a pixel. Untouched
  /// at [ColorRamp.skin], where the whole display is one colour and one call.
  final PointBuckets _buckets = PointBuckets(_mixColors + 1);

  ui.Paragraph? _leftLabel;
  ui.Paragraph? _rightLabel;

  /// The same two letters in the two inks the traces are drawn in, for the
  /// overlaid arrangement.
  ///
  /// Two traces around one centre line need a legend or they are one thick
  /// trace, and the legend has to be the thing that tells them apart — which
  /// here is weight, because a hue would not survive a change of skin. Faint
  /// letters beside each other would name the channels without saying which is
  /// which.
  ///
  /// **Which letter gets the full ink follows [OscilloscopeModule.front]**, so
  /// the legend and the traces are drawn from one decision. These two are the
  /// painter's copy, for the surfaces that have no strip to put the legend in —
  /// a remote display, and a module too narrow for one. Where there is a strip
  /// it carries the legend as a control; see [_ScopeKey].
  ui.Paragraph? _leftKey;
  ui.Paragraph? _rightKey;

  ui.Paragraph? _spanLabel;

  /// The same corner, saying what a tempo-locked window is a window *of*.
  ///
  /// Both are laid out, and `paint` picks — because which one is true depends
  /// on whether the host is offering a tempo *this frame*, and a label built in
  /// `build` would still say `1 bar` for as long as it took something else to
  /// rebuild the tree after a DAW went away.
  ui.Paragraph? _divisionLabel;

  Color? _builtColor;
  Color? _builtAccent;
  ScopeFront? _builtFront;
  ScopeTimeBase? _builtSpan;
  String? _builtDivision;

  @override
  void initState() {
    super.initState();
    widget.clock.measurements.addListener(_measured);
  }

  @override
  void didUpdateWidget(OscilloscopeModule old) {
    super.didUpdateWidget(old);
    if (!identical(old.clock, widget.clock)) {
      old.clock.measurements.removeListener(_measured);
      widget.clock.measurements.addListener(_measured);
    }
    // A different source is a different programme, and its elapsed clock has
    // no relationship to the one on screen — the desktop swaps its engine for
    // a plugin's decoded frames the moment a DAW connects. Keeping the old
    // waveform would draw one session's audio onto the end of another's.
    if (!identical(old.engine, widget.engine)) {
      _history.reset();
      // The same reason: the peak this was holding belongs to a programme that
      // is no longer playing, and a level taken from it would arm the trigger
      // somewhere the new signal never goes.
      _auto.reset();
      // And the same again for what the strip says about the source: the new
      // engine's channel count and transport are the ones the next paint will
      // read, and waiting a publish to find that out would draw one source's
      // legend over another's waveform.
      _channels = _channelsOf(widget.engine);
      _hasTempo = _hasTempoOf(widget.engine);
    }
    if (old.zoom != widget.zoom) _zoom = widget.zoom;
    if (old.threshold != widget.threshold) _threshold = widget.threshold;
  }

  @override
  void dispose() {
    widget.clock.measurements.removeListener(_measured);
    super.dispose();
  }

  /// **Not in `paint`, and neither is the spectrogram's record.**
  ///
  /// The modules that keep a history and still advance from paint advance by a
  /// mark per measurement they were *painted* for, so a throttled repaint
  /// costs them resolution and nothing else — a phase scope or a stereo cloud
  /// draws where the signal has been, and a coarser sample of that is a
  /// coarser picture of the same thing. This one advances by however much time
  /// the measurement carried, so a throttled repaint costs it the audio
  /// itself — at 30 fps one publish in three, which on a time axis is a hole
  /// rather than a coarser picture, and which leaves a window longer than one
  /// buffer unable to fill at all. The spectrogram is here for the same
  /// reason: its columns *are* the axis, so the ones a throttled repaint skips
  /// are measurements the record cannot be redrawn from, and the rate it dates
  /// them by came out as the repaint rate rather than the publish rate. See
  /// its `_measured`. `MeterClock.measurements` is unthrottled for exactly
  /// this; see its comment.
  ///
  /// Nothing here marks the tree dirty. Pixels still arrive on the clock's
  /// throttled notification, at the rate the user asked for.
  void _measured() {
    _history.ingest(widget.engine, coloured: widget.ramp == ColorRamp.rgb);
    _auto.ingest(widget.engine);
    // Both change on a source, not on a block — a device gains a channel, a
    // DAW connects — so this is a comparison per publish and a rebuild almost
    // never. See the fields.
    final channels = _channelsOf(widget.engine);
    final tempo = _hasTempoOf(widget.engine);
    if (channels != _channels || tempo != _hasTempo) {
      setState(() {
        _channels = channels;
        _hasTempo = tempo;
      });
    }
    // Only while the box is checked, and only when the decibel it prints
    // actually moved. On steady material the peak holds and this does nothing
    // at all; through a fade it fires a handful of times a second, which is
    // what rounding the level to `ScopeThreshold.stepDb` buys — the tenth of a
    // decibel a drag stores would rebuild the strip on every publish.
    if (!widget.autoThreshold) return;
    final level = _auto.level;
    if (level != null && level != _threshold) {
      setState(() => _threshold = level);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    final division = widget.grid == ScopeGrid.straight
        ? widget.division.label
        : '${widget.division.label} ${widget.grid.label.substring(0, 1)}';

    if (_builtColor != colors.textFaint ||
        _builtAccent != colors.accent ||
        _builtFront != widget.front ||
        _builtSpan != widget.timeBase ||
        _builtDivision != division) {
      _builtColor = colors.textFaint;
      _builtAccent = colors.accent;
      _builtFront = widget.front;
      _builtSpan = widget.timeBase;
      _builtDivision = division;
      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _leftLabel = layoutParagraph('L', style);
      _rightLabel = layoutParagraph('R', style);
      final front = OaaType.tick.copyWith(color: colors.accent);
      final back = OaaType.tick.copyWith(
        color: colors.accent.withValues(alpha: _dim),
      );
      final leads = widget.front == ScopeFront.left;
      _leftKey = layoutParagraph('L', leads ? front : back);
      _rightKey = layoutParagraph('R', leads ? back : front);
      _spanLabel = layoutParagraph(widget.timeBase.label, style);
      _divisionLabel = layoutParagraph(division, style);
    }

    // **The legend and the span are drawn in one place or the other, never
    // both.** Where there is a strip with room for them they are its leading
    // and trailing cells — the legend because it is a control there and only a
    // caption here, the span because a number about the x axis reads better on
    // the row under it than over the waveform it is describing. Where there is
    // no strip at all, which is every remote display and every module too
    // narrow for one, the painter's corners are still the only place they can
    // go.
    MeterBody plotWith({required bool chrome}) => MeterBody(
      painter: _OscilloscopePainter(
        engine: widget.engine,
        colors: colors,
        state: this,
        timeBase: widget.timeBase,
        sync: widget.sync,
        division: widget.division,
        grid: widget.grid,
        stereo: widget.stereo,
        front: widget.front,
        trigger: widget.trigger,
        threshold: _threshold,
        zoom: _zoom,
        ramp: widget.ramp,
        chrome: chrome,
        repaint: widget.clock,
      ),
    );

    if (widget.onOption == null) return plotWith(chrome: false);

    // The level is only a control where it is the thing deciding what is on
    // screen: a tempo-locked window is placed by the bar line and a
    // free-running one by [ScopeTrigger.auto], and a slider that moves a number
    // nothing reads is a slider that has to be explained. Same rule as the
    // menu, which offers the time base and the trigger to a free window and the
    // division and the grid to a locked one, and never both.
    final levelled = widget.sync == ScopeSync.free && widget.trigger.sweeps;

    // The legend is a control only where there is a front to choose: two
    // channels around one centre line, hiding one another. In lanes each trace
    // has its own line and crosses nothing, so its letter stays in its lane
    // where the painter draws it, and there is nothing here to click.
    final keyed = widget.stereo == ScopeStereo.overlay && _channels > 1;
    final span = widget.sync == ScopeSync.tempo && _hasTempo
        ? division
        : widget.timeBase.label;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Each control is cut to its own word and its own cells: the `AUTO`
        // box belongs to the threshold, so the room for it is only taken where
        // there is a threshold to set, and the height control's box ends where
        // `HEIGHT` does rather than where `THRESHOLD` would have.
        final heightChrome = _controlChrome(
          label: _heightLabel,
          reading: _zoomReading,
          auto: false,
        );
        final levelChrome = _controlChrome(
          label: _longestLabel,
          reading: _readingColumn,
          auto: levelled,
        );
        final minimum = (levelled ? levelChrome : heightChrome) + _trackMin;
        // **Chrome goes first, here as everywhere else in this module.** The
        // two end cells are taken only when what is left still holds a control,
        // and a module too narrow for both keeps the sliders and hands the
        // legend and the span back to the painter's corners. The other way
        // round — dropping a control to keep a caption — is the one arrangement
        // that would be wrong, and it is the one a `Spacer` would have produced
        // by squeezing the tracks instead.
        final ends =
            (keyed ? _keyColumn + Space.sm : 0.0) + _spanColumn + Space.sm;
        // The span's cell stands in for [_gripClearance] rather than sitting
        // inside it: it is more than twice as wide, so a control that stops
        // where it begins is already clear of the grip's target.
        final chrome = constraints.maxWidth - ends >= minimum;
        final inner = chrome
            ? constraints.maxWidth - ends
            : constraints.maxWidth - _gripClearance;
        // Two controls fit side by side on almost every module and on none of
        // the narrow ones, so the fallback is a second row rather than a
        // dropped control: a setting that disappears when a module is resized
        // is worse than a plot that is sixteen pixels shorter.
        // Measured against the *wider* control twice, not against the pair's
        // real widths: cutting the height control to its own word freed 100 px,
        // and spending that on fitting two 32 px tracks where two 136 px ones
        // used to stack would be a worse strip on every narrow module. The
        // freed room goes into the tracks that are already side by side.
        final rows = levelled && inner < minimum * 2 + Space.md ? 2 : 1;
        final side = (inner - heightChrome - levelChrome - Space.md) / 2;
        final strip = rows * OaaSlider.height + (rows - 1) * Space.xs;

        if (inner < minimum ||
            constraints.maxHeight < _plotAbove + strip + Space.xs) {
          return plotWith(chrome: false);
        }

        // **Not the whole width, on a wide module.** A track drawn across a
        // twelve-column module under a waveform is a scrub bar to anybody who
        // has used a DAW, and this one plays nothing and locates nothing.
        // [_trackMax] already puts half a decibel of level and a thirtieth of
        // an octave of height in a pixel, so the rest of the row is better
        // spent being empty and letting the strip read as a pair of controls.
        // One length, handed to both controls. Two sliders side by side whose
        // travel differs are two sliders that look mis-set rather than
        // differently scaled — the chrome around them may differ, the track
        // may not.
        final track = math.min(
          _trackMax,
          rows == 1 && levelled
              ? side
              : inner - (levelled ? levelChrome : heightChrome),
        );

        // The height is dragged in *octaves* and printed in multipliers. A
        // slider linear in the multiplier spends half its travel between 16x
        // and 32x, where the picture barely changes, and the first four
        // multipliers — which is where the material usually is — in an eighth
        // of it.
        final height = _ScopeControl(
          label: 'HEIGHT',
          semanticLabel: 'Waveform height',
          format: (position) => ScopeZoom.label(ScopeZoom.scaleAt(position)),
          value: ScopeZoom.positionOf(_zoom),
          min: 0,
          max: ScopeZoom.octaves,
          step: ScopeZoom.stepOctaves,
          onChanged: (position) => _setZoom(position, commit: false),
          onChangeEnd: (position) => _setZoom(position, commit: true),
          track: track,
          readingColumn: _zoomReading,
        );
        final level = _ScopeControl(
          label: 'THRESHOLD',
          semanticLabel: 'Trigger threshold',
          format: ScopeThreshold.label,
          value: _threshold,
          min: ScopeThreshold.minDb,
          max: ScopeThreshold.maxDb,
          step: ScopeThreshold.stepDb,
          // Dragging is what `AUTO` takes over. The track still shows where the
          // level has got to, because that is the whole of what it is for.
          enabled: !widget.autoThreshold,
          onChanged: (db) => _setThreshold(db, commit: false),
          onChangeEnd: (db) => _setThreshold(db, commit: true),
          track: track,
          readingColumn: _readingColumn,
          trailing: OaaCheck(
            label: 'AUTO',
            value: widget.autoThreshold,
            semanticLabel: 'Set the trigger threshold automatically',
            onChanged: _setAuto,
          ),
        );

        // Adjacent, one gutter apart. [side] already has the gutter taken out
        // of it, so the two fit whatever the module's width — pushed to the two
        // ends instead, as they were, a wide module put half a module between
        // them and the pair stopped reading as one strip of controls.
        final controls = rows == 1
            ? Row(
                children: [
                  SizedBox(width: heightChrome + track, child: height),
                  if (levelled) ...[
                    const SizedBox(width: Space.md),
                    SizedBox(width: levelChrome + track, child: level),
                  ],
                ],
              )
            : Column(
                children: [
                  Row(
                    children: [
                      SizedBox(width: heightChrome + track, child: height),
                    ],
                  ),
                  const SizedBox(height: Space.xs),
                  Row(
                    children: [
                      SizedBox(width: levelChrome + track, child: level),
                    ],
                  ),
                ],
              );

        return Column(
          children: [
            Expanded(child: plotWith(chrome: chrome)),
            const SizedBox(height: Space.xs),
            SizedBox(
              height: strip,
              child: Row(
                // **The two end cells belong to the first row**, not to the
                // strip: a second row is a control that did not fit beside the
                // first, and a legend that slid down to sit between them would
                // be naming the threshold. Top-aligned, so a strip that grows a
                // row leaves both of them where the one-row strip put them.
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (chrome && keyed) ...[
                    SizedBox(
                      width: _keyColumn,
                      child: _ScopeKey(
                        front: widget.front,
                        onChanged: _setFront,
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                  ],
                  // What is left over after the tracks have taken their capped
                  // length, which is most of a wide module, is what holds the
                  // span out at the right-hand edge. See [_trackMax] for why
                  // that room is not spent on track.
                  Expanded(child: controls),
                  if (chrome) ...[
                    const SizedBox(width: Space.sm),
                    SizedBox(
                      width: _spanColumn,
                      height: OaaSlider.height,
                      // Flush with the body's right-hand edge, which is where
                      // the plot's border ends directly above it: the number
                      // names the width of that axis, and one that stopped
                      // short of it would be measuring something narrower.
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          span,
                          // Chrome, in the ink the strip's own words are drawn
                          // in rather than the fainter one the painter uses:
                          // over the graticule it is competing with a waveform,
                          // and down here it is sitting beside two labels it
                          // would otherwise look switched off next to.
                          style: OaaType.tick.copyWith(color: colors.textMuted),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                        ),
                      ),
                    ),
                  ] else
                    const SizedBox(width: _gripClearance),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Both halves of a slider's contract, quantised once.
  ///
  /// The live value, the printed reading, the line drawn across the lane and
  /// the number written to the layout are all this one — a control that commits
  /// a value it never displayed is a control whose readout is a rounding of
  /// something else.
  void _setZoom(double position, {required bool commit}) {
    final scale = ScopeZoom.scaleAt(position);
    if (commit) widget.onOption!('zoom', scale);
    if (scale != _zoom) setState(() => _zoom = scale);
  }

  void _setThreshold(double db, {required bool commit}) {
    final level = ScopeThreshold.quantise(db);
    if (commit) widget.onOption!('threshold', level);
    if (level != _threshold) setState(() => _threshold = level);
  }

  /// Hands the level to the audio, or takes it back.
  ///
  /// **Switching `AUTO` off writes the level it had found, first.** The layout
  /// still holds whatever was dragged before the box was checked — the audio
  /// never wrote to it, deliberately, because a level that followed the
  /// material into the preset would spend an undo entry and a wire frame per
  /// published block — so without this, unchecking the box would jump the
  /// trigger back to a number nobody has looked at in minutes and move the line
  /// out from under the transient it was sitting on. Two writes and so two
  /// entries in the history, which is what happened: the level is this one now,
  /// and it is manual now.
  void _setAuto(bool on) {
    if (!on) {
      widget.onOption!('threshold', ScopeThreshold.quantise(_threshold));
    }
    widget.onOption!('autoThreshold', on);
  }

  /// Swaps which overlaid trace is in front.
  ///
  /// Straight to the layout with no local copy, unlike the height and the
  /// level: those are dragged and would spend an undo entry per pixel of
  /// travel, and this is one click that means one thing. It comes back through
  /// `widget.front` the way every other menu setting does.
  void _setFront(ScopeFront front) => widget.onOption!('front', front.id);
}

/// The legend, and the control it is.
///
/// Two letters in the inks their traces are drawn in, **front one first**, in a
/// box that says it can be clicked. Two cues for one fact, and both of them are
/// the picture's own: the front trace is the brighter one on screen and the
/// first one here, so reading the legend is reading the display rather than
/// remembering a convention.
///
/// It replaces the pair the painter used to draw over the top-left of the plot
/// — see `_paintLabels`, which still draws them wherever there is no strip to
/// put this in. What moving it buys is that it can be a control at all: a
/// legend painted into a meter's face is unreachable by pointer, by keyboard
/// and by a screen reader, because `MeterPainter` deliberately takes no hits.
///
/// **The letters keep their inks through hover and focus**, which is the one
/// place this departs from `OaaCheck` and `BarButton`, where the caption itself
/// brightens to `textPrimary`. Here the ink *is* the reading — brightening both
/// letters would say the two traces are drawn the same weight, which is the
/// single thing this control exists to deny. The box says the rest.
class _ScopeKey extends StatelessWidget {
  const _ScopeKey({required this.front, required this.onChanged});

  final ScopeFront front;
  final ValueChanged<ScopeFront> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final leader = front;
    final trailer = front.swapped;

    return OaaFocusable(
      onActivate: () => onChanged(front.swapped),
      semanticLabel: '${leader.label} in front of ${trailer.label}',
      builder: (context, hovered, focused) => Container(
        height: OaaSlider.height,
        decoration: BoxDecoration(
          borderRadius: OaaRadius.allXs,
          border: Border.all(
            color: focused || hovered ? colors.textPrimary : colors.hairline,
            width: OaaStroke.hairline,
          ),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _letter(leader, colors.accent),
              const SizedBox(width: Space.xxs),
              _letter(trailer, colors.accent.withValues(alpha: _dim)),
            ],
          ),
        ),
      ),
    );
  }

  /// One letter, in the ink its trace is drawn in.
  ///
  /// Clipped rather than allowed to overflow, for the reason `OaaCheck` gives:
  /// [_keyColumn] was measured against the face the application bundles, and a
  /// fallback must cost a glyph rather than a layout assertion that takes the
  /// whole strip with it.
  Widget _letter(ScopeFront channel, Color ink) => Flexible(
    child: Text(
      channel.label,
      style: OaaType.tick.copyWith(color: ink),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
    ),
  );
}

/// One row of the strip: what it sets, the track, and what it is set to.
///
/// Every control in the strip is this one widget, and every one of them has the
/// same geometry: the word, a seam, [track], a seam, the reading, and the
/// trailing cell where the strip has one. **Both seams are [Space.sm] and
/// nothing else is ever between a thing and the track it belongs to.**
///
/// Which is the whole design here, because the two labels are not the same
/// length — `HEIGHT` is 43 px of the label face and `THRESHOLD` is 68 — and
/// something has to absorb the difference. Three places to put it and only one
/// is any good:
///
///   - *Between the word and the track*, by giving every label a column as wide
///     as the longest one. Then `HEIGHT` floats 37 px off its own slider, which
///     is the defect this strip already had once at the other end: `1.0x`
///     right-aligned in a column sized for `-60.0 dB` sat forty pixels past the
///     track and read as a caption belonging to nothing.
///   - *In front of the word*, by right-aligning it in that column. Then the
///     rows no longer start where the plot above them does, and the first one
///     looks indented for no reason a reader can see.
///   - *Nowhere*, which is what this does. The word is tight and flush left,
///     the caller cuts each control's box to that control's own word, and
///     [track] — one number, handed to both — is what makes them agree. The
///     difference between the two labels is then simply not in the layout.
///
/// What that costs is that the controls start their tracks at different x.
/// They are the same *length*, which is what a slider's travel is read from and
/// the thing two controls side by side must agree about. Absorbing it as
/// trailing margin instead was the previous answer here, and it is the one that
/// put 85 px of nothing between the height control and the threshold beside it:
/// 29 px of unused label column and a blank [_autoColumn] behind it.
class _ScopeControl extends StatelessWidget {
  const _ScopeControl({
    required this.label,
    required this.semanticLabel,
    required this.format,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.onChangeEnd,
    required this.track,
    required this.readingColumn,
    this.enabled = true,
    this.trailing,
  });

  final String label;
  final String semanticLabel;

  /// The value in words. Drawn *and* announced from this one function, so the
  /// number a screen reader reads and the number on screen cannot drift.
  final String Function(double value) format;
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  /// How long the track is drawn. The same for every control in the strip —
  /// see the class comment for why the caller works it out rather than the
  /// row taking what is left over.
  final double track;

  /// How wide the readout is drawn — the widest string [format] can return,
  /// and not a pixel more. Tabular, so it never changes; sized per control,
  /// because the difference between `32.0x` and `-60.0 dB` is 20 px of gutter.
  final double readingColumn;

  /// Whether the track can be dragged. See [OaaSlider.enabled].
  final bool enabled;

  /// What sits past the reading, on the one control that has anything.
  ///
  /// Its cell is [_autoColumn] wide and exists only where it is filled — a
  /// control that reserved it blank would end 56 px past its own last glyph.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final reading = format(value);

    return SizedBox(
      height: OaaSlider.height,
      child: Row(
        children: [
          // Tight, and flexible only so that a fallback label face wider than
          // the one this was measured against clips a word rather than
          // overflowing the row. Chrome, in the ink the rest of the module's
          // chrome uses: a control on the measurement surface that took
          // `textPrimary` would be brighter than every reading around it.
          Flexible(
            child: Text(
              label,
              style: OaaType.label.copyWith(color: colors.textMuted),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
          const SizedBox(width: Space.sm),
          SizedBox(
            width: track,
            child: OaaSlider(
              value: value,
              min: min,
              max: max,
              step: step,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
              format: format,
              semanticLabel: semanticLabel,
              enabled: enabled,
            ),
          ),
          const SizedBox(width: Space.sm),
          SizedBox(
            width: readingColumn,
            child: Text(
              reading,
              textAlign: TextAlign.left,
              // Tabular, like every other number in the application: a readout
              // that changes width as it is dragged drags the control with it.
              style: OaaType.tick.copyWith(color: colors.textMuted),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Space.sm),
            Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: SizedBox(width: _autoColumn, child: trailing),
            ),
          ],
        ],
      ),
    );
  }
}

/// The loudest the trigger's own quantity has been lately, and the level that
/// follows it.
///
/// **It measures the mid of the two channels, not either channel and not an
/// absolute value.** `_ScopeHistory._sweepAudio` compares `(l + r) / 2` against
/// the level and fires on a *rising* crossing, so the only peak that says
/// anything about whether a level can ever fire is the largest positive
/// excursion of that same signal. Take the absolute value instead and a
/// waveform whose negative half is the bigger one — which is most kick drums —
/// gets a level nothing on the positive side ever reaches: the box says it
/// found something and the display never sweeps again.
///
/// **Two buckets rather than a release curve.** The window is the current two
/// seconds of audio and the one before it, so a transient holds the level for
/// between two and four seconds and is then let go. A decay would be an
/// invented ballistic — there is no standard for this and nothing to hold one
/// against — and a single bucket would drop the level to whatever the last two
/// seconds happened to contain at the instant the bucket turned over.
///
/// Time comes from the source's elapsed clock and not the wall, so a file
/// pushed through faster than real time gets the same window in audio seconds
/// that a device gets in real ones.
class _AutoLevel {
  static const double _bucketSeconds = 2;

  double _current = 0;
  double _previous = 0;
  int _bucket = 0;
  bool _seeded = false;

  /// The level to fire at, in dBFS, or null while nothing loud enough has been
  /// published. See [ScopeThreshold.autoAt].
  double? get level =>
      ScopeThreshold.autoAt(_current > _previous ? _current : _previous);

  void reset() {
    _current = 0;
    _previous = 0;
    _seeded = false;
  }

  void ingest(MeterSource engine) {
    final published = engine.scopeFrames;
    if (published <= 0) return;
    final elapsed = engine.elapsedSeconds;
    if (elapsed.isNaN) return;

    final bucket = (elapsed / _bucketSeconds).floor();
    if (!_seeded || bucket < _bucket) {
      // The first measurement, or the engine was reset under us. A peak from
      // before a reset belongs to audio that is no longer playing.
      _previous = 0;
      _current = 0;
      _bucket = bucket;
      _seeded = true;
    } else if (bucket != _bucket) {
      // One bucket on carries the last one. Further than that is a silence
      // longer than the window, and there is nothing in it to carry.
      _previous = bucket == _bucket + 1 ? _current : 0;
      _current = 0;
      _bucket = bucket;
    }

    // The whole published block, not just the frames that are new since the
    // last one: a maximum cannot double-count, and the few milliseconds of
    // overlap cost nothing. Every module reads this buffer as interleaved
    // pairs, a mono source included — see `MeterSource.scope`.
    final scope = engine.scope;
    var peak = _current;
    for (var i = 0; i < published; i++) {
      final mid = (scope[i * 2] + scope[i * 2 + 1]) * 0.5;
      if (mid > peak) peak = mid;
    }
    _current = peak;
  }
}

// ---------------------------------------------------------------------------
// The history
// ---------------------------------------------------------------------------

/// How much audio the module keeps for the triggered display.
///
/// The longest triggered span plus somewhere to search before it. Sized in
/// seconds rather than frames because the whole point is to hold a span the
/// user chose in seconds, at whatever rate the source turns out to run at: at
/// 48 kHz this is 14,400 frames and at 192 kHz it is 57,600, and both are the
/// same 0.3 s of signal.
const double _keptSeconds = 0.3;

/// The furthest back a trigger may be found, so the picture is never more than
/// a couple of published measurements stale.
const double _searchSeconds = 0.03;

/// Below this peak there is nothing to lock on to and the display free-runs,
/// which is what a scope does rather than triggering on a noise floor.
const double _triggerFloor = 1e-4;

/// The trigger's hysteresis, as a fraction of the peak in the search window.
///
/// Relative rather than absolute so that a quiet passage still triggers and a
/// loud one does not trigger on the ripple riding on it. The *level* stays at
/// zero — a rising zero crossing is what makes the drawn waveform start in the
/// same place every time.
const double _triggerHysteresis = 0.05;

/// What the painter draws, kept between frames.
///
/// Separated from the painter because a painter is rebuilt on every `build` and
/// this is the module's memory. Two things live here: a ring of raw frames,
/// which the triggered display searches and slices; and a ring of min/max
/// columns, which the rolling display scrolls. Only one is fed at a time.
///
/// Both are bounded — the raw ring by [_keptSeconds] and the column ring by the
/// module's own width — because a display that keeps history in proportion to
/// how long it has been open is the defect that once took this application to
/// 266 GB. See the header of `spectrogram.dart`.
class _ScopeHistory {
  /// Interleaved (L, R), oldest at [_rawWrite] once full.
  Float32List _raw = Float32List(0);
  int _rawFrames = 0;
  int _rawWrite = 0;
  int _rawFilled = 0;

  /// Which colour each column is drawn in at [ColorRamp.rgb]: the balance of
  /// low, mid and high content in the block it came from, quantised into
  /// [_mixColors] — or [_noMix] for a column nothing was published for, and for
  /// one whose block carried no spectrum.
  ///
  /// **Recorded with the column, not read off the newest measurement.** The
  /// colour is part of what the display remembers: a kick two seconds ago was
  /// red then and has to still be red now, and a display that coloured its whole
  /// history from the block being drawn would flash the entire waveform on every
  /// beat.
  Uint8List _tone = Uint8List(0);

  /// The colour the measurement being folded in belongs to, or [_noMix].
  int _blockTone = _noMix;

  /// One min/max pair per column, per channel. NaN is a column no audio was
  /// published for, and it is drawn as a gap rather than as silence.
  Float32List _minL = Float32List(0);
  Float32List _maxL = Float32List(0);
  Float32List _minR = Float32List(0);
  Float32List _maxR = Float32List(0);

  /// Samples, when a column holds fewer than one of them.
  Float32List _traceL = Float32List(0);
  Float32List _traceR = Float32List(0);

  /// Written by the painter, read back by it. `x, y, x, y` per column when
  /// the display is columns; `x, y` per sample when it is a trace.
  Float32List segments = Float32List(0);
  Float32List overSegments = Float32List(0);

  /// The used prefix of [segments], for the trace's single polyline.
  ///
  /// A polyline has no tail to park — every point in the buffer is joined to
  /// the next, so a parked one would be stroked to and back. The view is cut
  /// once and kept, because the length only changes when the span, the width
  /// or the sample rate does; cutting it per lane per frame is the allocation
  /// on the paint path this module does not make.
  Float32List _polyline = Float32List(0);

  Float32List polyline(int points) {
    if (_polyline.length != points * 2) {
      _polyline = Float32List.sublistView(segments, 0, points * 2);
    }
    return _polyline;
  }

  int _columns = 0;
  int _sampleRate = 0;
  ScopeTimeBase? _base;

  /// The width of a tempo-locked window in quarter notes, or null when the
  /// display is free-running.
  ///
  /// Quarters and not seconds, deliberately: the column a sample lands in is
  /// its *musical* position, so a tempo that drifts moves the audio through the
  /// window without moving the window. Seconds here would re-cut the display
  /// every time the host nudged its tempo.
  double? _quarters;

  /// The column the phase-locked display is currently filling, or -1.
  int _syncedColumn = -1;

  /// Whether the display is swept from a trigger rather than rolled or
  /// searched. Part of the shape: switching it clears what is on screen,
  /// because a rolling picture and a swept one put different audio in the same
  /// column.
  bool _sweep = false;

  /// The amplitude the sweep fires at. **Not** part of the shape — it is
  /// dragged, and re-cutting the display on every pointer event would mean
  /// nothing was ever on screen to aim at.
  double _level = 1;

  /// How much of the sweep has been written, or -1 when it is waiting for a
  /// trigger. Columns when the display is columns, samples when it is a trace.
  int _swept = -1;

  /// Whether the signal has been below [_level] since the last trigger.
  ///
  /// What makes the trigger a *rising* crossing rather than a level test. A
  /// sustain sitting above the threshold retriggers on every sample without
  /// it, which draws the same fifth of a window over and over.
  bool _armed = false;

  /// Next column to write, which in a full ring is also the oldest.
  int _cursor = 0;

  /// Frames folded into the column being built, and its running extremes.
  double _fill = 0;
  double _pMinL = 0;
  double _pMaxL = 0;
  double _pMinR = 0;
  double _pMaxR = 0;
  bool _pEmpty = true;

  /// −1 until the first measurement, so the first difference is not taken
  /// against a zero that means "unknown" rather than "the start".
  double _elapsed = -1;

  bool _dirty = true;

  /// Column `i` from the left edge is at `(origin + i) % columns`.
  int origin = 0;

  /// Points in [_traceL] / [_traceR], or zero when the display is columns.
  int traceCount = 0;

  /// The colour per column, and the one the newest block sits in — which is what
  /// a *trace* is drawn in, because a polyline is one colour and a trace window
  /// is a fraction of a block wide.
  Uint8List get tone => _tone;
  int get blockTone => _blockTone;

  Float32List get minL => _minL;
  Float32List get maxL => _maxL;
  Float32List get minR => _minR;
  Float32List get maxR => _maxR;
  Float32List get traceL => _traceL;
  Float32List get traceR => _traceR;
  int get columns => _columns;

  /// Frames of audio one column of the rolling display covers.
  double get _framesPerColumn => _columns == 0 || _base == null
      ? 0
      : _base!.seconds * _sampleRate / _columns;

  /// Frames of audio the whole width holds.
  int get _spanFrames =>
      _base == null ? 0 : (_base!.seconds * _sampleRate).round();

  /// Whether a column holds fewer than one sample, so the display is a trace.
  ///
  /// The same test [resolve] applies to the triggered display, and it is
  /// arithmetic rather than a mode — see the module header.
  bool get _traceWide => _spanFrames < _columns;

  /// Sizes the buffers, and clears them when the shape of the display changed.
  ///
  /// A different width or a different span is a different set of columns and
  /// none of the old ones mean anything at the new scale. Redrawing them anyway
  /// would show the last screen stretched or squeezed for as long as it took to
  /// scroll off, which reads as the meter having glitched. The spectrogram
  /// clears on a resize for the same reason.
  void configure({
    required int columns,
    required ScopeTimeBase base,
    required int sampleRate,
    required double? quarters,
    required bool sweep,
    required double level,
  }) {
    _level = level;
    if (columns == _columns &&
        base == _base &&
        sampleRate == _sampleRate &&
        quarters == _quarters &&
        sweep == _sweep) {
      return;
    }
    _sweep = sweep;

    final kept = sampleRate <= 0 ? 0 : (sampleRate * _keptSeconds).ceil();
    if (kept != _rawFrames) {
      _raw = Float32List(kept * 2);
      _rawFrames = kept;
      _rawWrite = 0;
      _rawFilled = 0;
    }

    if (columns != _columns) {
      _minL = Float32List(columns);
      _maxL = Float32List(columns);
      _minR = Float32List(columns);
      _maxR = Float32List(columns);
      _traceL = Float32List(columns);
      _traceR = Float32List(columns);
      _tone = Uint8List(columns);
      segments = Float32List(columns * 4);
      overSegments = Float32List(columns * 4);
      // The view above is into the buffer that has just been replaced.
      _polyline = Float32List(0);
      _columns = columns;
    }

    _base = base;
    _sampleRate = sampleRate;
    _quarters = quarters;
    _clearColumns();
    _dirty = true;
  }

  /// Forgets everything, for a source that has no relationship to the last.
  void reset() {
    _rawWrite = 0;
    _rawFilled = 0;
    _elapsed = -1;
    _clearColumns();
    _dirty = true;
  }

  /// Folds one published measurement in.
  ///
  /// [coloured] is whether the display is drawing [ColorRamp.rgb], and it gates
  /// the only thing here that reads anything but the scope buffer: **the band
  /// mix is not taken when nothing is going to draw it.** A 512-band pass
  /// forty-seven times a second for a setting that is off by default is work
  /// this module does not do, and a source is only asked for a spectrum by a
  /// display that is colouring by one.
  ///
  /// What that costs is at the moment of the switch: columns folded in before it
  /// carry no balance and keep the accent until they scroll off, which is a
  /// second at the default span and stays there indefinitely on a held sweep.
  /// The alternative is clearing the display to change a colour, which is worse
  /// — the spectrogram repaints its history in place for exactly this reason and
  /// this module cannot, because what it would have to repaint from is a
  /// measurement it never took.
  void ingest(MeterSource engine, {required bool coloured}) {
    // Measurements arrive before the first paint, which is what configures
    // this. There is nothing yet to fold them into, and nothing on screen for
    // them to be missing from.
    if (_base == null) return;

    final scope = engine.scope;
    // Not `scope.length`: over a wire the list is allocated at the protocol's
    // maximum and only partly filled, and how much of it is this measurement's
    // is the difference between a contiguous trace and one that resets every
    // frame. See `MeterSource.scopeFrames`.
    final published = engine.scopeFrames;
    if (_sampleRate <= 0 || _rawFrames == 0 || published == 0) return;

    final elapsed = engine.elapsedSeconds;
    if (elapsed.isNaN) return;

    // The colour every column this measurement fills will be drawn in. Taken
    // once per publish rather than per column: one publish is one analysis
    // block, and its spectrum is the spectrum *of* that block — the two describe
    // the same 1024 frames, which is exactly what makes the colour honest.
    _blockTone = coloured ? _mixOf(engine) : _noMix;

    if (_elapsed < 0 || elapsed < _elapsed) {
      // The first measurement, or the engine was reset under us. Neither can be
      // folded into what is on screen: the arithmetic below turns elapsed time
      // into a count of new frames, and across a reset that count is a negative
      // number of samples nobody played.
      _elapsed = elapsed;
      _rawWrite = 0;
      _rawFilled = 0;
      _clearColumns();
      _dirty = true;
      return;
    }

    final fresh = ((elapsed - _elapsed) * _sampleRate).round();
    _elapsed = elapsed;
    if (fresh <= 0) return;

    final taken = fresh < published ? fresh : published;
    final missed = fresh - taken;
    final first = published - taken;

    if (missed > 0) {
      // More audio was measured than the window still holds — a link that
      // dropped a frame, a file pushed through faster than real time, or a
      // source that outran four blocks between two looks. Those samples are
      // gone and this module will not pretend they are not: the raw ring can
      // no longer claim to be contiguous, and the rolling display gets that
      // many columns of nothing.
      _rawWrite = 0;
      _rawFilled = 0;
      if (_sweep) {
        // A sweep is one continuous stretch of audio drawn once across the
        // width, and this is a hole in the middle of it. There is no such thing
        // as a sweep with a gap, so it is abandoned: what is on screen stays,
        // and the next trigger starts a capture that is whole.
        _swept = -1;
        _armed = false;
      } else {
        _rollGap(missed);
      }
    }

    // A phase-locked display searches for nothing and scrolls nowhere, so it
    // needs neither the raw ring nor the rolling cursor — every sample goes
    // straight to the column its musical position falls in.
    if (_quarters != null) {
      _rollSynced(engine, scope, first, taken);
      _dirty = true;
      return;
    }

    // A swept display needs no raw ring either: its trigger is the audio
    // arriving rather than something to look back through, so every sample goes
    // to the column the sweep is on.
    if (_sweep) {
      _sweepAudio(scope, first, taken);
      _dirty = true;
      return;
    }

    _appendRaw(scope, first, taken);
    if (!_base!.isTriggered) _rollAudio(scope, first, taken);
    _dirty = true;
  }

  /// Waits for a rising crossing of [_level], then draws forward from it.
  ///
  /// The whole of [ScopeTrigger.transient]. Two things are worth saying about
  /// the shape of it:
  ///
  /// **The sample that fires the trigger is the first sample drawn**, which is
  /// what puts the transient itself at the left edge rather than a column of
  /// whatever preceded it.
  ///
  /// **The column display appears as it is written and the trace display only
  /// when it is finished.** Not an inconsistency: a column has NaN for "no
  /// audio here" and a half-drawn sweep at five seconds across the width is
  /// worth watching arrive, while a trace has no such value — a partly filled
  /// buffer would be drawn as a line through zero — and at the spans where a
  /// trace is the picture the whole sweep lands inside one published block
  /// anyway.
  void _sweepAudio(Float32List scope, int first, int count) {
    final span = _spanFrames;
    if (span < 2 || _columns == 0) return;
    final trace = _traceWide;
    final perColumn = trace ? 1.0 : _framesPerColumn;
    final limit = trace ? span : _columns;
    if (perColumn <= 0) return;

    for (var i = 0; i < count; i++) {
      final l = scope[(first + i) * 2];
      final r = scope[(first + i) * 2 + 1];

      if (_swept < 0) {
        // Waiting, and drawing nothing: the last capture is the picture until
        // there is a new one. Mid rather than either channel, so the level
        // means the same thing here as the zero crossing does in [_findTrigger]
        // and a trigger is not taken from a channel that is not on screen.
        final mid = (l + r) * 0.5;
        if (!_armed) {
          if (mid < _level) _armed = true;
          continue;
        }
        if (mid < _level) continue;
        _swept = 0;
        _armed = false;
        _fill = 0;
        _pEmpty = true;
      }

      if (trace) {
        _traceL[_swept] = l;
        _traceR[_swept] = r;
        _swept++;
      } else {
        if (_pEmpty) {
          _pMinL = _pMaxL = l;
          _pMinR = _pMaxR = r;
          _pEmpty = false;
        } else {
          if (l < _pMinL) {
            _pMinL = l;
          } else if (l > _pMaxL) {
            _pMaxL = l;
          }
          if (r < _pMinR) {
            _pMinR = r;
          } else if (r > _pMaxR) {
            _pMaxR = r;
          }
        }

        _fill += 1;
        if (_fill >= perColumn) {
          _fill -= perColumn;
          _minL[_swept] = _pMinL;
          _maxL[_swept] = _pMaxL;
          _minR[_swept] = _pMinR;
          _maxR[_swept] = _pMaxR;
          _tone[_swept] = _blockTone;
          _pEmpty = true;
          _swept++;
        }
      }

      if (_swept >= limit) {
        _swept = -1;
        if (trace) traceCount = span;
      }
    }
  }

  /// Folds new audio into the columns its *musical* position falls in.
  ///
  /// The whole of tempo sync. Each sample's position in quarter notes is the
  /// playhead at the start of the block plus however many samples into it the
  /// sample is; the column is where that lands inside one window of the chosen
  /// division. A pass over the window therefore overwrites the previous pass in
  /// place, and anything periodic with the bar — a kick, a gate, the attack of
  /// a loop — is drawn in the same column every time and stands still.
  ///
  /// **Nothing is written while the transport is parked.** A stopped playhead
  /// reports the same position for every block, so every sample would land in
  /// one column and pile the room tone of a stopped session into a single
  /// stripe. A frozen picture is the honest one: it is what was last played.
  void _rollSynced(
    MeterSource engine,
    Float32List scope,
    int first,
    int count,
  ) {
    final transport = engine.transport;
    if (!transport.isPlaying) return;

    final quartersPerFrame = transport.bpm / 60 / _sampleRate;
    final window = _quarters!;
    if (!(quartersPerFrame > 0) || !(window > 0)) return;

    for (var i = 0; i < count; i++) {
      final ppq = transport.ppqPosition + (first + i) * quartersPerFrame;
      var phase = (ppq % window) / window;
      if (phase < 0) phase += 1;
      var column = (phase * _columns).floor();
      if (column < 0) column = 0;
      if (column >= _columns) column = _columns - 1;

      if (column != _syncedColumn) {
        _writeSynced();
        _syncedColumn = column;
      }

      final l = scope[(first + i) * 2];
      final r = scope[(first + i) * 2 + 1];
      if (_pEmpty) {
        _pMinL = _pMaxL = l;
        _pMinR = _pMaxR = r;
        _pEmpty = false;
      } else {
        if (l < _pMinL) {
          _pMinL = l;
        } else if (l > _pMaxL) {
          _pMaxL = l;
        }
        if (r < _pMinR) {
          _pMinR = r;
        } else if (r > _pMaxR) {
          _pMaxR = r;
        }
      }
    }
    // **The column being filled is deliberately left unwritten.** A column is a
    // few hundred frames wide and a published block is about a thousand, so the
    // column the block ends in is usually only part measured — and writing it
    // here would finalise it, only for the next block's samples to land in the
    // same column and *replace* it rather than extend it. Every transient that
    // happened to fall in the last column of a block was drawn once and erased
    // a block later, which reads as a display that loses a beat now and again.
    // The extremes stay in the accumulator until the head moves on.
  }

  /// The accumulated extremes into the column they belong to, in place.
  ///
  /// Unlike [_pushColumn] this does not advance a cursor and does not blank an
  /// empty column: a column nothing arrived for this pass keeps what the last
  /// pass put there, which is what makes the display persist rather than chase
  /// a write head round an empty ring.
  void _writeSynced() {
    if (_pEmpty || _syncedColumn < 0) return;
    _minL[_syncedColumn] = _pMinL;
    _maxL[_syncedColumn] = _pMaxL;
    _minR[_syncedColumn] = _pMinR;
    _maxR[_syncedColumn] = _pMaxR;
    _tone[_syncedColumn] = _blockTone;
    _pEmpty = true;
  }

  /// Works out what the painter draws, once per change rather than per frame.
  void resolve() {
    if (!_dirty) return;
    _dirty = false;

    if (_base == null || _columns == 0) {
      traceCount = 0;
      return;
    }

    // Phase-locked: column zero is the start of the window, always. Nothing to
    // search for and nothing to scroll.
    if (_quarters != null) {
      traceCount = 0;
      origin = 0;
      return;
    }

    // Swept: the trigger was found in the audio as it arrived and the columns
    // were written forward from it, so there is nothing here to resolve but
    // where the left edge is — and nothing that may be cleared, because
    // between triggers what is on screen *is* the picture. [traceCount] is the
    // sweep's own and is not reset here.
    if (_sweep) {
      origin = 0;
      return;
    }

    traceCount = 0;

    if (!_base!.isTriggered) {
      // The rolling display is already in the columns; the oldest is the one
      // about to be overwritten.
      origin = _cursor;
      return;
    }

    origin = 0;
    _blankColumns();

    final span = (_base!.seconds * _sampleRate).round();
    // One frame of slack, so the window always has a sample before it for the
    // crossing test rather than starting on the oldest frame there is.
    if (span < 2 || _rawFilled < span + 1) return;

    final latest = _rawFilled - span;
    final search = math.min(
      latest,
      math.max(span, (_sampleRate * _searchSeconds).round()),
    );
    final start = _findTrigger(latest, search);

    if (span < _columns) {
      _readTrace(start, span);
    } else {
      _readColumns(start, span);
    }
  }

  // --- Filling ------------------------------------------------------------

  void _appendRaw(Float32List scope, int first, int count) {
    var from = first;
    var left = count;
    if (left > _rawFrames) {
      // More than the ring holds. Keep the newest of it and drop the rest,
      // which is what the ring was going to do anyway.
      from += left - _rawFrames;
      left = _rawFrames;
    }
    while (left > 0) {
      final room = _rawFrames - _rawWrite;
      final take = left < room ? left : room;
      _raw.setRange(_rawWrite * 2, (_rawWrite + take) * 2, scope, from * 2);
      _rawWrite = (_rawWrite + take) % _rawFrames;
      from += take;
      left -= take;
    }
    _rawFilled = math.min(_rawFilled + count, _rawFrames);
  }

  void _rollAudio(Float32List scope, int first, int count) {
    final perColumn = _framesPerColumn;
    if (perColumn <= 0) return;

    for (var i = 0; i < count; i++) {
      final l = scope[(first + i) * 2];
      final r = scope[(first + i) * 2 + 1];
      if (_pEmpty) {
        _pMinL = _pMaxL = l;
        _pMinR = _pMaxR = r;
        _pEmpty = false;
      } else {
        if (l < _pMinL) {
          _pMinL = l;
        } else if (l > _pMaxL) {
          _pMaxL = l;
        }
        if (r < _pMinR) {
          _pMinR = r;
        } else if (r > _pMaxR) {
          _pMaxR = r;
        }
      }

      _fill += 1;
      if (_fill >= perColumn) {
        _fill -= perColumn;
        _pushColumn();
      }
    }
  }

  void _rollGap(int frames) {
    final perColumn = _framesPerColumn;
    if (perColumn <= 0) return;
    final blank = (frames / perColumn).round();
    if (blank >= _columns) {
      _clearColumns();
      return;
    }
    _pushColumn();
    for (var i = 0; i < blank; i++) {
      _pushBlank();
    }
    _fill = 0;
  }

  /// The balance of this block's three bands, as an index into the scope's
  /// palette.
  ///
  /// Low, mid and high are the three thirds of the analyser's axis — 20–200 Hz,
  /// 200 Hz–2 kHz, 2–20 kHz, see `kLowBandTop` — summed as power from the bands
  /// the engine published, then compared **in decibels against the loudest of
  /// the three** over [_mixRangeDb]. That last step is the whole trick: bass
  /// carries an order of magnitude more power than air does in every piece of
  /// music, so a mix weighted by power draws all of them red, and a mix weighted
  /// by decibels draws what somebody would say they were hearing.
  ///
  /// **Nothing here measures anything.** Every number comes from the bands the
  /// engine published for this block; when there are none — a source with no
  /// spectrum, or a passage with nothing above the floor — the answer is [_noMix]
  /// and the module keeps its accent, which claims nothing.
  static int _mixOf(MeterSource engine) {
    if (!engine.hasSpectrum) return _noMix;
    final spectrum = engine.spectrum;
    final bands = spectrum.length;
    if (bands < 3) return _noMix;
    final power = [0.0, 0.0, 0.0];
    for (var band = 0; band < bands; band++) {
      final db = spectrum[band];
      if (db.isNaN || db <= _mixFloorDb) continue;
      final tone = band / (bands - 1);
      final of = tone < kLowBandTop
          ? 0
          : tone < kMidBandTop
          ? 1
          : 2;
      power[of] += math.pow(10, db / 10).toDouble();
    }

    var loudest = 0.0;
    for (final band in power) {
      if (band > loudest) loudest = band;
    }
    if (!(loudest > 0)) return _noMix;

    var index = 0;
    for (final band in power) {
      // Decibels below the loudest band, as a weight over the window. A band
      // that is not there at all is `-infinity` and clamps to nothing, which is
      // what the arithmetic does on its own.
      final under = band <= 0
          ? _mixRangeDb
          : 10 * math.log(loudest / band) / math.ln10;
      final weight = (1 - under / _mixRangeDb).clamp(0.0, 1.0);
      index = index * _mixSteps + (weight * (_mixSteps - 1)).round();
    }
    return index;
  }

  void _pushColumn() {
    if (_pEmpty) {
      _pushBlank();
      return;
    }
    _minL[_cursor] = _pMinL;
    _maxL[_cursor] = _pMaxL;
    _minR[_cursor] = _pMinR;
    _maxR[_cursor] = _pMaxR;
    _tone[_cursor] = _blockTone;
    _cursor = (_cursor + 1) % _columns;
    _pEmpty = true;
  }

  void _pushBlank() {
    _minL[_cursor] = double.nan;
    _maxL[_cursor] = double.nan;
    _minR[_cursor] = double.nan;
    _maxR[_cursor] = double.nan;
    _tone[_cursor] = _noMix;
    _cursor = (_cursor + 1) % _columns;
  }

  void _clearColumns() {
    _blankColumns();
    _cursor = 0;
    _syncedColumn = -1;
    _swept = -1;
    _armed = false;
    _fill = 0;
    _pEmpty = true;
    origin = 0;
    traceCount = 0;
  }

  void _blankColumns() {
    _minL.fillRange(0, _minL.length, double.nan);
    _maxL.fillRange(0, _maxL.length, double.nan);
    _minR.fillRange(0, _minR.length, double.nan);
    _maxR.fillRange(0, _maxR.length, double.nan);
    _tone.fillRange(0, _tone.length, _noMix);
  }

  // --- Reading ------------------------------------------------------------

  /// The ring slot holding the frame [age] positions after the oldest kept one.
  int _slot(int age) =>
      (_rawWrite - _rawFilled + age + _rawFrames * 2) % _rawFrames;

  /// The most recent rising zero crossing at or before [latest], or [latest].
  ///
  /// Two passes rather than one because the hysteresis is a fraction of the
  /// peak and the peak is not known until the window has been walked. Both are
  /// bounded by [_searchSeconds] of audio.
  int _findTrigger(int latest, int search) {
    final from = latest - search;

    var peak = 0.0;
    var at = _slot(from);
    for (var k = from; k <= latest; k++) {
      final mid = (_raw[at * 2] + _raw[at * 2 + 1]) * 0.5;
      final level = mid < 0 ? -mid : mid;
      if (level > peak) peak = level;
      if (++at == _rawFrames) at = 0;
    }
    if (peak < _triggerFloor) return latest;

    final gate = peak * _triggerHysteresis;
    var armed = false;
    var found = -1;
    at = _slot(from);
    for (var k = from; k <= latest; k++) {
      final mid = (_raw[at * 2] + _raw[at * 2 + 1]) * 0.5;
      if (armed) {
        if (mid >= gate) {
          found = k;
          armed = false;
        }
      } else if (mid <= -gate) {
        armed = true;
      }
      if (++at == _rawFrames) at = 0;
    }
    return found < 0 ? latest : found;
  }

  /// [span] frames from [start], one point per sample.
  void _readTrace(int start, int span) {
    var at = _slot(start);
    for (var i = 0; i < span; i++) {
      _traceL[i] = _raw[at * 2];
      _traceR[i] = _raw[at * 2 + 1];
      if (++at == _rawFrames) at = 0;
    }
    traceCount = span;
  }

  /// [span] frames from [start], as one min/max pair per column.
  void _readColumns(int start, int span) {
    var at = _slot(start);
    for (var column = 0; column < _columns; column++) {
      final until = ((column + 1) * span) ~/ _columns;
      var lo = _raw[at * 2];
      var hi = lo;
      var loR = _raw[at * 2 + 1];
      var hiR = loR;

      for (var k = (column * span) ~/ _columns; k < until; k++) {
        final l = _raw[at * 2];
        final r = _raw[at * 2 + 1];
        if (l < lo) {
          lo = l;
        } else if (l > hi) {
          hi = l;
        }
        if (r < loR) {
          loR = r;
        } else if (r > hiR) {
          hiR = r;
        }
        if (++at == _rawFrames) at = 0;
      }

      _minL[column] = lo;
      _maxL[column] = hi;
      _minR[column] = loR;
      _maxR[column] = hiR;
      // **The newest block's hue across the whole window, not a hue per
      // column.** A triggered window is 5 to 200 ms — a fraction of one
      // published block at the short end and nine of them at the long — and
      // these columns are re-cut out of the raw ring every frame rather than
      // accumulated, so there is no column here that a single measurement
      // filled. One colour for one window is the honest shape of that: it says
      // where the energy sits in the audio being shown, which at this span is
      // one sound rather than a sequence of them.
      _tone[column] = _blockTone;
    }
  }
}

// ---------------------------------------------------------------------------
// The painter
// ---------------------------------------------------------------------------

class _OscilloscopePainter extends MeterPainter {
  _OscilloscopePainter({
    required this.engine,
    required this.colors,
    required this.state,
    required this.timeBase,
    required this.sync,
    required this.division,
    required this.grid,
    required this.stereo,
    required this.front,
    required this.trigger,
    required this.threshold,
    required this.zoom,
    required this.ramp,
    required this.chrome,
    required Listenable repaint,
  }) : _grid = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _centre = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline),
       _signal = (Paint()
         ..color = colors.accent
         ..strokeWidth = OaaStroke.hairline
         ..strokeCap = StrokeCap.butt),
       // The second channel of an overlaid pair. A second `Paint` rather than
       // a colour set per draw, because the two are alive at the same time and
       // one of them is mutated mid-frame — see `_paintTrace`.
       _second = (Paint()
         ..color = colors.accent.withValues(alpha: _dim)
         ..strokeWidth = OaaStroke.hairline
         ..strokeCap = StrokeCap.butt),
       // The trigger level, which is chrome and brighter than the graticule
       // because it is a line somebody has put there. Never `accent`, `warn` or
       // `over`: those three are verdicts on the signal everywhere else on this
       // canvas, and a level is a setting.
       _level = (Paint()
         ..color = colors.hairlineStrong
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _over = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.hairline
         ..strokeCap = StrokeCap.butt),
       _overMark = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.mark
         ..strokeCap = StrokeCap.butt),
       // One box around the body, not one per lane. The lanes are two views of
       // one window — the same milliseconds, the same time base, one graticule
       // drawn through both — and boxing them separately would say they were
       // two displays that happen to be stacked. The gap between them already
       // separates them.
       _border = PlotBorder(colors),
       super(repaint: repaint) {
    // One ink per palette entry and a dimmed twin of each, built here because a
    // painter is built when the skin, the ramp or a setting moves and never on
    // the frame path. Nothing at all at [ColorRamp.skin] — there is one colour
    // there and `_signal` is already it.
    if (ramp != ColorRamp.rgb) return;
    for (var bucket = 0; bucket <= _mixColors; bucket++) {
      // Unpacked in the order `_mixOf` packed it: low, then mid, then high, each
      // a weight in five steps. The last bucket is not a mix — a block with no
      // spectrum behind it keeps the accent, because nothing is known about its
      // balance. See [_noMix].
      final steps = _mixSteps - 1;
      final ink = bucket == _noMix
          ? colors.accent
          : ramp.mixAt(
              bucket ~/ (_mixSteps * _mixSteps) / steps,
              bucket ~/ _mixSteps % _mixSteps / steps,
              bucket % _mixSteps / steps,
              colors,
            );
      _hueInk.add(
        Paint()
          ..color = ink
          ..strokeWidth = OaaStroke.hairline
          ..strokeCap = StrokeCap.butt
          ..isAntiAlias = false,
      );
      _hueInkDim.add(
        Paint()
          ..color = ink.withValues(alpha: _dim)
          ..strokeWidth = OaaStroke.hairline
          ..strokeCap = StrokeCap.butt
          ..isAntiAlias = false,
      );
    }
  }

  final MeterSource engine;
  final OaaColors colors;
  final _OscilloscopeModuleState state;
  final ScopeTimeBase timeBase;
  final ScopeSync sync;
  final ScopeDivision division;
  final ScopeGrid grid;
  final ScopeStereo stereo;
  final ScopeFront front;
  final ScopeTrigger trigger;
  final double threshold;
  final double zoom;

  /// Whether the strip below is carrying the legend and the span.
  ///
  /// True on a module wide enough for the strip's two end cells, and false
  /// everywhere else — a narrow module, and every remote display, which has no
  /// strip at all because it has no layout to write a setting to. When it is
  /// false these two are drawn in the plot's corners, which is where they were
  /// before the strip existed. See `build`.
  final bool chrome;

  /// Which colours the trace is drawn in. See [ColorRamp] — at
  /// [ColorRamp.skin] `_signal` and `_second` are the whole of it and the two
  /// lists below stay empty.
  final ColorRamp ramp;

  final Paint _grid;
  final Paint _centre;
  final Paint _signal;
  final Paint _second;
  final Paint _level;
  final Paint _over;
  final Paint _overMark;
  final PlotBorder _border;

  /// One ink per palette entry, and the same again at the weight the second of
  /// two overlaid channels is drawn at. Indexed by entry, [_noMix] included.
  final List<Paint> _hueInk = [];
  final List<Paint> _hueInkDim = [];

  @override
  void paint(Canvas canvas, Size size) {
    // The box, and the window inside it — see [PlotBorder]. It matters here
    // for the reason it matters on the spectrogram: a rolling trace puts the
    // newest audio hard against the right-hand edge, and a border over it
    // would hide the one column somebody is watching. Everything below is
    // drawn in the window's own coordinates, so nothing else in this painter
    // knows about it.
    _border.paint(canvas, Offset.zero & size);

    final window = PlotBorder.inside(Offset.zero & size);
    if (window.width <= 0 || window.height <= 0) return;

    canvas.save();
    canvas.translate(window.left, window.top);
    _paintWindow(canvas, window.size);
    canvas.restore();
  }

  /// Everything the module draws: the graticule, the traces and the labels.
  ///
  /// [size] is the window inside the border, not the body. See [paint].
  void _paintWindow(Canvas canvas, Size size) {
    final columns = size.width.floor();
    if (columns < 2 || size.height < _laneLabelAbove) return;

    // **A window can only be locked to a tempo somebody is reporting.** A
    // sound card has no playhead and neither does a DAW that never mentions
    // one, and a display that quietly drew a free window while its label said
    // `1 bar` would be the most convincing kind of wrong. When there is nothing
    // to lock to the module falls back to the free window *and to its label*,
    // so what is written in the corner is always what is drawn above it.
    final transport = engine.transport;
    final locked =
        sync == ScopeSync.tempo &&
        transport.hasBpm &&
        transport.bpm > 0 &&
        transport.hasPpq;
    final quarters = locked
        ? division.quartersIn(transport) * grid.factor
        : null;

    // **A trigger and a bar line cannot both decide where the window starts.**
    // The locked window is placed by the host and the swept one by the signal,
    // so the sweep is offered where the time base is — to a free-running
    // display — and a module set to both draws the locked window. The menu
    // offers them the same way round, and the level's own control is drawn only
    // where it is doing something. See [ScopeTrigger].
    final sweeping = sync == ScopeSync.free && trigger.sweeps;
    final level = ScopeThreshold.amplitude(threshold);

    final history = state._history;
    history.configure(
      columns: columns,
      base: timeBase,
      sampleRate: engine.sampleRate,
      quarters: quarters,
      sweep: sweeping,
      level: level,
    );

    // Note what is *not* here: the audio was folded in by
    // `_OscilloscopeModuleState._measured`, off the clock's unthrottled
    // measurement channel. Paint also runs on a resize and on a theme change,
    // and a display that advanced on those would invent time no audio passed
    // through — the same rule the other history modules reach by gating on
    // `generation`, from the other end.
    history.resolve();

    // What there is to draw, and how many rows it is drawn in. See
    // [_channelsOf] — a mono source is one trace whatever the arrangement says.
    final channels = _channelsOf(engine);
    final rows = stereo == ScopeStereo.overlay ? 1 : channels;
    final gap = rows > 1 ? Space.xs : 0.0;
    final laneHeight = (size.height - gap * (rows - 1)) / rows;
    if (laneHeight < OaaStroke.mark * 2) return;
    // Inset by the stroke so a full-scale sample is drawn inside the lane
    // rather than half outside it, where the clip takes it.
    final half = laneHeight / 2 - OaaStroke.hairline;

    // Where the trigger sits, drawn only while it is inside the lane: a level
    // the zoom has pushed off the top is drawn nowhere rather than pinned to
    // the edge, where it would read as a border. The slider beside it prints
    // the number either way.
    final zoomed = level * zoom;
    _paintGrid(
      canvas,
      size,
      rows,
      laneHeight,
      gap,
      half,
      quarters,
      sweeping && zoomed <= 1 ? zoomed : null,
    );

    // **Back first, front last, and the front one at full ink.** Two overlaid
    // traces cross constantly, and the one drawn second is the one you read
    // *through* the other — so which channel is in front is both which is drawn
    // last and which keeps the undimmed colour. It is a setting because it has
    // no right answer: it is whichever channel you are looking at. See
    // [ScopeFront] and `_ScopeKey`, which is the control.
    //
    // In lanes there is no front. Each trace has its own centre line and hides
    // nothing, so the pass order below is simply left then right.
    final frontChannel = rows == 1 && channels > 1 && front == ScopeFront.right
        ? 1
        : 0;
    for (var pass = 0; pass < channels; pass++) {
      final channel = frontChannel == 1 ? 1 - pass : pass;
      final row = rows == 1 ? 0 : channel;
      final centre = row * (laneHeight + gap) + laneHeight / 2;
      final low = channel == 0 ? history.minL : history.minR;
      final high = channel == 0 ? history.maxL : history.maxR;
      // Only the channel behind the other one is dimmed. In lanes each is on
      // its own centre line and there is nothing to tell it apart from.
      final dim = rows == 1 && channel != frontChannel;
      // At [ColorRamp.rgb] a *trace* is one colour — the newest block's, which is
      // what its whole window is — so the ink is picked here rather than per
      // point. The columns pick theirs per column; see [_paintColumns].
      final ink = ramp == ColorRamp.rgb
          ? (dim ? _hueInkDim : _hueInk)[history.blockTone]
          : (dim ? _second : _signal);

      if (history.traceCount > 0) {
        _paintTrace(
          canvas,
          size,
          history,
          channel == 0 ? history.traceL : history.traceR,
          centre,
          half,
          ink,
        );
      } else {
        _paintColumns(canvas, history, low, high, centre, half, ink, dim: dim);
      }
    }

    _paintLabels(canvas, size, rows, laneHeight, gap, channels, locked);
  }

  // --- Chrome -------------------------------------------------------------

  void _paintGrid(
    Canvas canvas,
    Size size,
    int lanes,
    double laneHeight,
    double gap,
    double half,
    double? quarters,
    double? level,
  ) {
    // **A tempo-locked window is divided into beats, not into tenths.** The
    // graticule is what says where in the bar something happened, and ten
    // equal columns across four beats puts a line at 2.4 of them. A window
    // narrower than a beat gets no internal lines at all, which is correct:
    // there is no beat inside it to mark.
    final divisions = quarters == null
        ? _divisions
        : quarters.round().clamp(1, _maxBeatDivisions);

    if (size.width / divisions >= _minDivision) {
      for (var i = 1; i < divisions; i++) {
        final x = (size.width * i / divisions).roundToDouble();
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), _grid);
      }
    }

    for (var lane = 0; lane < lanes; lane++) {
      final centre = lane * (laneHeight + gap) + laneHeight / 2;
      canvas.drawLine(Offset(0, centre), Offset(size.width, centre), _centre);
      if (level != null) {
        final y = (centre - level * half).roundToDouble();
        canvas.drawLine(Offset(0, y), Offset(size.width, y), _level);
      }
      if (laneHeight >= _halfScaleAbove) {
        final quarter = laneHeight / 4;
        canvas.drawLine(
          Offset(0, centre - quarter),
          Offset(size.width, centre - quarter),
          _grid,
        );
        canvas.drawLine(
          Offset(0, centre + quarter),
          Offset(size.width, centre + quarter),
          _grid,
        );
      }
    }
  }

  void _paintLabels(
    Canvas canvas,
    Size size,
    int rows,
    double laneHeight,
    double gap,
    int channels,
    bool locked,
  ) {
    // Below this there is nowhere for a letter or a number to sit that is not
    // on top of the waveform, and a module this small has already given up its
    // graticule for the same reason. What it loses is chrome; what it keeps is
    // the signal, which is the right way round.
    if (laneHeight < _laneLabelAbove) return;

    // Only when there are two of them. The letter distinguishes one channel
    // from the other, and a mono source draws one trace — labelling it `L`
    // would name a channel rather than the sum it is actually showing.
    if (channels > 1 && rows > 1) {
      for (var row = 0; row < rows; row++) {
        final label = row == 0 ? state._leftLabel : state._rightLabel;
        if (label == null) continue;
        canvas.drawParagraph(
          label,
          Offset(Space.xs, row * (laneHeight + gap) + Space.xxs),
        );
      }
    } else if (channels > 1 && !chrome) {
      // Overlaid: the two letters side by side, each in the ink its trace is
      // drawn in, the front one first. A legend rather than a label — see
      // `_leftKey`. Only where the strip is not carrying it as a control, which
      // is the arrangement this one is the fallback for; see [chrome].
      final leads = front == ScopeFront.left;
      final first = leads ? state._leftKey : state._rightKey;
      final second = leads ? state._rightKey : state._leftKey;
      if (first != null && second != null) {
        canvas.drawParagraph(first, const Offset(Space.xs, Space.xxs));
        canvas.drawParagraph(
          second,
          Offset(Space.xs + first.longestLine + Space.xxs, Space.xxs),
        );
      }
    }

    // The span, bottom right, over the graticule rather than in an axis row of
    // its own — a three-row module has no vertical space to spend on one, and
    // the number it would carry is the only thing an axis row would say. Where
    // there is a strip it is printed at the right-hand end of it instead, on
    // the row under the axis it describes; see [chrome].
    if (chrome) return;
    final span = locked ? state._divisionLabel : state._spanLabel;
    if (span != null) {
      canvas.drawParagraph(
        span,
        Offset(
          size.width - span.longestLine - Space.xs,
          size.height - span.height - Space.xxs,
        ),
      );
    }
  }

  // --- The signal ---------------------------------------------------------

  /// The columns, each drawn between the extremes of the samples that landed in
  /// it.
  ///
  /// **At [ColorRamp.rgb] the columns are sorted into hue buckets on the way
  /// out** and drawn as one `drawRawPoints` per colour, which is what lets a
  /// column carry the hue of the audio in it without becoming a draw call of its
  /// own. Everything about *where* a column is drawn is shared: the loop below
  /// runs once and the last few lines are the only place the two settings
  /// differ.
  void _paintColumns(
    Canvas canvas,
    _ScopeHistory history,
    Float32List low,
    Float32List high,
    double centre,
    double half,
    Paint ink, {
    required bool dim,
  }) {
    final columns = history.columns;
    final segments = history.segments;
    final over = history.overSegments;
    final rainbow = ramp == ColorRamp.rgb;
    final buckets = state._buckets;
    final tone = history.tone;
    if (rainbow) buckets.clear();
    var drawn = 0;
    var clipped = 0;

    // The previous column's drawn extent, or NaN across a gap and at the left
    // edge. See the overlap below.
    var previousTop = double.nan;
    var previousBottom = double.nan;

    for (var i = 0; i < columns; i++) {
      final slot = (history.origin + i) % columns;
      final hi = high[slot];
      // A column no audio was published for. Left as a gap, because the
      // alternative is drawing whatever the neighbouring samples were doing
      // across a stretch of time nobody measured.
      if (hi.isNaN) {
        previousTop = previousBottom = double.nan;
        continue;
      }
      final lo = low[slot];

      final x = i + 0.5;
      // **Snapped to the pixel grid, and drawn without antialiasing.** A
      // column is one pixel wide and as tall as the samples in it, and at a
      // short time base that is often a fraction of a pixel: the rasteriser
      // then spreads a third of the ink over one row and two thirds over the
      // next, and a run of such columns arrives as a line whose density
      // flickers sample by sample. Whole rows at full coverage are the same
      // measurement drawn so that a person can see it, and they are what a
      // waveform display has always been.
      var top = (centre - (hi * zoom).clamp(-1.0, 1.0) * half).roundToDouble();
      var bottom = (centre - (lo * zoom).clamp(-1.0, 1.0) * half)
          .roundToDouble();
      // A column whose extremes are equal — silence, or a held DC level — is a
      // zero-length segment, which draws nothing at all. A flat line is the
      // correct picture of a flat signal, so give it a pixel to be drawn in.
      if (bottom - top < OaaStroke.hairline) {
        bottom = top + OaaStroke.hairline;
      }

      // **Consecutive columns are made to overlap, or the trace comes apart.**
      // A column is drawn as the bar between the extremes of the samples that
      // landed in it, and at a short time base only one or two do — so on a
      // steep edge each bar is a dot a pixel tall, sitting several pixels above
      // or below its neighbour with nothing between them. The waveform then
      // reads as a dashed line, which is what the display looked like at every
      // span from 20 ms to about 100 ms: correct arithmetic, a picture of a
      // signal that was never there.
      //
      // Reaching to the neighbour's edge invents nothing. The samples either
      // side of a column boundary are consecutive samples of a continuous
      // waveform, so the signal did pass through every value between them;
      // what the extension draws is the connecting line a per-sample trace
      // would have drawn anyway. Only the *outermost* edges are measurements,
      // and neither of those moves.
      if (!previousTop.isNaN) {
        if (top > previousBottom) {
          top = previousBottom;
        } else if (bottom < previousTop) {
          bottom = previousTop;
        }
      }
      previousTop = top;
      previousBottom = bottom;

      // **The zoom is not part of this test.** A clip is a sample that reached
      // full scale, and a display that called one at 0.25 a clip because the
      // module is zoomed four times would be reporting something nobody
      // measured. What the zoom changes is where the lane's edge falls, and
      // the picture says that by running off it.
      if (hi >= 1.0 || lo <= -1.0) {
        over[clipped * 4] = x;
        over[clipped * 4 + 1] = top;
        over[clipped * 4 + 2] = x;
        over[clipped * 4 + 3] = bottom;
        clipped++;
      } else if (rainbow) {
        buckets.run(tone[slot], x, top, bottom);
      } else {
        segments[drawn * 4] = x;
        segments[drawn * 4 + 1] = top;
        segments[drawn * 4 + 2] = x;
        segments[drawn * 4 + 3] = bottom;
        drawn++;
      }
    }

    if (rainbow) {
      buckets.draw(canvas, ui.PointMode.lines, dim ? _hueInkDim : _hueInk);
    } else {
      segments.fillRange(drawn * 4, segments.length, _parked);
      ink.isAntiAlias = false;
      ink.strokeWidth = OaaStroke.hairline;
      canvas.drawRawPoints(ui.PointMode.lines, segments, ink);
    }
    if (clipped > 0) {
      over.fillRange(clipped * 4, over.length, _parked);
      _over.isAntiAlias = false;
      canvas.drawRawPoints(ui.PointMode.lines, over, _over);
    }
  }

  /// One point per sample, joined — the picture when a column holds fewer than
  /// one sample and there is nothing to take a minimum and a maximum of.
  ///
  /// **One polyline, not a segment per sample.** Independent segments meeting
  /// end to end are rasterised independently: each butt cap computes its own
  /// coverage, the shared endpoints composite twice and the pixels either side
  /// of them not at all, so a hairline trace arrives on screen with its density
  /// varying sample by sample and reads as a line that has been chewed. A
  /// polyline is one path, stroked once, with joins — the same ink everywhere.
  ///
  /// A polyline has no tail to park, because every point is joined to the next
  /// and a parked one would be stroked to and back across the module. The
  /// buffer is cut to length instead, once, by [_ScopeHistory.polyline].
  void _paintTrace(
    Canvas canvas,
    Size size,
    _ScopeHistory history,
    Float32List samples,
    double centre,
    double half,
    Paint ink,
  ) {
    final count = history.traceCount;
    if (count < 2) return;

    final line = history.polyline(count);
    final marks = history.overSegments;
    final step = (size.width - 1) / (count - 1);
    var clipped = 0;

    for (var i = 0; i < count; i++) {
      final sample = samples[i];
      final x = i * step;
      final y = centre - (sample * zoom).clamp(-1.0, 1.0) * half;

      line[i * 2] = x;
      line[i * 2 + 1] = y;

      // A tick rather than a point, so that the parked tail of the buffer is
      // a run of zero-length lines the rasteriser drops rather than a run of
      // squares it has to draw and clip. Taken from the sample and not from
      // the zoomed position it is drawn at — see the note in `_paintColumns`.
      if (sample <= -1.0 || sample >= 1.0) {
        marks[clipped * 4] = x;
        marks[clipped * 4 + 1] = y - OaaStroke.mark;
        marks[clipped * 4 + 2] = x;
        marks[clipped * 4 + 3] = y + OaaStroke.mark;
        clipped++;
      }
    }

    // The other way round from the columns: a trace is a diagonal, and a
    // diagonal without antialiasing is a staircase. It is drawn a half pixel
    // heavier for the same reason the columns are snapped — an antialiased
    // hairline running nearly flat puts half its ink in one row and half in
    // the next and reads as a line that is fading in and out, which is what a
    // one-pixel trace looked like along every peak and trough.
    ink.isAntiAlias = true;
    ink.strokeWidth = OaaStroke.mark;
    canvas.drawRawPoints(ui.PointMode.polygon, line, ink);
    if (clipped > 0) {
      marks.fillRange(clipped * 4, marks.length, _parked);
      canvas.drawRawPoints(ui.PointMode.lines, marks, _overMark);
    }
  }

  @override
  bool shouldRepaint(_OscilloscopePainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.timeBase != timeBase ||
      oldDelegate.sync != sync ||
      oldDelegate.division != division ||
      oldDelegate.grid != grid ||
      oldDelegate.stereo != stereo ||
      oldDelegate.front != front ||
      oldDelegate.chrome != chrome ||
      oldDelegate.trigger != trigger ||
      oldDelegate.threshold != threshold ||
      oldDelegate.zoom != zoom ||
      oldDelegate.ramp != ramp ||
      !identical(oldDelegate.engine, engine);
}
