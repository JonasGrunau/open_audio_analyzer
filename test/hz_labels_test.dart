// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// [fitHzLabels] is the one rule the three frequency axes label by. These
/// hold the two properties that rule exists for: the three anchors survive
/// whatever else has to go, and an axis with room labels the whole series.
void main() {
  group('formatHzReading', formatHzReadingTests);

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

/// [formatHzReading] is the sentence form — the analyser's cursor — and prints
/// three significant figures throughout, which is what the bands resolve.
void formatHzReadingTests() {
  test('three significant figures, in the unit the range calls for', () {
    expect(formatHzReading(20.3), '20.3 Hz');
    expect(formatHzReading(99.96), '100.0 Hz');
    expect(formatHzReading(440), '440 Hz');
    expect(formatHzReading(999.6), '1000 Hz');
    expect(formatHzReading(1020), '1.02 kHz');
    expect(formatHzReading(9996), '10.00 kHz');
    expect(formatHzReading(12500), '12.5 kHz');
    expect(formatHzReading(19952.6), '20.0 kHz');
  });

  test('neighbouring bands print apart at both ends of the range', () {
    expect(
      formatHzReading(bandCentreHz(0)),
      isNot(formatHzReading(bandCentreHz(1))),
    );
    expect(
      formatHzReading(bandCentreHz(MeterShape.spectrumBands - 2)),
      isNot(formatHzReading(bandCentreHz(MeterShape.spectrumBands - 1))),
    );
  });
}
