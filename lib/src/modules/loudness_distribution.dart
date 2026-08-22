// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// How much of the programme was spent at each loudness.
///
/// This is the picture behind the LRA number, drawn from **the same blocks**
/// the number is computed from — the relative-gated short-term distribution,
/// bracketed between the 10th and 95th percentiles. LRA is the distance between
/// those two and nothing else, so the module answers the question the number
/// provokes: an LRA of 9 LU, yes, but *which* 9 LU, and is the mass at the top
/// or the bottom of it? The number itself is printed on the bracket, which is
/// where it belongs and where the module did not have it for two phases.
///
/// A distribution drawn from a different population than the number beside it
/// would eventually be used to argue the number was wrong, which is why the
/// engine publishes this rather than the app accumulating its own.
///
/// ---------------------------------------------------------------------------
/// Three things share this plot, and only one of them may cross it
///
/// The module draws the distribution, the gated range, and the delivery target.
/// It used to draw all three as marks *through* the picture: two full-height
/// percentile lines at the reading weight, a full-height dashed target, and on
/// steady material all three landing within a few pixels of each other. The
/// distribution is the picture, so the other two are arranged around it now —
/// the range as a wash with a dimension line above it, the target as the one
/// dashed line that crosses, because it is the only one of the three the user
/// chose. And every annotation is painted **after** the fill, which the
/// percentile labels were not — on a module short enough that the strip at the
/// top was thinner than a line of text, the gradient was composited over the
/// reading. The strip is measured against the label it holds now, so that case
/// is gone twice over.
///
/// ---------------------------------------------------------------------------
/// Its relationship to the Histogram
///
/// The two are the same measurement asked two questions. The Histogram is
/// short-term loudness against **time** — when the programme was loud. This is
/// short-term loudness against **how often** — how the programme was
/// distributed, with time collapsed out of it. They share the target split and
/// the palette so that the pair reads as one instrument — quieter than the
/// target in [OaaColors.accent], louder in [OaaColors.warn] — and they do not
/// share a scale, deliberately.
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
    min: MeterShape.histogramMinLufs,
    max: MeterShape.histogramMaxLufs,
    step: 10,
  );

  // --- Buffers, allocated on resize and never on a frame --------------------

  /// The fill, as one logical pixel column per column of plot: two points each,
  /// floor and top, drawn as a single `PointMode.lines` call.
  Float32List _columns = Float32List(0);

  /// The silhouette's top edge, one point per column, drawn as a single
  /// `PointMode.polygon` call — so the risers between two steps come free from
  /// the points meeting.
  Float32List _edge = Float32List(0);
  int _builtColumns = -1;

  void _ensureColumns(int columns) {
    if (columns == _builtColumns) return;
    _builtColumns = columns;
    _columns = Float32List(columns * 4);
    _edge = Float32List(columns * 2);
  }

  /// The target line's dashes, allocated on resize. Every slot is written every
  /// frame, so the whole buffer goes over as it is — a `sublistView` to trim it
  /// to the dashes actually used would be the per-frame allocation the buffers
  /// above are shaped to avoid.
  Float32List _dashes = Float32List(0);
  double _builtHeight = -1;

  void _ensureDashes(double height) {
    if (height == _builtHeight) return;
    _builtHeight = height;
    _dashes = Float32List((height / _dashPeriod).ceil() * 4);
  }

  final _targetValue = ValueParagraph();
  final _rangeValue = ValueParagraph();

  ScaleGraticule? _graticule;
  ui.Paragraph? _unit;

  // --- The two fills, and the gradient they share ---------------------------

  Paint? _fillUnder;
  Paint? _fillOver;
  Rect? _shadedPlot;
  OaaColors? _shadedColors;

  /// The same construction, direction and alphas as the Histogram's fill: a
  /// shader on the `Paint`, evaluated in canvas space, so a plot's worth of
  /// butt-capped strokes drawn through it produce the gradient one filled
  /// `Path` would — and none of them allocates. Bright at the top means the
  /// mode of the distribution is the brightest thing on the module, which is
  /// the right emphasis: it is where the programme actually lived.
  void _ensureFills(Rect plot, OaaColors colors) {
    if (_shadedPlot == plot && _shadedColors == colors) return;
    _shadedPlot = plot;
    _shadedColors = colors;

    Paint fill(Color color) => Paint()
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = _columnWidth
      // The columns tile the plot exactly, so there is no edge for
      // antialiasing to soften — only cost.
      //
      // **This is the fix for a fence.** The fill used to be one stroke per
      // published bin, `barWidth + 0.5` wide, the half pixel deliberate so that
      // butt caps could not leave a seam of background wherever a bar centre
      // landed mid-pixel. But each bar is a separate stroke through a
      // translucent gradient, so every overlap composited *twice*: a brighter
      // vertical line at all hundred and nineteen bin boundaries, and on a
      // default-sized module — where a bin is under three pixels wide — nearly a
      // fifth of the fill double-drawn. What should have read as a shape read as
      // a row of green lines painted over each other. One-pixel columns
      // composite once each and cannot overlap, which is why the Histogram and
      // the Spectrum Analyzer have always drawn their fills this way.
      ..isAntiAlias = false
      ..shader = ui.Gradient.linear(plot.topCenter, plot.bottomCenter, <Color>[
        color.withValues(alpha: 0.70),
        color.withValues(alpha: 0.16),
      ]);

    _fillUnder = fill(colors.accent);
    _fillOver = fill(colors.warn);
  }

  @override
  void dispose() {
    _graticule?.dispose();
    _targetValue.dispose();
    _rangeValue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_graticule == null ||
        !_graticule!.matches(_scale, ScaleSide.bottom, colors.textFaint)) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.bottom,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );
      _unit = layoutParagraph(
        'LUFS',
        OaaType.tick.copyWith(color: colors.textFaint),
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

/// One logical pixel per column of the plot. Wide enough to tile exactly and
/// narrow enough that the bins are drawn as the steps they are.
const double _columnWidth = 1;

/// Dash geometry for the target line: six pixels on, five off. The same line as
/// the Histogram's, turned through a right angle.
const double _dashOn = 6;
const double _dashPeriod = 11;

/// How far the caliper's end serifs reach into the plot, top and bottom.
const double _serif = 4;

/// The least of the plot the bars leave clear at the top, for the caliper to
/// sit in, and the most of it the caliper is allowed to take.
///
/// A fraction alone is not enough: twelve per cent of a short module is three
/// pixels, and the caliper needs its label's height whatever the module is. A
/// ceiling alone is not enough either — a strip sized only by the label would
/// be most of a small module, and a distribution with no room to be a shape is
/// not worth annotating.
const double _stripFraction = 0.12;
const double _stripCeiling = 0.4;

class _DistributionPainter extends MeterPainter {
  _DistributionPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.graticule,
    required this.state,
    required Listenable repaint,
  }) : _rangeBand = (Paint()
         ..color = colors.textPrimary.withValues(alpha: 0.07)),
       // The caliper's marks, in `textMuted` and at the mark weight. They used
       // to be two `textPrimary` lines the full height of the plot, on the
       // argument that LRA *is* the distance between them and so they were the
       // reading. The argument was right and the conclusion was not: the
       // reading is a *number*, and drawing it as two lines through the picture
       // meant the module never printed it. It prints it now, on the caliper,
       // and the marks that carry the eye to it can be quiet. Every segment is
       // axis-aligned, so antialiasing is off and they land on whole pixels.
       _caliper = (Paint()
         ..color = colors.textMuted
         ..strokeWidth = OaaStroke.mark
         ..strokeCap = StrokeCap.butt
         ..isAntiAlias = false),
       // The silhouette's top edge, at full alpha over a fill that reaches 0.70
       // of it — the same relationship the Histogram's curve has to its own
       // fill, and what turns a plot's worth of one-pixel columns into a shape.
       // Antialiased, unlike the columns underneath: this one is a line at an
       // angle wherever the distribution rises or falls.
       _edgeUnder = (Paint()
         ..color = colors.accent
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.mark),
       _edgeOver = (Paint()
         ..color = colors.warn
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.mark),
       _target = (Paint()
         ..color = colors.textMuted
         ..strokeWidth = OaaStroke.mark
         ..strokeCap = StrokeCap.butt
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final ScaleGraticule graticule;
  final _LoudnessDistributionModuleState state;

  final Paint _rangeBand;
  final Paint _caliper;
  final Paint _edgeUnder;
  final Paint _edgeOver;
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

    final columns = (plot.width / _columnWidth).floor();
    state._ensureColumns(columns);
    state._ensureFills(plot, colors);
    state._ensureDashes(plot.height);

    graticule.paint(canvas, plot);
    canvas.drawParagraph(unit, Offset.zero);

    final low = engine.loudnessRangeLow;
    final high = engine.loudnessRangeHigh;
    final hasRange = !low.isNaN && !high.isNaN;

    // The gated range as a wash, behind everything the signal draws — it is a
    // region of the axis rather than a mark on the picture. Its annotation goes
    // on last, at the other end of this method.
    if (hasRange) {
      canvas.drawRect(
        Rect.fromLTRB(_x(plot, low), plot.top, _x(plot, high), plot.bottom),
        _rangeBand,
      );
    }

    final targetX = _x(plot, calibration.lufsTarget);
    _paintDistribution(canvas, plot, columns, targetX);
    _paintTarget(canvas, plot, targetX);

    // Last, so that nothing is ever drawn over the reading. The percentile marks
    // and their labels were painted *before* the bars, which was survivable
    // only because the strip at the top happened to be taller than a label on a
    // module of ordinary height — on a short one the fill was composited over
    // the part of the module meant to be read first. Both halves are fixed: the
    // strip is sized against the label now, and the annotation is on top
    // whatever the strip turns out to be.
    if (hasRange) _paintCaliper(canvas, plot, low, high);
  }

  /// The distribution itself: one column of fill per pixel, and the top edge
  /// that makes them a silhouette.
  void _paintDistribution(
    Canvas canvas,
    Rect plot,
    int columns,
    double targetX,
  ) {
    // Scaled to the tallest bin rather than to 1.0. A distribution over a long
    // programme spreads thin — a quarter of an hour of material rarely puts
    // more than a few percent in any one bin — and a plot fixed at 0..1 would
    // be an empty rectangle with a hairline along the bottom.
    final bins = engine.histogram;
    var tallest = 0.0;
    for (var bin = 0; bin < MeterShape.histogramBins; bin++) {
      final value = bins[bin];
      if (value > tallest) tallest = value;
    }
    if (tallest <= 0) return;

    // The strip at the top the caliper lives in. The tallest bin reaches the
    // top of the plot *by construction*, so without this the mode is drawn
    // through the annotation on every programme rather than on an unlucky one.
    final labelHeight = OaaType.tick.fontSize! + _serif + Space.xs;
    final strip = math.min(
      math.max(plot.height * _stripFraction, labelHeight),
      plot.height * _stripCeiling,
    );
    final usable = plot.height - strip;

    final fill = state._columns;
    final edge = state._edge;

    // Which columns have anything in them, so the edge can be held to the
    // occupied span. Run across the whole plot it would draw a bright line
    // along the floor — in the warning colour to the right of the target — and
    // claim programme at loudnesses that had none.
    var firstInked = columns;
    var lastInked = -1;

    for (var i = 0; i < columns; i++) {
      // Every bin whose span overlaps this column's, and the loudest of them.
      //
      // One rule for both directions, which is what keeps the picture free of
      // artefacts. Wider than the bins — the usual case — it draws each bin as
      // the plateau it is. Narrower, which a module 80 pixels wide against 120
      // published bins genuinely is, it takes the **loudest bin in the column**
      // rather than their mean, exactly as the engine takes the loudest bin in
      // a spectrum band and for the same reason: a mean at a coarser resolution
      // hides a spike, and a spike in a loudness distribution is a section of
      // the programme that sat at one level.
      final lowBin = i * MeterShape.histogramBins ~/ columns;
      var highBin =
          ((i + 1) * MeterShape.histogramBins + columns - 1) ~/ columns - 1;
      if (highBin >= MeterShape.histogramBins) {
        highBin = MeterShape.histogramBins - 1;
      }
      if (highBin < lowBin) highBin = lowBin;

      var value = 0.0;
      for (var bin = lowBin; bin <= highBin; bin++) {
        if (bins[bin] > value) value = bins[bin];
      }

      final x = plot.left + (i + 0.5) * _columnWidth;
      final top = plot.bottom - value / tallest * usable;

      fill[i * 4] = x;
      fill[i * 4 + 1] = plot.bottom;
      fill[i * 4 + 2] = x;
      fill[i * 4 + 3] = top;

      edge[i * 2] = x;
      edge[i * 2 + 1] = top;

      if (value > 0) {
        if (i < firstInked) firstInked = i;
        lastInked = i;
      }
    }

    // One column either side of the occupied span, which is empty and therefore
    // on the floor — so the silhouette closes down to the axis at both ends for
    // nothing. Outside that, every point is collapsed onto the nearest end: the
    // segments are zero length, a butt cap draws nothing, and the buffer still
    // goes over whole rather than through a `sublistView` that would allocate
    // once a frame.
    if (lastInked >= 0) {
      final firstEdge = firstInked > 0 ? firstInked - 1 : 0;
      final lastEdge = lastInked < columns - 1 ? lastInked + 1 : columns - 1;
      for (var i = 0; i < firstEdge; i++) {
        edge[i * 2] = edge[firstEdge * 2];
        edge[i * 2 + 1] = edge[firstEdge * 2 + 1];
      }
      for (var i = lastEdge + 1; i < columns; i++) {
        edge[i * 2] = edge[lastEdge * 2];
        edge[i * 2 + 1] = edge[lastEdge * 2 + 1];
      }
    }

    // Quieter than the target on one side, louder on the other, split by a clip
    // rather than by classifying each column. A bin is 0.5 LU wide and a target
    // is a point inside one of them, so the bin the target falls in has no
    // single answer — clipping puts the boundary where the target actually is.
    // What the reader adds up is the *area* to the right of the line: how much
    // of the programme sat above the number it was delivered against.
    void pass(Rect region, Paint fillPaint, Paint edgePaint) {
      if (region.width <= 0) return;
      canvas.save();
      canvas.clipRect(region);
      canvas.drawRawPoints(ui.PointMode.lines, fill, fillPaint);
      canvas.drawRawPoints(ui.PointMode.polygon, edge, edgePaint);
      canvas.restore();
    }

    pass(
      Rect.fromLTRB(plot.left, plot.top, targetX, plot.bottom),
      state._fillUnder!,
      _edgeUnder,
    );
    pass(
      Rect.fromLTRB(targetX, plot.top, plot.right, plot.bottom),
      state._fillOver!,
      _edgeOver,
    );
  }

  /// The gated range, as a dimension line with its reading on it.
  ///
  /// The ends are the 10th and 95th percentiles and the span between them is
  /// LRA, which is why the number is enough to name the marks — and why the
  /// `10%` and `95%` labels that used to sit here are gone. They named the
  /// percentiles without giving the reading, they were the module's only pair of
  /// strings that could collide with each other, and the collision rule that
  /// stopped them was another thing the module had to explain.
  ///
  /// Broken around the number where the span has room for it and unbroken with
  /// the number outside where it has not, which is what any dimension line
  /// does. Nothing is ever dropped: on steady material the two percentiles sit
  /// a fraction of a decibel apart — a correct reading, and the one the old
  /// pair of labels had to give way to — and the bracket becomes a narrow one
  /// with its reading beside it rather than an annotation that vanishes.
  void _paintCaliper(Canvas canvas, Rect plot, double low, double high) {
    final label = state._rangeValue.of(
      '${Metric.loudnessRange.label} '
      '${Metric.loudnessRange.format(engine.loudnessRange)} '
      '${Metric.loudnessRange.unit}',
      OaaType.tick.copyWith(color: colors.textPrimary),
    );

    final left = _x(plot, low);
    final right = _x(plot, high);
    final y = plot.top + label.height / 2;
    final width = label.longestLine;

    double labelLeft;
    if (right - left >= width + Space.sm) {
      // Room between the ends: the number goes inside and the line is broken
      // around it.
      labelLeft = (left + right) / 2 - width / 2;
      if (labelLeft - Space.xs > left) {
        canvas.drawLine(
          Offset(left, y),
          Offset(labelLeft - Space.xs, y),
          _caliper,
        );
      }
      if (right > labelLeft + width + Space.xs) {
        canvas.drawLine(
          Offset(labelLeft + width + Space.xs, y),
          Offset(right, y),
          _caliper,
        );
      }
    } else {
      // Narrower than its own reading, which on steady material it is: the
      // number moves outside the ends and the line runs unbroken between them,
      // the way a dimension line does when the dimension is small. Printed
      // inside, it would have covered both ends and the bracket would have
      // stopped looking like one — and centring it over a two-pixel span puts
      // it back on top of the target line, which is the pile-up this
      // arrangement exists to undo.
      canvas.drawLine(Offset(left, y), Offset(right, y), _caliper);
      labelLeft = right + Space.xs;
      if (labelLeft + width > plot.right) labelLeft = left - Space.xs - width;
      if (labelLeft < plot.left) {
        labelLeft = ((left + right) / 2 - width / 2).clamp(
          plot.left,
          plot.right - width,
        );
      }
    }

    // Serifs at both ends and at both edges of the plot. The pair at the floor
    // is what keeps the range legible against the axis the reader takes LUFS
    // off, where the caliper alone would only mark it at the top.
    for (final x in [left, right]) {
      canvas.drawLine(Offset(x, y), Offset(x, y + _serif), _caliper);
      canvas.drawLine(
        Offset(x, plot.bottom - _serif),
        Offset(x, plot.bottom),
        _caliper,
      );
    }

    canvas.drawParagraph(label, Offset(labelLeft, plot.top));
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
      OaaType.tick.copyWith(color: colors.textMuted),
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
