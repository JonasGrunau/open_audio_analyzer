// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:oaa_core/oaa_core.dart';

import 'text_cache.dart';
import 'tokens.dart';

/// A decibel scale, and where a reading sits on it.
///
/// Two shapes, one class, because five modules draw against this and two of
/// them side by side must agree about where −12 is.
///
/// **[MeterScale.tapered] is the level scale**, and it is deliberately not
/// linear. The top decade is where a mastering decision happens and the bottom
/// forty decibels are where nothing does, so the track gives the top the room:
/// the filled fraction of a reading is `10^(dB / 60)` — equivalently, the
/// signal's amplitude raised to the power ⅓ — which puts −3 dB three ticks'
/// worth of track from the top and compresses the floor smoothly into a
/// bottom edge that *is* −∞. That last property is the one a linear scale
/// cannot have: silence sits at a real point on the scale instead of below an
/// arbitrary cut-off, and a bar at the bottom of the track means "nothing" and
/// never "−60, or quieter, who knows". The labelled ticks are therefore given
/// explicitly, dense at the top and sparse below, rather than generated at an
/// even step that would crowd the compressed end.
///
/// The exponent is one constant for the whole application. Fitting each meter
/// its own curve flatters each in isolation and produces two adjacent modules
/// whose −12 gridlines do not line up, which reads as a rendering bug and is
/// two functions that disagree.
///
/// **The unnamed constructor is linear** and stays for axes that are a domain
/// rather than a level — the loudness distribution's horizontal LUFS axis
/// zooms, and a zoomed window has no −∞ to anchor a taper to.
@immutable
class MeterScale {
  /// Linear in dB between [min] and [max], labelled every [step].
  const MeterScale({required this.min, required this.max, required this.step})
    : labelled = null,
      assert(max > min),
      assert(step > 0);

  /// Tapered from [max] at the top of the track to −∞ at the bottom.
  ///
  /// [ticks] are the labelled values, top first; −∞ is appended by the scale
  /// itself, because it is not optional — a tapered scale that hides its floor
  /// is lying about having one.
  const MeterScale.tapered({required this.max, required List<double> ticks})
    : min = double.negativeInfinity,
      step = 0,
      labelled = ticks;

  /// Bottom of the scale, in dB or LU. −∞ on a tapered scale.
  final double min;

  /// Top of the scale.
  final double max;

  /// Spacing between labelled ticks. Meaningless (0) on a tapered scale, whose
  /// ticks are enumerated in [labelled] instead.
  final double step;

  /// The labelled ticks of a tapered scale, or null for a linear one.
  final List<double>? labelled;

  /// Decibels per decade of track. `10^(dB/60)` is amplitude to the power ⅓:
  /// −3 dB sits at 89% of the track, −12 at 63%, −40 at 21%. One value for
  /// every tapered scale in the application — see the class comment.
  static const double taperDecibels = 60;

  bool get isTapered => labelled != null;

  double get span => max - min;

  /// Where [value] sits, 0 at the bottom of the track and 1 at [max]. Clamped:
  /// a reading off the end of the scale pins to the end rather than drawing
  /// outside the meter. On a tapered scale the bottom is −∞ itself, which no
  /// finite reading reaches — only silence does.
  ///
  /// **And silence is spelled [MeterShape.dbFloor], not −∞**, which is the
  /// whole of why that last sentence needs a line of code under it. Every dB
  /// quantity is clamped to the floor before it leaves the engine, so what a
  /// silent meter is handed is −144.0 — a finite number, which the taper puts
  /// at 0.4% of the track rather than at the end of it. Four tenths of one
  /// percent is under a pixel on a small module and a visible hairline of lit
  /// fill on a large one, sitting at the foot of a meter that has nothing to
  /// show, seconds after the music stopped. The scale labels that end `-∞`
  /// already; this is what makes the reading agree with the label.
  double fractionOf(double value) {
    if (value.isNaN) return 0;
    if (labelled != null) {
      if (value >= max) return 1;
      if (value <= MeterShape.dbFloor) return 0;
      return math.pow(10, (value - max) / taperDecibels).toDouble();
    }
    final fraction = (value - min) / span;
    return fraction < 0 ? 0 : (fraction > 1 ? 1 : fraction);
  }

  /// The inverse, unclamped — for turning a pointer position into a value.
  double valueAt(double fraction) {
    if (labelled != null) {
      if (fraction <= 0) return double.negativeInfinity;
      return max + taperDecibels * math.log(fraction) / math.ln10;
    }
    return min + fraction * span;
  }

  /// Every labelled tick, top value last for a linear scale (ascending), and
  /// as given plus −∞ for a tapered one.
  List<double> get ticks {
    final explicit = labelled;
    if (explicit != null) return [...explicit, double.negativeInfinity];
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
      other.step == step &&
      listEquals(other.labelled, labelled);

  @override
  int get hashCode => Object.hash(
    min,
    max,
    step,
    labelled == null ? null : Object.hashAll(labelled!),
  );
}

/// Which edge of a meter the scale's labels sit against.
enum ScaleSide {
  /// Labels left of a vertical track, values increasing upwards.
  left,

  /// Labels right of a vertical track, values increasing upwards.
  right,

  /// Labels on both edges of a vertical track — what a meter whose bars span
  /// the module's width wants, so neither channel is further from its scale
  /// than the other.
  both,

  /// Labels below a horizontal track, values increasing rightwards.
  bottom,

  /// Labels above a horizontal track, values increasing rightwards.
  top,
}

/// The frequency gridline series, 20 Hz to 20 kHz.
///
/// The 1–2–3–5–7 subdivision, which is the set of round numbers a log axis can
/// carry without its labels touching. Every module with a Hz axis draws this
/// same list — an analyser and a spectrogram on one tab disagreeing about
/// which lines exist would read as one of them being wrong about the signal.
const List<double> kHzGrid = [
  20,
  30,
  50,
  70,
  100,
  200,
  300,
  500,
  1000,
  2000,
  3000,
  5000,
  7000,
  10000,
  20000,
];

/// `20` → "20", `2000` → "2k". The axis form, everywhere a frequency is a
/// tick rather than a sentence.
String formatHz(double hz) =>
    hz >= 1000 ? '${(hz / 1000).round()}k' : '${hz.round()}';

/// `31.6` → "31.6 Hz", `440` → "440 Hz", `1020` → "1.02 kHz", `12500` →
/// "12.5 kHz". The sentence form, for a frequency that is a *reading* — the
/// analyser's cursor — rather than a tick.
///
/// Three significant figures throughout, which is the resolution of the thing
/// being read: the analyser's 512 bands are a fifty-first of an octave apart,
/// 1.4 % of the frequency, and a fourth figure would print two neighbouring
/// bands as if they were measured apart when the spectrum does not resolve
/// them. A whole hertz below 100 Hz is too coarse the other way — adjacent
/// bands at 20 Hz are a quarter of a hertz apart and would all print "20".
String formatHzReading(double hz) {
  if (hz < 100) return '${hz.toStringAsFixed(1)} Hz';
  if (hz < 1000) return '${hz.round()} Hz';
  if (hz < 10000) return '${(hz / 1000).toStringAsFixed(2)} kHz';
  return '${(hz / 1000).toStringAsFixed(1)} kHz';
}

/// Which of [kHzGrid]'s values carry a label along an axis [extent] long,
/// when the label for value `i` is `sizeOf(i)` long along that axis, is
/// centred on its gridline but kept inside the axis, and wants [gap] clear
/// beside it.
///
/// Greedy, and anchored: 100 Hz, 1 kHz and 10 kHz are placed first, because
/// they are the three a reader orients by, then every other value that does
/// not collide with one already placed, in series order — which on a tight
/// axis leaves the 1-2-5 of each decade. **One rule for the three frequency
/// axes.** Two of them used to be all-or-nothing, the whole series where its
/// tightest pair fitted and three labels where it did not, while the third
/// fitted greedily — so a spectrogram beside a stereo cloud carried three
/// labels where the cloud, at the same height, carried ten.
List<bool> fitHzLabels(
  double extent,
  double Function(int index) sizeOf, {
  double gap = Space.xs,
}) {
  final labelled = List<bool>.filled(kHzGrid.length, false);
  final centre = List<double>.filled(kHzGrid.length, double.nan);

  bool place(int i) {
    final size = sizeOf(i);
    if (size <= 0 || size > extent) return false;
    final at = extent * bandOfHz(kHzGrid[i]) / MeterShape.spectrumBands;
    final c = at.clamp(size / 2, extent - size / 2);
    for (var j = 0; j < kHzGrid.length; j++) {
      if (!labelled[j]) continue;
      if ((c - centre[j]).abs() < (size + sizeOf(j)) / 2 + gap) return false;
    }
    labelled[i] = true;
    centre[i] = c;
    return true;
  }

  for (final hz in const [100.0, 1000.0, 10000.0]) {
    place(kHzGrid.indexOf(hz));
  }
  for (var i = 0; i < kHzGrid.length; i++) {
    if (!labelled[i]) place(i);
  }
  return labelled;
}

/// The ticks and labels of a [MeterScale], laid out once and painted every
/// frame.
///
/// Built in a module's [State] and rebuilt only when the scale or the palette
/// changes. Five modules draw a dB scale; without this they would each grow
/// their own tick loop, and the ticks on two meters sitting side by side would
/// eventually stop lining up — which looks like a rendering bug and is actually
/// two functions that round differently.
class ScaleGraticule {
  ScaleGraticule({
    required this.scale,
    required this.side,
    required Color lineColor,
    required Color labelColor,
    this.labelStyle = OaaType.tick,
    this.format = _defaultFormat,
    this.avoid,
  }) : _linePaint = (Paint()
         ..color = lineColor
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _labelColor = labelColor {
    _labels = [
      for (final value in scale.ticks)
        layoutParagraph(
          format(value),
          labelStyle.copyWith(color: labelColor),
          align: side == ScaleSide.left || side == ScaleSide.both
              ? TextAlign.right
              : TextAlign.left,
          maxWidth: _labelWidth,
        ),
    ];
    // A vertical track labelled on both edges needs each label twice: a
    // paragraph carries one alignment, and the left edge hangs its text
    // against the track while the right edge hangs it away from it.
    _labelsRight = side == ScaleSide.both
        ? [
            for (final value in scale.ticks)
              layoutParagraph(
                format(value),
                labelStyle.copyWith(color: labelColor),
                align: TextAlign.left,
                maxWidth: _labelWidth,
              ),
          ]
        : const [];

    for (final label in _labels) {
      if (label.longestLine > _inkWidth) _inkWidth = label.longestLine;
      if (label.height > _inkHeight) _inkHeight = label.height;
    }
  }

  final MeterScale scale;
  final ScaleSide side;
  final TextStyle labelStyle;
  final String Function(double value) format;

  /// A value whose own label the caller draws on this scale — the delivery
  /// target, printed in its own colour. Ticks whose labels would collide with
  /// it are skipped rather than overprinted: a target usually lands between
  /// two ticks, and on a short module "between" is not far enough. The
  /// gridlines stay; only the text yields.
  final double? avoid;

  final Paint _linePaint;
  final Color _labelColor;
  late final List<ui.Paragraph> _labels;
  late final List<ui.Paragraph> _labelsRight;

  /// The layout box the labels are aligned inside. Generous on purpose — it is
  /// an upper bound, not a measurement, and the labels are aligned to the edge
  /// of it that faces the track, so a box wider than the text costs nothing.
  static const double _labelWidth = 30;

  /// What the labels actually take up, once laid out.
  ///
  /// The gutter used to be [_labelWidth] flat, so a scale whose widest label is
  /// "-60" reserved thirteen more pixels than it drew in — and since the meter
  /// sits flush against the *other* side of its module, that surplus turned up
  /// as a module whose contents were visibly off-centre. Five modules share
  /// this class and all leaned the same way.
  double _inkWidth = 0;
  double _inkHeight = 0;

  static String _defaultFormat(double value) {
    if (value.isInfinite) return value.isNegative ? '-∞' : '∞';
    return value.round().toString();
  }

  /// How much room the labels need on their edge, so the caller can inset the
  /// track by it. For [ScaleSide.both] this is the room needed on *each* edge.
  double get gutter => switch (side) {
    ScaleSide.left || ScaleSide.right || ScaleSide.both => _inkWidth + Space.xs,
    ScaleSide.bottom || ScaleSide.top => _inkHeight + Space.xs,
  };

  /// Keeps a label inside the extent of the track it labels.
  ///
  /// A scale's end labels are centred on gridlines that sit on the track's own
  /// edges, so half of each falls outside it — and a track is normally flush
  /// with the edge of its module, where "outside" means clipped. **The zero at
  /// the top of the LUFS meter was drawn as its own bottom half**, and the
  /// spectrum analyser's top label and the histogram's first and last were the
  /// same defect in the same line of code.
  ///
  /// Nudging the label in is the smaller of the two fixes. The alternative —
  /// having every caller inset its track by half a label — moves the meter's
  /// full-scale point away from the top of the module, in five modules, one of
  /// which will be written later and forget. Here the gridline still sits
  /// exactly on its value and only the text moves, by at most half its own
  /// size, at the two ends of the scale where there is no neighbour to confuse
  /// it with.
  static double _inside(double start, double extent, double low, double high) =>
      start < low ? low : (start + extent > high ? high - extent : start);

  /// [position] moved onto the ruling [pitch] apart through [at], and held
  /// between [low] and [high] — a gridline that snapped past the end of its
  /// own track would be a line off the meter. One step is enough to bring it
  /// back: the snap never moves a line further than half a pitch.
  ///
  /// Public because a caller that snaps its scale onto a ruling is a caller
  /// that draws that ruling, and usually has to find these rows again in it —
  /// the Digital Meter re-lights them over its own segment gaps. Two roundings
  /// of the same grid are two grids the first time one of them changes.
  static double snapped(
    double position, {
    required double low,
    required double high,
    required double pitch,
    required double at,
  }) {
    if (pitch <= 0) return position;
    final snapped = at - ((at - position) / pitch).roundToDouble() * pitch;
    if (snapped < low) return snapped + pitch;
    if (snapped > high) return snapped - pitch;
    return snapped;
  }

  /// Draws the gridlines across [track] and the labels beside it.
  ///
  /// [track] is the meter's own rectangle, not the whole module: the labels are
  /// placed outside it, in the gutter the caller reserved.
  ///
  /// [snapPitch] puts every gridline on a ruling the caller draws itself:
  /// lines [snapPitch] apart with one of them through [snapAt]. Zero — the
  /// default, and what four of the five callers want — draws each line exactly
  /// on its value.
  ///
  /// The Digital Meter's segments are such a ruling. A scale line a pixel off
  /// it is a *second* ruling in the same picture: the two beat against each
  /// other down the bar, and a pair of lines two pixels apart reads as one
  /// line that has come loose rather than as a scale over a meter. Snapped, a
  /// line stands at most half a segment from its value — which is a difference
  /// the segments themselves already impose on everything else in the module,
  /// and its own label moves with it.
  void paint(
    Canvas canvas,
    Rect track, {
    double snapPitch = 0,
    double snapAt = 0,
  }) {
    final values = scale.ticks;

    for (var i = 0; i < values.length; i++) {
      final fraction = scale.fractionOf(values[i]);
      final label = _labels[i];

      if (side == ScaleSide.bottom || side == ScaleSide.top) {
        final x = snapped(
          track.left + fraction * track.width,
          low: track.left,
          high: track.right,
          pitch: snapPitch,
          at: snapAt,
        );
        canvas.drawLine(
          Offset(x, track.top),
          Offset(x, track.bottom),
          _linePaint,
        );
        // Yielding to the shielded value along the axis, by width — the
        // vertical branch below does the same by height. The rule was written
        // for the vertical sides first and reached the bottom axis late: the
        // loudness distribution's −15 stood half under its −14.0.
        final shield = avoid;
        if (shield != null &&
            (fraction - scale.fractionOf(shield)).abs() * track.width <
                label.longestLine + Space.xs) {
          continue;
        }

        // Centred against its own gridline, which needs the paragraph's width
        // — the reason these are laid out rather than measured by character
        // count. Held inside the plot at the two ends; see [_inside].
        canvas.drawParagraph(
          label,
          Offset(
            _inside(
              x - label.longestLine / 2,
              label.longestLine,
              track.left,
              track.right,
            ),
            side == ScaleSide.bottom
                ? track.bottom + Space.xs
                : track.top - label.height - Space.xs,
          ),
        );
      } else {
        final y = snapped(
          track.bottom - fraction * track.height,
          low: track.top,
          high: track.bottom,
          pitch: snapPitch,
          at: snapAt,
        );
        canvas.drawLine(
          Offset(track.left, y),
          Offset(track.right, y),
          _linePaint,
        );

        final shield = avoid;
        if (shield != null &&
            (fraction - scale.fractionOf(shield)).abs() * track.height <
                label.height + Space.xxs) {
          continue;
        }

        final dy = _inside(
          y - label.height / 2,
          label.height,
          track.top,
          track.bottom,
        );
        if (side == ScaleSide.left || side == ScaleSide.both) {
          canvas.drawParagraph(
            label,
            Offset(track.left - _labelWidth - Space.xs, dy),
          );
        }
        if (side == ScaleSide.right) {
          canvas.drawParagraph(label, Offset(track.right + Space.xs, dy));
        }
        if (side == ScaleSide.both) {
          canvas.drawParagraph(
            _labelsRight[i],
            Offset(track.right + Space.xs, dy),
          );
        }
      }
    }
  }

  /// True when this graticule would draw exactly what a new one would, so a
  /// painter can decide whether to rebuild it.
  bool matches(
    MeterScale other,
    ScaleSide otherSide,
    Color otherLabelColor, {
    double? avoiding,
  }) =>
      scale == other &&
      side == otherSide &&
      _labelColor == otherLabelColor &&
      avoid == avoiding;

  void dispose() {
    _labels.clear();
    // `const []` on every side but `both`, and a const list cannot be cleared.
    if (_labelsRight.isNotEmpty) _labelsRight.clear();
  }
}
