// SPDX-License-Identifier: MIT
//
// The VU meter, held against the mechanism it imitates.
//
// A VU meter is worth having only because it reads *differently* from an RMS
// meter, and there are exactly two reasons it does. Both are asserted here,
// because a VU that has quietly become an RMS meter with a needle drawn on it
// still looks entirely convincing:
//
//   1. It is average-responding and RMS-calibrated. The movement follows the
//      mean of the rectified signal; the scale is then calibrated so a sine
//      reads its RMS. Those two coincide only for a sine, so anything peakier
//      reads lower — which is the measurement.
//
//   2. It is second order, reaching 99% of a step in 300 ms with a little
//      overshoot. A one-pole smoother matches the 300 ms and never overshoots,
//      so it passes any test of where the needle settles and fails every test
//      of how it gets there.
//
// Levels here are dBFS. Zero VU is a property of the calibration, not of the
// signal, so the reference offset is applied where the meter is drawn and none
// of these numbers carry it.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bel_engine/bel_engine.dart';
import 'package:test/test.dart';

const _sampleRate = 48000;

/// One analysis block. Pushing at this size is what the engine does for every
/// real source, and the ballistics advance once per block — so a test that
/// pushed a second at a time would be measuring a needle that had been given
/// one enormous step, which is not the thing under test.
const _blockFrames = 1024;

/// Pushes `seconds` of audio produced by [sample], one analysis block at a
/// time, and returns the engine.
BelEngine _push(
  BelEngine engine,
  double seconds,
  double Function(int index) sample, {
  int channels = 2,
}) {
  final total = (seconds * _sampleRate).round();
  final buffer = Float32List(_blockFrames * channels);

  for (var start = 0; start < total; start += _blockFrames) {
    for (var i = 0; i < _blockFrames; i++) {
      final value = sample(start + i);
      for (var c = 0; c < channels; c++) {
        buffer[i * channels + c] = value;
      }
    }
    engine.push(buffer);
  }
  return engine;
}

BelEngine _engine() {
  final engine = BelEngine.start(
    source: BelSource.push,
    sampleRate: _sampleRate,
    channels: 2,
  );
  addTearDown(engine.dispose);
  return engine;
}

double Function(int) _sine(double amplitude, [double hz = 1000]) =>
    (i) => amplitude * math.sin(2 * math.pi * hz * i / _sampleRate);

void main() {
  test('a steady sine reads its own RMS', () {
    // This is what "RMS-calibrated" means, and it is the one signal for which
    // a VU and an RMS meter must agree exactly. If the pi/(2*sqrt(2)) factor
    // were missing the needle would sit 0.91 dB low here and nowhere else,
    // which is precisely small enough to be mistaken for ballistics.
    for (final amplitude in [1.0, 0.5, 0.1]) {
      final engine = _push(_engine(), 2.0, _sine(amplitude));
      final expected = 20 * math.log(amplitude / math.sqrt2) / math.ln10;

      expect(engine.vu[0], closeTo(expected, 0.1));
      expect(engine.vu[0], closeTo(engine.rms[0], 0.1));
    }
  });

  test('a peaky signal reads below its RMS', () {
    // A pulse train: one full-scale sample in every ten. Both meters can be
    // written down exactly.
    //
    //   mean|x| = 0.1        -> VU  = 20*log10(0.1 * 1.1107) = -19.09 dBFS
    //   rms     = sqrt(0.1)  -> RMS = 20*log10(0.31623)      = -10.00 dBFS
    //
    // Nine decibels apart. An RMS meter wearing a needle would read -10 here.
    final engine = _push(_engine(), 2.0, (i) => i % 10 == 0 ? 1.0 : 0.0);

    expect(engine.vu[0], closeTo(-19.09, 0.2));
    expect(engine.rms[0], closeTo(-10.0, 0.2));
    expect(engine.rms[0] - engine.vu[0], greaterThan(8.0));
  });

  test('the needle reaches 99% of a step in 300 ms', () {
    final engine = _push(_engine(), 0.3, _sine(0.5));

    // 99% of the deflection is 20*log10(0.99) = 0.087 dB short of the target,
    // so at exactly 300 ms the reading is within a tenth of a decibel of where
    // it is going to settle.
    final settled = 20 * math.log(0.5 / math.sqrt2) / math.ln10;
    expect(engine.vu[0], closeTo(settled, 0.15));
  });

  test('the needle is still climbing at 100 ms', () {
    // The other half of the ballistics. A meter that jumped straight to its
    // target would pass the 300 ms test above and be useless to watch.
    final engine = _push(_engine(), 0.1, _sine(0.5));

    final settled = 20 * math.log(0.5 / math.sqrt2) / math.ln10;
    expect(engine.vu[0], lessThan(settled - 1.0));
    expect(engine.vu[0], greaterThan(settled - 12.0));
  });

  test('the needle overshoots, which a one-pole cannot', () {
    // The distinguishing behaviour, and the reason this is a second-order
    // model at all. Sample densely through the step and look for a reading
    // above where it settles.
    final engine = _engine();
    final settled = 20 * math.log(0.5 / math.sqrt2) / math.ln10;
    final tone = _sine(0.5);

    var highest = kBelDbFloor;
    final buffer = Float32List(_blockFrames * 2);
    for (var block = 0; block < 40; block++) {
      for (var i = 0; i < _blockFrames; i++) {
        final value = tone(block * _blockFrames + i);
        buffer[i * 2] = value;
        buffer[i * 2 + 1] = value;
      }
      engine.push(buffer);
      highest = math.max(highest, engine.vu[0]);
    }

    expect(highest, greaterThan(settled));
    // ...but not by much. The standard allows 1 to 1.5%; more than 3% would be
    // a meter that rings rather than one that leans into a transient.
    expect(highest - settled, lessThan(0.26));
  });

  test('the needle falls back to rest on silence and stays there', () {
    final engine = _push(_engine(), 1.0, _sine(0.5));
    expect(engine.vu[0], greaterThan(-15.0));

    _push(engine, 2.0, (_) => 0.0);

    // Not merely low: at rest. An underdamped movement that was allowed to
    // swing negative would come back through the floor and flicker there,
    // because the dB conversion of a negative deflection is not a number.
    expect(engine.vu[0], kBelDbFloor);
  });
}
