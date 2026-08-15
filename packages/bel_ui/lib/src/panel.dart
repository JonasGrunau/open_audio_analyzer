// SPDX-License-Identifier: GPL-3.0-or-later

/// The chrome every Bel panel is built from.
///
/// Settings, the preset browser, the calibration editor and the Phase 5 report
/// all want the same thing: a bordered surface over the canvas, a title, a way
/// out, sections of labelled rows, and controls that look like the rest of the
/// instrument rather than like Material. Written once here, they cannot drift;
/// written per panel, they will.
///
/// Nothing in this file is a meter and nothing in it repaints per frame, so the
/// no-allocation-in-paint rule that governs `lib/src/modules/` does not apply —
/// these are ordinary widgets that rebuild when a human does something.
library;

import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

/// Shows [child] as a modal panel over the canvas.
///
/// **The palette has to be carried in by hand.** A route pushed with
/// `showGeneralDialog` is built by the [Navigator], which lives *above* the
/// `BelTheme` the application installs — so `BelTheme.of` inside a panel would
/// find nothing and assert. Reading the palette at the call site and
/// re-providing it inside the route is the fix, and it is invisible until the
/// first panel throws.
Future<T?> showBelPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final colors = BelTheme.of(context);

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // Dimming towards the palette's own background rather than towards black:
    // on a light skin a black scrim is a bruise across the middle of a pale
    // interface.
    barrierColor: colors.background.withValues(alpha: 0.72),
    // No slide, no scale, no fade beyond the barrier's own. A panel that
    // animates in is a panel you wait for, and this one is opened to change a
    // number and closed again.
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => BelTheme(
      colors: colors,
      child: Builder(builder: builder),
    ),
  );
}

/// A panel surface: title bar, scrolling body, optional footer.
class PanelScaffold extends StatelessWidget {
  const PanelScaffold({
    required this.title,
    required this.child,
    this.onClose,
    this.footer,
    this.width = 620,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback? onClose;

  /// Actions along the bottom. Laid out end-aligned by the caller.
  final Widget? footer;

  /// The panel's maximum width. Panels are read left to right in short lines;
  /// letting one span a 32" display makes a label and its control land at
  /// opposite ends of the desk.
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: 760),
          child: ClipRRect(
            borderRadius: BelRadius.allMd,
            // **A `Material` here is not decoration.** A panel is pushed as a
            // route, so it is built by the Navigator — *outside* the `Material`
            // the application wraps its canvas in. Every stock widget a panel
            // reaches for that draws an ink response, `PopupMenuButton` and
            // `TextField` among them, asserts "No Material widget found" and is
            // replaced by an error box. The error box then reports an intrinsic
            // width near 100 000 px, so the first thing anybody sees is a
            // RenderFlex overflow pointing at a `Row` that is perfectly fine.
            child: Material(
              color: colors.panel,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: colors.hairline,
                    width: BelStroke.hairline,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TitleBar(title: title, onClose: onClose),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.lg,
                          vertical: Space.md,
                        ),
                        child: child,
                      ),
                    ),
                    if (footer != null) ...[
                      _Hairline(colors: colors),
                      Padding(
                        padding: const EdgeInsets.all(Space.smd),
                        child: footer,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title, this.onClose});

  final String title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.smd,
            Space.sm,
            Space.smd,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: BelType.label.copyWith(
                    color: colors.textPrimary,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (onClose != null)
                _IconTarget(
                  tooltip: 'Close',
                  onPressed: onClose!,
                  child: Text(
                    '×',
                    style: BelType.reading(
                      18,
                    ).copyWith(color: colors.textMuted),
                  ),
                ),
            ],
          ),
        ),
        _Hairline(colors: colors),
      ],
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline({required this.colors});

  final BelColors colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: colors.hairline,
    child: const SizedBox(height: BelStroke.hairline, width: double.infinity),
  );
}

/// A labelled group of rows.
class PanelSection extends StatelessWidget {
  const PanelSection({
    required this.title,
    required this.children,
    this.note,
    super.key,
  });

  final String title;

  /// One line under the heading, for the thing a user would otherwise have to
  /// learn by trying it.
  final String? note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: BelType.label.copyWith(color: colors.textMuted),
          ),
          if (note != null) ...[
            const SizedBox(height: Space.xs),
            Text(
              note!,
              style: BelType.caption.copyWith(color: colors.textFaint),
            ),
          ],
          const SizedBox(height: Space.sm),
          ...children,
        ],
      ),
    );
  }
}

/// A label on the left, a control on the right.
class PanelRow extends StatelessWidget {
  const PanelRow({
    required this.label,
    required this.child,
    this.note,
    super.key,
  });

  final String label;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: BelType.body.copyWith(color: colors.textPrimary),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: BelType.caption.copyWith(color: colors.textFaint),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Space.md),
          child,
        ],
      ),
    );
  }
}

/// A selectable row: the preset browser's list, the skin list.
class PanelListRow extends StatefulWidget {
  const PanelListRow({
    required this.title,
    this.note,
    this.selected = false,
    this.onTap,
    this.trailing,
    super.key,
  });

  final String title;
  final String? note;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  State<PanelListRow> createState() => _PanelListRowState();
}

class _PanelListRowState extends State<PanelListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.only(bottom: Space.xs),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.smd,
            vertical: Space.sm,
          ),
          decoration: BoxDecoration(
            color: _hovered ? colors.panelRaised : null,
            borderRadius: BelRadius.allSm,
            border: Border.all(
              color: widget.selected ? colors.accent : colors.hairline,
              width: BelStroke.hairline,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BelType.body.copyWith(
                        color: widget.selected
                            ? colors.accent
                            : colors.textPrimary,
                      ),
                    ),
                    if (widget.note != null)
                      Text(
                        widget.note!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: BelType.caption.copyWith(
                          color: colors.textFaint,
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: Space.sm),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One choice from a short, fixed set.
///
/// For anything with more than about five options, or options that arrive at
/// runtime, use a menu instead — a segmented control that wraps onto two lines
/// has stopped being one control.
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    required this.segments,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final List<({T value, String label})> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BelRadius.allSm,
        border: Border.all(color: colors.hairline, width: BelStroke.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final segment in segments)
            GestureDetector(
              onTap: () => onChanged(segment.value),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.smd,
                  vertical: Space.xs + Space.xxs,
                ),
                decoration: BoxDecoration(
                  color: segment.value == value ? colors.panelRaised : null,
                  borderRadius: BelRadius.allSm,
                ),
                child: Text(
                  segment.label,
                  style: BelType.caption.copyWith(
                    color: segment.value == value
                        ? colors.accent
                        : colors.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A button. Three weights and no more.
class BelButton extends StatefulWidget {
  const BelButton({
    required this.label,
    required this.onPressed,
    this.emphasis = ButtonEmphasis.normal,
    super.key,
  });

  final String label;

  /// Null disables the button. A disabled button that still looks live is worse
  /// than no button.
  final VoidCallback? onPressed;
  final ButtonEmphasis emphasis;

  @override
  State<BelButton> createState() => _BelButtonState();
}

enum ButtonEmphasis { normal, primary, destructive }

class _BelButtonState extends State<BelButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final enabled = widget.onPressed != null;

    final accent = switch (widget.emphasis) {
      ButtonEmphasis.normal => colors.textMuted,
      ButtonEmphasis.primary => colors.accent,
      ButtonEmphasis.destructive => colors.over,
    };

    final border = switch (widget.emphasis) {
      ButtonEmphasis.normal =>
        _hovered ? colors.hairlineStrong : colors.hairline,
      _ => accent,
    };

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.smd,
            vertical: Space.sm,
          ),
          decoration: BoxDecoration(
            color: _hovered && enabled ? colors.panelRaised : null,
            borderRadius: BelRadius.allSm,
            border: Border.all(
              color: enabled ? border : colors.hairline,
              width: BelStroke.hairline,
            ),
          ),
          child: Text(
            widget.label.toUpperCase(),
            style: BelType.label.copyWith(
              color: enabled ? accent : colors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

/// A boolean.
///
/// Painted rather than a Material `Switch`, which arrives 60 px wide with a
/// ripple and a spring curve and looks like it came from a phone.
class BelToggle extends StatelessWidget {
  const BelToggle({required this.value, required this.onChanged, super.key});

  final bool value;
  final ValueChanged<bool> onChanged;

  static const double _width = 34;
  static const double _height = 18;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _width,
          height: _height,
          decoration: BoxDecoration(
            color: value ? colors.accent : colors.meterTrack,
            borderRadius: const BorderRadius.all(Radius.circular(_height / 2)),
            border: Border.all(
              color: value ? colors.accent : colors.hairlineStrong,
              width: BelStroke.hairline,
            ),
          ),
          child: Align(
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.all(Space.xxs),
              child: Container(
                width: _height - Space.sm,
                height: _height - Space.sm,
                decoration: BoxDecoration(
                  color: value ? colors.background : colors.textFaint,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single-line text input.
///
/// Numbers typed into one of these are monospaced with tabular figures like
/// every other number in the interface — a calibration's true-peak ceiling is a
/// measurement even while it is being edited.
class BelTextField extends StatelessWidget {
  const BelTextField({
    required this.controller,
    this.hintText,
    this.onSubmitted,
    this.onChanged,
    this.numeric = false,
    this.autofocus = false,
    this.width,
    super.key,
  });

  final TextEditingController controller;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool numeric;
  final bool autofocus;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final style = numeric
        ? BelType.readingSmall.copyWith(color: colors.textPrimary)
        : BelType.body.copyWith(color: colors.textPrimary);

    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BelRadius.allSm,
          border: Border.all(color: colors.hairline, width: BelStroke.hairline),
        ),
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          style: style,
          cursorColor: colors.accent,
          cursorWidth: BelStroke.hairline,
          textAlign: numeric ? TextAlign.right : TextAlign.start,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                )
              : TextInputType.text,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          decoration: InputDecoration.collapsed(
            hintText: hintText,
            hintStyle: style.copyWith(color: colors.textFaint),
          ),
        ),
      ),
    );
  }
}

/// A target for an icon or glyph, sized so it can actually be hit.
class _IconTarget extends StatelessWidget {
  const _IconTarget({
    required this.child,
    required this.onPressed,
    required this.tooltip,
  });

  final Widget child;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: Space.lg,
          height: Space.lg,
          child: Center(child: child),
        ),
      ),
    ),
  );
}
