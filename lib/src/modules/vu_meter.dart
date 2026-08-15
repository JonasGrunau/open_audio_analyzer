// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// A needle, on the movement the engine models.
///
/// The dial is not nostalgia. A VU is average-responding where every other
/// meter here is peak- or RMS-responding, and its 300 ms movement with a little
/// overshoot is a low-pass filter with a shape that happens to track perceived
/// level well — which is why people still mix to one. Both properties live in
/// `bel_analysis.c`; this module draws the result and nothing else.
///
/// **0 VU is the calibration's reference level, not 0 dBFS.** That is the whole
/// point of the module: −18 dBFS reads 0 VU for EBU work and −20 dBFS for US
/// broadcast, and a VU meter pinned to digital full scale would sit at the
/// bottom of its scale for every programme ever made.
class VuMeterModule extends StatefulWidget {
  const VuMeterModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final BelEngine engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<VuMeterModule> createState() => _VuMeterModuleState();
}

/// The marks on a VU face, in VU. Not evenly spaced, and that is the standard
/// face rather than a stylistic choice — the scale crowds towards −20 because
/// the movement's deflection is linear in *voltage*, not in decibels.
const _vuMarks = <double>[-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3];

/// Which of them get a number under them. All eleven would be a wall of digits
/// on a five-cell module.
const _vuLabelled = <double>[-20, -10, -5, -3, 0, 3];

class _VuMeterModuleState extends State<VuMeterModule> {
  List<ui.Paragraph> _labels = const [];
  ui.Paragraph? _unit;
  Color? _builtColor;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_builtColor != colors.textFaint) {
      _builtColor = colors.textFaint;
      _labels = [
        for (final mark in _vuMarks)
          if (_vuLabelled.contains(mark))
            layoutParagraph(
              mark == 0
                  ? '0'
                  : (mark > 0 ? '+${mark.toInt()}' : '${mark.toInt()}'),
              BelType.tick.copyWith(
                color: mark >= 0 ? colors.over : colors.textFaint,
              ),
            )
          else
            layoutParagraph('', BelType.tick),
      ];
      _unit = layoutParagraph(
        'VU',
        BelType.label.copyWith(color: colors.textFaint),
      );
    }

    return MeterBody(
      painter: _VuPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _VuPainter extends MeterPainter {
  _VuPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : _arc = (Paint()
         ..color = colors.textFaint
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.hairline),
       _arcOver = (Paint()
         ..color = colors.over
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.mark),
       _mark = (Paint()
         ..color = colors.textFaint
         ..strokeWidth = BelStroke.hairline),
       _markOver = (Paint()
         ..color = colors.over
         ..strokeWidth = BelStroke.mark),
       _needle = (Paint()
         ..color = colors.textPrimary
         ..strokeWidth = BelStroke.mark
         ..strokeCap = StrokeCap.round),
       _pivot = (Paint()..color = colors.textMuted),
       super(repaint: repaint);

  final BelEngine engine;
  final Calibration calibration;
  final BelColors colors;
  final _VuMeterModuleState state;

  final Paint _arc;
  final Paint _arcOver;
  final Paint _mark;
  final Paint _markOver;
  final Paint _needle;
  final Paint _pivot;

  /// The needle sweeps 50°, centred on vertical. Wider than a real movement's
  /// travel looks like a speedometer; narrower and the last few VU are
  /// indistinguishable.
  static const double _halfSweep = 25 * math.pi / 180;

  /// Ends of the scale, in VU. The face crowds towards the bottom end because
  /// deflection is linear in voltage.
  static const double _minVu = -20;
  static const double _maxVu = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 80 || size.height < 50) return;

    // The pivot sits below the face, so the needle sweeps across the top of the
    // module and the dial fills the width rather than the height — which is the
    // shape a VU module is actually resized into.
    final radius = math.min(size.width * 0.52, size.height * 0.92);
    final pivot = Offset(size.width / 2, size.height * 0.94);
    final faceRadius = radius * 0.88;

    final bounds = Rect.fromCircle(center: pivot, radius: faceRadius);
    final zero = -math.pi / 2; // straight up

    // --- The arc, in two pieces so "over" is part of the face --------------
    final overStart = zero + _angleOf(0);
    canvas.drawArc(
      bounds,
      zero - _halfSweep,
      overStart - (zero - _halfSweep),
      false,
      _arc,
    );
    canvas.drawArc(
      bounds,
      overStart,
      zero + _halfSweep - overStart,
      false,
      _arcOver,
    );

    // --- Marks --------------------------------------------------------------
    for (var i = 0; i < _vuMarks.length; i++) {
      final vu = _vuMarks[i];
      final angle = zero + _angleOf(vu);
      final direction = Offset(math.cos(angle), math.sin(angle));
      final long = _vuLabelled.contains(vu);

      canvas.drawLine(
        pivot + direction * faceRadius,
        pivot +
            direction * (faceRadius - (long ? radius * 0.09 : radius * 0.05)),
        vu >= 0 ? _markOver : _mark,
      );

      final label = state._labels[i];
      if (long && label.longestLine > 0) {
        final at = pivot + direction * (faceRadius - radius * 0.19);
        canvas.drawParagraph(
          label,
          at - Offset(label.longestLine / 2, label.height / 2),
        );
      }
    }

    // --- The needle ---------------------------------------------------------
    // The loudest channel. A stereo pair on one movement is what a mono VU
    // does, and showing the quieter of the two would understate the programme.
    var loudest = kBelDbFloor;
    final channels = engine.channels.clamp(1, kBelMaxChannels);
    for (var c = 0; c < channels; c++) {
      if (engine.vu[c] > loudest) loudest = engine.vu[c];
    }

    final vu = loudest - calibration.vuReference;
    final angle = zero + _angleOf(vu);
    final direction = Offset(math.cos(angle), math.sin(angle));
    canvas.drawLine(
      pivot - direction * (radius * 0.06),
      pivot + direction * (faceRadius - radius * 0.02),
      _needle,
    );
    canvas.drawCircle(pivot, radius * 0.035, _pivot);

    final unit = state._unit!;
    canvas.drawParagraph(
      unit,
      Offset(pivot.dx - unit.longestLine / 2, pivot.dy - radius * 0.30),
    );
  }

  /// Where a VU reading sits on the face, as an angle either side of vertical.
  ///
  /// Linear in voltage, not in decibels: a VU movement is a rectifier driving a
  /// meter whose deflection is proportional to current, so the *amplitude* is
  /// what maps evenly onto the arc. Spacing the marks evenly in dB instead is
  /// the usual mistake and produces a face that looks right and reads wrong
  /// everywhere except at its two ends.
  double _angleOf(double vu) {
    final clamped = vu.isNaN ? _minVu : vu.clamp(_minVu, _maxVu);
    final low = _voltage(_minVu);
    final high = _voltage(_maxVu);
    final fraction = (_voltage(clamped) - low) / (high - low);
    return (fraction * 2 - 1) * _halfSweep;
  }

  static double _voltage(double vu) => math.pow(10, vu / 20).toDouble();

  @override
  bool shouldRepaint(_VuPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine);
}
