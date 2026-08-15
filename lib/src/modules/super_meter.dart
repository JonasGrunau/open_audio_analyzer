// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// Momentary, short-term and integrated loudness as three concentric arcs.
///
/// Decibel's name, kept because there is no better one for this. The arrangement
/// earns its space by making one relationship immediate: the three arcs share a
/// scale and a target tick, so a momentary arc running far past the integrated
/// one is a mix that is about to get louder than it should, and that is visible
/// as a shape rather than as three numbers to compare.
///
/// The innermost arc is the integrated reading — the number that actually gets
/// delivered — and it is the one the centre readout repeats. Outward from it is
/// increasingly short-term, which is increasingly volatile, which is what a
/// glance should skip past.
class SuperMeterModule extends StatefulWidget {
  const SuperMeterModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<SuperMeterModule> createState() => _SuperMeterModuleState();
}

class _SuperMeterModuleState extends State<SuperMeterModule> {
  static const _scale = MeterScale(min: -48, max: 0, step: 6);

  final _integrated = ValueParagraph();
  final _range = ValueParagraph();
  ui.Paragraph? _unit;
  ui.Paragraph? _rangeLabel;
  List<ui.Paragraph> _arcLabels = const [];
  double _arcLabelHeight = 0;
  Color? _labelColor;

  @override
  void dispose() {
    _integrated.dispose();
    _range.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_labelColor != colors.textFaint) {
      _labelColor = colors.textFaint;
      final style = BelType.label.copyWith(color: colors.textFaint);
      _unit = layoutParagraph('LUFS', style);
      _rangeLabel = layoutParagraph('LRA', style);
      _arcLabels = [
        layoutParagraph('M', style),
        layoutParagraph('S', style),
        layoutParagraph('I', style),
      ];
      _arcLabelHeight = _arcLabels.first.height;
    }

    return MeterBody(
      painter: _SuperMeterPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        scale: _scale,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _SuperMeterPainter extends MeterPainter {
  _SuperMeterPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.scale,
    required this.state,
    required Listenable repaint,
  }) : _track = (Paint()
         ..color = colors.meterTrack
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.butt),
       _arc = (Paint()
         ..style = PaintingStyle.stroke
         ..strokeCap = StrokeCap.butt),
       _target = (Paint()
         ..color = colors.textMuted
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.mark),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final BelColors colors;
  final MeterScale scale;
  final _SuperMeterModuleState state;

  final Paint _track;
  final Paint _arc;
  final Paint _target;

  /// The gauge opens at the bottom: 150° round to 30°, clockwise. A full ring
  /// would have no beginning and no end, and a scale needs both.
  static const double _startAngle = 150 * math.pi / 180;
  static const double _sweepAngle = 240 * math.pi / 180;

  /// The width of one ring, as a fraction of the outer radius.
  static const double _ringWidth = 0.115;

  /// Where a ring's name sits, as a fraction of the ring's width, measured
  /// **along the arc** from its open end.
  ///
  /// An arc length rather than an angle, which is the whole point. The names
  /// used to lead the arcs by a fixed 0.12 radians, and a fixed angle is a
  /// fixed fraction of each radius — so the outermost name stood nearly twice
  /// as far from its own arc as the innermost did from its. Three names that
  /// each mark one ring then read as a diagonal drifting off the bottom of the
  /// gauge rather than as three labels. The same number of pixels for all
  /// three puts each name beside the arc it names.
  static const double _labelGap = 0.7;

  /// The angular lead of the *outermost* name.
  ///
  /// It is the lowest ink on the face, so the layout is solved against it
  /// rather than against the arcs. Both terms of the arc length scale with the
  /// outer radius, so this angle does not depend on the module's size: the
  /// name sits on its ring's centreline, half a ring in from the outer edge.
  static const double _labelLead =
      _ringWidth * _labelGap / (1 - _ringWidth / 2);

  @override
  void paint(Canvas canvas, Size size) {
    // **The gauge is not a circle and must not be centred as one.** It opens
    // 120° at the bottom, so its ink reaches only `sin` of the way below the
    // centre that it does above it — and centring the notional circle instead
    // of the drawn shape left a band of dead space along the bottom of the
    // module a fifth of its height deep, with the ring labels stranded in it.
    // Solve for the radius that fills the box, then centre what is actually
    // drawn.
    final labelDrop = math.sin(_startAngle - _labelLead);
    final labelHalf = state._arcLabelHeight / 2;

    final outer = math.min(
      size.width / 2,
      (size.height - labelHalf) / (1 + labelDrop),
    );
    if (outer < 40) return;

    final inkHeight = outer * (1 + labelDrop) + labelHalf;
    final centre = Offset(
      size.width / 2,
      (size.height - inkHeight) / 2 + outer,
    );

    // Three rings and two gaps, sized off the module rather than fixed, so the
    // meter reads the same at 6x6 cells and at 12x12.
    //
    // The gap is nearly as wide as a ring on purpose. At a third of a ring the
    // arithmetic is fine and the display is not: two adjacent rings at similar
    // brightness read as one thick band with a seam, and the whole point of
    // three concentric arcs is being able to tell which is which at a glance.
    final ring = outer * _ringWidth;
    final gap = ring * 0.85;

    _track.strokeWidth = ring;
    _arc.strokeWidth = ring;

    final readings = [
      engine.lufsMomentary,
      engine.lufsShort,
      engine.lufsIntegrated,
    ];
    // Both derived from `meterFill`, never from a text colour: `textMuted` sits
    // lighter than `meterFill` under the dark palette and darker under a light
    // one, so the momentary and short-term arcs would swap which looked
    // emphasised when the skin changed. The third entry is unused — the
    // integrated arc takes its colour from the target check below.
    final fills = [
      colors.meterFill,
      colors.meterFill.withValues(alpha: 0.55),
      colors.accent,
    ];

    for (var i = 0; i < 3; i++) {
      final radius = outer - i * (ring + gap);
      if (radius < ring) break;
      final bounds = Rect.fromCircle(center: centre, radius: radius - ring / 2);

      canvas.drawArc(bounds, _startAngle, _sweepAngle, false, _track);

      final value = readings[i];
      if (!value.isNaN) {
        // The integrated arc is the only one with a pass/fail meaning, so it is
        // the only one that takes the signal colour. Colouring all three would
        // make the accent decorative, and an accent that is decoration cannot
        // also be a warning.
        _arc.color = i == 2
            ? colorForState(
                classify(Metric.lufsIntegrated, value, calibration),
                colors,
              )
            : fills[i];
        final sweep = scale.fractionOf(value) * _sweepAngle;
        if (sweep > 0) {
          canvas.drawArc(bounds, _startAngle, sweep, false, _arc);
        }
      }

      // Target tick, on every ring, so the three can be compared against it
      // without the eye travelling to a legend.
      final angle =
          _startAngle + scale.fractionOf(calibration.lufsTarget) * _sweepAngle;
      final inner = radius - ring;
      canvas.drawLine(
        centre + Offset(math.cos(angle), math.sin(angle)) * inner,
        centre + Offset(math.cos(angle), math.sin(angle)) * radius,
        _target,
      );

      // Ring name, at the open end of the gauge, on the ring's own centreline
      // and the same arc length from every arc — see [_labelGap].
      final label = state._arcLabels[i];
      final labelRadius = radius - ring / 2;
      final labelAngle = _startAngle - ring * _labelGap / labelRadius;
      canvas.drawParagraph(
        label,
        centre +
            Offset(math.cos(labelAngle), math.sin(labelAngle)) * labelRadius -
            Offset(label.longestLine / 2, label.height / 2),
      );
    }

    // --- The centre ---------------------------------------------------------
    final integrated = engine.lufsIntegrated;
    final integratedColor = colorForState(
      classify(Metric.lufsIntegrated, integrated, calibration),
      colors,
    );

    // Sized off the gauge rather than off the module's short side: the
    // readout lives inside the rings, so it has to scale with them.
    // The ceiling is high enough that the gauge is what limits the number, not
    // the constant. At 56 a Super Meter given a quarter of a 27" display drew
    // the same digits in the middle of a 700 px dial as one in a corner drew in
    // a 350 px one, and the readout stopped looking like the centre of the
    // instrument and started looking like a caption that had been left behind.
    final dial = outer * 2;

    // **The rings bound the readout, not the module.** `outer` is the outside
    // of the first arc; three rings and two gaps in, what is left is the clear
    // disc the number sits in. Sizing against `dial` alone is what put a
    // four-digit reading through the innermost arc on both sides: the old
    // `maxWidth` of `dial * 0.6` is 1.2 times `outer`, and the disc is only
    // 0.92 of it across.
    final innerRadius = outer - 2 * (ring + gap) - ring;

    // A chord, not the diameter. The number is not a line — it stands about
    // four tenths of the inner radius tall — and a box as wide as the circle
    // fits only if it has no height. At 0.8 of the radius its corners still
    // clear the arc.
    final textWidth = innerRadius * 1.6;

    // Every glyph in a reading is a digit, a minus or a point, and the reading
    // face is monospaced, so the width is arithmetic and not a measurement —
    // no second layout to find out whether the first one fitted. 0.62 em covers
    // JetBrains Mono's 0.6 advance with a little slack.
    final text = Metric.lufsIntegrated.format(integrated);
    final fontSize = math
        .min(dial * 0.16, textWidth / (text.length * 0.62))
        .clamp(12.0, 120.0);

    final value = state._integrated.of(
      text,
      BelType.reading(fontSize).copyWith(color: integratedColor),
      align: TextAlign.center,
      maxWidth: textWidth,
    );
    canvas.drawParagraph(
      value,
      Offset(centre.dx - textWidth / 2, centre.dy - value.height * 0.72),
    );

    final unit = state._unit!;
    canvas.drawParagraph(
      unit,
      Offset(centre.dx - unit.longestLine / 2, centre.dy + value.height * 0.32),
    );

    // LRA underneath, because "how far does it move" is the second question
    // asked of an integrated reading and the only other one that survives to
    // delivery.
    if (size.height > 140) {
      final range = state._range.of(
        Metric.loudnessRange.format(engine.loudnessRange),
        BelType.readingSmall.copyWith(
          color: colorForState(
            classify(Metric.loudnessRange, engine.loudnessRange, calibration),
            colors,
          ),
        ),
      );
      final label = state._rangeLabel!;
      final total = label.longestLine + Space.xs + range.longestLine;
      final top = centre.dy + value.height * 0.32 + unit.height + Space.xs;
      canvas.drawParagraph(label, Offset(centre.dx - total / 2, top));
      canvas.drawParagraph(
        range,
        Offset(centre.dx - total / 2 + label.longestLine + Space.xs, top - 1),
      );
    }
  }

  @override
  bool shouldRepaint(_SuperMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      oldDelegate.scale != scale ||
      !identical(oldDelegate.engine, engine);
}
