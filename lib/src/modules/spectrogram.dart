// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Frequency against time, with level as brightness.
///
/// The same bands the analyser draws, one column per published measurement,
/// scrolling left. Frequency runs up the display because that is the axis the
/// analyser uses and two modules on one tab disagreeing about which way is up
/// would be worse than either choice.
///
/// ---------------------------------------------------------------------------
/// Why it scrolls the picture rather than redrawing the history
///
/// A minute of spectrogram is about three thousand columns. Keeping those as
/// data and re-drawing them each frame is three thousand columns of work to add
/// one, and it gets linearly worse the longer the session runs — the display
/// would visibly slow down over an afternoon. Instead the previous frame's
/// image is blitted back one column to the left and only the new column is
/// drawn. Cost is constant, and it is a GPU-side copy with no readback.
///
/// The column itself is drawn as **runs of equal colour**. A 300 px column is
/// 300 pixel rows, but a spectrogram is smooth: neighbouring rows usually land
/// in the same one of 48 brightness steps, so the run-length pass turns three
/// hundred rectangles into twenty or thirty. The palette is built once, as
/// [Paint]s, so nothing allocates while painting.
class SpectrogramModule extends StatefulWidget {
  const SpectrogramModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final BelEngine engine;
  final MeterClock clock;

  @override
  State<SpectrogramModule> createState() => _SpectrogramModuleState();
}

class _SpectrogramModuleState extends State<SpectrogramModule> {
  final _history = PersistenceLayer();

  /// One [Paint] per brightness step. Fine enough that the steps are invisible,
  /// coarse enough that the run-length pass has something to coalesce.
  List<Paint> _palette = const [];
  Color? _builtFor;

  int lastGeneration = -1;

  @override
  void dispose() {
    _history.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_builtFor != colors.accent) {
      _builtFor = colors.accent;
      _palette = [
        for (var step = 0; step < _steps; step++)
          Paint()..color = _rampColor(step / (_steps - 1), colors),
      ];
    }

    return MeterBody(
      painter: _SpectrogramPainter(
        engine: widget.engine,
        colors: colors,
        history: _history,
        state: this,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        repaint: widget.clock,
      ),
    );
  }
}

const int _steps = 48;

/// Background to accent to warn, in that order.
///
/// Deliberately not a rainbow. A hue ramp reads as more precise than it is —
/// the eye finds edges between hues that are not edges in the data — and it
/// stops working entirely for the eight percent of men who cannot separate red
/// from green. Brightness within the palette's own colours is monotonic, which
/// is the property that makes a spectrogram legible.
Color _rampColor(double level, BelColors colors) {
  if (level < 0.55) {
    return Color.lerp(colors.panel, colors.accent, level / 0.55)!;
  }
  return Color.lerp(colors.accent, colors.warn, (level - 0.55) / 0.45)!;
}

class _SpectrogramPainter extends MeterPainter {
  _SpectrogramPainter({
    required this.engine,
    required this.colors,
    required this.history,
    required this.state,
    required this.devicePixelRatio,
    required Listenable repaint,
  }) : _blit = Paint(),
       _background = (Paint()..color = colors.panel),
       super(repaint: repaint);

  final BelEngine engine;
  final BelColors colors;
  final PersistenceLayer history;
  final _SpectrogramModuleState state;
  final double devicePixelRatio;

  final Paint _blit;
  final Paint _background;

  /// One published measurement is one column. At ~47 Hz that is about 21 ms of
  /// audio per column, so a 600 px module holds roughly thirteen seconds.
  static const double _columnWidth = 1;

  /// The level range mapped onto the palette. Below the floor is background;
  /// a spectrogram scaled to the full 96 dB the analyser shows would be almost
  /// entirely dark.
  static const double _floorDb = -84;
  static const double _ceilingDb = -6;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 80 || size.height < 40 || state._palette.isEmpty) return;

    if (engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;

      history.update(size, devicePixelRatio, (layer, previous) {
        if (previous == null) {
          layer.drawRect(Offset.zero & size, _background);
        } else {
          history.replay(
            layer,
            previous,
            size,
            _blit,
            offset: const Offset(-_columnWidth, 0),
          );
        }
        if (engine.hasSpectrum) {
          _column(layer, size);
        }
      });
    }

    history.paint(canvas, size, _blit);
  }

  /// Draws the newest column at the right edge, as runs of equal colour.
  void _column(Canvas layer, Size size) {
    final rows = size.height.ceil();
    if (rows <= 0) return;

    final left = size.width - _columnWidth;
    final rowHeight = size.height / rows;

    var runStart = 0;
    var runStep = _stepAt(0, rows);

    for (var row = 1; row <= rows; row++) {
      final step = row < rows ? _stepAt(row, rows) : -1;
      if (step == runStep) continue;

      if (runStep > 0) {
        layer.drawRect(
          Rect.fromLTWH(
            left,
            runStart * rowHeight,
            _columnWidth,
            (row - runStart) * rowHeight,
          ),
          state._palette[runStep],
        );
      }
      runStart = row;
      runStep = step;
    }
  }

  /// The palette step for a pixel row. Row 0 is the top of the display, which
  /// is the top of the frequency range.
  int _stepAt(int row, int rows) {
    final band = ((rows - 1 - row) / (rows - 1) * (kBelSpectrumBands - 1))
        .round()
        .clamp(0, kBelSpectrumBands - 1);
    final db = engine.spectrum[band];
    if (db <= _floorDb) return 0;
    final level = ((db - _floorDb) / (_ceilingDb - _floorDb)).clamp(0.0, 1.0);
    return (level * (_steps - 1)).round();
  }

  @override
  bool shouldRepaint(_SpectrogramPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.devicePixelRatio != devicePixelRatio ||
      !identical(oldDelegate.engine, engine);
}
