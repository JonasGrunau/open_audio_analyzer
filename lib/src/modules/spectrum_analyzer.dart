// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Level against frequency, log-spaced, tilted, with a peak hold.
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
    this.tilt = SpectrumTilt.db4p5,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// How fast the curve follows what the engine publishes. See
  /// [SpectrumResponse] for why this is a time constant and not a frame rate.
  final SpectrumResponse response;

  /// How far the drawn curve is rotated, per octave about 1 kHz. See
  /// [SpectrumTilt] — it moves the picture and nothing else.
  final SpectrumTilt tilt;

  @override
  State<SpectrumAnalyzerModule> createState() => _SpectrumAnalyzerModuleState();
}

/// How long a band sits at its maximum before the drawn hold lets it down, and
/// how fast it falls after.
///
/// The same numbers as `OAA_SPECTRUM_HOLD_SECONDS` and
/// `OAA_SPECTRUM_FALL_DB_PER_SECOND` in `engine/src/oaa_spectrum.h`, restated
/// because that header is on the far side of an ABI this module never links —
/// the tablet runs this file with no engine at all. The engine holds the raw
/// bands on the same schedule this file holds the drawn ones, so a hold reads
/// the same whichever side of the wire is doing it. Move one and move the
/// other.
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
  final Float32List _bars = Float32List(MeterShape.spectrumBands * 4);

  /// x, y per band, for the peak-hold polyline.
  final Float32List _hold = Float32List(MeterShape.spectrumBands * 2);

  /// x, y per band, for the curve stroked along the top of the fill.
  final Float32List _curve = Float32List(MeterShape.spectrumBands * 2);

  /// The level actually drawn, per band, in dB.
  ///
  /// One pole per band, folded once per published frame — see [_advance]. On
  /// [SpectrumResponse.fast] it holds a copy of what the engine published and
  /// the arithmetic below collapses to an assignment.
  final Float32List _shown = Float32List(MeterShape.spectrumBands);

  /// The peak hold actually drawn, per band, in dB.
  ///
  /// The envelope of [_shown]: the highest the *drawn* curve has been, held for
  /// [_holdSeconds] and then let down at [_fallDbPerSecond], and folded through
  /// the same pole as the curve so the two move together. The engine's own hold
  /// over the raw bands — `spectrumPeak` — is a truer maximum, and it is the
  /// wrong line to draw here: it jumps to a new peak the instant one lands
  /// while the curve under it eases over the response's time constant, so on
  /// Slow the line above a calm shape flicked about as if it belonged to a
  /// different plot. A hold of the curve is a hold of what the reader can see.
  ///
  /// The cost is stated rather than hidden: on a slow response this sits below
  /// a peak the programme really reached, because the curve it is holding never
  /// went there. [SpectrumResponse.fast] is the setting that catches one.
  final Float32List _shownHold = Float32List(MeterShape.spectrumBands);

  /// Seconds left at the top, per band, before the hold starts falling.
  final Float32List _holdLeft = Float32List(MeterShape.spectrumBands);

  /// The offset the tilt adds to each band's drawn level, in dB.
  ///
  /// Built once per change of setting rather than per frame: the offsets are
  /// 512 logarithms, and the frame path does not take a logarithm per band for
  /// something that only moves when somebody picks a menu item. Held here
  /// rather than in the painter, which is rebuilt on every skin change and
  /// every selection.
  final Float32List _tiltDb = Float32List(MeterShape.spectrumBands);
  SpectrumTilt? _tiltFor;

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
  void _advance(MeterSource engine, double tau) {
    final elapsed = engine.elapsedSeconds;
    final dt = elapsed - _seenElapsed;
    _seenElapsed = elapsed;

    // A reset takes the clock back to zero, and a first frame has nothing to
    // average against. Reseat rather than fade in from whatever was on screen —
    // a curve rising slowly out of the floor after a reset is a picture of a
    // programme that did not happen — and reseat the *hold* with it, because a
    // hold carried across a discontinuity is a maximum of two different
    // programmes.
    //
    // `!(dt > 0)` rather than `dt <= 0`, so that a NaN takes this branch too. A
    // source whose link has gone quiet reports NaN seconds, and NaN compares
    // false against everything: the fade branch would compute an alpha of NaN,
    // write it into every band of [_shown], and leave the curve undrawn for the
    // rest of the session — including after a new source started publishing.
    // Reseating instead shows the stale frame's unavailable spectrum, and the
    // first real frame after it snaps back to something measured.
    //
    // **[SpectrumResponse.fast] is not a discontinuity**, and conflating the
    // two cost the hold entirely: an unaveraged curve is `alpha == 1`, which
    // draws the published frame exactly, but a *reseat* at `alpha == 1` also
    // starts the hold again from that frame — so on Fast, the one setting a
    // click is looked for at, the line above the curve was the curve.
    final reseat = !(dt > 0) || _seenGeneration < 0;
    final alpha = reseat || tau <= 0 ? 1.0 : 1 - math.exp(-dt / tau);
    final instant = alpha >= 1;

    final spectrum = engine.spectrum;
    final step = dt > 0 ? dt : 0.0;

    for (var band = 0; band < MeterShape.spectrumBands; band++) {
      final level = instant
          ? spectrum[band]
          : _shown[band] + (spectrum[band] - _shown[band]) * alpha;
      _shown[band] = level;

      // The highest the curve above has been, held and then let down at the
      // rate the engine lets its own hold down, so a hold reads the same
      // whichever side of the wire computed it.
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

      _shownHold[band] = instant
          ? held
          : _shownHold[band] + (held - _shownHold[band]) * alpha;
    }
  }

  ScaleGraticule? _graticule;

  /// The tilt, printed in the plot's top-left corner.
  ///
  /// Only when there is one. At [SpectrumTilt.db0] the dB scale on the right is
  /// true everywhere and there is nothing to disclose; at any other setting it
  /// is true at 1 kHz and rotated away from it, and a reader who has not been
  /// told that is reading the wrong numbers off a correct-looking axis.
  ///
  /// Top left because that is the corner a tilt *clears*: the same rotation
  /// that makes the label necessary takes the bottom octaves — which are the
  /// loudest part of every mix and were drawn against the ceiling — down the
  /// plot by twenty-odd decibels.
  ui.Paragraph? _tiltLabel;
  SpectrumTilt? _labelledTilt;
  Color? _labelColor;

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

    if (_tiltFor != widget.tilt) {
      for (var band = 0; band < MeterShape.spectrumBands; band++) {
        _tiltDb[band] = widget.tilt.dbAt(bandCentreHz(band));
      }
      _tiltFor = widget.tilt;
    }

    if (_labelledTilt != widget.tilt || _labelColor != colors.textFaint) {
      _tiltLabel = widget.tilt.dbPerOctave == 0
          ? null
          : layoutParagraph(
              widget.tilt.label,
              OaaType.tick.copyWith(color: colors.textFaint),
            );
      _labelledTilt = widget.tilt;
      _labelColor = colors.textFaint;
    }

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
        tilt: widget.tilt,
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
    required this.tilt,
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
  final SpectrumTilt tilt;
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
    final gap =
        (bandOfHz(50) - bandOfHz(20)) / MeterShape.spectrumBands * plot.width;
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
          plot.left +
          bandOfHz(_gridHz[i]) / MeterShape.spectrumBands * plot.width;
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

    if (engine.generation != state._seenGeneration) {
      state._advance(engine, response.timeConstant);
      state._seenGeneration = engine.generation;
    }

    // --- Bands --------------------------------------------------------------
    // The bands are drawn a half-band wider than they are spaced. Butt caps on
    // a stroke exactly one band wide leave a seam of background between
    // neighbours wherever the band centre lands mid-pixel, and five hundred
    // hairline seams read as vertical banding across the whole fill.
    final bandWidth = plot.width / MeterShape.spectrumBands;
    _fill.strokeWidth = bandWidth + 0.5;
    _fill.shader = state.fillShader(plot, colors.accent);

    // The tilt is added here rather than folded into [_advance], and that is
    // not an arrangement of convenience: a fixed per-band offset commutes with
    // a maximum, a hold and a one-pole alike, so the tilted picture is exactly
    // the untilted one rotated — and changing the setting rotates what is on
    // screen instead of reseating five hundred averages and drawing a curve
    // that climbs out of the floor for half a second.
    final tiltDb = state._tiltDb;

    for (var band = 0; band < MeterShape.spectrumBands; band++) {
      final x = plot.left + (band + 0.5) * bandWidth;
      final y = _y(plot, state._shown[band] + tiltDb[band]);

      state._bars[band * 4] = x;
      state._bars[band * 4 + 1] = plot.bottom;
      state._bars[band * 4 + 2] = x;
      state._bars[band * 4 + 3] = y;

      state._curve[band * 2] = x;
      state._curve[band * 2 + 1] = y;

      state._hold[band * 2] = x;
      state._hold[band * 2 + 1] = _y(
        plot,
        state._shownHold[band] + tiltDb[band],
      );
    }

    canvas.save();
    canvas.clipRect(plot);
    canvas.drawRawPoints(ui.PointMode.lines, state._bars, _fill);
    canvas.drawRawPoints(ui.PointMode.polygon, state._curve, _curve);
    canvas.drawRawPoints(ui.PointMode.polygon, state._hold, _hold);
    canvas.restore();

    final label = state._tiltLabel;
    if (label != null && label.longestLine + Space.sm < plot.width) {
      canvas.drawParagraph(
        label,
        Offset(plot.left + Space.xs, plot.top + Space.xxs),
      );
    }
  }

  double _y(Rect plot, double db) =>
      plot.bottom - graticule.scale.fractionOf(db) * plot.height;

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.response != response ||
      oldDelegate.tilt != tilt ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
