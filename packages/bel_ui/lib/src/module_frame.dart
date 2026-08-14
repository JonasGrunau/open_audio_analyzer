// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

import 'theme.dart';
import 'tokens.dart';

/// The chrome every meter module sits inside.
///
/// All twelve modules are this frame plus a painter. That is the whole reuse
/// strategy, and it is deliberate: a module that also owns its own border, its
/// own title treatment and its own menu affordance is a module that will drift
/// from the other eleven, and eleven near-identical borders is exactly how an
/// interface stops looking designed.
///
/// The frame is a [StatelessWidget] and stays out of the per-frame path
/// entirely. The title does not change 60 times a second; only [child] repaints,
/// and it does so inside a [RepaintBoundary] so that a spectrum analyser
/// redrawing cannot dirty the panel border around it.
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

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BelRadius.allSm,
        border: Border.all(
          color: selected ? colors.accent : colors.hairline,
          width: BelStroke.hairline,
        ),
      ),
      child: Column(
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
              padding: const EdgeInsets.all(Space.sm),
              // Isolates the meter's repaints from the frame around it. Without
              // this, a spectrogram scrolling at 60 fps marks the whole panel
              // dirty and the border is re-rastered along with it.
              child: RepaintBoundary(child: child),
            ),
          ),
        ],
      ),
    );
  }
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colors.hairline,
              width: BelStroke.hairline,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: BelType.label.copyWith(color: colors.textMuted),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Space.sm),
                DefaultTextStyle(
                  style: BelType.tick.copyWith(color: colors.textFaint),
                  child: trailing!,
                ),
              ],
              if (onMenu != null) ...[
                const SizedBox(width: Space.sm),
                _MenuButton(onPressed: onMenu!, colors: colors),
              ],
            ],
          ),
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
    return Center(
      child: Text(
        'TOO SMALL',
        style: BelType.label.copyWith(color: colors.textFaint),
      ),
    );
  }
}
