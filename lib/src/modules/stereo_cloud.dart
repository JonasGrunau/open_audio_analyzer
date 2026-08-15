// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Where each frequency sits in the stereo image, accumulated over time.
///
/// The phase scope answers "is this mix mono-compatible" in the time domain and
/// cannot tell you *which part* of it is not. This module is the same question
/// asked per band: horizontal is stereo position, vertical is frequency, and a
/// bass note that has drifted off centre or a cymbal pinned hard right shows up
/// as a shape in a place, which is the thing you can act on.
///
/// It accumulates rather than showing an instant, and that is the module. A
/// single frame of per-band pan is noise — the pan of a band between notes is
/// whatever leaked into it. Over a few seconds the persistent parts of the
/// image emerge from the noise and the transient parts fade, which is exactly
/// the distinction a mix engineer is trying to make.
class StereoCloudModule extends StatefulWidget {
  const StereoCloudModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  @override
  State<StereoCloudModule> createState() => _StereoCloudModuleState();
}

/// How many brightness passes the bands are sorted into. Each is one
/// `drawRawPoints` call, so this is also the number of draw calls per frame.
const int _levels = 5;

class _StereoCloudModuleState extends State<StereoCloudModule> {
  final _cloud = PersistenceLayer();

  /// One buffer, refilled and drawn once per brightness pass. Sized for the
  /// worst case of every band landing in the same pass.
  final Float32List _points = Float32List(kBelSpectrumBands * 2);

  List<Paint> _passes = const [];
  Color? _builtFor;
  ui.Paragraph? _left;
  ui.Paragraph? _right;
  List<ui.Paragraph> _frequencyLabels = const [];

  int lastGeneration = -1;

  @override
  void dispose() {
    _cloud.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_builtFor != colors.accent) {
      _builtFor = colors.accent;
      _passes = [
        for (var level = 0; level < _levels; level++)
          Paint()
            ..color = colors.accent.withValues(
              alpha: 0.12 + 0.88 * (level / (_levels - 1)),
            )
            ..strokeCap = StrokeCap.round,
      ];

      final style = BelType.tick.copyWith(color: colors.textFaint);
      _left = layoutParagraph('L', style);
      _right = layoutParagraph('R', style);
      _frequencyLabels = [
        for (final hz in _axisHz)
          layoutParagraph(
            hz >= 1000 ? '${(hz / 1000).round()}k' : '${hz.round()}',
            style,
          ),
      ];
    }

    return MeterBody(
      painter: _StereoCloudPainter(
        engine: widget.engine,
        colors: colors,
        cloud: _cloud,
        state: this,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        repaint: widget.clock,
      ),
    );
  }
}

const _axisHz = <double>[100, 1000, 10000];

class _StereoCloudPainter extends MeterPainter {
  _StereoCloudPainter({
    required this.engine,
    required this.colors,
    required this.cloud,
    required this.state,
    required this.devicePixelRatio,
    required Listenable repaint,
  }) : _fade = (Paint()
         ..color = const Color(0xFFFFFFFF).withValues(alpha: _decay)),
       _blit = Paint(),
       _guide = (Paint()
         ..color = colors.hairline
         ..strokeWidth = BelStroke.hairline
         ..isAntiAlias = false),
       _centreGuide = (Paint()
         ..color = colors.hairlineStrong
         ..strokeWidth = BelStroke.hairline
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final BelColors colors;
  final PersistenceLayer cloud;
  final _StereoCloudModuleState state;
  final double devicePixelRatio;

  final Paint _fade;
  final Paint _blit;
  final Paint _guide;
  final Paint _centreGuide;

  /// Slower than the phase scope's: this display is about what is *persistent*
  /// in the image, so it wants a few seconds of memory rather than a fraction
  /// of one.
  static const double _decay = 0.965;

  /// Bands quieter than this contribute nothing. Their pan is the pan of
  /// whatever leaked into an empty band, which is a direction with no signal
  /// behind it — see the note on `spectrumPan` in the engine.
  static const double _floorDb = -78;
  static const double _ceilingDb = -12;

  static const double _pointSize = 2.0;
  static const double _labelStrip = 12;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 80 || size.height < 60 || state._passes.isEmpty) return;

    final plot = Size(size.width, size.height - _labelStrip);
    if (plot.height < 40) return;

    if (engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      cloud.update(plot, devicePixelRatio, (layer, previous) {
        cloud.replay(layer, previous, plot, _fade);
        if (engine.hasSpectrum) _plot(layer, plot);
      });
    }

    cloud.paint(canvas, plot, _blit);

    // --- Guides -------------------------------------------------------------
    canvas.drawLine(
      Offset(plot.width / 2, 0),
      Offset(plot.width / 2, plot.height),
      _centreGuide,
    );
    for (var i = 0; i < _axisHz.length; i++) {
      final y = _y(plot, bandOfHz(_axisHz[i]));
      canvas.drawLine(Offset(0, y), Offset(plot.width, y), _guide);
      canvas.drawParagraph(state._frequencyLabels[i], Offset(Space.xxs, y));
    }

    final left = state._left!;
    final right = state._right!;
    canvas.drawParagraph(left, Offset(0, plot.height + Space.xxs));
    canvas.drawParagraph(
      right,
      Offset(size.width - right.longestLine, plot.height + Space.xxs),
    );
  }

  /// One pass per brightness level, each a single call.
  ///
  /// Sorting into passes rather than drawing points one at a time is what keeps
  /// this to five draw calls instead of five hundred, and `drawRawPoints` takes
  /// exactly one colour — so brightness has to *be* the grouping.
  void _plot(Canvas layer, Size plot) {
    for (var level = 0; level < _levels; level++) {
      var written = 0;

      for (var band = 0; band < kBelSpectrumBands; band++) {
        final db = engine.spectrum[band];
        if (db <= _floorDb) continue;

        final loudness = ((db - _floorDb) / (_ceilingDb - _floorDb)).clamp(
          0.0,
          1.0,
        );
        if ((loudness * (_levels - 1)).round() != level) continue;

        final pan = engine.spectrumPan[band].clamp(-1.0, 1.0);
        state._points[written++] = plot.width / 2 * (1 + pan);
        state._points[written++] = _y(plot, band.toDouble());
      }

      if (written == 0) continue;
      final paint = state._passes[level]..strokeWidth = _pointSize;
      layer.drawRawPoints(
        ui.PointMode.points,
        // A view, not a copy — and the only allocation in this module's frame,
        // which buys skipping the bands that are not in this pass.
        Float32List.sublistView(state._points, 0, written),
        paint,
      );
    }
  }

  /// Low frequencies at the bottom, as on the analyser.
  double _y(Size plot, double band) =>
      plot.height * (1 - band / kBelSpectrumBands);

  @override
  bool shouldRepaint(_StereoCloudPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.devicePixelRatio != devicePixelRatio ||
      !identical(oldDelegate.engine, engine);
}
