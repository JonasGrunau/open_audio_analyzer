// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// A needle, on the movement the engine models.
///
/// The dial is not nostalgia. A VU is average-responding where every other
/// meter here is peak- or RMS-responding, and its 300 ms movement with a little
/// overshoot is a low-pass filter with a shape that happens to track perceived
/// level well — which is why people still mix to one. Both properties live in
/// `oaa_analysis.c`; this module draws the result and nothing else.
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

  final MeterSource engine;
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

  /// How much room the scale labels need, above the arc and beside it.
  ///
  /// The labels sit outside the arc, each one pushed out far enough that its
  /// *near* edge clears the arc by the same gap — which is what puts six boxes
  /// of three different widths on one visual radius rather than scattered
  /// along it.
  ///
  /// The two directions get different bounds because they are genuinely
  /// different problems, and using one number for both is what left a band of
  /// dead space above the dial. Straight up the reserve is exactly one label
  /// height; the label nearest vertical is the tallest thing over the arc and
  /// nothing beyond it reaches higher. Sideways it depends on the angle the
  /// sweep opens to, so it is bounded rather than solved.
  double _labelAbove = 0;
  double _labelBeside = 0;

  /// Height of the `VU` badge, which is reserved below the pivot rather than
  /// drawn inside the dial. Printing it on the face is what a real VU does and
  /// it is wrong here: at 0 VU — the one reading anybody is looking for — the
  /// needle passes straight through it.
  double _unitHeight = 0;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtColor != colors.textFaint) {
      _builtColor = colors.textFaint;
      _labels = [
        for (final mark in _vuMarks)
          if (_vuLabelled.contains(mark))
            layoutParagraph(
              mark == 0
                  ? '0'
                  : (mark > 0 ? '+${mark.toInt()}' : '${mark.toInt()}'),
              OaaType.tick.copyWith(
                color: mark >= 0 ? colors.over : colors.textFaint,
              ),
            )
          else
            layoutParagraph('', OaaType.tick),
      ];
      _unit = layoutParagraph(
        'VU',
        OaaType.label.copyWith(color: colors.textFaint),
      );

      var widest = 0.0;
      var tallest = 0.0;
      for (final label in _labels) {
        if (label.longestLine <= 0) continue;
        if (label.longestLine > widest) widest = label.longestLine;
        if (label.height > tallest) tallest = label.height;
      }
      _labelAbove = tallest;
      _labelBeside =
          math.sqrt(widest * widest + tallest * tallest) / 2 + widest / 2;
      _unitHeight = _unit!.height;
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
         ..strokeWidth = OaaStroke.hairline),
       _arcOver = (Paint()
         ..color = colors.over
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.mark),
       _mark = (Paint()
         ..color = colors.textFaint
         ..strokeWidth = OaaStroke.hairline),
       _markOver = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.mark),
       _needle = (Paint()
         ..color = colors.textPrimary
         ..strokeWidth = OaaStroke.mark
         ..strokeCap = StrokeCap.round),
       _pivot = (Paint()..color = colors.textMuted),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final _VuMeterModuleState state;

  final Paint _arc;
  final Paint _arcOver;
  final Paint _mark;
  final Paint _markOver;
  final Paint _needle;
  final Paint _pivot;

  /// How far the sweep may open, either side of vertical.
  ///
  /// Not a constant, because the module is not a constant shape. A VU tile is
  /// resized in width far more often than in height, and a face laid out for
  /// one aspect ratio leaves a third of the other empty — which is precisely
  /// what this module did: a 35° sweep in a 2:1 tile drew its ink across the
  /// middle half of the width and left the rest bare with the badge adrift in
  /// it. The sweep now opens until the face fills the box, between two bounds
  /// that both come from looking at it: under 35° the eleven marks collide,
  /// and over 55° it stops reading as a VU and starts reading as a speedometer.
  static const double _minHalfSweep = 35 * math.pi / 180;
  static const double _maxHalfSweep = 55 * math.pi / 180;

  /// Ends of the scale, in VU. The face crowds towards the bottom end because
  /// deflection is linear in voltage.
  static const double _minVu = -20;
  static const double _maxVu = 3;

  /// The gap between the arc and the near edge of a scale label.
  static const double _labelGap = Space.xs;

  /// The pivot cap, as a fraction of the face radius.
  static const double _capShare = 0.035;

  @override
  void paint(Canvas canvas, Size size) {
    // --- Geometry -----------------------------------------------------------
    // Solved rather than assumed. `face` is the arc's radius; everything else
    // is expressed against it, so the whole dial scales as one object and the
    // ink is centred in the tile instead of pinned to a corner of it.
    // No inset of its own: `ModuleFrame` already gives every module the same
    // margin on all four sides, and a painter that adds a second one is a
    // module that sits differently from the other eleven.
    final availW = size.width;
    final availH = size.height;

    final above = _labelGap + state._labelAbove;
    final beside = _labelGap + state._labelBeside;
    final unitBand = state._unitHeight + Space.sm;

    final vertical = availH - above - unitBand;
    final horizontal = availW / 2 - beside;
    if (vertical <= 0 || horizontal <= 0) return;

    // Pick the sweep that makes width and height bind at the same radius, then
    // clamp it into the readable range.
    final halfSweep = math
        .asin(
          ((1 + _capShare) * horizontal / vertical).clamp(
            math.sin(_minHalfSweep),
            math.sin(_maxHalfSweep),
          ),
        )
        .toDouble();
    final sinHalf = math.sin(halfSweep);

    final face = math.min(vertical / (1 + _capShare), horizontal / sinHalf);
    if (face <= 0) return;

    final cap = face * _capShare;
    final inkHeight = face * (1 + _capShare) + above + unitBand;
    final pivot = Offset(
      size.width / 2,
      (size.height - inkHeight) / 2 + face + above,
    );

    final bounds = Rect.fromCircle(center: pivot, radius: face);
    final zero = -math.pi / 2; // straight up

    // --- The arc, in two pieces so "over" is part of the face --------------
    final overStart = zero + _angleOf(0, halfSweep);
    canvas.drawArc(
      bounds,
      zero - halfSweep,
      overStart - (zero - halfSweep),
      false,
      _arc,
    );
    canvas.drawArc(
      bounds,
      overStart,
      zero + halfSweep - overStart,
      false,
      _arcOver,
    );

    // --- Marks and labels ---------------------------------------------------
    // Labels sit *outside* the arc. Inside, they are in the needle's sweep:
    // at rest the needle lay along the −20 mark and struck its own label
    // through, and no reading on the lower half of the face could be read
    // without the needle across it.
    for (var i = 0; i < _vuMarks.length; i++) {
      final vu = _vuMarks[i];
      final angle = zero + _angleOf(vu, halfSweep);
      final direction = Offset(math.cos(angle), math.sin(angle));
      final long = _vuLabelled.contains(vu);

      canvas.drawLine(
        pivot + direction * face,
        pivot + direction * (face - (long ? face * 0.10 : face * 0.06)),
        vu >= 0 ? _markOver : _mark,
      );

      final label = state._labels[i];
      if (!long || label.longestLine <= 0) continue;

      // How far the label's own box extends along the radius it sits on. Push
      // the centre out by exactly that and every near edge lands on one
      // circle, whatever the angle — which is the difference between six
      // labels on a scale and six labels scattered near one.
      final half = Offset(label.longestLine / 2, label.height / 2);
      final extent =
          half.dx * direction.dx.abs() + half.dy * direction.dy.abs();
      final at = pivot + direction * (face + _labelGap + extent);
      canvas.drawParagraph(label, at - half);
    }

    // --- The needle ---------------------------------------------------------
    // The loudest channel. A stereo pair on one movement is what a mono VU
    // does, and showing the quieter of the two would understate the programme.
    var loudest = kOaaDbFloor;
    final channels = engine.channels.clamp(1, kOaaMaxChannels);
    for (var c = 0; c < channels; c++) {
      if (engine.vu[c] > loudest) loudest = engine.vu[c];
    }

    final vu = loudest - calibration.vuReference;
    final angle = zero + _angleOf(vu, halfSweep);
    final direction = Offset(math.cos(angle), math.sin(angle));

    // From the pivot outwards, and no further back. The needle used to start a
    // little behind its own centre — a counterweight a real movement has and a
    // drawing of one does not need — and the tail was longer than the cap that
    // was meant to hide it, so a second short needle stuck out of the bottom
    // of the pivot pointing the opposite way.
    canvas.drawLine(
      pivot,
      pivot + direction * (face - OaaStroke.mark),
      _needle,
    );
    canvas.drawCircle(pivot, cap, _pivot);

    // Below the pivot, where the needle cannot reach.
    final unit = state._unit!;
    canvas.drawParagraph(
      unit,
      Offset(pivot.dx - unit.longestLine / 2, pivot.dy + cap + Space.sm),
    );
  }

  /// Where a VU reading sits on the face, as an angle either side of vertical.
  ///
  /// Linear in voltage, not in decibels: a VU movement is a rectifier driving a
  /// meter whose deflection is proportional to current, so the *amplitude* is
  /// what maps evenly onto the arc. Spacing the marks evenly in dB instead is
  /// the usual mistake and produces a face that looks right and reads wrong
  /// everywhere except at its two ends.
  double _angleOf(double vu, double halfSweep) {
    final clamped = vu.isNaN ? _minVu : vu.clamp(_minVu, _maxVu);
    final fraction = (_voltage(clamped) - _lowVoltage) / _voltageSpan;
    return (fraction * 2 - 1) * halfSweep;
  }

  static double _voltage(double vu) => math.pow(10, vu / 20).toDouble();

  /// Hoisted off the frame path: the two ends of the scale never move, and
  /// recomputing them cost twenty-four `pow` calls a frame.
  static final double _lowVoltage = _voltage(_minVu);
  static final double _voltageSpan = _voltage(_maxVu) - _voltage(_minVu);

  @override
  bool shouldRepaint(_VuPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine);
}
