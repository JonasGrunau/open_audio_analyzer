// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// Keyboard focus, activation and screen-reader identity for the controls Bel
/// paints itself.
///
/// Bel draws its own controls rather than using Material's, and that is a good
/// decision — a stock `Switch` arrives 60 px wide with a ripple and a spring
/// curve and looks like it came from a phone. What it costs is everything
/// Material was quietly providing underneath: a `MouseRegion` wrapped around a
/// `GestureDetector` cannot be reached by Tab, cannot be activated by Enter or
/// Space, draws no focus ring, and is invisible to every assistive technology
/// on every platform. Nothing about the rendered result says so, which is why
/// five painted primitives shipped that way and the sixth would have too.
///
/// This is the one place that puts it back. A control built through here is
/// focusable, activates on Enter and Space, and announces itself; a control
/// that reaches for `GestureDetector` directly is a control somebody will not
/// be able to use, so do not add one.
///
/// **The focus ring is a hairline in `textPrimary`, and selection is
/// `hairlineStrong` at emphasis weight.** They are deliberately different in
/// both colour and thickness, because focus and selection are separate facts
/// that are usually true at the same time — the selected preset in a list is
/// normally also the focused row — and distinguishing them by brightness alone
/// at equal weight is not a thing anybody should have to do while working.
/// [builder] receives `focused` so each control can apply the ring to its own
/// border rather than have an outer ring bolted around a shape this widget
/// cannot see. The convention is one line:
/// `focused ? colors.textPrimary : <the border it would otherwise have>`.
class BelFocusable extends StatefulWidget {
  const BelFocusable({
    required this.onActivate,
    required this.builder,
    this.semanticLabel,
    this.button = true,
    this.toggled,
    this.selected,
    super.key,
  });

  /// The action. **Null disables the control** — it stops taking focus, stops
  /// responding to the keyboard and announces itself as disabled, which is the
  /// same contract `BelButton` already had for the mouse.
  final VoidCallback? onActivate;

  /// Builds the control. Receives whether it is hovered and whether it holds
  /// keyboard focus, in that order.
  final Widget Function(BuildContext context, bool hovered, bool focused)
  builder;

  /// Required only for controls whose child is a glyph or nothing at all — a
  /// toggle, an icon target. Where the control contains its own text, that text
  /// is merged into the announcement and this should be left null rather than
  /// duplicated.
  final String? semanticLabel;

  /// False for a row that selects rather than acts.
  final bool button;

  /// Set on a control with an on and an off, so it is announced as a switch
  /// rather than as a button that mysteriously does nothing visible.
  final bool? toggled;

  /// Set on a control that is one of a set, so its state is announced.
  final bool? selected;

  @override
  State<BelFocusable> createState() => _BelFocusableState();
}

class _BelFocusableState extends State<BelFocusable> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onActivate != null;

    // Merged so the control and the text inside it are announced as one thing.
    // Without this a button reads as a button with no name, followed by a
    // separate unrelated label.
    return MergeSemantics(
      child: Semantics(
        container: true,
        enabled: enabled,
        button: widget.button && widget.toggled == null,
        toggled: widget.toggled,
        selected: widget.selected,
        label: widget.semanticLabel,
        onTap: enabled ? widget.onActivate : null,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onActivate?.call();
                return null;
              },
            ),
          },
          // Guarded rather than assigned: these fire on every pointer move
          // across the control, and an unguarded setState would rebuild the
          // subtree continuously while the mouse simply rests on a button.
          onShowHoverHighlight: (value) {
            if (value != _hovered) setState(() => _hovered = value);
          },
          onShowFocusHighlight: (value) {
            if (value != _focused) setState(() => _focused = value);
          },
          child: GestureDetector(
            onTap: widget.onActivate,
            behavior: HitTestBehavior.opaque,
            child: widget.builder(context, _hovered, _focused),
          ),
        ),
      ),
    );
  }
}
