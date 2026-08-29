// SPDX-License-Identifier: GPL-3.0-or-later
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

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:oaa_engine/oaa_engine.dart';
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
  OaaEngine engine,
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
  _silenceGateTests();

  test('bindings match the compiled ABI', () {
    expect(OaaEngine.abiVersion, OaaEngine.expectedAbiVersion);
    expect(OaaEngine.versionString, isNotEmpty);
  });

  test('test tone reads its own arithmetic', () async {
    final engine = OaaEngine.start(source: OaaSource.testTone);
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
    final engine = OaaEngine.start(source: OaaSource.testTone);
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
    for (var band = 1; band < kOaaSpectrumBands; band++) {
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
      final engine = OaaEngine.start(source: OaaSource.testTone);
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
    final engine = OaaEngine.start(source: OaaSource.silence);
    addTearDown(engine.dispose);

    await _measure(engine, _settleSeconds);

    expect(engine.peak[0], closeTo(kOaaDbFloor, 0.001));
    expect(engine.rms[0], closeTo(kOaaDbFloor, 0.001));

    // Not -infinity: differences of dB values are meaningful here, and
    // -inf minus -inf is NaN.
    expect(engine.rms[0].isFinite, isTrue);
  });

  // **The floor has to be a floor, and for the two window readings it was a
  // substitute for -inf instead.** They clamped by comparing the result
  // against -HUGE_VAL, which an energy of exactly zero produces and nothing
  // else does. What a momentary window actually holds once the signal stops is
  // the tail of the K-weighting filters ringing out — an energy of 1e-90,
  // reported faithfully as -1860 LUFS — and the reading went on falling for as
  // long as that tail took to age out of the window, then jumped back *up* to
  // the floor at the moment it did. The bars drawn from it fell off the bottom
  // of the scale, went, and put a hairline of fill back at the foot of the
  // track a second later; the same numbers reached the wire and the JSON
  // report, where a four-figure LUFS reading is a measurement of nothing.
  //
  // Pushed rather than generated, because the defect is in what happens to a
  // *window that had programme in it* — OaaSource.silence never puts any there
  // and never rings.
  test('loudness stops at the floor when the signal stops', () {
    const rate = 48000;
    const frames = 512;
    final engine = OaaEngine.start(
      source: OaaSource.push,
      sampleRate: rate,
      channels: 2,
      blockFrames: frames,
    );
    addTearDown(engine.dispose);

    var phase = 0.0;
    for (var i = 0; i < (5 * rate) ~/ frames; i++) {
      final tone = Float32List(frames * 2);
      for (var f = 0; f < frames; f++) {
        final sample = 0.2 * math.sin(phase);
        phase += 2 * math.pi * 1000 / rate;
        tone[f * 2] = sample;
        tone[f * 2 + 1] = sample;
      }
      engine.push(tone);
    }
    expect(
      engine.lufsMomentary,
      greaterThan(-30.0),
      reason: 'the tone has to be measured before the silence means anything',
    );

    final silence = Float32List(frames * 2);
    var lowestMomentary = 0.0;
    var lowestShort = 0.0;
    for (var i = 0; i < (6 * rate) ~/ frames; i++) {
      engine.push(silence);
      lowestMomentary = math.min(lowestMomentary, engine.lufsMomentary);
      lowestShort = math.min(lowestShort, engine.lufsShort);
    }

    // Six seconds is twice the short-term window, so both have long since
    // emptied — and the excursion, when there was one, was over by then and
    // would be invisible in the final reading alone.
    expect(lowestMomentary, greaterThanOrEqualTo(kOaaDbFloor));
    expect(lowestShort, greaterThanOrEqualTo(kOaaDbFloor));
    expect(engine.lufsMomentary, closeTo(kOaaDbFloor, 0.001));
    expect(engine.lufsShort, closeTo(kOaaDbFloor, 0.001));
  });

  test('reset clears the integrators', () async {
    final engine = OaaEngine.start(source: OaaSource.testTone);
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

  test('a reserved source fails loudly', () {
    // A file is decoded by the caller and pushed, so that offline analysis is
    // the same `oaa_analyse` over the same buffers as realtime. Silently
    // substituting the test tone for a source the ABI declares but does not
    // accept would let somebody believe they had analysed their master.
    expect(
      () => OaaEngine.start(source: OaaSource.file),
      throwsA(isA<OaaEngineException>()),
    );
  });

  // --- Clip -----------------------------------------------------------------
  //
  // The published counter is the longest run since the reset, not the run that
  // happened to be alive at the block boundary. The distinction is the whole
  // measurement: a run is zeroed by the next sample below full scale, so the
  // boundary value is zero for every clip that ended inside the block — which
  // is nearly all of them — and the Digital Meter's clip lamp is fed from it.
  group('clip', () {
    /// One block of [frames] frames, quiet apart from [runLength] consecutive
    /// full-scale samples starting at [runStart].
    Float32List block({
      int frames = 1024,
      int channels = 2,
      required int runStart,
      required int runLength,
    }) {
      final data = Float32List(frames * channels);
      for (var i = 0; i < frames; i++) {
        final clipped = i >= runStart && i < runStart + runLength;
        for (var c = 0; c < channels; c++) {
          data[i * channels + c] = clipped ? 1.0 : 0.1;
        }
      }
      return data;
    }

    test('a run that ends inside the block is still reported', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(block(runStart: 400, runLength: 40));

      // Before the latch this read 0: the run was over by sample 440 and the
      // publish carried the counter's value at sample 1023.
      expect(engine.clip[0], 40);
      expect(engine.clip[1], 40);
    });

    test(
      'the worst run is kept, and a later quiet block does not clear it',
      () {
        final engine = OaaEngine.start(
          source: OaaSource.push,
          blockFrames: 1024,
        );
        addTearDown(engine.dispose);

        engine.push(block(runStart: 10, runLength: 12));
        engine.push(block(runStart: 500, runLength: 3));
        expect(engine.clip[0], 12, reason: 'a shorter run must not replace it');

        engine.push(Float32List(1024 * 2));
        expect(
          engine.clip[0],
          12,
          reason:
              'a clip lamp you can miss by looking away does not do its job',
        );
      },
    );

    test('reset clears it', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(block(runStart: 0, runLength: 8));
      expect(engine.clip[0], 8);

      // No thread on a pushed source, so the reset happens in place and the
      // next push is measured against a clean counter.
      engine.reset();
      engine.push(Float32List(1024 * 2));
      expect(engine.clip[0], 0);
    });

    test('silence never reports a clip', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(Float32List(1024 * 2));
      expect(engine.clip[0], 0);
    });
  });

  // --- The stereo field -----------------------------------------------------
  //
  // Correlation is 0/0 when neither channel carries energy, and the engine used
  // to answer `0` and let the 200 ms smoother chase it. A one-pole never
  // arrives, so the published reading kept the *sign* of the last audio for as
  // long as the silence lasted: a track fading out on a wide reverb tail ends
  // slightly out of phase, and the Phase Scope then held its marker a pixel off
  // centre and lit it in the warning colour — asserting anti-phase content in a
  // signal that had stopped — until the exponential underflowed twenty-odd
  // seconds later. It was reported as a meter that would not return to centre.
  group('stereo field', () {
    /// One block of a constant pair, so its correlation is exactly ±1 and its
    /// balance is exactly 0.
    Float32List pair(double left, double right, {int frames = 1024}) {
      final data = Float32List(frames * 2);
      for (var i = 0; i < frames; i++) {
        data[i * 2] = left;
        data[i * 2 + 1] = right;
      }
      return data;
    }

    test('a stereo pair says nothing until it has been handed audio', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      expect(engine.correlation.isNaN, isTrue);
      expect(engine.balance.isNaN, isTrue);
    });

    test('silence has no correlation and no balance', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(pair(0.5, -0.5));
      expect(engine.correlation, closeTo(-1.0, 1e-5));

      engine.push(Float32List(1024 * 2));
      expect(
        engine.correlation.isNaN,
        isTrue,
        reason: 'a signal that has stopped is not a signal out of phase',
      );
      expect(engine.balance.isNaN, isTrue);

      // And it stays undefined rather than creeping back towards a number.
      for (var i = 0; i < 50; i++) {
        engine.push(Float32List(1024 * 2));
      }
      expect(engine.correlation.isNaN, isTrue);
    });

    test('audio after silence is measured, not mixed with a NaN', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(pair(0.5, -0.5));
      engine.push(Float32List(1024 * 2));
      expect(engine.correlation.isNaN, isTrue);

      // The smoother's state *is* the published field, so the first block back
      // has to seed it. Mixing would give NaN for the rest of the session.
      engine.push(pair(0.5, 0.5));
      expect(engine.correlation, closeTo(1.0, 1e-5));
      expect(engine.balance, closeTo(0.0, 1e-5));
    });

    test('the sign of the last audio does not survive the silence', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      // A tail that ends out of phase, the way a wide reverb does.
      engine.push(pair(0.5, -0.5));
      engine.push(Float32List(1024 * 2));

      expect(
        engine.correlation.isNaN || engine.correlation >= 0,
        isTrue,
        reason: 'the warning colour was latched by arithmetic, not by audio',
      );
    });

    test('a noise floor is not a stereo image', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      // A live input with nothing playing into it is never *exactly* zero, and
      // the correlation of two channels of noise is a random number near zero
      // whose sign falls whichever way the block did — so a guard at float
      // underflow would answer honestly for a stopped software player and go
      // on rolling dice for a converter sitting idle. −100 dBFS, well under
      // the −70 LUFS gate.
      final random = math.Random(7);
      final floor = Float32List(1024 * 2);
      for (var i = 0; i < 1024; i++) {
        floor[i * 2] = (random.nextDouble() - 0.5) * 2e-5;
        floor[i * 2 + 1] = (random.nextDouble() - 0.5) * 2e-5;
      }

      engine.push(pair(0.5, 0.5));
      for (var i = 0; i < 20; i++) {
        engine.push(floor);
        expect(
          engine.correlation.isNaN,
          isTrue,
          reason: 'the noise floor is not a signal to correlate',
        );
        expect(engine.balance.isNaN, isTrue);
      }
    });

    test('a hard-panned source has a balance but no correlation', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(pair(0.5, 0.0));
      expect(
        engine.correlation.isNaN,
        isTrue,
        reason: 'there is nothing in the right channel to correlate with',
      );
      expect(
        engine.balance,
        closeTo(-1.0, 1e-5),
        reason: 'which side it is on is exactly what balance is for',
      );
    });

    test('a mono source answers for itself', () {
      final engine = OaaEngine.start(
        source: OaaSource.push,
        channels: 1,
        blockFrames: 1024,
      );
      addTearDown(engine.dispose);

      // True before any audio and true after it: one channel is perfectly
      // correlated with itself and dead centre, which is not the same claim as
      // the one silence cannot make.
      expect(engine.correlation, 1.0);
      expect(engine.balance, 0.0);

      engine.push(Float32List(1024));
      expect(engine.correlation, 1.0);
      expect(engine.balance, 0.0);
    });
  });

  // --- The scope window -----------------------------------------------------
  //
  // `scope` holds the newest four blocks, not the newest one, because a reader
  // at the display's rate misses publishes — a 10.7 ms block at 96 kHz against
  // a 16.7 ms tick, an engine catching up, a plugin pushing two blocks per host
  // callback — and a scope drew every missed block as silence. See
  // OAA_SCOPE_FRAMES in oaa.h. The window fills from the front, slides once it
  // is full, and `scopeFrames` says how much of it is audio, so a reader can
  // always take "the newest N pairs" as the N before the count.
  group('scope window', () {
    /// One block whose every frame is ([value], −[value]), so a block is
    /// readable back off any sample of it.
    Float32List block(double value, {int frames = 1024}) {
      final data = Float32List(frames * 2);
      for (var i = 0; i < frames; i++) {
        data[i * 2] = value;
        data[i * 2 + 1] = -value;
      }
      return data;
    }

    test('holds the blocks pushed, oldest first, and counts them', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(block(0.1));
      expect(engine.scopeFrames, 1024);

      engine.push(block(0.2));
      engine.push(block(0.3));
      expect(engine.scopeFrames, 3072);
      expect(engine.scope[0], closeTo(0.1, 1e-6), reason: 'oldest first');
      expect(engine.scope[1024 * 2], closeTo(0.2, 1e-6));
      expect(engine.scope[2048 * 2], closeTo(0.3, 1e-6));
      expect(engine.scope[2048 * 2 + 1], closeTo(-0.3, 1e-6));
    });

    test('a fifth block drops the oldest, never the newest', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      for (final value in [0.1, 0.2, 0.3, 0.4, 0.5]) {
        engine.push(block(value));
      }
      expect(engine.scopeFrames, kOaaScopeFrames);
      expect(
        engine.scope[0],
        closeTo(0.2, 1e-6),
        reason: 'the window slid by one block and 0.1 fell off the front',
      );
      expect(engine.scope[(kOaaScopeFrames - 1) * 2], closeTo(0.5, 1e-6));
    });

    test('a push larger than the window keeps its newest four blocks', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      const frames = 5000;
      final ramp = Float32List(frames * 2);
      for (var i = 0; i < frames; i++) {
        ramp[i * 2] = i / frames;
        ramp[i * 2 + 1] = -i / frames;
      }
      engine.push(ramp);

      expect(engine.scopeFrames, kOaaScopeFrames);
      expect(
        engine.scope[0],
        closeTo((frames - kOaaScopeFrames) / frames, 1e-6),
      );
      expect(
        engine.scope[(kOaaScopeFrames - 1) * 2],
        closeTo((frames - 1) / frames, 1e-6),
        reason: 'the last sample pushed is the last sample held',
      );
    });

    test('reset empties it', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(block(0.4));
      engine.push(block(0.4));
      engine.reset();
      // A push acquires; a reset publishes and leaves the acquiring to the
      // reader, so ask before looking.
      engine.refresh();
      expect(engine.scopeFrames, 0);

      engine.push(block(0.6));
      expect(engine.scopeFrames, 1024);
      expect(engine.scope[0], closeTo(0.6, 1e-6));
    });
  });

  // --- Crest ----------------------------------------------------------------
  //
  // Sample peak minus RMS over the same block. Both operands were once the
  // *displayed* values, which carry a 1.5 s hold and a 300 ms averager, so the
  // figure described the ballistics rather than the audio. The steady-state
  // sine is 3.0103 dB either way, which is why the sine case above never
  // caught it — these are the cases that do.
  group('crest', () {
    Float32List constant(double value, {int frames = 1024, int channels = 2}) {
      final data = Float32List(frames * channels);
      for (var i = 0; i < data.length; i++) {
        data[i] = value;
      }
      return data;
    }

    test('DC has no crest', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      // Peak and RMS of a constant are the same number, so the answer is 0.
      // With the held peak and the smoothed RMS this read 11.63 dB on the
      // first block, because the averager had not caught up with the step.
      engine.push(constant(0.9));
      expect(engine.crestFactor, closeTo(0.0, 0.01));
    });

    test('a transient does not leave it inflated', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      engine.push(constant(0.9));
      for (var block = 0; block < 20; block++) {
        engine.push(constant(0.001));
      }

      // 0.43 s after the transient this read 17.81 dB and was still climbing:
      // the peak was still held near full scale while the RMS decayed under
      // it. The blocks being measured are DC, so the answer is still 0.
      expect(engine.crestFactor, closeTo(0.0, 0.01));
    });

    test('a sine is 3.0103 dB', () {
      final engine = OaaEngine.start(
        source: OaaSource.push,
        sampleRate: 48000,
        blockFrames: 4800,
      );
      addTearDown(engine.dispose);

      // A whole number of cycles, so the block's own RMS is exactly A/sqrt(2)
      // and the expected value is arithmetic rather than a tolerance.
      const frames = 4800;
      final data = Float32List(frames * 2);
      for (var i = 0; i < frames; i++) {
        final sample = 0.5 * math.sin(2 * math.pi * 1000 * i / 48000);
        data[i * 2] = sample;
        data[i * 2 + 1] = sample;
      }
      engine.push(data);

      expect(engine.crestFactor, closeTo(3.0103, 0.01));
    });

    test('the peakiest channel is the one reported', () {
      final engine = OaaEngine.start(source: OaaSource.push, blockFrames: 1024);
      addTearDown(engine.dispose);

      // Left is DC, so no crest at all. Right is one full-scale sample in a
      // block of near-silence, so a very large one. Reporting the loudest peak
      // minus the loudest RMS mixed the two channels and described neither.
      const frames = 1024;
      final data = Float32List(frames * 2);
      for (var i = 0; i < frames; i++) {
        data[i * 2] = 0.5;
        data[i * 2 + 1] = i == 500 ? 1.0 : 0.001;
      }
      engine.push(data);

      final right = 20 * math.log(1.0) / math.ln10;
      final rightRms =
          10 *
          math.log((1.0 + (frames - 1) * 0.001 * 0.001) / frames) /
          math.ln10;
      expect(engine.crestFactor, closeTo(right - rightRms, 0.05));
    });
  });

  test('an unknown device id fails rather than falling back', () {
    // Falling back to the default device would be the friendly-looking choice
    // and the wrong one: a preset naming an interface that is not plugged in
    // would silently meter the laptop microphone instead, and every reading
    // after that would be of the wrong signal.
    expect(
      () => OaaEngine.start(
        source: OaaSource.device,
        deviceId: 'deadbeefdeadbeef',
      ),
      throwsA(isA<OaaEngineException>()),
    );
  });

  test('capture devices can be enumerated', () {
    // May legitimately be empty — a headless CI runner has no audio backend at
    // all, and that is a usable state rather than an error. What must hold is
    // that anything reported is well formed enough to put in a preset and show
    // to a human.
    final devices = OaaEngine.devices();
    for (final device in devices) {
      expect(device.id, isNotEmpty);
      expect(device.name, isNotEmpty);
      expect(device.channels, lessThanOrEqualTo(kOaaMaxChannels));
    }
    expect(devices.where((d) => d.isDefault).length, lessThanOrEqualTo(1));
  });

  test('a source with no producer is never reported as stopped', () {
    // OAA_FLAG_SOURCE_STOPPED is a statement about a capture device that has
    // gone away, and the generated sources have nothing that can go — the
    // analysis thread is the producer. A flag that leaked onto them would put
    // "the source has stopped sending audio" over a working test tone, which is
    // the one kind of warning worse than no warning.
    final engine = OaaEngine.start(source: OaaSource.testTone);
    addTearDown(engine.dispose);
    engine.refresh();
    expect(engine.isSourceStopped, isFalse);
  });

  group('system output', () {
    // The macOS Core Audio process tap, which appears in the device list as an
    // ordinary entry so that nothing above the engine has to know it is not a
    // sound card.
    //
    // Every assertion here is conditional on the entry existing, and that is
    // deliberate rather than lazy: it is offered only on macOS 14.2 and later,
    // and only when there is a default output device to tap. A Linux runner, a
    // Windows runner and a Mac with no output all legitimately have none, so a
    // test that demanded one would fail on three machines where the code is
    // behaving correctly.

    OaaDevice? systemOutput() {
      final matches = OaaEngine.devices().where((d) => d.isSystemOutput);
      return matches.isEmpty ? null : matches.first;
    }

    test('is offered on macOS only, and at most once', () {
      final devices = OaaEngine.devices();
      final taps = devices.where((d) => d.isSystemOutput).toList();
      expect(taps.length, lessThanOrEqualTo(1));
      if (!Platform.isMacOS) {
        // Windows already exposes WASAPI loopback as a real device and Linux a
        // monitor source, so an entry here would be a second way to do the
        // same thing — and on those platforms oaa_device_open refuses the id
        // outright rather than falling back to an input.
        expect(taps, isEmpty);
        expect(
          () => OaaEngine.start(
            source: OaaSource.device,
            deviceId: kOaaSystemOutputDeviceId,
          ),
          throwsA(isA<OaaEngineException>()),
        );
      }
    });

    test('advertises a format a preset can hold', () {
      final tap = systemOutput();
      if (tap == null) return;

      expect(tap.id, kOaaSystemOutputDeviceId);
      expect(tap.name, isNotEmpty);
      // It captures system output by construction, which is the one case where
      // the flag can be set without a backend reporting it.
      expect(tap.isLoopback, isTrue);
      // Never the default *capture* device — that belongs to whatever the
      // system nominated out of the real hardware.
      expect(tap.isDefault, isFalse);
      expect(tap.channels, inInclusiveRange(1, kOaaMaxChannels));
      expect(tap.sampleRate, greaterThan(0));
    });

    test('opens at the format enumeration advertised', () {
      final tap = systemOutput();
      if (tap == null) return;

      // Probe and open ask two different Core Audio objects the same question —
      // enumeration reads the output stream's virtual format, open reads the
      // created tap's. They are supposed to be the same number, and if they
      // ever drift the ring is sized for one format while the callback writes
      // the other. Nothing about that is visible on screen; it is a buffer
      // overread.
      final engine = OaaEngine.start(
        source: OaaSource.device,
        deviceId: kOaaSystemOutputDeviceId,
      );
      addTearDown(engine.dispose);

      expect(engine.channels, tap.channels);
      expect(engine.sampleRate, tap.sampleRate);
    });

    test(
      'delivering nothing is not the same as having stopped',
      () async {
        // **Five minutes on the timeout below, because opening the tap is what
        // takes the time.** On a machine that has never granted
        // `kTCCServiceAudioCapture` — a CI runner, where nobody can answer the
        // check either — creating the process tap blocks for about three
        // minutes before it returns. The sibling above pays the same three
        // minutes and does not trip the default 30 seconds, because it is
        // synchronous: a blocking FFI call holds the isolate, so the timer that
        // would fire never runs until the test has already finished. This one
        // awaits, the loop turns, and the timeout fires 30 seconds into an open
        // that has not returned yet.
        final tap = systemOutput();
        if (tap == null) return;

        final engine = OaaEngine.start(
          source: OaaSource.device,
          deviceId: kOaaSystemOutputDeviceId,
        );
        addTearDown(engine.dispose);

        // Long enough for several of the engine's own polls, which run every
        // 250 ms.
        await Future<void>.delayed(const Duration(milliseconds: 800));
        engine.refresh();

        // An output device with nothing playing through it has an idle clock,
        // and the IO proc does not fire at all: on a Mac with no audio playing
        // this engine has received precisely zero frames and `elapsedSeconds`
        // is still zero. **That is the state a watchdog built on "no audio for
        // a while" would call a fault**, and it is the reason
        // `oaa_device_running` asks the source about itself instead of timing
        // its output. Rebuilding a healthy Core Audio aggregate four times a
        // second on a quiet machine — and charging every rebuild to
        // `dropped_frames` as lost audio — would be a considerably worse bug
        // than the freeze the flag exists to report.
        //
        // Deliberately not asserting that no frames arrived: if somebody is
        // playing music while the suite runs, they will have. Neither of these
        // depends on which.
        expect(engine.isSourceStopped, isFalse);
        expect(engine.droppedFrames, 0);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'the tap\'s own aggregate device is not offered as a source',
      () {
        final tap = systemOutput();
        if (tap == null) return;

        // A tap is read through a *private aggregate device*, and private means
        // private to every process but this one. This process is the one
        // drawing the source menu, and to miniaudio that aggregate is an
        // ordinary capture device with an input stream and a name — so opening
        // the menu while the tap ran offered "Open Audio Analyzer System
        // Capture" underneath the System Output entry that had built it. The
        // application's own plumbing, presented as something to meter.
        //
        // Enumerated *while an engine holds the tap*, because that is the only
        // window in which the device exists at all. The list is filtered by
        // UID rather than by the name asserted here; the name is what a user
        // would have seen.
        final before = OaaEngine.devices().length;

        final engine = OaaEngine.start(
          source: OaaSource.device,
          deviceId: kOaaSystemOutputDeviceId,
        );
        addTearDown(engine.dispose);

        final during = OaaEngine.devices();
        expect(during.where((d) => d.name.contains('System Capture')), isEmpty);
        // The stronger claim: the running tap added nothing at all. A device
        // genuinely arriving mid-test would fail this, which is worth the
        // vanishing risk — the alternative is a test that passes because the
        // name changed.
        expect(during.length, before);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  // The `oaa_engine_reset_all` cases are deliberately not here. They are a
  // program — `test/reclaim_orphans.dart` — run after this suite rather than
  // inside it, because a process-global reset cannot share a process with
  // anything. See that file, and this package's AGENTS.md.
}

/// The engine's half of the LUFS time modes.
///
/// Only [LufsTimeMode.system] reaches the engine at all — the two
/// transport-driven modes are the producer declining to push, which needs no
/// engine API and is tested against a real host in
/// `packages/oaa_wire/test/plugin_e2e_test.dart`.
void _silenceGateTests() {
  group('the silence gate', () {
    const frames = 1024;
    const rate = 48000;
    const blockSeconds = frames / rate;

    Float32List tone({double amplitude = 0.5, int channels = 2}) {
      final data = Float32List(frames * channels);
      for (var i = 0; i < frames; i++) {
        // A quarter-cycle-per-frame sine, which is signal by any measure and
        // nowhere near full scale.
        final sample = amplitude * math.sin(i * 0.05);
        for (var c = 0; c < channels; c++) {
          data[i * channels + c] = sample;
        }
      }
      return data;
    }

    Float32List quiet({int channels = 2}) => Float32List(frames * channels);

    /// Pushes enough silence to outlast [OAA_SILENCE_HOLD_SECONDS].
    void pushSilence(OaaEngine engine) {
      final blocks = (2.0 / blockSeconds).ceil() + 1;
      for (var i = 0; i < blocks; i++) {
        engine.push(quiet());
      }
    }

    test('is off unless asked, so nothing existing changes behaviour', () {
      final engine = OaaEngine.start(
        source: OaaSource.push,
        blockFrames: frames,
      );
      addTearDown(engine.dispose);

      engine.push(tone());
      final before = engine.elapsedSeconds;
      expect(before, greaterThan(0));

      pushSilence(engine);
      engine.push(tone());

      // The clock kept running straight through the gap: no reset happened.
      expect(engine.elapsedSeconds, greaterThan(before));
    });

    test('a return after silence restarts the measurement', () {
      final engine = OaaEngine.start(
        source: OaaSource.push,
        blockFrames: frames,
      )..silenceReset = true;
      addTearDown(engine.dispose);

      for (var i = 0; i < 20; i++) {
        engine.push(tone());
      }
      final firstRun = engine.elapsedSeconds;
      expect(firstRun, greaterThan(15 * blockSeconds));

      pushSilence(engine);
      engine.push(tone());

      // One block of the new take, not the old take plus the gap plus one.
      expect(
        engine.elapsedSeconds,
        lessThan(firstRun),
        reason: 'the elapsed clock restarted with the new audio',
      );
      expect(engine.elapsedSeconds, closeTo(blockSeconds, blockSeconds));
    });

    test('a gap shorter than the hold is not the end of the programme', () {
      final engine = OaaEngine.start(
        source: OaaSource.push,
        blockFrames: frames,
      )..silenceReset = true;
      addTearDown(engine.dispose);

      for (var i = 0; i < 20; i++) {
        engine.push(tone());
      }
      final before = engine.elapsedSeconds;

      // Half a second of rest, which is a musical pause and not a stop.
      final blocks = (0.5 / blockSeconds).floor();
      for (var i = 0; i < blocks; i++) {
        engine.push(quiet());
      }
      engine.push(tone());

      expect(
        engine.elapsedSeconds,
        greaterThan(before),
        reason: 'a held pause between movements must not restart the reading',
      );
    });

    test('the peak of the returning block is kept, not cleared by its own '
        'reset', () {
      // The reason the gate runs before the block it judges rather than after.
      // Material that opens on a transient is most material, and clearing the
      // peak that arrived with the reset would under-report every one of them.
      final engine = OaaEngine.start(
        source: OaaSource.push,
        blockFrames: frames,
      )..silenceReset = true;
      addTearDown(engine.dispose);

      engine.push(tone(amplitude: 0.2));
      pushSilence(engine);
      engine.push(tone(amplitude: 0.9));

      // dBFS, not linear: 0.9 is -0.915 dBFS. Had the reset run after the
      // block instead of before it, this would read the -14 dBFS of the tone
      // that follows in the *next* block, or nothing at all.
      expect(engine.samplePeakMax, closeTo(-0.915, 0.1));
    });

    test('turning it off forgets the silence it had accumulated', () {
      final engine = OaaEngine.start(
        source: OaaSource.push,
        blockFrames: frames,
      )..silenceReset = true;
      addTearDown(engine.dispose);

      engine.push(tone());
      pushSilence(engine);

      engine.silenceReset = false;
      final before = engine.elapsedSeconds;
      engine.push(tone());

      // No reset: the run it was in the middle of measuring continues.
      expect(engine.elapsedSeconds, greaterThan(before));
    });
  });
}
