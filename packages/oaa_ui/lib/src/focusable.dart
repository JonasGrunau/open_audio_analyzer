// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keyboard focus, activation and screen-reader identity for the controls Open
/// Audio Analyzer paints itself.
///
/// Open Audio Analyzer draws its own controls rather than using Material's, and
/// that is a good decision — a stock `Switch` arrives 60 px wide with a ripple
/// and a spring curve and looks like it came from a phone. What it costs is
/// everything Material was quietly providing underneath: a `MouseRegion`
/// wrapped around a
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
/// A control whose value is a *range* comes through [OaaFocusable.range]
/// instead, which is the same widget with the three differences a slider forces
/// — the arrows rather than Enter, a slider's announcement rather than a
/// button's, and its own pointer handling, because where a press landed is the
/// value it sets.
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
class OaaFocusable extends StatefulWidget {
  const OaaFocusable({
    required this.onActivate,
    required this.builder,
    this.semanticLabel,
    this.button = true,
    this.toggled,
    this.selected,
    super.key,
  }) : onIncrease = null,
       onDecrease = null,
       valueLabel = null,
       increasedLabel = null,
       decreasedLabel = null,
       _takesPointer = true;

  /// A control whose value is a range rather than a state: a slider.
  ///
  /// Three things about a range control are different, and every one of them is
  /// forced by what it is rather than chosen.
  ///
  /// **The arrow keys move it.** Enter and Space have nothing to do to a value,
  /// so [onActivate] is not part of this constructor and the shortcuts below
  /// are. They are installed on the control's own [FocusableActionDetector],
  /// which is what lets them win against the application's global bindings —
  /// the canvas moves the selected module with the same four keys, and a key
  /// event travels *up* from the focused node, so the innermost handler is the
  /// one that answers. Nothing else in the application overrides an arrow.
  ///
  /// **It is announced as a slider carrying [valueLabel].** A screen reader
  /// reading "button" for a level is reading a control the listener cannot
  /// operate; `onIncrease` and `onDecrease` are what an assistive technology
  /// adjusts it through, and they are the same two callbacks the keys use.
  ///
  /// **It takes its own pointer input.** Where a press landed *is* the value it
  /// sets, and a tap callback carries no position — so [builder] provides the
  /// detector, and this widget installs none of its own. Two detectors, one
  /// here and one in the control, would put two tap recognisers in the same
  /// arena for every press.
  const OaaFocusable.range({
    required this.onIncrease,
    required this.onDecrease,
    required this.valueLabel,
    required this.increasedLabel,
    required this.decreasedLabel,
    required this.builder,
    this.semanticLabel,
    super.key,
  }) : onActivate = null,
       button = false,
       toggled = null,
       selected = null,
       _takesPointer = false;

  /// The action. **Null disables the control** — it stops taking focus, stops
  /// responding to the keyboard and announces itself as disabled, which is the
  /// same contract `OaaButton` already had for the mouse.
  ///
  /// Always null on a [OaaFocusable.range], which is enabled by having an
  /// [onIncrease] or an [onDecrease] instead: a value has no action to
  /// activate.
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

  /// One step up, for a range control. Bound to the right and up arrows.
  final VoidCallback? onIncrease;

  /// One step down. Bound to the left and down arrows.
  final VoidCallback? onDecrease;

  /// What a range control reads out — `-12.0 dB`, `4.0x`. Null on everything
  /// else, which is what tells the two apart.
  final String? valueLabel;

  /// What it would read out one step up, and one step down.
  ///
  /// **Not optional, and not decoration.** A semantics node that offers the
  /// increase action while carrying a value has to say what the value would
  /// become — Flutter asserts on one without the other — and the assertion is
  /// right: "slider, -12.0 dB" with no idea what a press does is a control
  /// operated blind.
  final String? increasedLabel;
  final String? decreasedLabel;

  /// False for [OaaFocusable.range], whose builder brings its own detector.
  final bool _takesPointer;

  @override
  State<OaaFocusable> createState() => _OaaFocusableState();
}

class _OaaFocusableState extends State<OaaFocusable> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final range = widget.valueLabel != null;
    final enabled =
        widget.onActivate != null ||
        widget.onIncrease != null ||
        widget.onDecrease != null;

    // Merged so the control and the text inside it are announced as one thing.
    // Without this a button reads as a button with no name, followed by a
    // separate unrelated label.
    return MergeSemantics(
      child: Semantics(
        container: true,
        enabled: enabled,
        button: widget.button && widget.toggled == null,
        slider: range,
        value: widget.valueLabel,
        increasedValue: widget.increasedLabel,
        decreasedValue: widget.decreasedLabel,
        toggled: widget.toggled,
        selected: widget.selected,
        label: widget.semanticLabel,
        onTap: enabled ? widget.onActivate : null,
        onIncrease: widget.onIncrease,
        onDecrease: widget.onDecrease,
        child: FocusableActionDetector(
          enabled: enabled,
          // A range control is dragged rather than clicked, and the cursor says
          // which of the two it is before the press.
          mouseCursor: !enabled
              ? SystemMouseCursors.basic
              : range
              ? SystemMouseCursors.resizeLeftRight
              : SystemMouseCursors.click,
          shortcuts: range ? _rangeShortcuts : null,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onActivate?.call();
                return null;
              },
            ),
            if (range)
              OaaAdjustIntent: CallbackAction<OaaAdjustIntent>(
                onInvoke: (intent) {
                  if (intent.up) {
                    widget.onIncrease?.call();
                  } else {
                    widget.onDecrease?.call();
                  }
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
          child: widget._takesPointer
              ? GestureDetector(
                  onTap: widget.onActivate,
                  behavior: HitTestBehavior.opaque,
                  child: widget.builder(context, _hovered, _focused),
                )
              : widget.builder(context, _hovered, _focused),
        ),
      ),
    );
  }
}

/// One step of a range control, from a key or from assistive technology.
///
/// Declared here because `flutter/widgets` has none: Material's slider defines
/// its own privately, so a painted one has to bring its own too.
class OaaAdjustIntent extends Intent {
  const OaaAdjustIntent({required this.up});

  final bool up;
}

/// Both axes, because a slider drawn horizontally is still reached vertically
/// by anybody who learned it on a volume control. The four arrows are the only
/// keys a range control claims.
const Map<ShortcutActivator, Intent> _rangeShortcuts = {
  SingleActivator(LogicalKeyboardKey.arrowRight): OaaAdjustIntent(up: true),
  SingleActivator(LogicalKeyboardKey.arrowUp): OaaAdjustIntent(up: true),
  SingleActivator(LogicalKeyboardKey.arrowLeft): OaaAdjustIntent(up: false),
  SingleActivator(LogicalKeyboardKey.arrowDown): OaaAdjustIntent(up: false),
};
