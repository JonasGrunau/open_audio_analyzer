// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bel_engine/bel_engine.dart';
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
/// The transform does the work, so nothing is copied
///
/// The engine publishes 1024 raw (L, R) pairs as a `Float32List` view straight
/// onto its own memory. Rotating and scaling those in Dart would mean writing
/// 2048 floats into a second buffer every frame, per scope. Instead the canvas
/// is transformed — translate, scale, rotate — and the native buffer is handed
/// to `drawRawPoints` exactly as it arrived. The GPU does the arithmetic it was
/// going to do anyway, and the audio never touches the Dart heap.
class PhaseScopeModule extends StatefulWidget {
  const PhaseScopeModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final BelEngine engine;
  final MeterClock clock;

  @override
  State<PhaseScopeModule> createState() => _PhaseScopeModuleState();
}

class _PhaseScopeModuleState extends State<PhaseScopeModule> {
  final _trail = PersistenceLayer();

  ui.Paragraph? _left;
  ui.Paragraph? _right;
  ui.Paragraph? _mono;
  Color? _builtColor;

  /// The last generation drawn into the trail. Persistence advances on new
  /// audio, not on repaints — a resize or a theme change must not age the trail
  /// by a frame it did not measure.
  int lastGeneration = -1;

  @override
  void dispose() {
    _trail.dispose();
    super.dispose();
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

    return MeterBody(
      painter: _PhaseScopePainter(
        engine: widget.engine,
        colors: colors,
        trail: _trail,
        state: this,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        repaint: widget.clock,
      ),
    );
  }
}

class _PhaseScopePainter extends MeterPainter {
  _PhaseScopePainter({
    required this.engine,
    required this.colors,
    required this.trail,
    required this.state,
    required this.devicePixelRatio,
    required Listenable repaint,
  }) : _points = (Paint()
         ..color = colors.accent
         ..strokeCap = StrokeCap.round),
       _fade = (Paint()
         ..color = const Color(0xFFFFFFFF).withValues(alpha: _decay)),
       _blit = Paint(),
       _guide = (Paint()
         ..color = colors.hairline
         ..style = PaintingStyle.stroke
         ..strokeWidth = BelStroke.hairline),
       _correlation = (Paint()..color = colors.meterFill),
       _correlationTrack = (Paint()..color = colors.meterTrack),
       super(repaint: repaint);

  final BelEngine engine;
  final BelColors colors;
  final PersistenceLayer trail;
  final _PhaseScopeModuleState state;
  final double devicePixelRatio;

  final Paint _points;
  final Paint _fade;
  final Paint _blit;
  final Paint _guide;
  final Paint _correlation;
  final Paint _correlationTrack;

  /// How much of the previous frame survives. At ~47 published frames a second
  /// this leaves a trail a little under half a second long, which is enough to
  /// see the shape of a bass note without smearing a whole bar into a blob.
  static const double _decay = 0.86;

  /// Radius of a plotted sample, in logical pixels.
  static const double _pointSize = 1.4;

  static const double _correlationHeight = 10;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 60 || size.height < 60) return;

    final plotHeight = size.height - _correlationHeight - Space.xs;
    if (plotHeight < 40) return;
    final plot = Size(size.width, plotHeight);

    final centre = Offset(plot.width / 2, plot.height / 2);
    // sqrt(2) of headroom, because a mono full-scale signal reaches (1,1),
    // whose rotated length is sqrt(2). Without it a loud mono passage would
    // clip against the top of the display and read as a limiter.
    final radius =
        math.min(plot.width, plot.height) / 2 / math.sqrt2 - Space.xs;

    if (engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      trail.update(plot, devicePixelRatio, (layer, previous) {
        trail.replay(layer, previous, plot, _fade);

        layer.save();
        layer.translate(centre.dx, centre.dy);
        // Screen y grows downwards; the scale flips it so a positive sample
        // goes up. The rotation then turns the L=R diagonal upright.
        layer.scale(radius, -radius);
        layer.rotate(math.pi / 4);

        // strokeWidth is in the transformed space, so it has to be divided back
        // out or a dot would be `radius` pixels across.
        _points.strokeWidth = _pointSize / radius;
        layer.drawRawPoints(ui.PointMode.points, engine.scope, _points);
        layer.restore();
      });
    }

    trail.paint(canvas, plot, _blit);

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
      oldDelegate.colors != colors ||
      oldDelegate.devicePixelRatio != devicePixelRatio ||
      !identical(oldDelegate.engine, engine);
}
