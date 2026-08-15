// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// A goniometer: left against right, rotated so mono stands upright.
///
/// The rotation is the convention that makes the display readable — a mono
/// signal has L equal to R, which is a 45° diagonal until you turn the whole
/// plot 45°, at which point it becomes a vertical line and "vertical means
/// mono, horizontal means out of phase" is something you can learn in one
/// glance. It stays here rather than in the engine because it is a convention
/// this module has and the CLI does not.
///
/// ---------------------------------------------------------------------------
/// The transform does the work, so the audio is never copied
///
/// The engine publishes 1024 raw (L, R) pairs as a `Float32List` view straight
/// onto its own memory. Rotating and scaling those in Dart would mean writing
/// 2048 floats into a second buffer every frame. Instead the canvas is
/// transformed — translate, scale, rotate — and the buffer is handed to
/// `drawRawPoints` as it arrived. The GPU does arithmetic it was going to do
/// anyway.
///
/// ---------------------------------------------------------------------------
/// The trail is the last [_trailFrames] frames, not a faded picture
///
/// The obvious afterglow keeps last frame's image, draws it back at 86% and
/// adds the new points. That is what this module used to do, and the image it
/// kept came from `toImageSync`, which retains the display list that drew it
/// for as long as the image lives — so every frame's image pinned the frame
/// before it, back to the first one. It leaked one image per published frame
/// and eventually killed the raster thread on the way out; the full account is
/// in the header of `spectrogram.dart`.
///
/// The trail is short, so keeping the frames is cheaper than keeping a picture
/// of them: at a decay of 0.86 a frame is below one part in 255 after forty of
/// them, and forty frames of scope is a 327 KB ring. Each is one
/// `drawRawPoints` call at its own age's alpha — forty calls, recorded in about
/// 0.1 ms. Two things improve as a side effect: the decay is exact rather
/// than compounded through an 8-bit surface, and the trail no longer blurs. The
/// old one resampled the whole picture every frame, so a moving dot smeared
/// instead of fading in place.
class PhaseScopeModule extends StatefulWidget {
  const PhaseScopeModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  @override
  State<PhaseScopeModule> createState() => _PhaseScopeModuleState();
}

/// How much of the previous frame survives. At ~47 published frames a second
/// this leaves a trail a little under half a second long, which is enough to
/// see the shape of a bass note without smearing a whole bar into a blob.
const double _decay = 0.86;

/// How many frames the trail keeps. `0.86^40` is 0.0024, below the 1/255 a
/// surface can show, so the fortieth frame is the last that could contribute.
const int _trailFrames = 40;

class _PhaseScopeModuleState extends State<PhaseScopeModule> {
  /// [_trailFrames] frames of scope points, oldest overwritten. The views onto
  /// its slots are built once, so drawing neither copies nor allocates.
  Float32List _ring = Float32List(0);
  List<Float32List> _frames = const [];
  int _next = 0;
  int _filled = 0;

  ui.Paragraph? _left;
  ui.Paragraph? _right;
  ui.Paragraph? _mono;
  Color? _builtColor;

  /// One [Paint] per age, alpha `_decay^age`.
  List<Paint> _trail = const [];
  Color? _builtTrail;

  /// The last generation written into the ring. The trail advances on new
  /// audio, not on repaints — a resize or a theme change must not age it by a
  /// frame it did not measure.
  ///
  /// Starts at 0 rather than −1 because generation 0 is "nothing measured yet",
  /// and the scope behind a fresh source is zeroed — a full frame of samples
  /// sitting exactly at the origin.
  int lastGeneration = 0;

  /// Stores one frame of scope points as the newest.
  void write(Float32List scope) {
    if (scope.isEmpty) return;
    if (_ring.length != _trailFrames * scope.length) {
      _ring = Float32List(_trailFrames * scope.length);
      _frames = [
        for (var slot = 0; slot < _trailFrames; slot++)
          Float32List.sublistView(
            _ring,
            slot * scope.length,
            (slot + 1) * scope.length,
          ),
      ];
      _next = 0;
      _filled = 0;
    }

    _ring.setRange(_next * scope.length, (_next + 1) * scope.length, scope);
    _next = (_next + 1) % _trailFrames;
    if (_filled < _trailFrames) _filled++;
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    if (_builtColor != colors.textFaint) {
      _builtColor = colors.textFaint;
      final style = BelType.tick.copyWith(color: colors.textFaint);
      _left = layoutParagraph('L', style);
      _right = layoutParagraph('R', style);
      _mono = layoutParagraph('M', style);
    }

    if (_builtTrail != colors.accent) {
      _builtTrail = colors.accent;
      _trail = [
        for (var age = 0; age < _trailFrames; age++)
          Paint()
            ..color = colors.accent.withValues(
              alpha: math.pow(_decay, age).toDouble(),
            )
            ..strokeCap = StrokeCap.round,
      ];
    }

    return MeterBody(
      painter: _PhaseScopePainter(
        engine: widget.engine,
        colors: colors,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _PhaseScopePainter extends MeterPainter {
  _PhaseScopePainter({
    required this.engine,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : _guide = (Paint()
         ..color = colors.hairline
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.hairline),
       _correlation = (Paint()..color = colors.meterFill),
       _correlationTrack = (Paint()..color = colors.meterTrack),
       super(repaint: repaint);

  final MeterSource engine;
  final BelColors colors;
  final _PhaseScopeModuleState state;

  final Paint _guide;
  final Paint _correlation;
  final Paint _correlationTrack;

  /// Radius of a plotted sample, in logical pixels.
  static const double _pointSize = 1.4;

  static const double _correlationHeight = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final plotHeight = size.height - _correlationHeight - Space.xs;
    if (plotHeight < 40) return;
    final plot = Size(size.width, plotHeight);

    final centre = Offset(plot.width / 2, plot.height / 2);
    // sqrt(2) of headroom, because a mono full-scale signal reaches (1,1),
    // whose rotated length is sqrt(2). Without it a loud mono passage would
    // clip against the top of the display and read as a limiter.
    final radius =
        math.min(plot.width, plot.height) / 2 / math.sqrt2 - Space.xs;
    if (radius <= 0) return;

    if (engine.generation != 0 && engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      state.write(engine.scope);
    }

    // --- The trail, oldest first so the newest frame is on top --------------
    if (state._trail.length == _trailFrames) {
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      // Screen y grows downwards; the scale flips it so a positive sample goes
      // up. The rotation then turns the L=R diagonal upright.
      canvas.scale(radius, -radius);
      canvas.rotate(math.pi / 4);

      for (var age = state._filled - 1; age >= 0; age--) {
        final slot = (state._next - 1 - age + _trailFrames * 2) % _trailFrames;
        canvas.drawRawPoints(
          ui.PointMode.points,
          state._frames[slot],
          // strokeWidth is in the transformed space, so it has to be divided
          // back out or a dot would be `radius` pixels across.
          state._trail[age]..strokeWidth = _pointSize / radius,
        );
      }
      canvas.restore();
    }

    // --- Guides, drawn fresh each frame so the trail cannot burn them in ----
    canvas.drawCircle(centre, radius * math.sqrt2, _guide);
    canvas.drawLine(
      Offset(centre.dx, centre.dy - radius * math.sqrt2),
      Offset(centre.dx, centre.dy + radius * math.sqrt2),
      _guide,
    );
    canvas.drawLine(
      Offset(centre.dx - radius * math.sqrt2, centre.dy),
      Offset(centre.dx + radius * math.sqrt2, centre.dy),
      _guide,
    );

    final reach = radius * math.sqrt2;
    _label(
      canvas,
      state._mono!,
      Offset(centre.dx, centre.dy - reach + Space.sm),
    );
    _label(
      canvas,
      state._left!,
      Offset(centre.dx - reach * 0.72, centre.dy - reach * 0.72 + Space.sm),
    );
    _label(
      canvas,
      state._right!,
      Offset(centre.dx + reach * 0.72, centre.dy - reach * 0.72 + Space.sm),
    );

    // --- Correlation --------------------------------------------------------
    // The same fact as the shape above, as a number you can read off. −1 is a
    // signal that will disappear in mono, which is the failure a phase scope
    // exists to catch and the one thing about it worth quantifying.
    final track = Rect.fromLTWH(
      0,
      size.height - _correlationHeight,
      size.width,
      _correlationHeight,
    );
    canvas.drawRect(track, _correlationTrack);

    final correlation = engine.correlation;
    if (!correlation.isNaN) {
      final centreX = track.center.dx;
      final extent = correlation.clamp(-1.0, 1.0) * track.width / 2;
      _correlation.color = correlation < 0 ? colors.warn : colors.meterFill;
      canvas.drawRect(
        Rect.fromLTRB(
          extent < 0 ? centreX + extent : centreX,
          track.top,
          extent < 0 ? centreX : centreX + extent,
          track.bottom,
        ),
        _correlation,
      );
    }
    canvas.drawLine(
      Offset(track.center.dx, track.top),
      Offset(track.center.dx, track.bottom),
      _guide,
    );
  }

  void _label(Canvas canvas, ui.Paragraph label, Offset at) =>
      canvas.drawParagraph(
        label,
        at - Offset(label.longestLine / 2, label.height / 2),
      );

  @override
  bool shouldRepaint(_PhaseScopePainter oldDelegate) =>
      oldDelegate.colors != colors || !identical(oldDelegate.engine, engine);
}
