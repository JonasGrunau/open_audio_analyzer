// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
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
    this.response = SpectrumResponse.normal,
    this.hold = SpectrumHold.peaks,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// How fast the curve follows what the engine publishes. See
  /// [SpectrumResponse] for why this is a time constant and not a frame rate.
  final SpectrumResponse response;

  /// What the line above the curve is a hold of. See [SpectrumHold].
  final SpectrumHold hold;

  @override
  State<SpectrumAnalyzerModule> createState() => _SpectrumAnalyzerModuleState();
}

/// How long a band sits at its maximum before the drawn hold lets it down, and
/// how fast it falls after.
///
/// The same numbers as `OAA_SPECTRUM_HOLD_SECONDS` and
/// `OAA_SPECTRUM_FALL_DB_PER_SECOND` in `engine/src/oaa_spectrum.h`, restated
/// because that header is on the far side of an ABI this module never links —
/// the tablet runs this file with no engine at all. They are only used by
/// [SpectrumHold.envelope], and they are the engine's on purpose: the setting
/// changes what is held, not how a hold behaves. Move one and move the other.
const double _holdSeconds = 1.5;
const double _fallDbPerSecond = 12;

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
  final Float32List _bars = Float32List(kOaaSpectrumBands * 4);

  /// x, y per band, for the peak-hold polyline.
  final Float32List _hold = Float32List(kOaaSpectrumBands * 2);

  /// x, y per band, for the curve stroked along the top of the fill.
  final Float32List _curve = Float32List(kOaaSpectrumBands * 2);

  /// The level actually drawn, per band, in dB.
  ///
  /// One pole per band, folded once per published frame — see [_advance]. On
  /// [SpectrumResponse.fast] it holds a copy of what the engine published and
  /// the arithmetic below collapses to an assignment.
  final Float32List _shown = Float32List(kOaaSpectrumBands);

  /// The peak hold actually drawn, per band, in dB.
  ///
  /// Folded through the same pole as [_shown] whatever [SpectrumHold] says, and
  /// that is the half of the mismatch that was never a matter of taste. The
  /// engine's hold jumps to a new peak the instant one lands; the curve under
  /// it eases over the response's time constant — so on Slow the line above a
  /// calm shape flicked about as if it belonged to a different plot. One pole
  /// on both and they move together.
  ///
  /// What the pole is applied *to* is the setting. See [_holdSeconds] for the
  /// second source, and [SpectrumHold] for what each costs.
  final Float32List _shownHold = Float32List(kOaaSpectrumBands);

  /// Seconds left at the top, per band, for [SpectrumHold.envelope].
  ///
  /// Only that mode keeps a hold of its own; the other reads one the engine
  /// already keeps, on audio this side never sees.
  final Float32List _holdLeft = Float32List(kOaaSpectrumBands);

  /// The mode [_shownHold] currently holds, so a change of setting starts the
  /// new one from the signal rather than easing across from the old one's
  /// answer — which would be a line drifting between two definitions.
  SpectrumHold? _heldMode;

  /// The generation [_shown] and [_shownHold] were last folded for, and the
  /// engine time they were folded at.
  ///
  /// **Zero is a real generation to have never seen**, so this starts at −1: an
  /// engine that has published exactly once and then stopped — a file being
  /// analysed, a device that dropped — must still get its one frame folded in.
  int _seenGeneration = -1;
  double _seenElapsed = 0;

  /// Folds one published frame into [_shown].
  ///
  /// **Called on a change of generation, never on a paint.** Paint also runs on
  /// a resize, a skin change and a selection, and an average that advanced on
  /// those would settle further every time the window moved — time passing that
  /// no audio passed through, which is the same defect the spectrogram's
  /// scrolling has and is just as convincing to look at.
  ///
  /// The coefficient is derived from *engine* time rather than counted in
  /// frames, so the setting means the same thing at every refresh rate: at
  /// 30 fps the clock reads fewer of the engine's ~47 published frames per
  /// second than at 120, and a fixed per-fold coefficient would make Normal
  /// slower on a laptop than on a workstation.
  void _advance(MeterSource engine, double tau, SpectrumHold mode) {
    final elapsed = engine.elapsedSeconds;
    final dt = elapsed - _seenElapsed;
    _seenElapsed = elapsed;

    // A reset takes the clock back to zero, and a first frame has nothing to
    // average against. Snap rather than fade in from whatever was on screen —
    // a curve rising slowly out of the floor after a reset is a picture of a
    // programme that did not happen.
    final snap = tau <= 0 || dt <= 0 || _seenGeneration < 0;
    final alpha = snap ? 1.0 : 1 - math.exp(-dt / tau);
    final reseat = snap || _heldMode != mode;
    _heldMode = mode;

    final spectrum = engine.spectrum;
    final peaks = engine.spectrumPeak;
    final step = dt > 0 ? dt : 0.0;

    for (var band = 0; band < kOaaSpectrumBands; band++) {
      final level = snap
          ? spectrum[band]
          : _shown[band] + (spectrum[band] - _shown[band]) * alpha;
      _shown[band] = level;

      // The band the hold is taken over. `peaks` is the engine's, measured on
      // every hop; `envelope` is the highest the curve above has been, held and
      // then let down at the same rate the engine's is so the two modes are the
      // same picture of different data.
      final double source;
      if (mode == SpectrumHold.peaks) {
        source = peaks[band];
      } else {
        var held = reseat ? level : _shownHold[band];
        if (level >= held) {
          held = level;
          _holdLeft[band] = _holdSeconds;
        } else if (_holdLeft[band] > 0) {
          _holdLeft[band] -= step;
        } else {
          held -= _fallDbPerSecond * step;
          if (held < level) held = level;
        }
        source = held;
      }

      _shownHold[band] = reseat
          ? source
          : _shownHold[band] + (source - _shownHold[band]) * alpha;
    }
  }

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
    final colors = OaaTheme.of(context);

    if (_graticule == null ||
        !_graticule!.matches(_scale, ScaleSide.right, colors.textFaint)) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.right,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );

      final style = OaaType.tick.copyWith(color: colors.textFaint);
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
        response: widget.response,
        hold: widget.hold,
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
    required this.response,
    required this.hold,
    required this.state,
    required Listenable repaint,
  }) : _fill = (Paint()..strokeCap = StrokeCap.butt),
       _curve = (Paint()
         ..color = colors.accent
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.mark),
       // Dimmer than the curve on purpose. The hold is where the signal *has*
       // been and the curve is where it is now; drawn at the same weight, the
       // eye reads the upper line as the measurement.
       _hold = (Paint()
         ..color = colors.accent.withValues(alpha: 0.45)
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.hairline),
       _grid = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final ScaleGraticule graticule;
  final SpectrumResponse response;
  final SpectrumHold hold;
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
    final gap = (bandOfHz(50) - bandOfHz(20)) / kOaaSpectrumBands * plot.width;
    return gap > widest + Space.sm ? wide : state._gridLabelsNarrow;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final labelHeight = OaaType.tick.fontSize! + Space.xs;
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
          plot.left + bandOfHz(_gridHz[i]) / kOaaSpectrumBands * plot.width;
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

    if (engine.generation != state._seenGeneration || state._heldMode != hold) {
      state._advance(engine, response.timeConstant, hold);
      state._seenGeneration = engine.generation;
    }

    // --- Bands --------------------------------------------------------------
    // The bands are drawn a half-band wider than they are spaced. Butt caps on
    // a stroke exactly one band wide leave a seam of background between
    // neighbours wherever the band centre lands mid-pixel, and five hundred
    // hairline seams read as vertical banding across the whole fill.
    final bandWidth = plot.width / kOaaSpectrumBands;
    _fill.strokeWidth = bandWidth + 0.5;
    _fill.shader = state.fillShader(plot, colors.accent);

    for (var band = 0; band < kOaaSpectrumBands; band++) {
      final x = plot.left + (band + 0.5) * bandWidth;
      final y = _y(plot, state._shown[band]);

      state._bars[band * 4] = x;
      state._bars[band * 4 + 1] = plot.bottom;
      state._bars[band * 4 + 2] = x;
      state._bars[band * 4 + 3] = y;

      state._curve[band * 2] = x;
      state._curve[band * 2 + 1] = y;

      state._hold[band * 2] = x;
      state._hold[band * 2 + 1] = _y(plot, state._shownHold[band]);
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
      oldDelegate.response != response ||
      oldDelegate.hold != hold ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
