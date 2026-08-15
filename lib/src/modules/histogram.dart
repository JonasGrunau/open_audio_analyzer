// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// How much of the programme was spent at each loudness.
///
/// This is the picture behind the LRA number, drawn from **the same blocks**
/// the number is computed from — the relative-gated short-term distribution,
/// with the 10th and 95th percentiles marked. LRA is the distance between those
/// two lines and nothing else, so the module answers the question the number
/// provokes: an LRA of 9 LU, yes, but *which* 9 LU, and is the mass at the top
/// or the bottom of it?
///
/// A distribution drawn from a different population than the number beside it
/// would eventually be used to argue the number was wrong, which is why the
/// engine publishes this rather than the app accumulating its own.
class HistogramModule extends StatefulWidget {
  const HistogramModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final BelEngine engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<HistogramModule> createState() => _HistogramModuleState();
}

class _HistogramModuleState extends State<HistogramModule> {
  /// The published range, exactly. Drawing a different one would either clip
  /// bins that exist or invent axis that has no bins behind it.
  static const _scale = MeterScale(
    min: kBelHistogramMinLufs,
    max: kBelHistogramMaxLufs,
    step: 10,
  );

  /// Two points per bar — top and bottom — drawn as one `PointMode.lines` call.
  /// Allocated once: a `Path` rebuilt each frame would be 120 segments of
  /// garbage sixty times a second.
  final Float32List _bars = Float32List(kBelHistogramBins * 4);

  ScaleGraticule? _graticule;
  ui.Paragraph? _lowLabel;
  ui.Paragraph? _highLabel;

  @override
  void dispose() {
    _graticule?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_graticule == null ||
        !_graticule!.matches(_scale, ScaleSide.bottom, colors.textFaint)) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.bottom,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );
      final style = BelType.tick.copyWith(color: colors.textMuted);
      _lowLabel = layoutParagraph('10%', style);
      _highLabel = layoutParagraph('95%', style);
    }

    return MeterBody(
      painter: _HistogramPainter(
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

class _HistogramPainter extends MeterPainter {
  _HistogramPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.graticule,
    required this.state,
    required Listenable repaint,
  }) : _bars = (Paint()
         ..color = colors.meterFill
         ..strokeCap = StrokeCap.butt),
       _rangeBand = (Paint()..color = colors.accent.withValues(alpha: 0.10)),
       _percentile = (Paint()
         ..color = colors.accent
         ..strokeWidth = BelStroke.mark
         ..isAntiAlias = false),
       _target = (Paint()
         ..color = colors.textMuted
         ..strokeWidth = BelStroke.mark
         ..isAntiAlias = false),
       super(repaint: repaint);

  final BelEngine engine;
  final Calibration calibration;
  final BelColors colors;
  final ScaleGraticule graticule;
  final _HistogramModuleState state;

  final Paint _bars;
  final Paint _rangeBand;
  final Paint _percentile;
  final Paint _target;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 120 || size.height < 60) return;

    final plot = Rect.fromLTRB(
      0,
      0,
      size.width,
      size.height - graticule.gutter,
    );
    if (plot.height < 24) return;

    graticule.paint(canvas, plot);

    // --- The gated range ----------------------------------------------------
    final low = engine.loudnessRangeLow;
    final high = engine.loudnessRangeHigh;
    if (!low.isNaN && !high.isNaN) {
      final left = _x(plot, low);
      final right = _x(plot, high);
      canvas.drawRect(
        Rect.fromLTRB(left, plot.top, right, plot.bottom),
        _rangeBand,
      );
      canvas.drawLine(
        Offset(left, plot.top),
        Offset(left, plot.bottom),
        _percentile,
      );
      canvas.drawLine(
        Offset(right, plot.top),
        Offset(right, plot.bottom),
        _percentile,
      );

      canvas.drawParagraph(
        state._lowLabel!,
        Offset(left + Space.xxs, plot.top),
      );
      canvas.drawParagraph(
        state._highLabel!,
        Offset(right - state._highLabel!.longestLine - Space.xxs, plot.top),
      );
    }

    // --- The target ---------------------------------------------------------
    final targetX = _x(plot, calibration.lufsTarget);
    canvas.drawLine(
      Offset(targetX, plot.top),
      Offset(targetX, plot.bottom),
      _target,
    );

    // --- The bars -----------------------------------------------------------
    // Scaled to the tallest bin rather than to 1.0. A distribution over a long
    // programme spreads thin — a quarter of an hour of material rarely puts
    // more than a few percent in any one bin — and a plot fixed at 0..1 would
    // be an empty rectangle with a hairline along the bottom.
    var tallest = 0.0;
    for (var bin = 0; bin < kBelHistogramBins; bin++) {
      final value = engine.histogram[bin];
      if (value > tallest) tallest = value;
    }
    if (tallest <= 0) return;

    final barWidth = plot.width / kBelHistogramBins;
    _bars.strokeWidth = barWidth;

    // Every bin is written, empty ones included, so the whole buffer can be
    // handed over as it is. A `sublistView` would be one small allocation per
    // frame per histogram, and a zero-length segment under a butt cap draws
    // nothing anyway — the empty bins cost a few floats and no pixels.
    for (var bin = 0; bin < kBelHistogramBins; bin++) {
      final x = plot.left + (bin + 0.5) * barWidth;
      final height = engine.histogram[bin] / tallest * plot.height;
      state._bars[bin * 4] = x;
      state._bars[bin * 4 + 1] = plot.bottom;
      state._bars[bin * 4 + 2] = x;
      state._bars[bin * 4 + 3] = plot.bottom - height;
    }

    canvas.drawRawPoints(ui.PointMode.lines, state._bars, _bars);
  }

  double _x(Rect plot, double lufs) =>
      plot.left + graticule.scale.fractionOf(lufs) * plot.width;

  @override
  bool shouldRepaint(_HistogramPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
