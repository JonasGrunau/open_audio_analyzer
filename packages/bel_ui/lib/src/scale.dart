// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'text_cache.dart';
import 'tokens.dart';

/// A decibel scale, and where a reading sits on it.
///
/// Linear in dB, deliberately. Several hardware meters expand the top of the
/// scale so the last few decibels get more room, and it is tempting — that is
/// where a mastering decision actually happens. It is also how you get a meter
/// whose gridlines are unevenly spaced, which reads as approximate, and whose
/// two halves cannot be compared by eye. A scale you can measure off with a
/// ruler is worth more than one that flatters the top octave, and anything that
/// genuinely needs the resolution gets a narrower range instead.
@immutable
class MeterScale {
  const MeterScale({required this.min, required this.max, required this.step})
    : assert(max > min),
      assert(step > 0);

  /// Bottom of the scale, in dB or LU.
  final double min;

  /// Top of the scale.
  final double max;

  /// Spacing between labelled ticks.
  final double step;

  double get span => max - min;

  /// Where [value] sits, 0 at [min] and 1 at [max]. Clamped: a reading off the
  /// end of the scale pins to the end rather than drawing outside the meter.
  double fractionOf(double value) {
    if (value.isNaN) return 0;
    final fraction = (value - min) / span;
    return fraction < 0 ? 0 : (fraction > 1 ? 1 : fraction);
  }

  /// The inverse, unclamped — for turning a pointer position into a value.
  double valueAt(double fraction) => min + fraction * span;

  /// Every labelled tick from the first multiple of [step] at or above [min].
  List<double> get ticks {
    final result = <double>[];
    final first = (min / step).ceil() * step;
    for (var value = first; value <= max + 1e-9; value += step) {
      // Snap: repeated addition of 0.1-style steps drifts, and a tick labelled
      // "-23.000000000004" is a real thing that happens.
      result.add((value / step).round() * step);
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is MeterScale &&
      other.min == min &&
      other.max == max &&
      other.step == step;

  @override
  int get hashCode => Object.hash(min, max, step);
}

/// Which edge of a meter the scale's labels sit against.
enum ScaleSide {
  /// Labels left of a vertical track, values increasing upwards.
  left,

  /// Labels right of a vertical track, values increasing upwards.
  right,

  /// Labels below a horizontal track, values increasing rightwards.
  bottom,
}

/// The ticks and labels of a [MeterScale], laid out once and painted every
/// frame.
///
/// Built in a module's [State] and rebuilt only when the scale or the palette
/// changes. Four modules draw a dB scale; without this they would each grow
/// their own tick loop, and the ticks on two meters sitting side by side would
/// eventually stop lining up — which looks like a rendering bug and is actually
/// two functions that round differently.
class ScaleGraticule {
  ScaleGraticule({
    required this.scale,
    required this.side,
    required Color lineColor,
    required Color labelColor,
    this.labelStyle = BelType.tick,
    this.format = _defaultFormat,
  }) : _linePaint = (Paint()
         ..color = lineColor
         ..strokeWidth = BelStroke.hairline
         ..isAntiAlias = false),
       _labelColor = labelColor {
    _labels = [
      for (final value in scale.ticks)
        layoutParagraph(
          format(value),
          labelStyle.copyWith(color: labelColor),
          align: side == ScaleSide.left ? TextAlign.right : TextAlign.left,
          maxWidth: _labelWidth,
        ),
    ];
  }

  final MeterScale scale;
  final ScaleSide side;
  final TextStyle labelStyle;
  final String Function(double value) format;

  final Paint _linePaint;
  final Color _labelColor;
  late final List<ui.Paragraph> _labels;

  /// Enough for "-60" at 10 px, with room for a minus sign and a decimal.
  static const double _labelWidth = 30;

  static String _defaultFormat(double value) => value.round().toString();

  /// How much room the labels need on their edge, so the caller can inset the
  /// track by it.
  double get gutter => switch (side) {
    ScaleSide.left || ScaleSide.right => _labelWidth + Space.xs,
    ScaleSide.bottom => labelStyle.fontSize! + Space.xs,
  };

  /// Draws the gridlines across [track] and the labels beside it.
  ///
  /// [track] is the meter's own rectangle, not the whole module: the labels are
  /// placed outside it, in the gutter the caller reserved.
  void paint(Canvas canvas, Rect track) {
    final values = scale.ticks;

    for (var i = 0; i < values.length; i++) {
      final fraction = scale.fractionOf(values[i]);
      final label = _labels[i];

      if (side == ScaleSide.bottom) {
        final x = track.left + fraction * track.width;
        canvas.drawLine(
          Offset(x, track.top),
          Offset(x, track.bottom),
          _linePaint,
        );
        // Centred under its own gridline, which needs the paragraph's width —
        // the reason these are laid out rather than measured by character
        // count.
        canvas.drawParagraph(
          label,
          Offset(x - label.longestLine / 2, track.bottom + Space.xs),
        );
      } else {
        final y = track.bottom - fraction * track.height;
        canvas.drawLine(
          Offset(track.left, y),
          Offset(track.right, y),
          _linePaint,
        );

        final dy = y - label.height / 2;
        if (side == ScaleSide.left) {
          canvas.drawParagraph(
            label,
            Offset(track.left - _labelWidth - Space.xs, dy),
          );
        } else {
          canvas.drawParagraph(label, Offset(track.right + Space.xs, dy));
        }
      }
    }
  }

  /// True when this graticule would draw exactly what a new one would, so a
  /// painter can decide whether to rebuild it.
  bool matches(MeterScale other, ScaleSide otherSide, Color otherLabelColor) =>
      scale == other && side == otherSide && _labelColor == otherLabelColor;

  void dispose() => _labels.clear();
}
