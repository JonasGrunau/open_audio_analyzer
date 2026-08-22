// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'drag_devices.dart';
import 'focusable.dart';
import 'theme.dart';
import 'tokens.dart';

/// A value dragged rather than chosen: the oscilloscope's height and its
/// trigger level.
///
/// **The one control in this application that lives on a meter rather than in a
/// panel,** which is what most of the decisions below follow from. It is short
/// enough to sit inside a module without taking the picture's room, it is drawn
/// in chrome colours so it cannot be mistaken for a reading, and it takes the
/// signal hue for nothing at all — on the measurement surface `accent` means
/// "in spec" and a slider is not a verdict. See [OaaColors.accent].
///
/// ---------------------------------------------------------------------------
/// Continuous while dragging, committed once
///
/// [onChanged] fires per pointer event and [onChangeEnd] once, at the end. A
/// caller whose value is layout state — which is every caller here, because a
/// module's settings live in the preset — has to keep those apart: the canvas's
/// undo history is a stack of whole workspaces and its autosave watches the
/// same provider, so writing per pointer event would spend sixty history
/// entries and sixty JSON encodings on one gesture, and a display on the other
/// end of a socket would receive sixty layouts. The live value belongs in the
/// widget that is drawing, the committed one in the layout.
///
/// The keyboard is the other case and it commits every press. A keystroke is a
/// discrete edit and there is no gesture around it to be the end of.
class OaaSlider extends StatefulWidget {
  const OaaSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.onChangeEnd,
    required this.format,
    this.semanticLabel,
    this.enabled = true,
    super.key,
  });

  /// Where the thumb sits, in the caller's own units.
  ///
  /// Linear between [min] and [max], and deliberately not curved here: a
  /// control that has to feel logarithmic passes the logarithm. The
  /// oscilloscope's height is in octaves for that reason, and its trigger level
  /// is in dB, which is already one.
  final double value;
  final double min;
  final double max;

  /// One press of an arrow key, in the same units.
  final double step;

  /// Fires continuously while the control is dragged.
  final ValueChanged<double> onChanged;

  /// Fires once, when the gesture ends or a key is pressed. **This is the one
  /// to persist** — see the class comment.
  final ValueChanged<double> onChangeEnd;

  /// The value in words, for the screen reader — and for the caller's own
  /// readout, which should be the same string.
  ///
  /// A function rather than a string because a slider has to announce what one
  /// press *would* do as well as where it is: "50 percent" of a range nobody
  /// can see is a control that cannot be operated by ear, and a value with no
  /// next value is one that cannot be aimed.
  final String Function(double value) format;

  /// What this sets. The control carries no text of its own.
  ///
  /// It must be given a bounded width: it fills the room it is handed, the way
  /// a track does, and has no natural length of its own.
  final String? semanticLabel;

  /// False for a value that something else is setting.
  ///
  /// The oscilloscope's trigger level while `AUTO` is checked: the number is
  /// still live and the thumb still moves, because it is following the audio,
  /// and a control that hid where the value had got to would be worse than one
  /// that cannot be dragged. So the track stays drawn — in
  /// [OaaColors.textFaint] rather than chrome ink — and the pointer, the arrow
  /// keys and the focus traversal all pass over it. It announces itself as
  /// disabled rather than quietly ignoring what is done to it.
  final bool enabled;

  /// The row a slider occupies. Deliberately half the height of a panel
  /// control: [OaaControl.height] is sized for a row of buttons and a module
  /// has a waveform to draw.
  static const double height = Space.md;

  /// The thumb, and the inset at each end of the track that it needs — the
  /// travel is the width less one thumb, so the drawn thumb never hangs over
  /// an edge and the ends of the track are the ends of the range.
  static const double _thumb = Space.sm;

  @override
  State<OaaSlider> createState() => _OaaSliderState();
}

class _OaaSliderState extends State<OaaSlider> {
  /// The track, measured where the pointer is handled.
  ///
  /// **Not a `LayoutBuilder` around the detector**, which is the obvious way to
  /// learn the width and is a trap: a `LayoutBuilder` re-runs its builder in
  /// the next *layout* pass, so the callbacks the recogniser holds are the ones
  /// built for the previous frame. A drag is a run of pointer events inside one
  /// frame, and the value committed at the end of it was then the value the
  /// control had before the gesture began — every drag wrote back where it had
  /// started from.
  final GlobalKey _track = GlobalKey();

  /// The last value this control reported, for the end of the gesture.
  ///
  /// Read back rather than taken from `widget.value` for the same reason: the
  /// release arrives in the same frame as the move before it, so the widget
  /// still carries the value from before the drag.
  double? _dragged;

  double get _span => widget.max - widget.min;

  double _valueAt(double dx) {
    final width = _track.currentContext?.size?.width ?? 0;
    final travel = width - OaaSlider._thumb;
    if (travel <= 0) return widget.value;
    final fraction = ((dx - OaaSlider._thumb / 2) / travel).clamp(0.0, 1.0);
    return widget.min + fraction * _span;
  }

  void _report(double value) {
    _dragged = value;
    widget.onChanged(value);
  }

  void _commit(double value) {
    _dragged = null;
    widget.onChangeEnd(value);
  }

  void _nudge(int direction) {
    final next = (widget.value + direction * widget.step).clamp(
      widget.min,
      widget.max,
    );
    if (next == widget.value) return;
    widget.onChanged(next);
    widget.onChangeEnd(next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    // Drawn the same whether or not it can be dragged. Where the value has got
    // to is the whole of what this control shows, and a disabled slider is
    // exactly the case where something else is moving it.
    Widget track(bool hovered, bool focused) => CustomPaint(
      key: _track,
      size: Size(double.infinity, OaaSlider.height),
      painter: _SliderPainter(
        fraction: _span <= 0
            ? 0
            : ((widget.value - widget.min) / _span).clamp(0.0, 1.0),
        groove: colors.meterTrack,
        // Focus is a hairline in `textPrimary` everywhere else in the
        // interface, and a slider has no border to put one on — so it is the
        // thumb that brightens, and hover with it. A ring drawn around a 16 px
        // row inside a module would read as a second module frame.
        ink: !widget.enabled
            ? colors.textFaint
            : focused || hovered
            ? colors.textPrimary
            : colors.textMuted,
        thumb: OaaSlider._thumb,
      ),
    );

    return OaaFocusable.range(
      // Null rather than a callback that does nothing: it is what tells the
      // focusable this control is disabled, which is what takes it out of the
      // traversal order, off the arrow keys and out of the pointer's cursor.
      onIncrease: widget.enabled ? () => _nudge(1) : null,
      onDecrease: widget.enabled ? () => _nudge(-1) : null,
      valueLabel: widget.format(widget.value),
      increasedLabel: widget.format(
        (widget.value + widget.step).clamp(widget.min, widget.max),
      ),
      decreasedLabel: widget.format(
        (widget.value - widget.step).clamp(widget.min, widget.max),
      ),
      semanticLabel: widget.semanticLabel,
      builder: (context, hovered, focused) => !widget.enabled
          ? track(hovered, focused)
          : GestureDetector(
              // The whole row, not the hairline in the middle of it. A track is
              // drawn thin because it is chrome and hit at the height of the
              // thumb because it is a control.
              behavior: HitTestBehavior.opaque,
              // Or a two-finger trackpad gesture that begins over the slider
              // moves it, with no slop to cross and no button pressed. See
              // [kDragDevices].
              supportedDevices: kDragDevices,
              // Without this the drag is reported as beginning where it was
              // *recognised* rather than where the pointer went down, so the
              // value jumps by the pan slop the moment it starts moving.
              dragStartBehavior: DragStartBehavior.down,
              onTapDown: (details) =>
                  _report(_valueAt(details.localPosition.dx)),
              onTapUp: (details) => _commit(_valueAt(details.localPosition.dx)),
              onHorizontalDragStart: (details) =>
                  _report(_valueAt(details.localPosition.dx)),
              onHorizontalDragUpdate: (details) =>
                  _report(_valueAt(details.localPosition.dx)),
              onHorizontalDragEnd: (_) => _commit(_dragged ?? widget.value),
              onHorizontalDragCancel: () => _commit(_dragged ?? widget.value),
              child: track(hovered, focused),
            ),
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({
    required this.fraction,
    required this.groove,
    required this.ink,
    required this.thumb,
  });

  final double fraction;
  final Color groove;
  final Color ink;
  final double thumb;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = (size.height / 2).roundToDouble();
    final travel = size.width - thumb;
    if (travel <= 0) return;
    final at = (thumb / 2 + fraction * travel).roundToDouble();

    final line = Paint()
      ..strokeWidth = OaaStroke.mark
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(thumb / 2, centre),
      Offset(size.width - thumb / 2, centre),
      line..color = groove,
    );
    // The travelled part of the track is drawn over the groove rather than
    // instead of it, so the two agree about where the middle of the row is at
    // every value including the ends.
    if (at > thumb / 2) {
      canvas.drawLine(
        Offset(thumb / 2, centre),
        Offset(at, centre),
        line..color = ink,
      );
    }
    canvas.drawCircle(Offset(at, centre), thumb / 2, Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.fraction != fraction ||
      old.groove != groove ||
      old.ink != ink ||
      old.thumb != thumb;
}
