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
/// The band area is a vertical gradient — brightest along the curve, the base
/// colour a little down, still clearly present at the floor — which is what
/// keeps the top edge the brightest thing in the plot without hollowing the
/// fill out into an outline. That would normally want a filled `Path` with a
/// gradient, and the paragraph above is the reason it cannot have one.
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
    this.source = SpectrumSource.all,
    this.response = SpectrumResponse.normal,
    this.tilt = SpectrumTilt.db4p5,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// Which signal the bands are measured on. See [SpectrumSource]. A source
  /// the measurement cannot make on this signal — the right, mid or side of a
  /// one-channel input — is drawn as the notice it is, not as silence.
  final SpectrumSource source;

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

class _SpectrumAnalyzerModuleState extends State<SpectrumAnalyzerModule> {
  /// Ticks crowded at the top, −∞ on the floor. The top of the scale is
  /// unlabelled: 0 dB is the plot's own top edge, and a label there would sit
  /// in the frequency axis's band. The taper is [MeterScale.tapered]'s and
  /// shared with every other level scale.
  static const _scale = MeterScale.tapered(
    max: 0,
    ticks: [-3, -6, -9, -12, -18, -24, -30, -40, -60],
  );

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

  /// What a source the signal cannot provide is drawn as.
  ui.Paragraph? _mono;

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
  void _advance(MeterSource engine, double tau, SpectrumSource source) {
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

    final spectrum = engine.spectrumOf(source);
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

  /// A paragraph per gridline, laid out at both label densities. Both sets are
  /// built here rather than at paint time because laying out a paragraph on the
  /// frame path is the thing the frame path most wants not to do.
  List<ui.Paragraph> _gridLabels = const [];

  /// The tilt, printed in the plot's top-left corner.
  ///
  /// Only when there is one. At [SpectrumTilt.db0] the dB scale is true
  /// everywhere and there is nothing to disclose; at any other setting it is
  /// true at 1 kHz and rotated away from it, and a reader who has not been
  /// told that is reading the wrong numbers off a correct-looking axis.
  ///
  /// Top left because that is the corner a tilt *clears*: the same rotation
  /// that makes the label necessary takes the bottom octaves — which are the
  /// loudest part of every mix and were drawn against the ceiling — down the
  /// plot by twenty-odd decibels. Decibel prints no such caption; this one
  /// stays, because the scale beside a tilted curve is a scale with a caveat.
  ui.Paragraph? _tiltLabel;
  SpectrumTilt? _labelledTilt;
  Color? _labelColor;

  /// Which [kHzGrid] values carry a label at the current plot width — solved
  /// by [fitHzLabels] when the plot resizes, not per frame.
  List<bool> _gridLabelled = const [];
  double _gridLabelledFor = -1;

  void solveAxis(double plotWidth) {
    if (_gridLabelledFor == plotWidth || _gridLabels.isEmpty) return;
    _gridLabelledFor = plotWidth;
    _gridLabelled = fitHzLabels(plotWidth, (i) => _gridLabels[i].longestLine);
  }

  /// The band fill's vertical gradient, and the plot it was built for. Rebuilt
  /// on a resize or a skin change and at no other time.
  ///
  /// Near-flat on purpose: brightest at the top where the curve lives, the
  /// accent itself a little down, and still unmistakably the accent at the
  /// floor. The old ramp faded to fourteen percent alpha at the bottom, which
  /// made a full-range mix read as a curve with a shadow rather than as a
  /// filled spectrum.
  ui.Shader? _fillShader;
  Rect? _shaderPlot;
  OaaColors? _shaderColors;

  ui.Shader fillShader(Rect plot, OaaColors colors) {
    if (_fillShader == null || _shaderPlot != plot || _shaderColors != colors) {
      final base = colors.accent;
      _fillShader = ui.Gradient.linear(
        plot.topCenter,
        plot.bottomCenter,
        <Color>[
          Color.lerp(base, colors.textPrimary, 0.30)!,
          base,
          Color.lerp(base, colors.background, 0.25)!,
        ],
        const [0.0, 0.4, 1.0],
      );
      _shaderPlot = plot;
      _shaderColors = colors;
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
        !_graticule!.matches(_scale, ScaleSide.left, colors.textFaint)) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.left,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
      );

      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _gridLabels = [
        for (final hz in kHzGrid) layoutParagraph(formatHz(hz), style),
      ];
      _gridLabelledFor = -1;
      // The same words the stereo cloud and the phase scope use for the same
      // fact, in the same face.
      _mono = layoutParagraph(
        'MONO SOURCE',
        OaaType.label.copyWith(color: colors.textMuted),
      );
    }

    return MeterBody(
      painter: _SpectrumPainter(
        engine: widget.engine,
        colors: colors,
        graticule: _graticule!,
        source: widget.source,
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
    required this.source,
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
  final SpectrumSource source;
  final SpectrumResponse response;
  final SpectrumTilt tilt;
  final _SpectrumAnalyzerModuleState state;

  final Paint _fill;
  final Paint _curve;
  final Paint _hold;
  final Paint _grid;

  @override
  void paint(Canvas canvas, Size size) {
    final labelHeight = OaaType.tick.fontSize! + Space.xs;
    final plot = Rect.fromLTRB(
      graticule.gutter,
      labelHeight,
      size.width,
      size.height,
    );
    if (plot.width < 60 || plot.height < 32) return;

    graticule.paint(canvas, plot);

    // --- Frequency graticule ------------------------------------------------
    // Labels along the top, where the loudest octaves of a mix — the bottom of
    // the plot — cannot run into them; every value that fits, by the one rule
    // every frequency axis fits by. See [fitHzLabels].
    state.solveAxis(plot.width);
    final labels = state._gridLabels;
    for (var i = 0; i < kHzGrid.length; i++) {
      final x =
          plot.left +
          bandOfHz(kHzGrid[i]) / MeterShape.spectrumBands * plot.width;
      if (x < plot.left || x > plot.right) continue;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), _grid);

      final label = labels[i];
      if (i < state._gridLabelled.length && state._gridLabelled[i]) {
        // Nudged inside the plot rather than centred on the line, because the
        // first gridline *is* the left edge: 20 Hz is band zero. Centred, half
        // of "20" is drawn off the module and the axis appears to start at 30.
        final room = plot.right - label.longestLine;
        final left = room <= plot.left
            ? plot.left
            : (x - label.longestLine / 2).clamp(plot.left, room);
        canvas.drawParagraph(
          label,
          Offset(left, plot.top - label.height - Space.xxs),
        );
      }
    }

    if (!engine.hasSpectrum) return;

    // A source this signal cannot provide is NaN throughout — see
    // `MeterSource.spectrumOf`. Nothing is folded from it, so the curve is
    // where the last measured source left it when the setting is changed
    // back, and the plot says why it is empty rather than drawing the floor.
    if (engine.spectrumOf(source)[0].isNaN) {
      final mono = state._mono!;
      canvas.drawParagraph(
        mono,
        Offset(
          plot.left + (plot.width - mono.longestLine) / 2,
          plot.top + (plot.height - mono.height) / 2,
        ),
      );
      return;
    }

    if (engine.generation != state._seenGeneration) {
      state._advance(engine, response.timeConstant, source);
      state._seenGeneration = engine.generation;
    }

    // --- Bands --------------------------------------------------------------
    // The bands are drawn a half-band wider than they are spaced. Butt caps on
    // a stroke exactly one band wide leave a seam of background between
    // neighbours wherever the band centre lands mid-pixel, and five hundred
    // hairline seams read as vertical banding across the whole fill.
    final bandWidth = plot.width / MeterShape.spectrumBands;
    _fill.strokeWidth = bandWidth + 0.5;
    _fill.shader = state.fillShader(plot, colors);

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
      oldDelegate.source != source ||
      oldDelegate.response != response ||
      oldDelegate.tilt != tilt ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
