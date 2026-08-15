// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
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

  final BelEngine engine;
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

  final BelEngine engine;
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

  @override
  void paint(Canvas canvas, Size size) {
    final extent = math.min(size.width, size.height);
    if (extent < 90) return;

    final centre = Offset(size.width / 2, size.height / 2);
    final outer = extent / 2 - Space.sm;

    // Three rings and two gaps, sized off the module rather than fixed, so the
    // meter reads the same at 6x6 cells and at 12x12.
    final ring = outer * 0.13;
    final gap = ring * 0.35;

    _track.strokeWidth = ring;
    _arc.strokeWidth = ring;

    final readings = [
      engine.lufsMomentary,
      engine.lufsShort,
      engine.lufsIntegrated,
    ];
    final fills = [colors.meterFill, colors.textMuted, colors.accent];

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

      // Ring name, at the open end of the gauge.
      final label = state._arcLabels[i];
      final labelAngle = _startAngle - 0.12;
      canvas.drawParagraph(
        label,
        centre +
            Offset(math.cos(labelAngle), math.sin(labelAngle)) *
                (radius - ring / 2) -
            Offset(label.longestLine / 2, label.height / 2),
      );
    }

    // --- The centre ---------------------------------------------------------
    final integrated = engine.lufsIntegrated;
    final integratedColor = colorForState(
      classify(Metric.lufsIntegrated, integrated, calibration),
      colors,
    );

    final fontSize = (extent * 0.16).clamp(16.0, 56.0);
    final value = state._integrated.of(
      Metric.lufsIntegrated.format(integrated),
      BelType.reading(fontSize).copyWith(color: integratedColor),
      align: TextAlign.center,
      maxWidth: extent * 0.6,
    );
    canvas.drawParagraph(
      value,
      Offset(centre.dx - extent * 0.3, centre.dy - value.height * 0.72),
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
