// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Level against frequency, log-spaced, with a peak hold.
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
/// The band area is a vertical gradient — bright along the curve, fading to
/// almost nothing at the floor — which is what stops a spectrum reading as a
/// solid block of paint and lets the shape of the top edge carry the
/// information. That would normally want a filled `Path` with a gradient, and
/// the paragraph above is the reason it cannot have one.
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
class SpectrumAnalyzerModule extends StatefulWidget {
  const SpectrumAnalyzerModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  @override
  State<SpectrumAnalyzerModule> createState() => _SpectrumAnalyzerModuleState();
}

/// The decade lines a frequency axis is read against.
const _gridHz = <double>[
  20,
  30,
  50,
  100,
  200,
  300,
  500,
  1000,
  2000,
  3000,
  5000,
  10000,
  20000,
];

/// And the ones that get a label, at each of two widths.
///
/// Labelling all thirteen turns the graticule into text, and three of them on a
/// wide analyser leaves the reader counting gridlines to find 200 Hz. Which set
/// is drawn depends on whether the labels fit with a gap between them, measured
/// rather than guessed — see `_labelStride`.
const _labelledHz = <double>[20, 50, 100, 200, 500, 1000, 2000, 5000, 10000];
const _labelledHzNarrow = <double>[100, 1000, 10000];

class _SpectrumAnalyzerModuleState extends State<SpectrumAnalyzerModule> {
  static const _scale = MeterScale(min: -96, max: 0, step: 12);

  /// x, yBottom, x, yTop per band.
  final Float32List _bars = Float32List(kBelSpectrumBands * 4);

  /// x, y per band, for the peak-hold polyline.
  final Float32List _hold = Float32List(kBelSpectrumBands * 2);

  /// x, y per band, for the curve stroked along the top of the fill.
  final Float32List _curve = Float32List(kBelSpectrumBands * 2);

  ScaleGraticule? _graticule;

  /// A paragraph per gridline, laid out at both label densities. Both sets are
  /// built here rather than at paint time because laying out a paragraph on the
  /// frame path is the thing the frame path most wants not to do.
  List<ui.Paragraph> _gridLabels = const [];
  List<ui.Paragraph> _gridLabelsNarrow = const [];

  /// The band fill's vertical gradient, and the plot it was built for. Rebuilt
  /// on a resize or a skin change and at no other time.
  ui.Shader? _fillShader;
  Rect? _shaderPlot;
  Color? _shaderColor;

  ui.Shader fillShader(Rect plot, Color accent) {
    if (_fillShader == null || _shaderPlot != plot || _shaderColor != accent) {
      _fillShader = ui.Gradient.linear(
        plot.topCenter,
        plot.bottomCenter,
        <Color>[accent.withValues(alpha: 0.66), accent.withValues(alpha: 0.14)],
      );
      _shaderPlot = plot;
      _shaderColor = accent;
    }
    return _fillShader!;
  }

  @override
  void dispose() {
    _graticule?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_graticule == null ||
        !_graticule!.matches(_scale, ScaleSide.right, colors.textFaint)) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.right,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );

      final style = BelType.tick.copyWith(color: colors.textFaint);
      List<ui.Paragraph> labels(List<double> labelled) => [
        for (final hz in _gridHz)
          layoutParagraph(
            labelled.contains(hz)
                ? (hz >= 1000 ? '${(hz / 1000).round()}k' : '${hz.round()}')
                : '',
            style,
          ),
      ];
      _gridLabels = labels(_labelledHz);
      _gridLabelsNarrow = labels(_labelledHzNarrow);
    }

    return MeterBody(
      painter: _SpectrumPainter(
        engine: widget.engine,
        colors: colors,
        graticule: _graticule!,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _SpectrumPainter extends MeterPainter {
  _SpectrumPainter({
    required this.engine,
    required this.colors,
    required this.graticule,
    required this.state,
    required Listenable repaint,
  }) : _fill = (Paint()..strokeCap = StrokeCap.butt),
       _curve = (Paint()
         ..color = colors.accent
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.mark),
       // Dimmer than the curve on purpose. The hold is where the signal *has*
       // been and the curve is where it is now; drawn at the same weight, the
       // eye reads the upper line as the measurement.
       _hold = (Paint()
         ..color = colors.accent.withValues(alpha: 0.45)
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.hairline),
       _grid = (Paint()
         ..color = colors.hairline
         ..strokeWidth = BelStroke.hairline
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final BelColors colors;
  final ScaleGraticule graticule;
  final _SpectrumAnalyzerModuleState state;

  final Paint _fill;
  final Paint _curve;
  final Paint _hold;
  final Paint _grid;

  /// Labels are drawn at the wider density only when the widest of them fits
  /// into the narrowest gap between two labelled gridlines with a clear space
  /// beside it. The gap that decides it is 20→50 Hz, which is the tightest pair
  /// on a log axis that starts at 20.
  List<ui.Paragraph> _labelsFor(Rect plot) {
    final wide = state._gridLabels;
    var widest = 0.0;
    for (final label in wide) {
      if (label.longestLine > widest) widest = label.longestLine;
    }
    final gap = (bandOfHz(50) - bandOfHz(20)) / kBelSpectrumBands * plot.width;
    return gap > widest + Space.sm ? wide : state._gridLabelsNarrow;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final labelHeight = BelType.tick.fontSize! + Space.xs;
    final plot = Rect.fromLTRB(
      0,
      0,
      size.width - graticule.gutter,
      size.height - labelHeight,
    );
    if (plot.width < 60 || plot.height < 32) return;

    graticule.paint(canvas, plot);

    // --- Frequency graticule ------------------------------------------------
    final labels = _labelsFor(plot);
    for (var i = 0; i < _gridHz.length; i++) {
      final x =
          plot.left + bandOfHz(_gridHz[i]) / kBelSpectrumBands * plot.width;
      if (x < plot.left || x > plot.right) continue;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _grid);

      final label = labels[i];
      if (label.longestLine > 0) {
        // Nudged inside the plot rather than centred on the line, because the
        // first gridline *is* the left edge: 20 Hz is band zero. Centred, half
        // of "20" is drawn off the module and the axis appears to start at 50.
        final room = plot.right - label.longestLine;
        final left = room <= plot.left
            ? plot.left
            : (x - label.longestLine / 2).clamp(plot.left, room);
        canvas.drawParagraph(label, Offset(left, plot.bottom + Space.xxs));
      }
    }

    if (!engine.hasSpectrum) return;

    // --- Bands --------------------------------------------------------------
    // The bands are drawn a half-band wider than they are spaced. Butt caps on
    // a stroke exactly one band wide leave a seam of background between
    // neighbours wherever the band centre lands mid-pixel, and five hundred
    // hairline seams read as vertical banding across the whole fill.
    final bandWidth = plot.width / kBelSpectrumBands;
    _fill.strokeWidth = bandWidth + 0.5;
    _fill.shader = state.fillShader(plot, colors.accent);

    for (var band = 0; band < kBelSpectrumBands; band++) {
      final x = plot.left + (band + 0.5) * bandWidth;
      final y = _y(plot, engine.spectrum[band]);

      state._bars[band * 4] = x;
      state._bars[band * 4 + 1] = plot.bottom;
      state._bars[band * 4 + 2] = x;
      state._bars[band * 4 + 3] = y;

      state._curve[band * 2] = x;
      state._curve[band * 2 + 1] = y;

      state._hold[band * 2] = x;
      state._hold[band * 2 + 1] = _y(plot, engine.spectrumPeak[band]);
    }

    canvas.save();
    canvas.clipRect(plot);
    canvas.drawRawPoints(ui.PointMode.lines, state._bars, _fill);
    canvas.drawRawPoints(ui.PointMode.polygon, state._curve, _curve);
    canvas.drawRawPoints(ui.PointMode.polygon, state._hold, _hold);
    canvas.restore();
  }

  double _y(Rect plot, double db) =>
      plot.bottom - graticule.scale.fractionOf(db) * plot.height;

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
