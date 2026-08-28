// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// [fitHzLabels] is the one rule the three frequency axes label by. These
/// hold the two properties that rule exists for: the three anchors survive
/// whatever else has to go, and an axis with room labels the whole series.
void main() {
  int indexOf(double hz) => kHzGrid.indexOf(hz);

  test('an axis with room for every label labels every value', () {
    // Ten pixels a label on a thousand-pixel axis: the tightest pair, 20 to
    // 30 Hz, is fifty-eight pixels apart.
    final labelled = fitHzLabels(1000, (_) => 10);
    expect(labelled.every((on) => on), isTrue);
  });

  test('a tight axis keeps 100, 1k and 10k and thins the rest', () {
    // Twelve-pixel labels on a sixty-pixel axis: the anchors land twenty
    // pixels apart, which is a label and a gap, and nothing else has room.
    final labelled = fitHzLabels(60, (_) => 12);
    expect(labelled[indexOf(100)], isTrue);
    expect(labelled[indexOf(1000)], isTrue);
    expect(labelled[indexOf(10000)], isTrue);
    expect(labelled.where((on) => on).length, lessThan(kHzGrid.length));
  });

  test('a horizontal axis a module wide labels most of the series', () {
    // The spectrum analyser's default photograph: about 360 logical pixels
    // of plot, tick-sized text — two glyphs for "2k", three for "100".
    final labelled = fitHzLabels(
      360,
      (i) => kHzGrid[i] >= 1000 || kHzGrid[i] < 100 ? 12 : 18,
    );
    expect(labelled.where((on) => on).length, greaterThanOrEqualTo(8));
    // 20 and 30 Hz are the tightest pair; whichever is dropped, the axis
    // still starts at 20.
    expect(labelled[indexOf(20)], isTrue);
  });

  test('a label at either end is kept inside the axis rather than dropped', () {
    // Only the two ends have a size; 20 Hz sits at pixel 0 and 20 kHz at
    // pixel 100, and both are labelled only if their thirty pixels can be
    // held inside the axis, which the clamp does.
    final ends = {indexOf(20), indexOf(20000)};
    final labelled = fitHzLabels(100, (i) => ends.contains(i) ? 30 : 0);
    expect(labelled[indexOf(20)], isTrue);
    expect(labelled[indexOf(20000)], isTrue);
    expect(labelled.where((on) => on).length, 2);
  });
}
