// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Which edge of the module the light rises out of.
///
/// Two, because two modules glow: the Number Box from its foot, under the
/// digits, and the Alert Meter from its left edge. A third is one arm of the
/// switch in [EdgeGlow._prepare] and no design decision has asked for one.
enum GlowEdge { bottom, left }

/// A wash of colour rising out of one edge of a module.
///
/// One class for both, and that is the point: every defect this shape has had
/// was a property of the *shape*, so a second copy of it is a second copy of
/// all of them. `test/module_glow_test.dart` is the catalogue.
///
/// **An ellipse, scaled on both axes, because a module's aspect is not fixed.**
/// A circle sized off one dimension alone is right on precisely one shape and
/// wrong either side of it: the same shader that fades over four fifths of a
/// six-cell box does not fade at all inside a two-cell chip three times as wide
/// as it is tall, where the module sits so deep inside the circle that every
/// pixel of it is near the crown — a flat sheet of colour with the glow's own
/// edge across it rather than light coming from anywhere. Tying each radius to
/// the dimension it runs along makes every module the picture the largest one
/// already was, which is the only one that ever looked right.
///
/// The ellipse is a circle with a matrix scaling it out on the other axis,
/// because that is the only ellipse `dart:ui` offers.
///
/// **Anchored outside the edge so only the crown reaches in: a glow, not a
/// spotlight.** The anchor is a share of the radius rather than a distance, so
/// the brightness where the light meets the module's edge is the same at every
/// size — it is how far the light travels that scales, not how bright it
/// starts.
///
/// The shader is rebuilt only when the module resizes or the verdict changes
/// colour, which happens when a reading crosses a limit and not per frame. The
/// same bargain every cached shader in the application makes.
class EdgeGlow {
  EdgeGlow(this.edge);

  final GlowEdge edge;

  /// How far the light travels into the module, as a fraction of the dimension
  /// it crosses: it is out by the time it is four fifths of the way across,
  /// whatever the module's size or shape.
  static const double _reach = 0.8;

  /// How far it spreads along the edge, as a fraction of the module's other
  /// dimension — half again as far as the module's own side, so the full
  /// length of that edge is lit and only the corners fall away.
  static const double _spread = 0.75;

  /// Where the centre sits outside the edge, as a share of the radius pointing
  /// into the module. The wash is at its strongest at that centre, so this is
  /// what decides how bright it is where it meets the edge.
  static const double _anchor = 0.3;

  /// At the centre. Strong enough to read as light on the panel and weak
  /// enough that a reading drawn over it keeps its contrast.
  static const double _alpha = 0.28;

  final Paint _paint = Paint();
  Rect? _rect;
  Color? _color;

  void _prepare(Rect rect, Color color) {
    if (_paint.shader != null && _rect == rect && _color == color) return;
    _rect = rect;
    _color = color;

    // The radius pointing into the module, the radius running along the edge,
    // and the centre — which is the whole of the difference between the two.
    final (double into, double along, Offset center) = switch (edge) {
      GlowEdge.bottom => () {
        final r = rect.height * _reach / (1 - _anchor);
        return (
          r,
          rect.width * _spread,
          Offset(rect.center.dx, rect.bottom + r * _anchor),
        );
      }(),
      GlowEdge.left => () {
        final r = rect.width * _reach / (1 - _anchor);
        return (
          r,
          rect.height * _spread,
          Offset(rect.left - r * _anchor, rect.center.dy),
        );
      }(),
    };

    final scale = along / into;
    final horizontal = edge == GlowEdge.bottom;
    _paint.shader = ui.Gradient.radial(
      center,
      into,
      [color.withValues(alpha: _alpha), color.withValues(alpha: 0.0)],
      null,
      TileMode.clamp,
      (Matrix4.identity()
            ..translateByDouble(center.dx, center.dy, 0, 1)
            ..scaleByDouble(
              horizontal ? scale : 1,
              horizontal ? 1 : scale,
              1,
              1,
            )
            ..translateByDouble(-center.dx, -center.dy, 0, 1))
          .storage,
    );
  }

  /// Fills [rect] with the glow. The caller passes the *panel* rather than the
  /// body it was handed — light that stops at a margin is a lit rectangle in a
  /// dark gutter — which is what `ModuleFrame.bleed` exists to allow.
  void paint(Canvas canvas, Rect rect, Color color) {
    if (rect.isEmpty) return;
    _prepare(rect, color);
    canvas.drawRect(rect, _paint);
  }
}
