// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
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
///
/// ---------------------------------------------------------------------------
/// The accumulation is a grid of numbers, not a picture
///
/// This module used to accumulate into an image: draw last frame's picture back
/// at 96.5%, add this frame's dots, keep the result. The image came from
/// `toImageSync`, which holds the display list that drew it for as long as the
/// image lives — so each frame's image pinned the one before it, back to the
/// first, and none of it was ever released. See the header of
/// `spectrogram.dart` for what that cost.
///
/// What the image actually held was one number per cell: how bright this bit of
/// the plot is right now. So that is what is kept — a `Float32List` of
/// [_cell]-sized cells, faded in place on each published frame and splatted
/// into by the bands that are loud enough. The whole grid is then drawn as
/// points sorted into [_alphaSteps] brightness buckets, which is that many draw
/// calls rather than one per cell.
///
/// It costs one pass over the grid per published frame and one to emit it,
/// which is proportional to the module's *area* rather than to how long the
/// session has been running. That is the property the image version did not
/// have.
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

/// How many brightness buckets the accumulated grid is drawn in. Each is one
/// `drawRawPoints` call, so this is also the number of draw calls per frame.
/// Sixteen steps of alpha on a soft cloud are not distinguishable from a
/// continuous ramp.
const int _alphaSteps = 16;

/// The side of an accumulator cell, in logical pixels — and the size of the dot
/// drawn for it, which is the dot size this module has always used. Cells any
/// finer would cost four times the passes to draw the same picture.
const double _cell = 2.0;

class _StereoCloudModuleState extends State<StereoCloudModule> {
  /// Brightness per cell, `0..1`. The picture the module used to keep, as the
  /// numbers it was a picture of.
  Float32List _grid = Float32List(0);
  int _columns = 0;
  int _rows = 0;

  /// The emitted grid, sorted by brightness.
  final _marks = PointBuckets(_alphaSteps);

  /// One [Paint] per brightness bucket.
  List<Paint> _passes = const [];
  Color? _builtFor;
  ui.Paragraph? _left;
  ui.Paragraph? _right;
  ui.Paragraph? _mono;
  List<ui.Paragraph> _frequencyLabels = const [];

  /// Generation 0 is "nothing has been measured yet". The arrays behind a fresh
  /// source are zeroed, which as dB is full scale on every band, at a pan of
  /// dead centre — a bright line down the middle of the cloud that then takes
  /// several seconds to fade, before any audio has arrived.
  int lastGeneration = 0;

  /// Reallocates the grid when the plot changes size, and reports whether it
  /// did. The accumulation is dropped: it is in cells, and the same cell means
  /// a different pan and a different band once the plot has moved under it.
  bool resize(Size plot) {
    final columns = (plot.width / _cell).ceil();
    final rows = (plot.height / _cell).ceil();
    if (columns == _columns && rows == _rows) return false;
    _columns = columns;
    _rows = rows;
    _grid = Float32List(columns * rows);
    return true;
  }

  /// Everything dims by [decay], once per published frame.
  void fade(double decay) {
    for (var cell = 0; cell < _grid.length; cell++) {
      _grid[cell] *= decay;
    }
  }

  /// Adds a dot of [alpha] at ([x], [y]) in cells, spread across the four cells
  /// it lies between.
  ///
  /// The spread is what keeps the cloud smooth. Rounding to the nearest cell
  /// instead would quantise every band's pan to two logical pixels, and a bass
  /// note drifting slowly off centre — the thing this module exists to show —
  /// would move in visible steps rather than sliding.
  void splat(double x, double y, double alpha) {
    final left = x.floor();
    final top = y.floor();
    final fx = x - left;
    final fy = y - top;

    _add(left, top, alpha * (1 - fx) * (1 - fy));
    _add(left + 1, top, alpha * fx * (1 - fy));
    _add(left, top + 1, alpha * (1 - fx) * fy);
    _add(left + 1, top + 1, alpha * fx * fy);
  }

  void _add(int column, int row, double alpha) {
    if (column < 0 || column >= _columns || row < 0 || row >= _rows) return;
    final cell = row * _columns + column;
    final was = _grid[cell];
    // What drawing a dot of this alpha over the cell would have done.
    _grid[cell] = was + alpha * (1 - was);
  }

  /// Sorts every cell that is above one part in 255 — the point below which a
  /// surface cannot show it — into a brightness bucket.
  void emit() {
    _marks.clear();
    for (var row = 0; row < _rows; row++) {
      final base = row * _columns;
      for (var column = 0; column < _columns; column++) {
        final value = _grid[base + column];
        if (value < 1 / 255) continue;
        final bucket = (value * _alphaSteps).ceil().clamp(1, _alphaSteps) - 1;
        _marks.point(bucket, (column + 0.5) * _cell, (row + 0.5) * _cell);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtFor != colors.accent) {
      _builtFor = colors.accent;
      _passes = [
        for (var step = 0; step < _alphaSteps; step++)
          Paint()
            ..color = colors.accent.withValues(alpha: (step + 1) / _alphaSteps)
            // A round, antialiased dot per cell, half again as wide as the
            // cell so that neighbours overlap. Square dots tile the grid
            // exactly and are cheaper, but they turn the cloud into a mosaic;
            // round ones at exactly the cell pitch leave the corners between
            // them dark, which reads as a halftone screen. The shape of the
            // cloud is the whole reading, so it is worth the overlap.
            ..strokeWidth = _cell * 1.5
            ..strokeCap = StrokeCap.round,
      ];

      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _left = layoutParagraph('L', style);
      _right = layoutParagraph('R', style);
      _mono = layoutParagraph(
        'MONO SOURCE',
        OaaType.label.copyWith(color: colors.textMuted),
      );
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
        state: this,
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
    required this.state,
    required Listenable repaint,
  }) : _guide = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _centreGuide = (Paint()
         ..color = colors.hairlineStrong
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final _StereoCloudModuleState state;

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

  static const double _labelStrip = 12;

  @override
  void paint(Canvas canvas, Size size) {
    if (state._passes.isEmpty) return;

    final plot = Size(size.width, size.height - _labelStrip);
    if (plot.height < 40 || plot.width <= 0) return;

    // A one-channel source has no stereo position to plot, and the engine says
    // so the way it says it for `correlation` and `balance`: mono is dead
    // centre. Drawing that is a confident bright line down the middle of the
    // display for every band at once — which is indistinguishable from a broken
    // module, and was reported as one. The fade still runs, so switching to a
    // mono device dissolves the previous cloud rather than freezing it.
    final stereo = engine.channels >= 2;

    var stale = state.resize(plot);

    if (engine.generation != 0 && engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      state.fade(_decay);
      if (stereo && engine.hasSpectrum) _accumulate(plot);
      stale = true;
    }

    if (stale) state.emit();
    state._marks.draw(canvas, ui.PointMode.points, state._passes);

    // --- Guides -------------------------------------------------------------
    // **The frequency axis first, then the centre line over it.** The two are
    // not peers: the horizontals are a scale to read a height against, and the
    // vertical is the fact the module exists to show — where dead centre is.
    // Drawn underneath, it was interrupted at all three crossings by a line
    // dimmer than itself, which reads as a dashed line rather than as a marked
    // centre. Crossing hairlines have to resolve one way or the other, and the
    // one that resolves in front is the one carrying the meaning.
    for (var i = 0; i < _axisHz.length; i++) {
      final y = _y(plot, bandOfHz(_axisHz[i]));
      canvas.drawLine(Offset(0, y), Offset(plot.width, y), _guide);
      canvas.drawParagraph(state._frequencyLabels[i], Offset(Space.xxs, y));
    }

    final centre = plot.width / 2;
    if (stereo) {
      canvas.drawLine(
        Offset(centre, 0),
        Offset(centre, plot.height),
        _centreGuide,
      );
    } else {
      // Broken around the notice below. A hairline through the middle of a
      // word reads as a strikethrough, which is the opposite of what the
      // notice says.
      final gap = state._mono!.height / 2 + Space.xs;
      canvas.drawLine(
        Offset(centre, 0),
        Offset(centre, plot.height / 2 - gap),
        _centreGuide,
      );
      canvas.drawLine(
        Offset(centre, plot.height / 2 + gap),
        Offset(centre, plot.height),
        _centreGuide,
      );
    }

    final left = state._left!;
    final right = state._right!;
    canvas.drawParagraph(left, Offset(0, plot.height + Space.xxs));
    canvas.drawParagraph(
      right,
      Offset(size.width - right.longestLine, plot.height + Space.xxs),
    );

    if (!stereo) {
      // The axis stays drawn beneath it. The module is not unavailable — it is
      // showing everything a mono signal has, which is why it names the reason
      // rather than blanking the face.
      final mono = state._mono!;
      canvas.drawParagraph(
        mono,
        Offset(
          (plot.width - mono.longestLine) / 2,
          (plot.height - mono.height) / 2,
        ),
      );
    }
  }

  /// Splats this frame's bands into the grid.
  void _accumulate(Size plot) {
    for (var band = 0; band < MeterShape.spectrumBands; band++) {
      final db = engine.spectrum[band];
      if (db <= _floorDb) continue;

      final loudness = ((db - _floorDb) / (_ceilingDb - _floorDb)).clamp(
        0.0,
        1.0,
      );
      final pan = engine.spectrumPan[band].clamp(-1.0, 1.0);

      state.splat(
        plot.width / 2 * (1 + pan) / _cell,
        _y(plot, band.toDouble()) / _cell,
        // The alpha this band's dot was drawn at before there was a grid.
        0.12 + 0.88 * loudness,
      );
    }
  }

  /// Low frequencies at the bottom, as on the analyser.
  double _y(Size plot, double band) =>
      plot.height * (1 - band / MeterShape.spectrumBands);

  @override
  bool shouldRepaint(_StereoCloudPainter oldDelegate) =>
      oldDelegate.colors != colors || !identical(oldDelegate.engine, engine);
}
