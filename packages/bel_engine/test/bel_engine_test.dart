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
// The loudness assertions live next door in conformance_test.dart, against the
// EBU Tech 3341/3342 cases. What is checked here is the surrounding contract:
// the ABI matches, unmeasured quantities say so, silence falls to the floor
// instead of freezing, reset clears the integrators, and an unavailable source
// fails loudly rather than substituting something plausible.

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

/// Wait until the engine has *measured* [seconds] of signal.
///
/// Deliberately not a fixed wall-clock delay. `elapsedSeconds` counts samples,
/// not wall time — a file analysed at 200x real time has to produce the same
/// numbers as the same file played live, which is the whole reason the engine
/// never consults a clock to decide what it has measured.
///
/// The synthetic source paces itself against a monotonic clock, and
/// `nanosleep` only ever guarantees *at least* the delay it is given. On a
/// contended machine every block overshoots, and the source falls behind real
/// time — on a CI runner it was observed at a third of real speed. A test that
/// slept for 1.6 s and then asserted on a 300 ms averager having settled was
/// therefore asserting something about the runner's scheduler.
///
/// Times out, so an engine that has genuinely stalled still fails rather than
/// hanging the suite.
Future<void> _measure(
  BelEngine engine,
  double seconds, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    engine.refresh();
    if (engine.elapsedSeconds >= seconds) return;
  }
  fail(
    'engine measured only ${engine.elapsedSeconds}s of signal within $timeout',
  );
}

/// Enough signal for a 300 ms averager to settle: five time constants leaves
/// under 1% of the step remaining.
const _settleSeconds = 1.6;

void main() {
  test('bindings match the compiled ABI', () {
    expect(BelEngine.abiVersion, BelEngine.expectedAbiVersion);
    expect(BelEngine.versionString, isNotEmpty);
  });

  test('test tone reads its own arithmetic', () async {
    final engine = BelEngine.start(source: BelSource.testTone);
    addTearDown(engine.dispose);

    await _measure(engine, _settleSeconds);

    expect(engine.sampleRate, 48000);
    expect(engine.channels, 2);
    expect(engine.isRunning, isTrue);
    expect(engine.elapsedSeconds, greaterThanOrEqualTo(_settleSeconds));

    expect(engine.peak[0], closeTo(_tonePeakDb, _toleranceDb));
    expect(engine.rms[0], closeTo(_toneRmsDb, _toleranceDb));

    // Peak minus RMS is the crest factor of a sine, which is a constant.
    expect(engine.peak[0] - engine.rms[0], closeTo(3.0103, _toleranceDb));
  });

  test('measured quantities are measured, unmeasured ones say so', () async {
    final engine = BelEngine.start(source: BelSource.testTone);
    addTearDown(engine.dispose);

    // Long enough for short-term loudness, whose window is 3 s. Momentary
    // needs only 400 ms, and integrated needs one gating block above the
    // absolute gate — the three become defined at different times, which is
    // itself worth exercising here.
    await _measure(engine, 3.5);

    // Loudness landed together with the conformance suite that proves it —
    // see conformance_test.dart. The flag stays in the ABI as the mechanism
    // for saying "not measured here", and consumers must keep checking it; it
    // is simply not set by this build.
    expect(engine.hasLoudness, isTrue);
    expect(engine.lufsMomentary.isNaN, isFalse);
    expect(engine.lufsShort.isNaN, isFalse);
    expect(engine.truePeak.isNaN, isFalse);
    expect(engine.truePeakMax.isNaN, isFalse);
    expect(engine.samplePeakMax.isNaN, isFalse);
    expect(engine.crestFactor.isNaN, isFalse);
    expect(engine.correlation.isNaN, isFalse);

    // A true peak below the sample peak is impossible — the interpolated
    // waveform passes through every sample.
    expect(engine.truePeakMax, greaterThanOrEqualTo(engine.samplePeakMax));

    // The spectrum is measured now, and the test tone is a 1 kHz sine, so the
    // loudest band has to be the one containing 1 kHz. A spectrum that is
    // merely *present* proves nothing — an FFT with its bands mapped backwards
    // still fills the array.
    expect(engine.hasSpectrum, isTrue);

    var loudest = 0;
    for (var band = 1; band < kBelSpectrumBands; band++) {
      if (engine.spectrum[band] > engine.spectrum[loudest]) loudest = band;
    }
    expect(bandCentreHz(loudest), closeTo(1000, 20));

    // Amplitude 0.5 on the left and up to 0.65 on the tilted right, so the
    // louder of the two sits between -6.02 and -3.74 dBFS, less up to 1.4 dB
    // of Hann scalloping — 1 kHz does not land on a bin centre at 48 kHz.
    expect(engine.spectrum[loudest], inInclusiveRange(-8.0, -3.0));

    // And the rest of the spectrum is not merely a copy of it.
    expect(engine.spectrum[10], lessThan(-40.0));
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

    await _measure(engine, _settleSeconds);

    expect(engine.peak[0], closeTo(kBelDbFloor, 0.001));
    expect(engine.rms[0], closeTo(kBelDbFloor, 0.001));

    // Not -infinity: differences of dB values are meaningful here, and
    // -inf minus -inf is NaN.
    expect(engine.rms[0].isFinite, isTrue);
  });

  test('reset clears the integrators', () async {
    final engine = BelEngine.start(source: BelSource.testTone);
    addTearDown(engine.dispose);

    await _measure(engine, _settleSeconds);
    final before = engine.elapsedSeconds;
    expect(before, greaterThanOrEqualTo(_settleSeconds));

    engine.reset();

    // The reset is honoured by the analysis thread at a block boundary, so it
    // is not instantaneous. Poll for the elapsed clock going *backwards*
    // rather than for it landing under some absolute figure — how much signal
    // the engine has measured again by the time we look is a property of the
    // host, not of reset.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var cleared = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      engine.refresh();
      if (engine.elapsedSeconds < before) {
        cleared = true;
        break;
      }
    }
    expect(cleared, isTrue, reason: 'reset did not clear the elapsed clock');
  });

  test('an unimplemented source fails loudly', () {
    // File decoding is Phase 5. Silently substituting the test tone would let
    // somebody believe they had analysed their master.
    expect(
      () => BelEngine.start(source: BelSource.file),
      throwsA(isA<BelEngineException>()),
    );
  });

  test('an unknown device id fails rather than falling back', () {
    // Falling back to the default device would be the friendly-looking choice
    // and the wrong one: a preset naming an interface that is not plugged in
    // would silently meter the laptop microphone instead, and every reading
    // after that would be of the wrong signal.
    expect(
      () => BelEngine.start(
        source: BelSource.device,
        deviceId: 'deadbeefdeadbeef',
      ),
      throwsA(isA<BelEngineException>()),
    );
  });

  test('capture devices can be enumerated', () {
    // May legitimately be empty — a headless CI runner has no audio backend at
    // all, and that is a usable state rather than an error. What must hold is
    // that anything reported is well formed enough to put in a preset and show
    // to a human.
    final devices = BelEngine.devices();
    for (final device in devices) {
      expect(device.id, isNotEmpty);
      expect(device.name, isNotEmpty);
      expect(device.channels, lessThanOrEqualTo(kBelMaxChannels));
    }
    expect(devices.where((d) => d.isDefault).length, lessThanOrEqualTo(1));
  });
}
