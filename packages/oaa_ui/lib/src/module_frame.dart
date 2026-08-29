// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'meter_painter.dart';
import 'theme.dart';
import 'tokens.dart';

/// The chrome every meter module sits inside.
///
/// All fourteen modules are this frame plus a painter. That is the whole reuse
/// strategy, and it is deliberate: a module that also owns its own border, its
/// own title treatment and its own menu affordance is a module that will drift
/// from the other eleven, and eleven near-identical borders is exactly how an
/// interface stops looking designed.
///
/// The frame is a [StatelessWidget] and stays out of the per-frame path
/// entirely. The title does not change 60 times a second; only [child] repaints,
/// and it does so inside a [RepaintBoundary] so that a spectrum analyser
/// redrawing cannot dirty the panel border around it.
///
/// ---------------------------------------------------------------------------
/// The chrome is painted, not decorated, because decorations eat pointers
///
/// The obvious way to draw this is a `DecoratedBox` with a `BoxDecoration`, and
/// that is what it used to be. It is a trap. `RenderDecoratedBox.hitTestSelf`
/// asks the decoration whether the point is inside its shape, and a
/// `BoxDecoration` says yes to every point in the box — so the frame silently
/// consumed every pointer event that landed anywhere on the module. The canvas
/// puts a module's drag and selection affordances *behind* it, so the symptom
/// was a canvas where no meter could be selected or dragged and nothing
/// anywhere reported an error. `RenderParagraph` does the same thing, which is
/// why the title label is wrapped in an [IgnorePointer].
///
/// So the fill, the border and the title rule are drawn by a [MeterPainter],
/// which does not take input, and the only thing in the frame that can be
/// clicked is the menu button. The frame is chrome, and chrome is inert.
///
/// ---------------------------------------------------------------------------
/// The panel is lit from its top-left corner
///
/// Decibel's are, and it is most of what makes its modules read as machined
/// panels under a light rather than as rectangles of colour. Measured off a
/// screenshot, its light falls off in a straight line from the corner to
/// nothing four fifths of the way across and four fifths of the way down, on a
/// module as tall as it is wide. So the fill is one radial gradient anchored on
/// the corner, from [OaaColors.panelLit] to [OaaColors.panel], reaching
/// [_FramePainter.lightReach] of the width and, separately, of the height — an
/// ellipse in the panel's own proportions, and the reason is on that constant.
/// The *strength* is about half of Decibel's, and the reason for that is on
/// [OaaColors.panelLift].
///
/// It is the *panel* that is lit, and the title bar is part of the panel: the
/// bar has no fill of its own, so the light runs under the title and the rule
/// and on into the body, and a module is one surface under one light rather
/// than a dark strip glued to a lit one. Two things follow that are meant. The
/// hairline border has less to stand on at the corner than at the far edges,
/// where the panel is a few levels off the background and the border is all
/// that marks the edge; it stays a step above the lit fill on the default skin,
/// and that step is what set the strength. And a module that paints an opaque
/// ground of its own over the body — the spectrogram's RGB ramp — stands as a
/// flat rectangle inside a lit gutter, which is what a plot on a panel is; the
/// skin ramp's floor is transparent for exactly this reason, so the light
/// reaches the field it grounds — see `ColorRamp.groundOf`.
///
/// The light is skin-relative rather than a colour of its own: the panel
/// colour lifted, so a skin's panel carries it with no second value to keep in
/// step, and a light skin — whose panel is already near white — is barely lit
/// at all. See [OaaColors.panelLift].
class ModuleFrame extends StatelessWidget {
  const ModuleFrame({
    required this.title,
    required this.child,
    this.trailing,
    this.selected = false,
    this.bleed = false,
    this.onMenu,
    super.key,
  });

  /// Shown uppercase in the title bar.
  final String title;

  /// The meter itself.
  final Widget child;

  /// Optional status shown at the right of the title bar — a channel mode, a
  /// sample rate, whatever the module needs to disambiguate itself when six of
  /// them are on screen.
  final Widget? trailing;

  /// Draws the emphasis border. Set while the module is being moved or resized.
  final bool selected;

  /// Lets the body paint past the inset below, out to the panel's own edges.
  ///
  /// The inset is a margin for *content* — a reading, a scale, a plot — and it
  /// is right for all of it. It is wrong for a wash: the Number Box's glow
  /// rises from the module's foot, and stopped twelve pixels short of every
  /// edge, so what should have been light leaking out of the bottom of the
  /// panel was a lit rectangle with a dark gutter around it. A background that
  /// ends before its own background does reads as a rendering fault.
  ///
  /// Off by default, and the body is then not clipped here at all — most
  /// modules clip themselves through [MeterBody], and a rounded clip per module
  /// per frame is not something to hand the fourteen of them for the sake of
  /// one. Where it is on, the clip is what keeps the bleed honest: it stops at
  /// the panel's bottom corners rather than running out through them and over
  /// whatever the canvas put next door.
  final bool bleed;

  final VoidCallback? onMenu;

  /// Height of the title bar. Modules subtract this when deciding whether they
  /// have room to draw.
  ///
  /// It is the *painted* height, and on the canvas it is no longer the whole of
  /// the drag target: `_ModuleSlot` lays a taller invisible one under the bar
  /// for a finger, which has no cursor and covers all twenty-four pixels of
  /// this. Nothing here changes size — see `lib/src/canvas/grid_canvas.dart`.
  static const double titleBarHeight = 24;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _FramePainter(
            fill: colors.panel,
            // Derived, and taken here rather than in `paint` — see its note.
            lit: colors.panelLit,
            // Selection is weight and brightness, never the signal hue. A
            // module outlined in `accent` is outlined in the colour that means
            // "in spec" everywhere else on this canvas, and here the two are
            // adjacent by construction — the border literally touches the
            // reading it would be confused with.
            border: selected ? colors.hairlineStrong : colors.hairline,
            borderWidth: selected ? OaaStroke.emphasis : OaaStroke.hairline,
            rule: colors.hairline,
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TitleBar(
              title: title,
              trailing: trailing,
              onMenu: onMenu,
              colors: colors,
            ),
            Expanded(child: _body()),
          ],
        ),
      ],
    );
  }

  Widget _body() {
    final body = Padding(
      // The same on all four sides, and the same value the title bar insets
      // by — the title's left edge is the meter's left edge, and two paddings
      // that differ by four pixels read as a misalignment rather than as a
      // decision. This is the *only* margin a module gets: painters draw to
      // the edges of what they are handed, so a painter that adds a second
      // inset of its own is a module that no longer matches the other eleven.
      // A module may paint *outside* it — see [bleed] — and that is a
      // different statement: the inset still holds for everything it reads.
      padding: const EdgeInsets.all(Space.smd),
      // Isolates the meter's repaints from the frame around it. Without this,
      // a spectrogram scrolling at 60 fps marks the whole panel dirty and the
      // border is re-rastered along with it.
      child: RepaintBoundary(child: child),
    );

    if (!bleed) return body;

    // Square at the top, where the rule under the title bar already ends the
    // panel, and the panel's own radius at the foot. The rect is the fill's,
    // not the border's, so a wash covers the inner half of the hairline at the
    // bottom edge and stops — which is the whole point of drawing one there.
    // The rule at the top is under the same arrangement: a wash reaching it
    // tints it rather than being held a gutter's width below it, which is the
    // seam this exists to remove.
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: OaaRadius.sm,
        bottomRight: OaaRadius.sm,
      ),
      child: body,
    );
  }
}

/// The panel fill, lit from its top-left corner, its hairline border and the
/// rule under the title.
class _FramePainter extends MeterPainter {
  _FramePainter({
    required this.fill,
    required this.lit,
    required this.border,
    required this.borderWidth,
    required this.rule,
  }) : _fillPaint = (Paint()..color = fill),
       _borderPaint = (Paint()
         ..color = border
         ..style = PaintingStyle.stroke
         ..strokeWidth = borderWidth),
       _rulePaint = (Paint()
         ..color = rule
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false);

  final Color fill;

  /// The fill at the top-left corner; [fill] is what it fades to.
  final Color lit;

  final Color border;
  final double borderWidth;
  final Color rule;

  final Paint _fillPaint;
  final Paint _borderPaint;
  final Paint _rulePaint;

  /// How far the light reaches from the corner, as a share of the panel's
  /// width and, separately, of its height: gone at four fifths of each, which
  /// is where Decibel's is on a square module.
  ///
  /// A share of each side rather than a circle off either one. Sized off the
  /// shortest side, the light on a wide module is a spot in the corner of a
  /// panel otherwise dark; off the longest, a tall module is lit across its
  /// whole width with nothing to say the light came from the left. An ellipse
  /// in the panel's own proportions is the same picture on every shape — the
  /// lesson `EdgeGlow` learnt from a Number Box three times wider than it was
  /// tall; see `test/module_glow_test.dart`.
  static const double lightReach = 0.8;

  /// The size the fill's shader was built for. A radial gradient is anchored
  /// in pixels, so it is rebuilt when the panel is laid out at a new size and
  /// on nothing else: the frame sits outside the module's repaint boundary
  /// and paints when the module moves, not when it measures.
  Size? _litSize;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    if (size != _litSize && !size.isEmpty) {
      _litSize = size;
      _fillPaint.shader = ui.Gradient.radial(
        Offset.zero,
        size.width * lightReach,
        [lit, fill],
        null,
        TileMode.clamp,
        // A circle across the width, scaled into the panel's proportions
        // down the height. The centre is the origin, so the scale leaves it
        // where it is.
        Matrix4.diagonal3Values(1, size.height / size.width, 1).storage,
      );
    }
    canvas.drawRRect(RRect.fromRectAndRadius(bounds, OaaRadius.sm), _fillPaint);
    // Inset by half the stroke so a hairline lands inside the panel rather than
    // straddling its edge, where it renders as two grey half-pixels.
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds.deflate(borderWidth / 2), OaaRadius.sm),
      _borderPaint,
    );
    // Stops at the border's inner edge rather than running to the panel edge.
    // A full-width rule is drawn *after* the border and in the dim hairline
    // colour, so it punched two notches out of the selection outline — at
    // `OaaStroke.emphasis` that is a visible break in the one line whose whole
    // job is to be continuous, and it reads as the divider sitting on top of
    // the selection rather than inside it.
    canvas.drawLine(
      Offset(borderWidth, ModuleFrame.titleBarHeight),
      Offset(size.width - borderWidth, ModuleFrame.titleBarHeight),
      _rulePaint,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      oldDelegate.fill != fill ||
      oldDelegate.lit != lit ||
      oldDelegate.border != border ||
      oldDelegate.borderWidth != borderWidth ||
      oldDelegate.rule != rule;
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.title,
    required this.trailing,
    required this.onMenu,
    required this.colors,
  });

  final String title;
  final Widget? trailing;
  final VoidCallback? onMenu;
  final OaaColors colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: ModuleFrame.titleBarHeight,
      child: Padding(
        // Matches the body's inset — see the note there.
        padding: const EdgeInsets.fromLTRB(Space.sm, 0, 4, 0),
        child: Row(
          children: [
            // The title bar is a drag handle everywhere except the menu button,
            // and text absorbs pointer events — see this file's header. The
            // canvas extends that handle below the bar for touch, which changes
            // nothing here: the frame stays inert either way.
            Expanded(
              child: IgnorePointer(
                child: Text(
                  title.toUpperCase(),
                  style: OaaType.label.copyWith(color: colors.textMuted),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Space.sm),
              IgnorePointer(
                child: DefaultTextStyle(
                  style: OaaType.tick.copyWith(color: colors.textFaint),
                  child: trailing!,
                ),
              ),
            ],
            if (onMenu != null) ...[
              const SizedBox(width: Space.sm),
              _MenuButton(onPressed: onMenu!, colors: colors),
            ],
          ],
        ),
      ),
    );
  }
}

/// Three stacked rules. Drawn rather than shipped as an icon font, because a
/// 10 px glyph rasterises differently on each platform and this one has to line
/// up with a hairline border.
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.onPressed, required this.colors});

  final VoidCallback onPressed;
  final OaaColors colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: Space.md,
        height: ModuleFrame.titleBarHeight,
        child: Center(
          child: SizedBox(
            width: 10,
            height: 8,
            child: CustomPaint(painter: _MenuGlyphPainter(colors.textFaint)),
          ),
        ),
      ),
    );
  }
}

class _MenuGlyphPainter extends CustomPainter {
  const _MenuGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = OaaStroke.hairline
      ..isAntiAlias = false;

    for (var i = 0; i < 3; i++) {
      final y = i * (size.height / 2);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_MenuGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Shown in place of a module that has been resized below the point where it
/// can be read.
///
/// Decibel does the same thing, and it is the right call: a spectrum analyser
/// squeezed into two grid cells is not a small spectrum analyser, it is a
/// smear that still costs a full FFT to draw. Saying "too small" is more useful
/// and considerably cheaper.
class ModuleTooSmall extends StatelessWidget {
  const ModuleTooSmall({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    // Inert, like every other meter body: this stands in for a module and must
    // not stop the canvas selecting or dragging the module it stands in for.
    return IgnorePointer(
      child: Center(
        child: Text(
          'TOO SMALL',
          style: OaaType.label.copyWith(color: colors.textFaint),
        ),
      ),
    );
  }
}
