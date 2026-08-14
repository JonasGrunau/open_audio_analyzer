// SPDX-License-Identifier: MIT
//
// These tests are the reason the test tone exists.
//
// A sine of amplitude A has a peak of A and an RMS of A/sqrt(2), which is
// exactly 3.0103 dB lower. Those two numbers are not conventions, they are
// arithmetic, so a meter that disagrees with them is wrong — and that makes the
// tone a reference the meters can be held against on a headless CI runner with
// no sound hardware anywhere near it.
//
// The loudness assertions are the other half. They check that the engine
// reports loudness as *unavailable* rather than reporting a number, because
// until Phase 1 lands K-weighting and the EBU conformance vectors, any LUFS
// value this engine produced would be fiction.

import 'dart:math' as math;

import 'package:bel_engine/bel_engine.dart';
import 'package:test/test.dart';

/// Peak of the built-in tone on channel 0, in dBFS. Amplitude 0.5.
const _tonePeakDb = -6.020599913;

/// RMS of the same tone: 20*log10(0.5 / sqrt(2)).
const _toneRmsDb = -9.030899869;

/// Generous enough to absorb the tail of the RMS averager, tight enough that a
/// genuinely wrong meter cannot slip through.
const _toleranceDb = 0.1;

/// Let the engine run long enough for a 300 ms averager to settle. Five time
/// constants leaves under 1% of the step remaining.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 1600));

void main() {
  test('bindings match the compiled ABI', () {
    expect(BelEngine.abiVersion, BelEngine.expectedAbiVersion);
    expect(BelEngine.versionString, isNotEmpty);
  });

  test('test tone reads its own arithmetic', () async {
    final engine = BelEngine.start(source: BelSource.testTone);
    addTearDown(engine.dispose);

    await _settle();
    expect(engine.refresh(), isTrue, reason: 'engine published nothing');

    expect(engine.sampleRate, 48000);
    expect(engine.channels, 2);
    expect(engine.isRunning, isTrue);
    expect(engine.elapsedSeconds, greaterThan(1.0));

    expect(engine.peak[0], closeTo(_tonePeakDb, _toleranceDb));
    expect(engine.rms[0], closeTo(_toneRmsDb, _toleranceDb));

    // Peak minus RMS is the crest factor of a sine, which is a constant.
    expect(engine.peak[0] - engine.rms[0], closeTo(3.0103, _toleranceDb));
  });

  test('unmeasured quantities are NaN, not zero', () async {
    final engine = BelEngine.start(source: BelSource.testTone);
    addTearDown(engine.dispose);

    await _settle();
    engine.refresh();

    expect(engine.hasLoudness, isFalse);
    expect(engine.hasSpectrum, isFalse);

    // The distinction this test defends: a UI that treated these as 0.0 would
    // display "0.0 LUFS", which is both a valid-looking reading and wildly
    // wrong.
    expect(engine.lufsMomentary.isNaN, isTrue);
    expect(engine.lufsShort.isNaN, isTrue);
    expect(engine.lufsIntegrated.isNaN, isTrue);
    expect(engine.loudnessRange.isNaN, isTrue);
    expect(engine.truePeak.isNaN, isTrue);
    expect(engine.truePeakMax.isNaN, isTrue);

    // Measured, so emphatically not NaN.
    expect(engine.samplePeakMax.isNaN, isFalse);
    expect(engine.crestFactor.isNaN, isFalse);
    expect(engine.correlation.isNaN, isFalse);
  });

  test(
    'the stereo modulators actually move',
    () async {
      final engine = BelEngine.start(source: BelSource.testTone);
      addTearDown(engine.dispose);

      // The right channel is phase-swept against the left at 0.05 Hz, so
      // correlation must traverse a wide range rather than sitting still. A
      // frozen meter that happens to read a plausible value is the failure this
      // catches.
      var lowest = double.infinity;
      var highest = double.negativeInfinity;

      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        if (engine.refresh()) {
          lowest = math.min(lowest, engine.correlation);
          highest = math.max(highest, engine.correlation);
        }
      }

      expect(
        highest - lowest,
        greaterThan(0.5),
        reason: 'correlation is stuck',
      );
      expect(lowest, greaterThanOrEqualTo(-1.0));
      expect(highest, lessThanOrEqualTo(1.0));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('silence falls to the floor rather than freezing', () async {
    final engine = BelEngine.start(source: BelSource.silence);
    addTearDown(engine.dispose);

    await _settle();
    engine.refresh();

    expect(engine.peak[0], closeTo(kBelDbFloor, 0.001));
    expect(engine.rms[0], closeTo(kBelDbFloor, 0.001));

    // Not -infinity: differences of dB values are meaningful here, and
    // -inf minus -inf is NaN.
    expect(engine.rms[0].isFinite, isTrue);
  });

  test('reset clears the integrators', () async {
    final engine = BelEngine.start(source: BelSource.testTone);
    addTearDown(engine.dispose);

    await _settle();
    engine.refresh();
    expect(engine.elapsedSeconds, greaterThan(1.0));

    engine.reset();

    // The reset is honoured by the analysis thread at a block boundary, so it
    // is not instantaneous — give it a few blocks.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    engine.refresh();
    expect(engine.elapsedSeconds, lessThan(1.0));
  });

  test('unimplemented sources fail loudly', () {
    // Silently substituting the test tone here would let somebody believe they
    // were metering their soundcard.
    expect(
      () => BelEngine.start(source: BelSource.device),
      throwsA(isA<BelEngineException>()),
    );
  });
}
