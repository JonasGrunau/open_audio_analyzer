// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
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

  final BelEngine engine;
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
      _momentaryLabel = layoutParagraph('M', style, align: TextAlign.center);
      _shortLabel = layoutParagraph('S', style, align: TextAlign.center);
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

  final BelEngine engine;
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
  static const double _readoutHeight = 34;

  /// And below this even the scale labels stop fitting.
  static const double _minimumHeight = 60;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height < _minimumHeight || size.width < 60) return;

    final showReadouts = size.height > _minimumHeight + _readoutHeight;
    final barLabelHeight = BelType.label.fontSize! + Space.xs;

    final track = Rect.fromLTRB(
      graticule.gutter,
      0,
      size.width,
      size.height -
          barLabelHeight -
          (showReadouts ? _readoutHeight + Space.xs : 0),
    );
    if (track.height < 24 || track.width < 24) return;

    canvas.drawRect(track, _track);
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
    const gap = Space.xs;
    final barWidth = (track.width - gap) / 2;

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
    final integrated = engine.lufsIntegrated;
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
    final readoutTop = size.height - _readoutHeight;
    final half = size.width / 2;

    _readout(
      canvas,
      state._integratedLabel!,
      state._integrated,
      Metric.lufsIntegrated.format(integrated),
      colorForState(
        classify(Metric.lufsIntegrated, integrated, calibration),
        colors,
      ),
      Rect.fromLTWH(0, readoutTop, half - Space.xs, _readoutHeight),
    );
    _readout(
      canvas,
      state._rangeLabel!,
      state._range,
      Metric.loudnessRange.format(engine.loudnessRange),
      colorForState(
        classify(Metric.loudnessRange, engine.loudnessRange, calibration),
        colors,
      ),
      Rect.fromLTWH(half, readoutTop, half, _readoutHeight),
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
  ) {
    canvas.drawParagraph(label, bounds.topLeft);
    canvas.drawParagraph(
      value.of(
        text,
        BelType.reading(20).copyWith(color: color),
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
