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
  // −14 LUFS ±0.5, true peak −1.0 dBTP, LRA 20. No ODR floor, which is what
  // every built-in but `dynamic-master` states — see [everyLine].
  const target = BuiltInCalibrations.streaming;

  /// The same target with both dynamics floors stated, which **no built-in
  /// does**: `dynamic-master` states the short one and nothing states the
  /// integrated one. It is here so that "a line exists for this metric" can be
  /// asserted at all, and its absence from the built-ins is the whole reason
  /// Delta had to become a question about the target as well as the metric.
  const everyLine = Calibration(
    id: 'test-every-line',
    name: 'Every line',
    lufsTarget: -14,
    lufsTolerance: 0.5,
    truePeakMax: -1.0,
    loudnessRangeMax: 20,
    odrIntegratedFloor: 8.0,
    odrShortFloor: 8.0,
  );

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

    test('silence passes no ceiling, on the meters or in the table', () {
      // A true peak at the floor is the clamp every dB level is limited to
      // before it leaves C, standing in for "nothing has played". Held
      // against a −1 dBTP ceiling it satisfies it, so an idle input used to
      // read `-144.0` in the pass colour with a precise Δ beside it — a
      // delivery verdict on a programme that does not exist, and the one
      // green line on a Validator whose every other row was still waiting.
      // Neutral rather than in spec: the ceiling has not been met, it has
      // not been tested.
      expect(
        classify(Metric.truePeakMax, MeterShape.dbFloor, target),
        ReadingState.neutral,
      );
      expect(
        classify(Metric.truePeak, MeterShape.dbFloor, target),
        ReadingState.neutral,
      );
      expect(
        targetDelta(Metric.truePeakMax, MeterShape.dbFloor, target).isNaN,
        isTrue,
      );
      // A real peak, however quiet, is judged as one.
      expect(classify(Metric.truePeakMax, -60.0, target), ReadingState.inSpec);
      expect(
        targetDelta(Metric.truePeakMax, -60.0, target),
        closeTo(-59, 1e-9),
      );
    });
  });

  // The one warning in the application that no delivery target states, and the
  // only place `warn` means something a Calibration cannot move.
  group('anti-phase is a reading, not a sign bit', () {
    test('a signal that will disappear in mono is warned about', () {
      expect(classify(Metric.correlation, -1.0, target), ReadingState.warn);
      expect(classify(Metric.correlation, -0.4, target), ReadingState.warn);
      expect(classify(Metric.correlation, -0.01, target), ReadingState.warn);
    });

    test('a correlated or uncorrelated one is not', () {
      expect(classify(Metric.correlation, 1.0, target), ReadingState.neutral);
      expect(classify(Metric.correlation, 0.0, target), ReadingState.neutral);
    });

    test('a reading that prints as zero is not coloured as anti-phase', () {
      // `Metric.correlation` prints two decimals, so −0.001 formats as
      // `-0.00`. Under a bare `value < 0` it was coloured like −0.9, and a
      // Phase Scope marker sitting dead centre on unrelated channels changed
      // colour as the sign fell one way or the other.
      expect(Metric.correlation.format(-0.001), '-0.00');
      expect(
        classify(Metric.correlation, -0.001, target),
        ReadingState.neutral,
      );
      expect(isAntiPhase(-0.001), isFalse);
      expect(isAntiPhase(-0.01), isTrue);
    });
  });

  // The Alert Meter's Delta prints these, and the Validator's Δ column has
  // printed them since it was written — one function now, because two ways of
  // saying how far a mix is from its target is two numbers that can disagree
  // in front of somebody about to deliver.
  group('the distance from the target', () {
    test('is signed the same way for a ceiling and for a target', () {
      // −13 against a −14 target, and −0.5 against a −1.0 ceiling. Both are
      // over the line, and both read positive: the sign says which side, and
      // the colour says whether that side is the failing one.
      expect(
        targetDelta(Metric.lufsIntegrated, -13.0, target),
        closeTo(1.0, 1e-9),
      );
      expect(targetDelta(Metric.truePeakMax, -0.5, target), closeTo(0.5, 1e-9));
      expect(
        targetDelta(Metric.loudnessRange, 12.0, target),
        closeTo(-8.0, 1e-9),
      );
    });

    test('is unavailable where the target draws no line', () {
      // Nothing is stated about correlation, so there is nothing to be a
      // distance from — and the module prints the same dash it prints for a
      // quantity this build does not measure.
      expect(targetDelta(Metric.correlation, 0.4, target).isNaN, isTrue);
      expect(formatDelta(targetDelta(Metric.correlation, 0.4, target)), '—');
      expect(hasTarget(Metric.correlation, target), isFalse);
      expect(hasTarget(Metric.lufsIntegrated, target), isTrue);
    });

    test('is unavailable when this target sets no ODR floor', () {
      // The streaming targets state none, and a difference from a floor
      // nobody stated would be a number nobody measured.
      expect(target.odrIntegratedFloor, isNull);
      expect(target.odrShortFloor, isNull);
      expect(targetDelta(Metric.odrIntegrated, 9.0, target).isNaN, isTrue);
      expect(targetDelta(Metric.odrShort, 9.0, target).isNaN, isTrue);
      // And [hasTarget] says so, which is the half that was missing: it
      // answered on the metric alone, so the menu offered Delta on a floor
      // nobody had stated and the module printed that dash for ever.
      expect(hasTarget(Metric.odrIntegrated, target), isFalse);
      expect(hasTarget(Metric.odrShort, target), isFalse);
      expect(
        hasTarget(Metric.odrShort, BuiltInCalibrations.dynamicMaster),
        isTrue,
      );
    });

    test('is offered exactly where it can be answered', () {
      // The invariant behind both rows above, over every metric and both
      // shapes of target: [hasTarget] is the complement of [targetDelta]'s
      // NaN. Anything else is a menu that offers a reading the module cannot
      // print, or withholds one it can.
      for (final calibration in [target, everyLine]) {
        for (final metric in Metric.values) {
          expect(
            hasTarget(metric, calibration),
            !targetDelta(metric, 9.0, calibration).isNaN,
            reason: '${metric.label} under ${calibration.name}',
          );
        }
      }
    });

    test('spells the sign out, and never negative zero', () {
      expect(formatDelta(0.6), '+0.6');
      expect(formatDelta(-0.6), '-0.6');
      expect(formatDelta(0.0), '+0.0');
      expect(
        formatDelta(-0.04),
        '+0.0',
        reason: 'a reading rounding onto the line is not below it',
      );
      expect(formatDelta(double.nan), '—');
    });

    test('is a dash for a reading nobody has taken', () {
      expect(
        targetDelta(Metric.lufsIntegrated, double.nan, target).isNaN,
        isTrue,
      );
    });

    test('is the unit of the difference, never the metric\'s own', () {
      // The reference cancels in a subtraction. `+0.8 dBTP` after a delta
      // would name a clipped master rather than eight tenths over the line,
      // which is the one place carrying the metric's unit across turns a
      // helpful reading into a false one.
      expect(deltaUnit(Metric.truePeakMax), 'dB');
      expect(Metric.truePeakMax.unit, 'dBTP');
      expect(deltaUnit(Metric.lufsIntegrated), 'LU');
      expect(Metric.lufsIntegrated.unit, 'LUFS');
      // LRA and the two dynamics ratios are already in LU, so those agree.
      expect(deltaUnit(Metric.loudnessRange), 'LU');
      // And nothing at all where there is no delta to give a unit to. Asked of
      // the target that draws every line, because the unit is a property of
      // the metric: an ODR delta is in LU whether or not this target states
      // the floor it would be measured from.
      for (final metric in Metric.values) {
        if (!hasTarget(metric, everyLine)) {
          expect(deltaUnit(metric), isEmpty, reason: metric.label);
        }
      }
    });

    test('is what an Alert Meter shows only where there is a line', () {
      // Delta is off until it is asked for, and asking for it where nothing
      // draws a line cannot happen from the menu — the row is disabled there.
      // What can happen is asking for it and then moving the line out from
      // under it, and there are two ways to do that: change the metric, or
      // change the target. `alertDeltaOf` is where both are resolved, because
      // a module printing an em dash for ever with a disabled row as its only
      // way out is not a setting, it is a trap.
      ModuleSpec alert(
        Metric metric, [
        Map<String, Object?> options = const {},
      ]) => ModuleSpec(
        id: 'm',
        kind: ModuleKind.alertMeter,
        rect: const GridRect(column: 0, row: 0, columns: 4, rows: 3),
        options: {'metric': metric.id, ...options},
      );

      expect(alertDeltaOf(alert(Metric.truePeakMax), target), isFalse);
      expect(
        alertDeltaOf(alert(Metric.truePeakMax, {'delta': true}), target),
        isTrue,
      );
      expect(
        alertDeltaOf(alert(Metric.correlation, {'delta': true}), target),
        isFalse,
      );

      // The trap that was live, and it was two clicks from the shipped
      // defaults: the default preset's Alert Meter, its metric row set to
      // ODR-S and Delta switched on, under the `streaming-14` the application
      // starts with. It asked for a distance from a floor that target does not
      // state, and read an em dash from the first frame to the last.
      const odr = {'delta': true};
      expect(
        alertDeltaOf(alert(Metric.odrShort, odr), target),
        isFalse,
        reason: 'no ODR-S floor here, so the module prints the reading itself',
      );
      expect(
        alertDeltaOf(alert(Metric.odrIntegrated, odr), everyLine),
        isTrue,
        reason: 'and the stored choice is waiting when a floor is stated',
      );
      // Under every target that ships, an ODR-I delta has nothing to measure
      // from — which is why the metric alone could never have been the whole
      // question.
      for (final calibration in BuiltInCalibrations.all) {
        expect(
          alertDeltaOf(alert(Metric.odrIntegrated, odr), calibration),
          isFalse,
          reason: calibration.name,
        );
      }
    });
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
