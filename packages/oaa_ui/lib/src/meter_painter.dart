// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// A meter's body: one painter, filling whatever room the frame gives it.
///
/// The `SizedBox.expand` is not decoration. A [CustomPaint] with no child has
/// no intrinsic size and collapses to nothing, and the symptom is a module that
/// draws its frame and its title and then nothing at all — which reads as a
/// broken meter rather than as a layout mistake. Every module used to write
/// this line; now none of them can forget it.
///
/// ---------------------------------------------------------------------------
/// The clip is not decoration either
///
/// **A `CustomPaint` does not clip its painter to its size.** The size handed to
/// `paint` is a statement about the room available, not a boundary that is
/// enforced, and a painter that draws outside it draws over the module's own
/// border, its title, and whatever module the canvas put next to it.
///
/// Nothing catches this. It is not an overflow — `RenderFlex` has no part in it,
/// so there is no debug stripe and no exception — and it only appears when the
/// signal makes it appear, which for the phase scope means a sample past full
/// scale. The engine deliberately does not clamp those (a float WAV may
/// legitimately exceed ±1.0, and those overshoots are the ones true-peak
/// metering exists to find), so the scope drew its points outside its own guide
/// circle and out through the side of the module, on exactly the material
/// somebody is looking at it to check.
///
/// Clipping here rather than in each painter is the same decision as the frame:
/// a module that owns its own boundary is a module that will drift from the
/// others, and eleven of the twelve that existed then had never clipped at all.
/// A painter that wants to draw a glow past its edge has to say so, and none
/// does.
class MeterBody extends StatelessWidget {
  const MeterBody({required this.painter, super.key});

  final MeterPainter painter;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: CustomPaint(painter: painter, child: const SizedBox.expand()),
  );
}

/// The base class every module painter extends.
///
/// It exists for one reason, and it is not shared behaviour — it is a default
/// in Flutter that is wrong for this application.
///
/// [CustomPainter.hitTest] returns `null` by default, and `RenderCustomPaint`
/// reads that as **true**: a `CustomPaint` with a background painter swallows
/// every pointer event that lands on it. That default is right for a painted
/// button and wrong for a meter. The canvas puts a module's drag, select and
/// context-menu affordances *behind* the module — so that the frame's own menu
/// button keeps priority without any gesture-arena arbitration — and a painter
/// that absorbs hits makes the whole body of the module dead to the mouse. You
/// can drag a meter by its title bar and not by its face, which reads as a bug
/// in the canvas rather than a default in the painter.
///
/// So meters are display surfaces and do not take input. A module that genuinely
/// needs it — scrubbing a histogram, dragging a spectrum cursor — overrides
/// [hitTest] again and opts back in deliberately.
abstract class MeterPainter extends CustomPainter {
  const MeterPainter({super.repaint});

  @override
  bool? hitTest(Offset position) => false;
}

/// The vertical gradient every filled meter body is painted with: brightest at
/// the reading, the base colour a third of the way down, dimming toward the
/// floor.
///
/// One recipe rather than one per module, because the gradient is doing a job
/// and not decorating: it keeps a tall fill from reading as a solid block of
/// paint, so the *top edge* — the measurement — is the brightest thing in the
/// bar. Modules that invent their own stops end up with two bars side by side
/// whose fills disagree about how loud "bright" is.
///
/// The shader is anchored to the **fill's own top**, not the track's, and that
/// is the part that costs a save/clip/translate instead of a plain `drawRect`:
/// a track-anchored gradient leaves a quiet channel entirely in the dim end of
/// the ramp, so its reading has no bright edge at all and the two channels of
/// one meter look like different instruments. Anchoring at the tip would
/// normally mean building a new shader per bar per frame — an allocation on
/// the frame path — so instead one shader is built per track height and the
/// canvas is translated under it: the same object, moved, exact, and free.
class MeterFill {
  final Paint _paint = Paint();

  ui.Shader? _shader;
  double? _fadeHeight;
  Color? _base;
  Color? _bright;

  /// Rebuilds the cached shader if [fadeHeight] (normally the track height) or
  /// the palette changed. Call once per paint, before [draw].
  void prepare(double fadeHeight, OaaColors colors, {Color? color}) {
    final base = color ?? colors.meterFill;
    if (_shader != null && _fadeHeight == fadeHeight && _base == base) return;
    _fadeHeight = fadeHeight;
    _base = base;
    _bright = Color.lerp(base, colors.textPrimary, 0.35)!;
    _shader = ui.Gradient.linear(
      Offset.zero,
      Offset(0, fadeHeight),
      [_bright!, base, Color.lerp(base, colors.background, 0.40)!],
      const [0.0, 0.35, 1.0],
    );
    _paint.shader = _shader;
  }

  /// The gradient's top colour — for the marks that must match the fill they
  /// annotate, like a bar's own peak cap.
  Color get bright => _bright ?? const Color(0x00000000);

  /// Paints [fill] with the gradient anchored at `fill.top`.
  void draw(Canvas canvas, Rect fill) {
    if (_shader == null || fill.isEmpty) return;
    canvas.save();
    canvas.clipRect(fill);
    canvas.translate(fill.left, fill.top);
    canvas.drawRect(Rect.fromLTWH(0, 0, fill.width, _fadeHeight!), _paint);
    canvas.restore();
  }
}
