// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Level against frequency, log-spaced, tilted, with a peak hold.
///
/// The horizontal axis needs no mapping code at all, and that is by design: the
/// engine's 512 bands are *already* log-spaced across 20 Hz to 20 kHz, so band
/// index is the axis and the only thing left to do is scale it to the width.
/// The alternative — publishing linear FFT bins and taking their logarithm here
/// — would put a `log` per bin per frame on the paint path and give every
/// module drawing frequency content its own opportunity to disagree about where
/// 1 kHz is.
///
/// Drawn as 512 vertical segments in a single `drawRawPoints` call rather than
/// as a filled `Path`. A path of 512 points rebuilt sixty times a second is
/// thirty thousand points of garbage a second per analyser; the segment buffer
/// below is allocated once and overwritten in place.
///
/// ---------------------------------------------------------------------------
/// Why the fill is a shader and not a colour
///
/// The band area is a vertical gradient — brightest along the curve, the base
/// colour a little down, still clearly present at the floor — which is what
/// keeps the top edge the brightest thing in the plot without hollowing the
/// fill out into an outline. That would normally want a filled `Path` with a
/// gradient, and the paragraph above is the reason it cannot have one.
///
/// It does not need one. A shader on the `Paint` is evaluated per pixel in
/// canvas space, so five hundred butt-capped vertical strokes drawn through it
/// produce exactly the same gradient a single filled path would. The shader is
/// built once and rebuilt only when the plot resizes or the skin changes —
/// never per frame.
///
/// The curve itself is then stroked along the top of the fill as a second
/// `drawRawPoints`, from a buffer that is also allocated once. Without it the
/// fill's top edge is a one-pixel staircase of band tops, which is legible but
/// looks like a bar chart rather than a spectrum.
///
/// ---------------------------------------------------------------------------
/// The cursor
///
/// Press anywhere on the plot and a line stands at that frequency with a tag
/// beside it: the frequency, the level there, the peak hold there, and the
/// level A-weighted. Drag it and it follows; press the line itself, or press
/// anywhere away from the module, and it goes — "away" being what
/// [ModuleTapGroup] says it is: not the module's own chrome, and not an item of
/// its own menu, so a `Range` can be changed with the cursor up.
/// It is a band index, not a pixel — see [SpectrumCursor] — so it stays on the
/// same frequency through a resize, and the three numbers are read straight
/// out of the buffers the curve and the hold are drawn from, so they are the
/// two lines the cursor crosses and not a third measurement that could
/// disagree with them.
///
/// **The numbers are the measurement and not the picture.** `Tilt` rotates the
/// drawn curve about 1 kHz and the axis with it, which is what makes a mix read
/// flat and what makes the axis unreadable as absolute level anywhere but at
/// 1 kHz. The marker sits on the drawn curve, where the eye expects it; the tag
/// prints the untilted level, which is what the band measured. Under a tilt
/// those disagree by design, and the caption in the plot's corner is what says
/// so.
///
/// **dB(A) is the level plus the IEC 61672-1 curve at the band's centre**, and
/// that is exact for a band: a band is a level at a frequency, and weighting a
/// component at a frequency is adding the curve's value there. It is not an
/// A-weighted loudness — that would be a sum over the weighted spectrum, a
/// number nothing here reports — and the curve as a whole is not weighted. See
/// `aWeightingDb`.
///
/// **Input arrives through a raw `Listener`, not a gesture recogniser**, and
/// through a translucent one. The canvas puts a module's select-and-menu
/// catcher *behind* the module, and a `GestureDetector` here would enter the
/// same arena as that catcher's tap and win it, so pressing the plot would
/// place a cursor and stop selecting the module. A `Listener` is not in any
/// arena: it sees the raw press and the catcher's recogniser still wins its
/// tap, so one press does both. A right click is left alone entirely — it is
/// the module's menu — and a two-finger gesture arrives as a pan-zoom event
/// this never handles, so a trackpad scroll over the plot moves nothing. The
/// finger-sized drag handle the canvas lays under the title bar ends above the
/// plot's top edge, so the two never share a press.
class SpectrumAnalyzerModule extends StatefulWidget {
  const SpectrumAnalyzerModule({
    required this.engine,
    required this.clock,
    this.source = SpectrumSource.all,
    this.response = SpectrumResponse.normal,
    this.tilt = SpectrumTilt.db4p5,
    this.range = SpectrumRange.db90,
    this.cursor,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// Which signal the bands are measured on. See [SpectrumSource]. A source
  /// the measurement cannot make on this signal — the right, mid or side of a
  /// one-channel input — is drawn as the notice it is, not as silence.
  final SpectrumSource source;

  /// How fast the curve follows what the engine publishes. See
  /// [SpectrumResponse] for why this is a time constant and not a frame rate.
  final SpectrumResponse response;

  /// How far the drawn curve is rotated, per octave about 1 kHz. See
  /// [SpectrumTilt] — it moves the picture and nothing else.
  final SpectrumTilt tilt;

  /// How far below 0 dBFS the plot reaches. See [SpectrumRange] — like the
  /// tilt, a view of the same measurement.
  final SpectrumRange range;

  /// Where the cursor stands, if the caller wants to hold it. The canvas hands
  /// none in and the module keeps its own; a test hands one in and reads where
  /// a press put it.
  final SpectrumCursor? cursor;

  @override
  State<SpectrumAnalyzerModule> createState() => _SpectrumAnalyzerModuleState();
}

/// Where the analyser's cursor stands — a band index, or nowhere.
///
/// A band and not a pixel, so that the same frequency is read after a resize
/// and so that the tag's three numbers are the entries of the curve's own
/// buffers at that index, with no interpolation to be a fourth opinion. The
/// bands are a fifty-first of an octave apart, which at any width the plot can
/// be drawn at is a pixel or less, so nothing is lost to the snap.
///
/// A [ChangeNotifier] because it is one of the painter's `repaint`
/// listenables. The clock notifies only when the engine has published a new
/// frame, and a cursor placed while nothing is playing — a stopped device, a
/// file that has finished — has to appear all the same; this is what draws it.
class SpectrumCursor extends ChangeNotifier {
  /// The band the cursor stands on, or null for no cursor.
  int? get band => _band;
  int? _band;
  set band(int? value) {
    if (value == _band) return;
    _band = value;
    notifyListeners();
  }
}

/// How long a band sits at its maximum before the drawn hold lets it down, and
/// how fast it falls after.
///
/// The same numbers as `OAA_SPECTRUM_HOLD_SECONDS` and
/// `OAA_SPECTRUM_FALL_DB_PER_SECOND` in `engine/src/oaa_spectrum.h`, restated
/// because that header is on the far side of an ABI this module never links —
/// the tablet runs this file with no engine at all. The engine holds the raw
/// bands on the same schedule this file holds the drawn ones, so a hold reads
/// the same whichever side of the wire is doing it. Move one and move the
/// other.
const double _holdSeconds = 1.5;
const double _fallDbPerSecond = 12;

/// A plot narrower or shorter than this draws nothing, and takes no cursor.
const double _minPlotWidth = 60;
const double _minPlotHeight = 32;

class _SpectrumAnalyzerModuleState extends State<SpectrumAnalyzerModule> {
  /// The level axis: 0 dBFS at the top, the chosen range's floor at the
  /// bottom, a labelled gridline every step of it.
  ///
  /// **Linear, and the one level scale in the application that is.** The
  /// meters draw [MeterScale.tapered], whose bottom edge is −∞ and whose top
  /// decade takes half the track; that is the right scale for a reading a
  /// delivery decision is made from, and the wrong one for a range setting,
  /// which on a taper would move nothing but the bottom tenth of the plot. A
  /// spectrum is read for its shape and its floor, and both want decibels
  /// evenly spaced — which is also how every analyser a mix engineer has used
  /// draws them. See [SpectrumRange].
  static MeterScale _scaleFor(SpectrumRange range) =>
      MeterScale(min: -range.decibels, max: 0, step: range.step);

  /// x, yBottom, x, yTop per band.
  final Float32List _bars = Float32List(MeterShape.spectrumBands * 4);

  /// x, y per band, for the peak-hold polyline.
  final Float32List _hold = Float32List(MeterShape.spectrumBands * 2);

  /// x, y per band, for the curve stroked along the top of the fill.
  final Float32List _curve = Float32List(MeterShape.spectrumBands * 2);

  /// The level actually drawn, per band, in dB.
  ///
  /// One pole per band, folded once per published frame — see [_advance]. On
  /// [SpectrumResponse.fast] it holds a copy of what the engine published and
  /// the arithmetic below collapses to an assignment.
  final Float32List _shown = Float32List(MeterShape.spectrumBands);

  /// The peak hold actually drawn, per band, in dB.
  ///
  /// The envelope of [_shown]: the highest the *drawn* curve has been, held for
  /// [_holdSeconds] and then let down at [_fallDbPerSecond], and folded through
  /// the same pole as the curve so the two move together. The engine's own hold
  /// over the raw bands — `spectrumPeak` — is a truer maximum, and it is the
  /// wrong line to draw here: it jumps to a new peak the instant one lands
  /// while the curve under it eases over the response's time constant, so on
  /// Slow the line above a calm shape flicked about as if it belonged to a
  /// different plot. A hold of the curve is a hold of what the reader can see.
  ///
  /// The cost is stated rather than hidden: on a slow response this sits below
  /// a peak the programme really reached, because the curve it is holding never
  /// went there. [SpectrumResponse.fast] is the setting that catches one.
  final Float32List _shownHold = Float32List(MeterShape.spectrumBands);

  /// What a source the signal cannot provide is drawn as.
  ui.Paragraph? _mono;

  /// Seconds left at the top, per band, before the hold starts falling.
  final Float32List _holdLeft = Float32List(MeterShape.spectrumBands);

  /// The offset the tilt adds to each band's drawn level, in dB.
  ///
  /// Built once per change of setting rather than per frame: the offsets are
  /// 512 logarithms, and the frame path does not take a logarithm per band for
  /// something that only moves when somebody picks a menu item. Held here
  /// rather than in the painter, which is rebuilt on every skin change and
  /// every selection.
  final Float32List _tiltDb = Float32List(MeterShape.spectrumBands);
  SpectrumTilt? _tiltFor;

  /// The generation [_shown] and [_shownHold] were last folded for, and the
  /// engine time they were folded at.
  ///
  /// **Zero is a real generation to have never seen**, so this starts at −1: an
  /// engine that has published exactly once and then stopped — a file being
  /// analysed, a device that dropped — must still get its one frame folded in.
  int _seenGeneration = -1;
  double _seenElapsed = 0;

  /// Folds one published frame into [_shown].
  ///
  /// **Called on a change of generation, never on a paint.** Paint also runs on
  /// a resize, a skin change and a selection, and an average that advanced on
  /// those would settle further every time the window moved — time passing that
  /// no audio passed through, which is the same defect the spectrogram's
  /// scrolling has and is just as convincing to look at.
  ///
  /// The coefficient is derived from *engine* time rather than counted in
  /// frames, so the setting means the same thing at every refresh rate: at
  /// 30 fps the clock reads fewer of the engine's ~47 published frames per
  /// second than at 120, and a fixed per-fold coefficient would make Normal
  /// slower on a laptop than on a workstation.
  void _advance(MeterSource engine, double tau, SpectrumSource source) {
    final elapsed = engine.elapsedSeconds;
    final dt = elapsed - _seenElapsed;
    _seenElapsed = elapsed;

    // A reset takes the clock back to zero, and a first frame has nothing to
    // average against. Reseat rather than fade in from whatever was on screen —
    // a curve rising slowly out of the floor after a reset is a picture of a
    // programme that did not happen — and reseat the *hold* with it, because a
    // hold carried across a discontinuity is a maximum of two different
    // programmes.
    //
    // `!(dt > 0)` rather than `dt <= 0`, so that a NaN takes this branch too. A
    // source whose link has gone quiet reports NaN seconds, and NaN compares
    // false against everything: the fade branch would compute an alpha of NaN,
    // write it into every band of [_shown], and leave the curve undrawn for the
    // rest of the session — including after a new source started publishing.
    // Reseating instead shows the stale frame's unavailable spectrum, and the
    // first real frame after it snaps back to something measured.
    //
    // **[SpectrumResponse.fast] is not a discontinuity**, and conflating the
    // two cost the hold entirely: an unaveraged curve is `alpha == 1`, which
    // draws the published frame exactly, but a *reseat* at `alpha == 1` also
    // starts the hold again from that frame — so on Fast, the one setting a
    // click is looked for at, the line above the curve was the curve.
    final reseat = !(dt > 0) || _seenGeneration < 0;
    final alpha = reseat || tau <= 0 ? 1.0 : 1 - math.exp(-dt / tau);
    final instant = alpha >= 1;

    final spectrum = engine.spectrumOf(source);
    final step = dt > 0 ? dt : 0.0;

    for (var band = 0; band < MeterShape.spectrumBands; band++) {
      final level = instant
          ? spectrum[band]
          : _shown[band] + (spectrum[band] - _shown[band]) * alpha;
      _shown[band] = level;

      // The highest the curve above has been, held and then let down at the
      // rate the engine lets its own hold down, so a hold reads the same
      // whichever side of the wire computed it.
      var held = reseat ? level : _shownHold[band];
      if (level >= held) {
        held = level;
        _holdLeft[band] = _holdSeconds;
      } else if (_holdLeft[band] > 0) {
        _holdLeft[band] -= step;
      } else {
        held -= _fallDbPerSecond * step;
        if (held < level) held = level;
      }

      _shownHold[band] = instant
          ? held
          : _shownHold[band] + (held - _shownHold[band]) * alpha;
    }
  }

  ScaleGraticule? _graticule;

  /// A paragraph per gridline, laid out at both label densities. Both sets are
  /// built here rather than at paint time because laying out a paragraph on the
  /// frame path is the thing the frame path most wants not to do.
  List<ui.Paragraph> _gridLabels = const [];

  /// The tilt, printed in the plot's top-left corner, and the range in the
  /// top-right — the two settings that change what the dB axis means.
  ///
  /// The tilt only when there is one. At [SpectrumTilt.db0] the dB scale is
  /// true everywhere and there is nothing to disclose; at any other setting it
  /// is true at 1 kHz and rotated away from it, and a reader who has not been
  /// told that is reading the wrong numbers off a correct-looking axis. The
  /// range always, because the axis's floor is what it names and the floor's
  /// own label sits at the bottom of a gutter nobody reads first.
  ///
  /// Top left because that is the corner a tilt *clears*: the same rotation
  /// that makes the label necessary takes the bottom octaves — which are the
  /// loudest part of every mix and were drawn against the ceiling — down the
  /// plot by twenty-odd decibels. Decibel prints no such caption; this one
  /// stays, because the scale beside a tilted curve is a scale with a caveat.
  /// Both are inset by [Space.sm] rather than hugging the corner, so they sit
  /// in the plot rather than on its edge.
  ui.Paragraph? _tiltLabel;
  SpectrumTilt? _labelledTilt;
  ui.Paragraph? _rangeLabel;
  SpectrumRange? _labelledRange;
  Color? _labelColor;

  /// Which [kHzGrid] values carry a label at the current plot width — solved
  /// by [fitHzLabels] when the plot resizes, not per frame.
  List<bool> _gridLabelled = const [];
  double _gridLabelledFor = -1;

  void solveAxis(double plotWidth) {
    if (_gridLabelledFor == plotWidth || _gridLabels.isEmpty) return;
    _gridLabelledFor = plotWidth;
    _gridLabelled = fitHzLabels(plotWidth, (i) => _gridLabels[i].longestLine);
  }

  /// The band fill's vertical gradient, and the plot it was built for. Rebuilt
  /// on a resize or a skin change and at no other time.
  ///
  /// The accent fading from two thirds opaque at the top of the plot to a
  /// seventh at the floor. A fade rather than a solid: a full-range mix at
  /// 90 dB fills most of the plot, and an opaque fill of that size is a slab
  /// with the graticule lost under it — the fade lets the gridlines read
  /// through the quiet end while the curve's own edge, stroked over the top,
  /// stays the brightest thing in the picture. It was briefly near-opaque, and
  /// went back; the fade is the look this module has always had.
  ui.Shader? _fillShader;
  Rect? _shaderPlot;
  OaaColors? _shaderColors;

  ui.Shader fillShader(Rect plot, OaaColors colors) {
    if (_fillShader == null || _shaderPlot != plot || _shaderColors != colors) {
      final base = colors.accent;
      _fillShader = ui.Gradient.linear(
        plot.topCenter,
        plot.bottomCenter,
        <Color>[base.withValues(alpha: 0.66), base.withValues(alpha: 0.14)],
      );
      _shaderPlot = plot;
      _shaderColors = colors;
    }
    return _fillShader!;
  }

  // --- The cursor -----------------------------------------------------------

  /// The widget's, or one of this state's own — see [SpectrumAnalyzerModule.cursor].
  late SpectrumCursor _cursor = widget.cursor ?? SpectrumCursor();

  /// The pointer that pressed inside the plot, while it is down. One at a
  /// time: a second finger on a tablet is ignored until the first lifts.
  int? _pointer;
  Offset _pressedAt = Offset.zero;
  bool _dragged = false;
  bool _pressedOnCursor = false;
  double _slop = 0;

  /// The frequency tag's headline and the three readings under it. The
  /// headline changes only when the cursor moves, so its string is formatted
  /// then and not per frame; the readings change with the signal and go
  /// through [ValueParagraph], which re-lays out only when the rounded string
  /// differs.
  final ValueParagraph _hzParagraph = ValueParagraph();
  int _hzFor = -1;
  String _hzText = '';
  final List<ValueParagraph> _readings = [
    ValueParagraph(),
    ValueParagraph(),
    ValueParagraph(),
  ];
  TextStyle _hzStyle = OaaType.reading(14);
  TextStyle _readingStyle = OaaType.readingSmall;

  /// `LEVEL`, `PEAK`, `dB(A)` in the tick face, and the widest they are. Built
  /// with the grid labels, on a skin change.
  List<ui.Paragraph> _readingLabels = const [];
  double _readingLabelWidth = 0;

  /// A paragraph as wide as any reading can be, so the tag's value column has
  /// one width and does not breathe when a level crosses −10.
  ui.Paragraph? _readingSlot;

  /// The A-weighting curve at the cursor's band — one logarithm per move of
  /// the cursor rather than one per frame.
  int _weightedFor = -1;
  double _weightDb = double.nan;

  double weightFor(int band) {
    if (_weightedFor != band) {
      _weightedFor = band;
      _weightDb = aWeightingDb(bandCentreHz(band));
    }
    return _weightDb;
  }

  ui.Paragraph hzParagraph(int band) {
    if (_hzFor != band) {
      _hzFor = band;
      _hzText = formatHzReading(bandCentreHz(band));
    }
    return _hzParagraph.of(_hzText, _hzStyle);
  }

  /// The box the border is drawn on, and the plot inside it, for a body of
  /// [size] — shared by the painter and by the input layer laid over the plot,
  /// so the pixels that take a press are exactly the pixels the bands are
  /// drawn in. Null when the body is too small to draw a plot at all.
  Rect boxFor(Size size) => Rect.fromLTRB(
    _graticule!.gutter,
    OaaType.tick.fontSize! + Space.xs,
    size.width,
    size.height,
  );

  Rect? plotFor(Size size) {
    final plot = PlotBorder.inside(boxFor(size));
    if (plot.width < _minPlotWidth || plot.height < _minPlotHeight) return null;
    return plot;
  }

  /// The band under plot-relative [x], on a plot [width] wide.
  static int _bandAt(double x, double width) =>
      (x / width * MeterShape.spectrumBands).floor().clamp(
        0,
        MeterShape.spectrumBands - 1,
      );

  /// The centre of [band], plot-relative — the same x the bars are drawn at.
  static double _xOfBand(int band, double width) =>
      (band + 0.5) * width / MeterShape.spectrumBands;

  void _pointerDown(PointerDownEvent event, double plotWidth) {
    if (_pointer != null) return;
    // A right click is the module's menu, and a stylus's barrel button is the
    // same bit — see `kPrimaryStylusButton`. A plain contact of any device is
    // the primary button.
    if (event.buttons != kPrimaryButton) return;

    final x = event.localPosition.dx;
    _pointer = event.pointer;
    _pressedAt = event.localPosition;
    _dragged = false;
    _slop = computeHitSlop(event.kind, null);

    // On the line itself, or near enough. A finger gets the touch slop, which
    // is how wide a finger is; a mouse gets a few pixels either side of a
    // one-pixel line, because a hairline is not a target anyone can hit
    // exactly and a cursor that cannot be dismissed is a cursor nobody places
    // twice. A press on the line changes nothing yet: it is a drag if it moves
    // and a dismissal if it does not, and the cursor should not jump the few
    // pixels to the press first in either case.
    final current = _cursor.band;
    _pressedOnCursor =
        current != null &&
        (x - _xOfBand(current, plotWidth)).abs() <= math.max(Space.xs, _slop);
    if (!_pressedOnCursor) _cursor.band = _bandAt(x, plotWidth);
  }

  void _pointerMove(PointerMoveEvent event, double plotWidth) {
    if (event.pointer != _pointer) return;
    if (!_dragged && (event.localPosition - _pressedAt).distance <= _slop) {
      return;
    }
    _dragged = true;
    // Clamped, so a drag that runs off the end of the plot parks the cursor on
    // the last band rather than losing it.
    _cursor.band = _bandAt(
      event.localPosition.dx.clamp(0.0, plotWidth),
      plotWidth,
    );
  }

  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    if (_pressedOnCursor && !_dragged) _cursor.band = null;
    _pointer = null;
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _pointer = null;
  }

  /// **A different signal is a different measurement, and the hold above the
  /// curve is the only thing here that outlives one frame.**
  ///
  /// `_advance` already reseats both across a discontinuity of the clock, for
  /// the reason written there — "a hold carried across a discontinuity is a
  /// maximum of two different programmes". Switching `Source` is that sentence
  /// with "signals" for "programmes", and the clock does not so much as
  /// stutter: the line over Right was the maximum of Right and whatever Left
  /// had just done, standing at a level Right never reached and falling at
  /// 12 dB a second towards the truth. The spectrogram beside it, reading the
  /// same bands, has cleared its record on this since the setting existed.
  ///
  /// `Tilt` and `Range` are deliberately not here. Both are views of the dB
  /// the hold is stored in — a rotation and an axis extent — so the held
  /// measurement is still a measurement of this signal, and reseating on them
  /// would throw away seconds of true peaks to redraw the same numbers.
  ///
  /// Nor is the cursor: it is a frequency, and a frequency is the same on every
  /// signal.
  ///
  /// −1 is the sentinel for "nothing has been folded yet", which is what makes
  /// the next `_advance` reseat the curve *and* the hold from the frame it is
  /// handed rather than fading into it out of the previous signal's shape.
  @override
  void didUpdateWidget(SpectrumAnalyzerModule old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source || !identical(old.engine, widget.engine)) {
      _seenGeneration = -1;
    }
    if (!identical(old.cursor, widget.cursor)) {
      if (old.cursor == null) _cursor.dispose();
      _cursor = widget.cursor ?? SpectrumCursor();
      _pointer = null;
    }
  }

  @override
  void dispose() {
    _graticule?.dispose();
    _hzParagraph.dispose();
    for (final reading in _readings) {
      reading.dispose();
    }
    if (widget.cursor == null) _cursor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    // Read here, not in the layout builder below: an inherited lookup belongs
    // in a build, and a press away is decided against the route this module is
    // on, which the layout builder's context also is but the intent is clearer
    // from the widget's own.
    final tapGroup = ModuleTapGroup.maybeOf(context);

    if (_tiltFor != widget.tilt) {
      for (var band = 0; band < MeterShape.spectrumBands; band++) {
        _tiltDb[band] = widget.tilt.dbAt(bandCentreHz(band));
      }
      _tiltFor = widget.tilt;
    }

    final recolour = _labelColor != colors.textFaint;
    if (_labelledTilt != widget.tilt || recolour) {
      _tiltLabel = widget.tilt.dbPerOctave == 0
          ? null
          : layoutParagraph(
              widget.tilt.label,
              OaaType.tick.copyWith(color: colors.textFaint),
            );
      _labelledTilt = widget.tilt;
    }
    if (_labelledRange != widget.range || recolour) {
      _rangeLabel = layoutParagraph(
        widget.range.label,
        OaaType.tick.copyWith(color: colors.textFaint),
      );
      _labelledRange = widget.range;
    }
    _labelColor = colors.textFaint;

    final scale = _scaleFor(widget.range);
    if (_graticule == null ||
        !_graticule!.matches(scale, ScaleSide.left, colors.textFaint)) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: scale,
        side: ScaleSide.left,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );

      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _gridLabels = [
        for (final hz in kHzGrid) layoutParagraph(formatHz(hz), style),
      ];
      _gridLabelledFor = -1;
      // The same words the stereo cloud and the phase scope use for the same
      // fact, in the same face.
      _mono = layoutParagraph(
        'MONO SOURCE',
        OaaType.label.copyWith(color: colors.textMuted),
      );

      // The tag's fixed text, in the same face as the axis it reads off. The
      // third label is a unit and the first two are words on purpose: LEVEL
      // and PEAK are the two lines of the plot, in dB like the axis, and the
      // third is the one number on the tag that is *not* in the axis's unit,
      // so its label says which unit it is in.
      _readingLabels = [
        for (final text in const ['LEVEL', 'PEAK', 'dB(A)'])
          layoutParagraph(text, style),
      ];
      _readingLabelWidth = _readingLabels
          .map((p) => p.longestLine)
          .reduce(math.max);
      _hzStyle = OaaType.reading(14).copyWith(color: colors.textPrimary);
      _readingStyle = OaaType.readingSmall.copyWith(color: colors.textPrimary);
      // Six glyphs of tabular figures — the widest a reading gets, at the
      // floor of the widest range.
      _readingSlot = layoutParagraph('-120.0', _readingStyle);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        MeterBody(
          painter: _SpectrumPainter(
            engine: widget.engine,
            colors: colors,
            graticule: _graticule!,
            source: widget.source,
            response: widget.response,
            tilt: widget.tilt,
            state: this,
            // The clock for the signal, the cursor for the cursor — see
            // [SpectrumCursor] for why the clock alone would not do.
            repaint: Listenable.merge([widget.clock, _cursor]),
          ),
        ),
        // The input layer, over the plot and nothing else: not the gutter, not
        // the label strip above it. A press there would place a cursor on a
        // band whose x is off the plot. See the header for why this is a
        // `Listener` and why it is translucent.
        LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final plot = plotFor(size);
            if (plot == null) return const SizedBox.shrink();
            return Padding(
              padding: EdgeInsets.fromLTRB(
                plot.left,
                plot.top,
                size.width - plot.right,
                size.height - plot.bottom,
              ),
              // A press anywhere that is not this module dismisses the
              // cursor — on the press, through the same mechanism that clears
              // the module's selection. In the module's group where there is
              // one, so the title bar, the grip and the menu are not "away";
              // alone on the remote display, where everything off the plot is.
              // Translucent for the same reason the layers inside it are: a
              // region that took the hit would hide the press from the
              // canvas's catcher behind the module.
              child: TapRegion(
                groupId: tapGroup,
                behavior: HitTestBehavior.translucent,
                onTapOutside: (_) {
                  if (isPressAway(context)) _cursor.band = null;
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  // Or the region takes the hit and the canvas's catcher
                  // behind the module never sees the press.
                  opaque: false,
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) => _pointerDown(event, plot.width),
                    onPointerMove: (event) => _pointerMove(event, plot.width),
                    onPointerUp: _pointerUp,
                    onPointerCancel: _pointerCancel,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SpectrumPainter extends MeterPainter {
  _SpectrumPainter({
    required this.engine,
    required this.colors,
    required this.graticule,
    required this.source,
    required this.response,
    required this.tilt,
    required this.state,
    required Listenable repaint,
  }) : _fill = (Paint()..strokeCap = StrokeCap.butt),
       _curve = (Paint()
         ..color = colors.accent
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.mark),
       // Dimmer than the curve on purpose. The hold is where the signal *has*
       // been and the curve is where it is now; drawn at the same weight, the
       // eye reads the upper line as the measurement.
       _hold = (Paint()
         ..color = colors.accent.withValues(alpha: 0.45)
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.hairline),
       _grid = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       // The cursor is in the text colour and not the accent, because the
       // accent is the signal: an accent line through an accent fill under an
       // accent curve is three things in one colour, and the marker where the
       // line meets the curve would vanish into the thing it marks. Dimmed so
       // it sits over the picture without cutting it in two; the marker at
       // full strength, because it is the one point on the plot the tag's
       // numbers are about. Not anti-aliased, like the gridlines, so a line at
       // a fractional band centre is one crisp pixel and not two soft ones.
       _cursorLine = (Paint()
         ..color = colors.textPrimary.withValues(alpha: 0.55)
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _cursorMark = (Paint()..color = colors.textPrimary),
       // The tag is a raised surface with the strong hairline, which is what a
       // menu is made of — a thing laid over the panel rather than part of it.
       _tagFill = (Paint()..color = colors.panelRaised),
       _tagBorder = (Paint()
         ..color = colors.hairlineStrong
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.hairline),
       _border = PlotBorder(colors),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final ScaleGraticule graticule;
  final SpectrumSource source;
  final SpectrumResponse response;
  final SpectrumTilt tilt;
  final _SpectrumAnalyzerModuleState state;

  final Paint _fill;
  final Paint _curve;
  final Paint _hold;
  final Paint _grid;
  final Paint _cursorLine;
  final Paint _cursorMark;
  final Paint _tagFill;
  final Paint _tagBorder;
  final PlotBorder _border;

  /// Where the two captions were drawn this frame, if they were, so the
  /// cursor's line can stop short of one it would otherwise run through.
  Rect? _tiltCaption;
  Rect? _rangeCaption;

  @override
  void paint(Canvas canvas, Size size) {
    // The box, and the plot inside it — see [PlotBorder]. Everything below is
    // measured against the plot, so the labels beside it and the bands within
    // it move together and nothing is drawn under the edge.
    final box = state.boxFor(size);
    final plot = state.plotFor(size);
    if (plot == null) return;
    _tiltCaption = null;
    _rangeCaption = null;

    graticule.paint(canvas, plot);

    // --- Frequency graticule ------------------------------------------------
    // Labels along the top, where the loudest octaves of a mix — the bottom of
    // the plot — cannot run into them; every value that fits, by the one rule
    // every frequency axis fits by. See [fitHzLabels].
    state.solveAxis(plot.width);
    final labels = state._gridLabels;
    // **The gridlines at the ends of the range are the plot's own edges, and
    // the border is what draws them.** [bandOfHz] returns a band *centre*, so
    // the series' endpoints — 20 Hz and 20 kHz, which are the range itself —
    // fall half a band outside the left edge and half a band inside the right
    // one. The left one has always been dropped by the bounds test below; the
    // right one landed four tenths of a pixel inside the border, in the
    // border's own colour and at the border's own weight, so the right-hand
    // edge of every analyser read as twice as thick as the other three. One
    // band is the width to test against, because half a band is exactly how
    // far in a range endpoint sits and nothing else on the series is within
    // forty of one.
    final oneBand = plot.width / MeterShape.spectrumBands;
    for (var i = 0; i < kHzGrid.length; i++) {
      final x =
          plot.left +
          bandOfHz(kHzGrid[i]) / MeterShape.spectrumBands * plot.width;
      if (x < plot.left || x > plot.right) continue;
      if (x - plot.left >= oneBand && plot.right - x >= oneBand) {
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _grid);
      }

      final label = labels[i];
      if (i < state._gridLabelled.length && state._gridLabelled[i]) {
        // Nudged inside the plot rather than centred on the line, because the
        // first gridline *is* the left edge: 20 Hz is band zero. Centred, half
        // of "20" is drawn off the module and the axis appears to start at 30.
        final room = plot.right - label.longestLine;
        final left = room <= plot.left
            ? plot.left
            : (x - label.longestLine / 2).clamp(plot.left, room);
        canvas.drawParagraph(
          label,
          Offset(left, plot.top - label.height - Space.xxs),
        );
      }
    }

    // The picture, the cursor over it, then the box around both. Drawn from
    // methods of their own so that the box is drawn on the paths that return
    // early as well: an analyser waiting for a signal still has an edge, and
    // still has its cursor.
    _paintSpectrum(canvas, plot);
    _paintCursor(canvas, plot);
    _border.paint(canvas, box);
  }

  /// The bands, the curve, the hold and the two captions — everything that is
  /// the signal rather than the frame around it.
  void _paintSpectrum(Canvas canvas, Rect plot) {
    if (!engine.hasSpectrum) return;

    // A source this signal cannot provide is NaN throughout — see
    // `MeterSource.spectrumOf`. Nothing is folded from it, so the curve is
    // where the last measured source left it when the setting is changed
    // back, and the plot says why it is empty rather than drawing the floor.
    if (engine.spectrumOf(source)[0].isNaN) {
      final mono = state._mono!;
      canvas.drawParagraph(
        mono,
        Offset(
          plot.left + (plot.width - mono.longestLine) / 2,
          plot.top + (plot.height - mono.height) / 2,
        ),
      );
      return;
    }

    if (engine.generation != state._seenGeneration) {
      state._advance(engine, response.timeConstant, source);
      state._seenGeneration = engine.generation;
    }

    // --- Bands --------------------------------------------------------------
    // The bands are drawn a half-band wider than they are spaced. Butt caps on
    // a stroke exactly one band wide leave a seam of background between
    // neighbours wherever the band centre lands mid-pixel, and five hundred
    // hairline seams read as vertical banding across the whole fill.
    final bandWidth = plot.width / MeterShape.spectrumBands;
    _fill.strokeWidth = bandWidth + 0.5;
    _fill.shader = state.fillShader(plot, colors);

    // The tilt is added here rather than folded into [_advance], and that is
    // not an arrangement of convenience: a fixed per-band offset commutes with
    // a maximum, a hold and a one-pole alike, so the tilted picture is exactly
    // the untilted one rotated — and changing the setting rotates what is on
    // screen instead of reseating five hundred averages and drawing a curve
    // that climbs out of the floor for half a second.
    final tiltDb = state._tiltDb;

    for (var band = 0; band < MeterShape.spectrumBands; band++) {
      final x = plot.left + (band + 0.5) * bandWidth;
      final y = _y(plot, state._shown[band] + tiltDb[band]);

      state._bars[band * 4] = x;
      state._bars[band * 4 + 1] = plot.bottom;
      state._bars[band * 4 + 2] = x;
      state._bars[band * 4 + 3] = y;

      state._curve[band * 2] = x;
      state._curve[band * 2 + 1] = y;

      state._hold[band * 2] = x;
      state._hold[band * 2 + 1] = _y(
        plot,
        state._shownHold[band] + tiltDb[band],
      );
    }

    canvas.save();
    canvas.clipRect(plot);
    canvas.drawRawPoints(ui.PointMode.lines, state._bars, _fill);
    canvas.drawRawPoints(ui.PointMode.polygon, state._curve, _curve);
    canvas.drawRawPoints(ui.PointMode.polygon, state._hold, _hold);
    canvas.restore();

    // --- Captions -----------------------------------------------------------
    // The tilt at the top left, the range at the top right, each inset by
    // [Space.sm]; on a plot too narrow for both, the tilt wins, because it is
    // the one that changes what a number on the axis means.
    final tilt = state._tiltLabel;
    var taken = plot.left;
    if (tilt != null && tilt.longestLine + 2 * Space.sm < plot.width) {
      final at = Offset(plot.left + Space.sm, plot.top + Space.sm);
      canvas.drawParagraph(tilt, at);
      _tiltCaption = Rect.fromLTWH(at.dx, at.dy, tilt.longestLine, tilt.height);
      taken = plot.left + Space.sm + tilt.longestLine;
    }
    final range = state._rangeLabel;
    if (range != null) {
      final left = plot.right - Space.sm - range.longestLine;
      if (left > taken + Space.sm) {
        final at = Offset(left, plot.top + Space.sm);
        canvas.drawParagraph(range, at);
        _rangeCaption = Rect.fromLTWH(
          at.dx,
          at.dy,
          range.longestLine,
          range.height,
        );
      }
    }
  }

  /// The cursor's line, its marker on the curve, and the tag — see the header.
  void _paintCursor(Canvas canvas, Rect plot) {
    final band = state._cursor.band;
    if (band == null) return;

    final x =
        plot.left + _SpectrumAnalyzerModuleState._xOfBand(band, plot.width);

    // The readings are the drawn buffers' entries at this band, and they are
    // readings only while the buffers hold this signal. Before a first frame
    // they hold zeros — which is full scale, not silence — and on a source the
    // signal cannot provide they hold whatever the last one left, which is a
    // measurement of something else; either way the tag prints a dash, the way
    // every unmeasured number in the application is printed.
    final measured = engine.hasSpectrum && !engine.spectrumOf(source)[0].isNaN;
    final level = measured ? state._shown[band] : double.nan;
    final peak = measured ? state._shownHold[band] : double.nan;
    final weighted = level + state.weightFor(band);

    canvas.save();
    canvas.clipRect(plot);

    // From the top of the plot, unless that runs it through a caption — the
    // tilt's on the left, the range's on the right — in which case from just
    // under it. A line through "90 dB" reads as a rendering fault, and a
    // caption over a line is a caption with a stroke between two of its
    // glyphs, which is no better.
    var lineTop = plot.top;
    lineTop = _under(_tiltCaption, x, lineTop);
    lineTop = _under(_rangeCaption, x, lineTop);
    canvas.drawLine(Offset(x, lineTop), Offset(x, plot.bottom), _cursorLine);
    if (measured) {
      // On the *drawn* curve — tilted — which is where the eye looks for it.
      canvas.drawCircle(
        Offset(x, _y(plot, level + state._tiltDb[band])),
        Space.xs,
        _cursorMark,
      );
    }

    // --- The tag ------------------------------------------------------------
    // Below the captions' row, so the tilt and the range stay legible with a
    // cursor up; beside the line, on whichever side has the room, and never
    // on top of it if the plot is wide enough to avoid that. A plot too short
    // for the tag keeps the line and the marker and loses the numbers.
    final hz = state.hzParagraph(band);
    final labels = state._readingLabels;
    final style = state._readingStyle;
    final readings = [
      state._readings[0].of(_db(level), style),
      state._readings[1].of(_db(peak), style),
      state._readings[2].of(_db(weighted), style),
    ];
    final slot = state._readingSlot!.longestLine;
    final rowHeight = readings[0].height;
    final width =
        Space.sm +
        math.max(hz.longestLine, state._readingLabelWidth + Space.sm + slot) +
        Space.sm;

    // As many rows as the plot has room for under the headline, dropped from
    // the bottom: a short plot loses dB(A) first and the peak next, and keeps
    // the frequency and the level to the last, because a cursor whose tag says
    // only where it is still says something. Nothing at all only when the plot
    // has no room for the frequency, or is narrower than the tag.
    final top = plot.top + Space.sm + OaaType.tick.fontSize! + Space.sm;
    final headline = Space.sm + hz.height + Space.sm;
    final room = plot.bottom - Space.xs - top;
    if (room < headline || width > plot.width - 2 * Space.xs) {
      canvas.restore();
      return;
    }
    final rows =
        ((room - headline - Space.xs + Space.xxs) / (rowHeight + Space.xxs))
            .floor()
            .clamp(0, readings.length);
    final height = rows == 0
        ? headline
        : headline + Space.xs + rows * rowHeight + (rows - 1) * Space.xxs;

    var left = x + Space.smd;
    if (left + width > plot.right - Space.xs) left = x - Space.smd - width;
    if (left < plot.left + Space.xs) left = plot.left + Space.xs;

    final tag = Rect.fromLTWH(left, top, width, height);
    final rounded = RRect.fromRectAndRadius(tag, OaaRadius.sm);
    canvas.drawRRect(rounded, _tagFill);
    canvas.drawRRect(rounded, _tagBorder);

    var y = tag.top + Space.sm;
    canvas.drawParagraph(hz, Offset(tag.left + Space.sm, y));
    y += hz.height + Space.xs;
    for (var i = 0; i < rows; i++) {
      final label = labels[i];
      canvas.drawParagraph(
        label,
        Offset(tag.left + Space.sm, y + (rowHeight - label.height) / 2),
      );
      final reading = readings[i];
      canvas.drawParagraph(
        reading,
        Offset(tag.right - Space.sm - reading.longestLine, y),
      );
      y += rowHeight + Space.xxs;
    }

    canvas.restore();
  }

  /// [lineTop], or the bottom of [caption] plus a gap if a line at [x] would
  /// run through it — whichever is lower.
  static double _under(Rect? caption, double x, double lineTop) {
    if (caption == null) return lineTop;
    if (x < caption.left - Space.xs || x > caption.right + Space.xs) {
      return lineTop;
    }
    return math.max(lineTop, caption.bottom + Space.xs);
  }

  /// A band level as the tag prints it: one decimal, the floor as `-∞`, and
  /// the dash for a number nobody measured — the same three rules
  /// `Metric.format` applies to every other reading.
  static String _db(double db) {
    if (db.isNaN) return '—';
    if (db <= MeterShape.dbFloor) return '-∞';
    return db.toStringAsFixed(1);
  }

  double _y(Rect plot, double db) =>
      plot.bottom - graticule.scale.fractionOf(db) * plot.height;

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.source != source ||
      oldDelegate.response != response ||
      oldDelegate.tilt != tilt ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
