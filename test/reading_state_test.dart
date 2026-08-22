// SPDX-License-Identifier: GPL-3.0-or-later
//
// The colour rule, as assertions.
//
// One sentence decides every one of these: **red is over a number the delivery
// target names, amber is approaching one, and nothing else may use either.**
// The four modules that draw a bar or an arc against the target paint the part
// past it in `over`, and a Number Box or an Alert Meter watching the same
// quantity has to agree with the bar beside it — `classify` is the single
// function both go through, so this file is where the two are held together.
//
// It exists because `Metric.lufsIntegrated` returned `neutral` for a mix over
// its target for eight phases. Nothing failed: there was no test of `classify`
// at all, and on screen it looked like a reading nobody had an opinion about
// rather than like the failure the delivery report had already called it.

import 'package:oaa/src/data/metric_reader.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // −14 LUFS ±0.5, true peak −1.0 dBTP, LRA 20.
  const target = BuiltInCalibrations.streaming;

  group('over a number the target names is over', () {
    test('integrated loudness past the target and its tolerance', () {
      expect(
        classify(Metric.lufsIntegrated, -13.0, target),
        ReadingState.over,
        reason: '−13 is 1 LU over a −14 target with 0.5 LU of tolerance',
      );
    });

    test('true peak past the ceiling', () {
      expect(classify(Metric.truePeak, -0.5, target), ReadingState.over);
      expect(classify(Metric.truePeakMax, -0.5, target), ReadingState.over);
    });

    test('loudness range past the maximum', () {
      expect(classify(Metric.loudnessRange, 21.0, target), ReadingState.over);
    });

    test('sample peak at full scale', () {
      expect(classify(Metric.samplePeakMax, 0.0, target), ReadingState.over);
      expect(classify(Metric.peak, 0.2, target), ReadingState.over);
    });
  });

  group('amber is approaching, never past', () {
    test('true peak within the last decibel is a warning, not a failure', () {
      expect(classify(Metric.truePeak, -1.5, target), ReadingState.warn);
      expect(
        classify(Metric.truePeak, -2.0, target),
        ReadingState.inSpec,
        reason: 'two decibels of headroom is not approaching anything',
      );
    });

    test('the warning band stops exactly at the ceiling', () {
      // −1.0 is the ceiling itself: not yet exceeded, so not `over`.
      expect(classify(Metric.truePeak, -1.0, target), ReadingState.warn);
      expect(classify(Metric.truePeak, -0.9, target), ReadingState.over);
    });
  });

  group('quiet is not over', () {
    test('integrated loudness under the target is neutral', () {
      expect(
        classify(Metric.lufsIntegrated, -20.0, target),
        ReadingState.neutral,
      );
    });

    test('on target is in spec', () {
      expect(
        classify(Metric.lufsIntegrated, -14.0, target),
        ReadingState.inSpec,
      );
      expect(
        classify(Metric.lufsIntegrated, -14.4, target),
        ReadingState.inSpec,
      );
      expect(
        classify(Metric.lufsIntegrated, -13.6, target),
        ReadingState.inSpec,
      );
    });
  });

  group('a quantity nobody measured has no verdict', () {
    test(
      'NaN is unavailable on every metric, not a pass and not a failure',
      () {
        for (final metric in Metric.values) {
          expect(
            classify(metric, double.nan, target),
            ReadingState.unavailable,
            reason: '$metric',
          );
        }
      },
    );
  });

  test('the delivery report and the meters agree about the same mix', () {
    // The one case that has to hold: a reading the report calls a failure must
    // not be drawn as a reading with no opinion. Loudness is the metric where
    // the two disagreed.
    const overTarget = -12.0;
    expect(target.meetsLoudnessTarget(overTarget), isFalse);
    expect(
      classify(Metric.lufsIntegrated, overTarget, target),
      ReadingState.over,
    );
  });
}
