// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

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
class SpectrumAnalyzerModule extends StatefulWidget {
  const SpectrumAnalyzerModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final BelEngine engine;
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

/// And the few that get a label. Labelling all thirteen turns the graticule
/// into text.
const _labelledHz = <double>[100, 1000, 10000];

class _SpectrumAnalyzerModuleState extends State<SpectrumAnalyzerModule> {
  static const _scale = MeterScale(min: -96, max: 0, step: 12);

  /// x, yBottom, x, yTop per band.
  final Float32List _bars = Float32List(kBelSpectrumBands * 4);

  /// x, y per band, for the peak-hold polyline.
  final Float32List _hold = Float32List(kBelSpectrumBands * 2);

  ScaleGraticule? _graticule;
  List<ui.Paragraph> _gridLabels = const [];

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
      _gridLabels = [
        for (final hz in _gridHz)
          layoutParagraph(
            _labelledHz.contains(hz)
                ? (hz >= 1000 ? '${(hz / 1000).round()}k' : '${hz.round()}')
                : '',
            style,
          ),
      ];
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
  }) : _fill = (Paint()
         ..color = colors.meterFill
         ..strokeCap = StrokeCap.butt),
       _hold = (Paint()
         ..color = colors.accent
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.hairline),
       _grid = (Paint()
         ..color = colors.hairline
         ..strokeWidth = BelStroke.hairline
         ..isAntiAlias = false),
       super(repaint: repaint);

  final BelEngine engine;
  final BelColors colors;
  final ScaleGraticule graticule;
  final _SpectrumAnalyzerModuleState state;

  final Paint _fill;
  final Paint _hold;
  final Paint _grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 120 || size.height < 60) return;

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
    for (var i = 0; i < _gridHz.length; i++) {
      final x =
          plot.left + bandOfHz(_gridHz[i]) / kBelSpectrumBands * plot.width;
      if (x < plot.left || x > plot.right) continue;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _grid);

      final label = state._gridLabels[i];
      if (label.longestLine > 0) {
        canvas.drawParagraph(
          label,
          Offset(x - label.longestLine / 2, plot.bottom + Space.xxs),
        );
      }
    }

    if (!engine.hasSpectrum) return;

    // --- Bands --------------------------------------------------------------
    final bandWidth = plot.width / kBelSpectrumBands;
    _fill.strokeWidth = bandWidth;

    for (var band = 0; band < kBelSpectrumBands; band++) {
      final x = plot.left + (band + 0.5) * bandWidth;
      final y = _y(plot, engine.spectrum[band]);

      state._bars[band * 4] = x;
      state._bars[band * 4 + 1] = plot.bottom;
      state._bars[band * 4 + 2] = x;
      state._bars[band * 4 + 3] = y;

      state._hold[band * 2] = x;
      state._hold[band * 2 + 1] = _y(plot, engine.spectrumPeak[band]);
    }

    canvas.save();
    canvas.clipRect(plot);
    canvas.drawRawPoints(ui.PointMode.lines, state._bars, _fill);
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
