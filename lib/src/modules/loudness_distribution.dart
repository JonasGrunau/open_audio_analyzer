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
///
/// ---------------------------------------------------------------------------
/// Its relationship to the Histogram
///
/// The two are the same measurement asked two questions. The Histogram is
/// short-term loudness against **time** — when the programme was loud. This is
/// short-term loudness against **how often** — how the programme was
/// distributed, with time collapsed out of it. They share the target split and
/// the palette so that the pair reads as one instrument; they do not share a
/// scale, and deliberately.
///
/// **The axis is the published range exactly**, −60 to 0 LUFS, not the −48 the
/// loudness meters draw. `MeterScale.fractionOf` clamps, so a narrower axis
/// would not drop the bins below its floor — it would stack every one of them
/// onto the bottom column as a single tall bar, which is a shape the programme
/// never had. An axis that disagrees with a neighbour by a labelled amount is a
/// smaller problem than a picture that is wrong.
class LoudnessDistributionModule extends StatefulWidget {
  const LoudnessDistributionModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<LoudnessDistributionModule> createState() =>
      _LoudnessDistributionModuleState();
}

class _LoudnessDistributionModuleState
    extends State<LoudnessDistributionModule> {
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

  /// The target line's dashes, allocated on resize. Every slot is written every
  /// frame, so the whole buffer goes over as it is — a `sublistView` to trim it
  /// to the dashes actually used would be the per-frame allocation the bars
  /// above are shaped to avoid.
  Float32List _dashes = Float32List(0);
  double _builtHeight = -1;

  void _ensureDashes(double height) {
    if (height == _builtHeight) return;
    _builtHeight = height;
    _dashes = Float32List((height / _dashPeriod).ceil() * 4);
  }

  final _targetValue = ValueParagraph();

  ScaleGraticule? _graticule;
  ui.Paragraph? _lowLabel;
  ui.Paragraph? _highLabel;
  ui.Paragraph? _unit;

  // --- The two fills, and the gradient they share ---------------------------

  Paint? _fillUnder;
  Paint? _fillOver;
  Rect? _shadedPlot;
  BelColors? _shadedColors;

  /// The same construction, direction and alphas as the Histogram's fill: a
  /// shader on the `Paint`, evaluated in canvas space, so a hundred and twenty
  /// butt-capped strokes drawn through it produce the gradient one filled
  /// `Path` would — and none of them allocates. Bright at the top means the
  /// mode of the distribution is the brightest thing on the module, which is
  /// the right emphasis: it is where the programme actually lived.
  void _ensureFills(Rect plot, BelColors colors, double barWidth) {
    if (_shadedPlot == plot && _shadedColors == colors) return;
    _shadedPlot = plot;
    _shadedColors = colors;

    Paint fill(Color color) => Paint()
      ..strokeCap = StrokeCap.butt
      // Half a pixel wider than the spacing, the same as the spectrum
      // analyser's bands and for the same reason: butt caps on a stroke exactly
      // one bar wide leave a seam of background wherever a bar centre lands
      // mid-pixel, and a row of hairline seams reads as banding.
      ..strokeWidth = barWidth + 0.5
      ..shader = ui.Gradient.linear(plot.topCenter, plot.bottomCenter, <Color>[
        color.withValues(alpha: 0.70),
        color.withValues(alpha: 0.16),
      ]);

    _fillUnder = fill(colors.accent);
    _fillOver = fill(colors.over);
  }

  @override
  void dispose() {
    _graticule?.dispose();
    _targetValue.dispose();
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
      _unit = layoutParagraph(
        'LUFS',
        BelType.tick.copyWith(color: colors.textFaint),
      );
    }

    return MeterBody(
      painter: _DistributionPainter(
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

/// Dash geometry for the target line: six pixels on, five off. The same line as
/// the Histogram's, turned through a right angle.
const double _dashOn = 6;
const double _dashPeriod = 11;

/// The fraction of the plot the bars leave clear at the top, for the percentile
/// labels to sit in.
const double _annotationStrip = 0.12;

class _DistributionPainter extends MeterPainter {
  _DistributionPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.graticule,
    required this.state,
    required Listenable repaint,
  }) : _rangeBand = (Paint()
         ..color = colors.textPrimary.withValues(alpha: 0.05)),
       // The percentiles are the reading — LRA *is* the distance between these
       // two lines — so they take the reading colour and the mark weight, and
       // the wash between them stays almost nothing. The accent cannot serve
       // here: the bars are already drawn in it, and a percentile line that
       // matches the bars is a percentile line nobody can find.
       _percentile = (Paint()
         ..color = colors.textPrimary
         ..strokeWidth = BelStroke.mark
         ..isAntiAlias = false),
       _target = (Paint()
         ..color = colors.textMuted
         ..strokeWidth = BelStroke.mark
         ..strokeCap = StrokeCap.butt
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final BelColors colors;
  final ScaleGraticule graticule;
  final _LoudnessDistributionModuleState state;

  final Paint _rangeBand;
  final Paint _percentile;
  final Paint _target;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = state._unit!;
    final plot = Rect.fromLTRB(
      0,
      unit.height + Space.xs,
      size.width,
      size.height - graticule.gutter,
    );
    if (plot.width < 80 || plot.height < 32) return;

    final barWidth = plot.width / kBelHistogramBins;
    state._ensureFills(plot, colors, barWidth);
    state._ensureDashes(plot.height);

    graticule.paint(canvas, plot);
    canvas.drawParagraph(unit, Offset.zero);

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

      // Labelled only when there is room between the two lines. On steady
      // material the percentiles sit a fraction of a decibel apart — a correct
      // reading, and one that would otherwise print both labels in the same
      // place.
      final room =
          state._lowLabel!.longestLine +
          state._highLabel!.longestLine +
          Space.sm;
      if (right - left > room) {
        canvas.drawParagraph(
          state._lowLabel!,
          Offset(left + Space.xxs, plot.top),
        );
        canvas.drawParagraph(
          state._highLabel!,
          Offset(right - state._highLabel!.longestLine - Space.xxs, plot.top),
        );
      }
    }

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

    final targetX = _x(plot, calibration.lufsTarget);

    if (tallest > 0) {
      // Every bin is written, empty ones included, so the whole buffer can be
      // handed over as it is. A `sublistView` would be one small allocation per
      // frame per module, and a zero-length segment under a butt cap draws
      // nothing anyway — the empty bins cost a few floats and no pixels.
      // Scaled into nine tenths of the plot, not all of it. The tallest bin
      // touching the top edge is what put the mode through the "95%" label —
      // and the mode reaches the top *by construction*, so it is not an unlucky
      // case, it is every programme whose busiest loudness happens to sit near
      // a percentile. The strip left over is where the annotations live.
      final headroom = plot.height * _annotationStrip;

      for (var bin = 0; bin < kBelHistogramBins; bin++) {
        final x = plot.left + (bin + 0.5) * barWidth;
        final height =
            engine.histogram[bin] / tallest * (plot.height - headroom);
        state._bars[bin * 4] = x;
        state._bars[bin * 4 + 1] = plot.bottom;
        state._bars[bin * 4 + 2] = x;
        state._bars[bin * 4 + 3] = plot.bottom - height;
      }

      // Quieter than the target on one side, louder on the other, split by a
      // clip rather than by classifying each bar. A bin is 0.5 LU wide and a
      // target is a point inside one of them, so the bin the target falls in
      // has no single answer — clipping puts the boundary where the target
      // actually is. What the reader adds up is the *area* to the right of the
      // line: how much of the programme sat above the number it was delivered
      // against.
      void pass(Rect region, Paint fill) {
        if (region.width <= 0) return;
        canvas.save();
        canvas.clipRect(region);
        canvas.drawRawPoints(ui.PointMode.lines, state._bars, fill);
        canvas.restore();
      }

      pass(
        Rect.fromLTRB(plot.left, plot.top, targetX, plot.bottom),
        state._fillUnder!,
      );
      pass(
        Rect.fromLTRB(targetX, plot.top, plot.right, plot.bottom),
        state._fillOver!,
      );
    }

    // --- The target ---------------------------------------------------------
    _paintTarget(canvas, plot, targetX);
  }

  /// The dashed target line, and its value in the gutter under it.
  ///
  /// The label is dropped rather than allowed to collide with a scale tick,
  /// which is the same rule the Histogram applies to its own — the annotation
  /// gives way to the scale, because a half-covered tick reads as a rendering
  /// fault where a missing one reads as a scale you can still count in tens.
  void _paintTarget(Canvas canvas, Rect plot, double targetX) {
    final dashes = state._dashes;
    for (var i = 0; i < dashes.length ~/ 4; i++) {
      final y = plot.top + i * _dashPeriod;
      dashes[i * 4] = targetX;
      dashes[i * 4 + 1] = y;
      dashes[i * 4 + 2] = targetX;
      dashes[i * 4 + 3] = y + _dashOn > plot.bottom ? plot.bottom : y + _dashOn;
    }
    canvas.drawRawPoints(ui.PointMode.lines, dashes, _target);

    final label = state._targetValue.of(
      Metric.lufsIntegrated.format(calibration.lufsTarget),
      BelType.tick.copyWith(color: colors.textMuted),
    );

    final scale = graticule.scale;
    final target = calibration.lufsTarget.clamp(scale.min, scale.max);
    final nearestTick = (target / scale.step).roundToDouble() * scale.step;
    final gap = (target - nearestTick).abs() / scale.span * plot.width;
    if (gap <= label.longestLine + Space.xs) return;

    canvas.drawParagraph(
      label,
      Offset(
        (targetX - label.longestLine / 2).clamp(
          plot.left,
          plot.right - label.longestLine,
        ),
        plot.bottom + Space.xs,
      ),
    );
  }

  double _x(Rect plot, double lufs) =>
      plot.left + graticule.scale.fractionOf(lufs) * plot.width;

  @override
  bool shouldRepaint(_DistributionPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
