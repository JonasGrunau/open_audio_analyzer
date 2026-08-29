// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// The hairline box around a module's plot.
///
/// Six modules draw one — the spectrum analyser, the oscilloscope, the
/// spectrogram, the histogram, the loudness distribution and the stereo cloud,
/// and the histogram twice, because its overview strip is a second picture
/// rather than the plot's footer. One class for the same reason
/// [ScaleGraticule] is one class: two of these side by side with edges of
/// different weights, or in different inks, read as one module being wrong
/// rather than as two decisions.
///
/// In [OaaColors.hairline] — the gridlines' own ink — and never
/// `hairlineStrong`. The box says where the measurement stops, which is the
/// least of what any of these modules has to say; drawn heavier it competes
/// with the marks inside it, and on the stereo cloud it competed with the
/// centre line, which is the one thing on that module that has to be found
/// first.
///
/// It replaced the rules those modules drew on the one or two sides a scale
/// happened to sit against. A rule that stops where the field stops on two
/// sides of four does not read as an edge — it reads as an unfinished box —
/// and which two sides you got depended on which axes the module had.
///
/// **The box is drawn around the picture and never over it.** A module takes
/// the rectangle it was given, draws the box on it, and plots inside
/// [PlotBorder.inside] — a hairline in on every side. The alternative, letting
/// the box own the outermost pixel of the plot, costs nothing on four of these
/// modules and hides the newest measurement on the other two: a spectrogram's
/// newest column and a rolling scope's newest sample both land hard against
/// the right-hand edge, which is exactly where the eye is. One rule rather
/// than a judgement per module, because the judgement is invisible until the
/// module it was got wrong on is the one you are reading.
class PlotBorder {
  PlotBorder(OaaColors colors)
    : _paint = (Paint()
        ..color = colors.hairline
        ..style = PaintingStyle.stroke
        ..strokeWidth = OaaStroke.hairline
        ..isAntiAlias = false);

  final Paint _paint;

  /// The plot inside a box drawn on [box] — the rectangle a module measures,
  /// clips and draws in.
  static Rect inside(Rect box) => box.deflate(OaaStroke.hairline);

  /// Draws the box on [box], whose inside is [PlotBorder.inside].
  ///
  /// Deflated by half a hairline, which is not decoration: [MeterBody] clips
  /// every module painter to its size and a plot is normally flush with the
  /// body on at least one side, so a stroke centred on that edge loses its
  /// outer half and comes out half as dark as the sides that had room to be
  /// drawn whole.
  void paint(Canvas canvas, Rect box) =>
      canvas.drawRect(box.deflate(OaaStroke.hairline / 2), _paint);
}
