// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

import 'meter_painter.dart';
import 'theme.dart';
import 'tokens.dart';

/// The chrome every meter module sits inside.
///
/// All thirteen modules are this frame plus a painter. That is the whole reuse
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
class ModuleFrame extends StatelessWidget {
  const ModuleFrame({
    required this.title,
    required this.child,
    this.trailing,
    this.selected = false,
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

  final VoidCallback? onMenu;

  /// Height of the title bar. Modules subtract this when deciding whether they
  /// have room to draw.
  static const double titleBarHeight = 24;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _FramePainter(
            fill: colors.panel,
            // Selection is weight and brightness, never the signal hue. A
            // module outlined in `accent` is outlined in the colour that means
            // "in spec" everywhere else on this canvas, and here the two are
            // adjacent by construction — the border literally touches the
            // reading it would be confused with.
            border: selected ? colors.hairlineStrong : colors.hairline,
            borderWidth: selected ? BelStroke.emphasis : BelStroke.hairline,
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
            Expanded(
              child: Padding(
                // The same on all four sides, and the same value the title bar
                // insets by — the title's left edge is the meter's left edge,
                // and two paddings that differ by four pixels read as a
                // misalignment rather than as a decision. This is the *only*
                // margin a module gets: painters draw to the edges of what
                // they are handed, so a painter that adds a second inset of
                // its own is a module that no longer matches the other eleven.
                padding: const EdgeInsets.all(Space.smd),
                // Isolates the meter's repaints from the frame around it.
                // Without this, a spectrogram scrolling at 60 fps marks the
                // whole panel dirty and the border is re-rastered along with it.
                child: RepaintBoundary(child: child),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The panel fill, its hairline border and the rule under the title.
class _FramePainter extends MeterPainter {
  _FramePainter({
    required this.fill,
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
         ..strokeWidth = BelStroke.hairline
         ..isAntiAlias = false);

  final Color fill;
  final Color border;
  final double borderWidth;
  final Color rule;

  final Paint _fillPaint;
  final Paint _borderPaint;
  final Paint _rulePaint;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectAndRadius(bounds, BelRadius.sm), _fillPaint);
    // Inset by half the stroke so a hairline lands inside the panel rather than
    // straddling its edge, where it renders as two grey half-pixels.
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds.deflate(borderWidth / 2), BelRadius.sm),
      _borderPaint,
    );
    // Stops at the border's inner edge rather than running to the panel edge.
    // A full-width rule is drawn *after* the border and in the dim hairline
    // colour, so it punched two notches out of the selection outline — at
    // `BelStroke.emphasis` that is a visible break in the one line whose whole
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
  final BelColors colors;

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
            // and text absorbs pointer events — see this file's header.
            Expanded(
              child: IgnorePointer(
                child: Text(
                  title.toUpperCase(),
                  style: BelType.label.copyWith(color: colors.textMuted),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Space.sm),
              IgnorePointer(
                child: DefaultTextStyle(
                  style: BelType.tick.copyWith(color: colors.textFaint),
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
  final BelColors colors;

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
      ..strokeWidth = BelStroke.hairline
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
    final colors = BelTheme.of(context);
    // Inert, like every other meter body: this stands in for a module and must
    // not stop the canvas selecting or dragging the module it stands in for.
    return IgnorePointer(
      child: Center(
        child: Text(
          'TOO SMALL',
          style: BelType.label.copyWith(color: colors.textFaint),
        ),
      ),
    );
  }
}
