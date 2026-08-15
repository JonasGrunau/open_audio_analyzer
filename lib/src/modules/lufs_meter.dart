// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// Momentary and short-term loudness as bars, integrated loudness as a line.
///
/// The three quantities are drawn on **one** scale rather than three, because
/// the only question anybody has while mixing is how they relate: momentary
/// swinging far above integrated is a mix that will be turned down, and you can
/// see that in one glance here and in no arrangement of three separate numbers.
///
/// The target band comes from the active calibration and is the reason the
/// meter is worth looking at rather than the number underneath it. A line at
/// −14 LUFS with a ±0.5 LU band around it turns "what is my loudness" into
/// "am I there yet", which is the question that actually gets asked.
class LufsMeterModule extends StatefulWidget {
  const LufsMeterModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<LufsMeterModule> createState() => _LufsMeterModuleState();
}

class _LufsMeterModuleState extends State<LufsMeterModule> {
  /// Wide enough for broadcast at −23 and streaming at −14 without either
  /// sitting against an edge, and a 6 LU step divides it exactly.
  static const _scale = MeterScale(min: -48, max: 0, step: 6);

  ScaleGraticule? _graticule;
  final _integrated = ValueParagraph();
  final _range = ValueParagraph();
  ui.Paragraph? _momentaryLabel;
  ui.Paragraph? _shortLabel;
  ui.Paragraph? _integratedLabel;
  ui.Paragraph? _rangeLabel;

  @override
  void dispose() {
    _graticule?.dispose();
    _integrated.dispose();
    _range.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    // Rebuilt only when the palette changes, never per frame: these hold laid
    // out paragraphs, and throwing them away every rebuild would defeat the
    // point of caching them.
    if (_graticule == null ||
        !_graticule!.matches(_scale, ScaleSide.left, colors.textFaint)) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.left,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );

      final style = BelType.label.copyWith(color: colors.textFaint);
      // **Left-aligned, and centred by [_centred] instead.** These asked for
      // `TextAlign.center` and were not drawn at all: an unconstrained
      // paragraph is laid out a megapixel wide, and centre alignment then puts
      // the glyph half a million pixels along a line whose origin is the offset
      // it is drawn at. `longestLine` still reports the ink, so the arithmetic
      // around it looks right and the letter is simply somewhere else. Centre
      // a bare paragraph by measuring it, or lay it out in a box it can be
      // centred in — see the reading in `super_meter.dart` for the second.
      _momentaryLabel = layoutParagraph('M', style);
      _shortLabel = layoutParagraph('S', style);
      _integratedLabel = layoutParagraph('LUFS-I', style);
      _rangeLabel = layoutParagraph('LRA', style);
    }

    return MeterBody(
      painter: _LufsMeterPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        graticule: _graticule!,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _LufsMeterPainter extends MeterPainter {
  _LufsMeterPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.graticule,
    required this.state,
    required Listenable repaint,
  }) : _track = (Paint()..color = colors.meterTrack),
       _momentary = (Paint()..color = colors.meterFill),
       // Derived from the same token as the momentary bar rather than borrowing
       // a text colour, so the two stay in a fixed relationship under any skin.
       // `textMuted` was the obvious pick and is wrong: under the dark palette
       // it is *lighter* than `meterFill` and under a light one it is darker, so
       // switching skins silently swapped which of these two bars looked like
       // the emphasised one. A meter fill is not a text colour.
       _short = (Paint()..color = colors.meterFill.withValues(alpha: 0.55)),
       _targetBand = (Paint()
         ..color = colors.textFaint.withValues(alpha: 0.18)),
       _targetLine = (Paint()
         ..color = colors.textMuted
         ..strokeWidth = BelStroke.mark
         ..isAntiAlias = false),
       _integratedLine = (Paint()..strokeWidth = BelStroke.emphasis),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final BelColors colors;
  final ScaleGraticule graticule;
  final _LufsMeterModuleState state;

  final Paint _track;
  final Paint _momentary;
  final Paint _short;
  final Paint _targetBand;
  final Paint _targetLine;
  final Paint _integratedLine;

  /// Below this there is no room for the readouts and the bars keep the space.
  static const double _minimumHeight = 60;

  /// The same judgement as [_minimumHeight], in the other axis: under this a
  /// reading is chrome rather than a number, and the bars keep the space.
  static const double _minimumValueSize = 11;

  /// Advance of one glyph of [BelType.reading], in ems. JetBrains Mono is 0.6
  /// and the style tightens it by half a pixel; the slack is what keeps this an
  /// upper bound rather than a measurement.
  static const double _advance = 0.62;

  /// The reading is fitted to at least this many glyphs — the width of
  /// `-17.6` — whatever it currently prints.
  ///
  /// Fitting the string that is actually on screen would resize the whole row
  /// the moment integrated loudness crossed −10 or LRA reached 10.0 and the
  /// number gained a digit. Tabular figures exist so a readout does not move
  /// while you watch it; a face that changes size at a threshold undoes that
  /// far more visibly than proportional digits ever did.
  static const int _minimumGlyphs = 5;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = Space.xs;
    final barWidth = (size.width - graticule.gutter - gap) / 2;

    final integrated = engine.lufsIntegrated;
    final integratedText = Metric.lufsIntegrated.format(integrated);
    final rangeText = Metric.loudnessRange.format(engine.loudnessRange);

    // **The readouts scale with the module, like the bars above them.** They
    // were fixed at 20 px in a band 34 px deep, so on a tall meter the two
    // numbers that get delivered shrank to a caption under a bar four times
    // their height, and on a short one they crowded it. The bars have always
    // been sized off the module; a reading that is not is a reading that is
    // legible at exactly one window size.
    //
    // **The column bounds it as well as the height does.** Sized off the height
    // alone, a tall narrow meter asked for a 40 px reading in a column that
    // holds 30 — and a paragraph laid out at `maxLines: 1` does not complain,
    // it simply stops drawing where it runs out of room. `-17.6` was rendered
    // as `-17.`, which is not a clipped number but a *different* one, and the
    // meter looked entirely willing to stand behind it. Both readings take the
    // smaller of the two sizes so the row still reads as a pair; the widest of
    // the two strings decides it, since a `2.9` beside a `-17.6` set larger
    // reads as the more important of the two.
    //
    // Every glyph of a reading is a digit, a minus or a point and the face is
    // monospaced, so the width that fits is arithmetic — no trial layout on the
    // frame path to find out whether the real one fitted. The column is fitted
    // one space short of its full width, because a reading that ends exactly at
    // the column boundary stands one bar gap from the next one, and `-17.6 2.9`
    // closes up into a single run of digits.
    final glyphs = math.max(
      _minimumGlyphs,
      math.max(integratedText.length, rangeText.length),
    );
    final valueSize = math
        .min(size.height * 0.09, (barWidth - Space.sm) / (glyphs * _advance))
        .clamp(0.0, 40.0)
        .toDouble();
    final labelHeight = state._integratedLabel!.height;
    final readoutHeight = labelHeight + Space.xxs + valueSize * 1.3;

    final showReadouts =
        valueSize >= _minimumValueSize &&
        size.height > _minimumHeight + readoutHeight;
    final barLabelHeight = BelType.label.fontSize! + Space.xs;

    final track = Rect.fromLTRB(
      graticule.gutter,
      0,
      size.width,
      size.height -
          barLabelHeight -
          (showReadouts ? readoutHeight + Space.xs : 0),
    );
    if (track.height < 24 || track.width < 24) return;

    // **A trough per bar, not one rectangle behind both.** Painted as a single
    // background, the gap between momentary and short-term is the same colour
    // as the empty part of either bar, so the two only separate where their
    // fills stop — and when they read alike, which is most of the time on
    // steady programme, they merge into one bar. The gap has to show the
    // module behind it to be a gap.
    canvas.drawRect(
      Rect.fromLTRB(track.left, track.top, track.left + barWidth, track.bottom),
      _track,
    );
    canvas.drawRect(
      Rect.fromLTRB(
        track.right - barWidth,
        track.top,
        track.right,
        track.bottom,
      ),
      _track,
    );

    // Over the troughs and under everything else: the scale belongs to the
    // meter as a whole, so it crosses the gap the way the target and
    // integrated rules below do.
    graticule.paint(canvas, track);

    // --- Target band --------------------------------------------------------
    // A band rather than a line, because every delivery spec states a tolerance
    // and a target drawn as a hairline is a pass/fail on an infinitely thin
    // edge that no real programme lands on.
    //
    // The band goes under the bars so a bar crossing it stays readable, but the
    // *line* goes over them further down. Both underneath looked right in a
    // mock-up and is wrong in use: a programme above its target — which is the
    // case you are looking at the meter to fix — hides the target completely
    // behind the bars, exactly when you need to see how far above it you are.
    final targetTop = _y(
      track,
      calibration.lufsTarget + calibration.lufsTolerance,
    );
    final targetBottom = _y(
      track,
      calibration.lufsTarget - calibration.lufsTolerance,
    );
    canvas.drawRect(
      Rect.fromLTRB(track.left, targetTop, track.right, targetBottom),
      _targetBand,
    );

    // --- Bars ---------------------------------------------------------------
    _bar(canvas, track, track.left, barWidth, engine.lufsMomentary, _momentary);
    _bar(
      canvas,
      track,
      track.left + barWidth + gap,
      barWidth,
      engine.lufsShort,
      _short,
    );

    // The target line, over the bars — see the note above the band.
    final targetY = _y(track, calibration.lufsTarget);
    canvas.drawLine(
      Offset(track.left, targetY),
      Offset(track.right, targetY),
      _targetLine,
    );

    // --- Integrated ---------------------------------------------------------
    // A line across both bars, not a third bar. Integrated loudness is the
    // number that gets delivered, and drawing it as a rule the bars pass
    // through is what makes "am I above or below where I will end up" readable
    // without arithmetic.
    if (!integrated.isNaN) {
      _integratedLine.color = colorForState(
        classify(Metric.lufsIntegrated, integrated, calibration),
        colors,
      );
      final y = _y(track, integrated);
      canvas.drawLine(
        Offset(track.left, y),
        Offset(track.right, y),
        _integratedLine,
      );
    }

    // --- Bar labels ---------------------------------------------------------
    _centred(
      canvas,
      state._momentaryLabel!,
      track.left,
      barWidth,
      track.bottom + Space.xxs,
    );
    _centred(
      canvas,
      state._shortLabel!,
      track.left + barWidth + gap,
      barWidth,
      track.bottom + Space.xxs,
    );

    if (!showReadouts) return;

    // --- Readouts -----------------------------------------------------------
    // **Two columns aligned to the two bars, not to the module.** They were
    // laid out against `size.width / 2`, which is the middle of the *module* —
    // but the bars start after the scale's gutter, so their middle is some
    // twenty-odd pixels to the right of it. LUFS-I ended up under the scale
    // numbers and LRA under the middle of the momentary bar, and a column of
    // figures that does not line up with the thing above it reads as a
    // misprint. The M and S labels directly under the bars say which bar is
    // which; these two are a row of results, and they line up with the meter.
    final readoutTop = size.height - readoutHeight;

    _readout(
      canvas,
      state._integratedLabel!,
      state._integrated,
      integratedText,
      colorForState(
        classify(Metric.lufsIntegrated, integrated, calibration),
        colors,
      ),
      Rect.fromLTWH(track.left, readoutTop, barWidth, readoutHeight),
      valueSize,
    );
    _readout(
      canvas,
      state._rangeLabel!,
      state._range,
      rangeText,
      colorForState(
        classify(Metric.loudnessRange, engine.loudnessRange, calibration),
        colors,
      ),
      Rect.fromLTWH(
        track.left + barWidth + gap,
        readoutTop,
        barWidth,
        readoutHeight,
      ),
      valueSize,
    );
  }

  double _y(Rect track, double value) =>
      track.bottom - graticule.scale.fractionOf(value) * track.height;

  void _bar(
    Canvas canvas,
    Rect track,
    double left,
    double width,
    double value,
    Paint paint,
  ) {
    if (value.isNaN) return;
    final top = _y(track, value);
    if (top >= track.bottom) return;
    canvas.drawRect(
      Rect.fromLTRB(left, top, left + width, track.bottom),
      paint,
    );
  }

  void _centred(
    Canvas canvas,
    ui.Paragraph label,
    double left,
    double width,
    double top,
  ) => canvas.drawParagraph(
    label,
    Offset(left + (width - label.longestLine) / 2, top),
  );

  void _readout(
    Canvas canvas,
    ui.Paragraph label,
    ValueParagraph value,
    String text,
    Color color,
    Rect bounds,
    double fontSize,
  ) {
    canvas.drawParagraph(label, bounds.topLeft);
    canvas.drawParagraph(
      value.of(
        text,
        BelType.reading(fontSize).copyWith(color: color),
        maxWidth: bounds.width,
      ),
      Offset(bounds.left, bounds.top + label.height + Space.xxs),
    );
  }

  @override
  bool shouldRepaint(_LufsMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
