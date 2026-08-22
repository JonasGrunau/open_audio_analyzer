// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/semantics.dart';
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
/// A control whose value is a *point* comes through [OaaFocusable.plane]. There
/// is exactly one — the saturation/value square in the colour picker — and it
/// exists because a range cannot be made to serve: [OaaFocusable.range] binds
/// right *and* up to `onIncrease`, which is right for a slider drawn either way
/// round and useless for a surface where the two axes are different quantities.
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
    this.focusNode,
    this.button = true,
    this.toggled,
    this.selected,
    super.key,
  }) : onIncrease = null,
       onDecrease = null,
       onNudge = null,
       valueLabel = null,
       increasedLabel = null,
       decreasedLabel = null,
       nudgeLabels = null,
       _kind = _FocusableKind.button;

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
    this.focusNode,
    super.key,
  }) : onActivate = null,
       onNudge = null,
       nudgeLabels = null,
       button = false,
       toggled = null,
       selected = null,
       _kind = _FocusableKind.range;

  /// A control whose value is a point on a surface: the colour picker's
  /// saturation/value square, and nothing else so far.
  ///
  /// [OaaFocusable.range] cannot be bent into this. It binds right and up to
  /// the same callback on purpose — a slider drawn horizontally is still
  /// reached vertically by anybody who learned it on a volume control — and on
  /// a plane the horizontal and vertical axes are two different quantities.
  ///
  /// So the four arrows are separate here, and [onNudge] receives which way in
  /// units of one step: `Offset(-1, 0)` for left, `Offset(0, 1)` for down.
  /// Holding shift multiplies the step by ten, because crossing a
  /// two-hundred-pixel square one step at a time is not an interaction anybody
  /// completes.
  ///
  /// **Assistive technology reaches it through custom actions rather than
  /// through increase and decrease**, which are a one-dimensional pair and
  /// would silently expose half the control. [nudgeLabels] names the four in
  /// the words a screen reader reads out — "Less saturated", not "Left" — and
  /// is required for that reason.
  ///
  /// Like a range, it installs no pointer handling of its own: where a press
  /// landed *is* the value it sets, so [builder] brings the detector.
  const OaaFocusable.plane({
    required this.onNudge,
    required this.valueLabel,
    required this.nudgeLabels,
    required this.builder,
    this.semanticLabel,
    this.focusNode,
    super.key,
  }) : onActivate = null,
       onIncrease = null,
       onDecrease = null,
       increasedLabel = null,
       decreasedLabel = null,
       button = false,
       toggled = null,
       selected = null,
       _kind = _FocusableKind.plane;

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

  /// Supplied by a control that has to be able to focus *itself*.
  ///
  /// A `FocusableActionDetector` is reached by Tab and not by a click, which is
  /// right for a button — clicking one runs it, and there is nothing left to
  /// do with the keyboard afterwards. It is wrong for a value: somebody who has
  /// just clicked a point on a colour plane is exactly the person who wants to
  /// nudge it one step, and being told to Tab back to the thing under their
  /// pointer is not an answer. A control that wants that owns the node and
  /// requests it on the way down.
  final FocusNode? focusNode;

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

  /// One step in a direction, for a plane control. `Offset(1, 0)` is one step
  /// right; `Offset(0, -1)` is one step up. Magnitudes above one are a held
  /// shift.
  final void Function(Offset delta)? onNudge;

  /// What the four directions of a plane control are called, in the order
  /// left, right, up, down. Read out by assistive technology as the control's
  /// custom actions.
  final ({String left, String right, String up, String down})? nudgeLabels;

  /// What it would read out one step up, and one step down.
  ///
  /// **Not optional, and not decoration.** A semantics node that offers the
  /// increase action while carrying a value has to say what the value would
  /// become — Flutter asserts on one without the other — and the assertion is
  /// right: "slider, -12.0 dB" with no idea what a press does is a control
  /// operated blind.
  final String? increasedLabel;
  final String? decreasedLabel;

  /// Which of the three shapes this is. Decides the announcement, the
  /// shortcuts, the cursor and whether this widget installs a detector.
  final _FocusableKind _kind;

  @override
  State<OaaFocusable> createState() => _OaaFocusableState();
}

class _OaaFocusableState extends State<OaaFocusable> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final range = widget._kind == _FocusableKind.range;
    final plane = widget._kind == _FocusableKind.plane;
    final enabled =
        widget.onActivate != null ||
        widget.onIncrease != null ||
        widget.onDecrease != null ||
        widget.onNudge != null;

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
        // Four named actions rather than an increase/decrease pair, because a
        // plane has two axes and the pair describes one. Built here rather
        // than in the widget so the labels stay next to what they invoke.
        customSemanticsActions: plane ? _planeActions() : null,
        child: FocusableActionDetector(
          enabled: enabled,
          focusNode: widget.focusNode,
          // A range control is dragged rather than clicked, and the cursor says
          // which of the two it is before the press. A plane is dragged in both
          // directions at once, which is what the crosshair means everywhere
          // else.
          mouseCursor: !enabled
              ? SystemMouseCursors.basic
              : range
              ? SystemMouseCursors.resizeLeftRight
              : plane
              ? SystemMouseCursors.precise
              : SystemMouseCursors.click,
          shortcuts: range
              ? _rangeShortcuts
              : plane
              ? _planeShortcuts
              : null,
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
            if (plane)
              OaaNudgeIntent: CallbackAction<OaaNudgeIntent>(
                onInvoke: (intent) {
                  widget.onNudge?.call(intent.delta);
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
          child: widget._kind == _FocusableKind.button
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

  Map<CustomSemanticsAction, VoidCallback> _planeActions() {
    final labels = widget.nudgeLabels!;
    final nudge = widget.onNudge;
    if (nudge == null) return const {};

    return {
      CustomSemanticsAction(label: labels.left): () =>
          nudge(const Offset(-1, 0)),
      CustomSemanticsAction(label: labels.right): () =>
          nudge(const Offset(1, 0)),
      CustomSemanticsAction(label: labels.up): () => nudge(const Offset(0, -1)),
      CustomSemanticsAction(label: labels.down): () =>
          nudge(const Offset(0, 1)),
    };
  }
}

/// Which of [OaaFocusable]'s three shapes a given instance is.
enum _FocusableKind { button, range, plane }

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

/// One step of a plane control, in units of a step.
class OaaNudgeIntent extends Intent {
  const OaaNudgeIntent(this.delta);

  /// Which way, and how far in steps. Screen coordinates: `y` grows downwards,
  /// the same direction the surface is painted in, so a control converts one
  /// axis and not the other.
  final Offset delta;
}

/// The four arrows on two axes, and the same four with shift held for ten
/// steps at a time.
///
/// **Shift is not a nicety.** The one plane control is a saturation/value
/// square around two hundred pixels across; at one step a press, crossing it is
/// a hundred presses, which is a control that is technically reachable and
/// practically not.
const Map<ShortcutActivator, Intent> _planeShortcuts = {
  SingleActivator(LogicalKeyboardKey.arrowLeft): OaaNudgeIntent(Offset(-1, 0)),
  SingleActivator(LogicalKeyboardKey.arrowRight): OaaNudgeIntent(Offset(1, 0)),
  SingleActivator(LogicalKeyboardKey.arrowUp): OaaNudgeIntent(Offset(0, -1)),
  SingleActivator(LogicalKeyboardKey.arrowDown): OaaNudgeIntent(Offset(0, 1)),
  SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): OaaNudgeIntent(
    Offset(-10, 0),
  ),
  SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): OaaNudgeIntent(
    Offset(10, 0),
  ),
  SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): OaaNudgeIntent(
    Offset(0, -10),
  ),
  SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): OaaNudgeIntent(
    Offset(0, 10),
  ),
};
