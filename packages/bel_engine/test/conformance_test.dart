// SPDX-License-Identifier: MIT
//
// EBU Tech 3341 / 3342 conformance.
//
// This is the most important test in the project. A loudness meter that has
// never been run against the reference cases is a number generator, and every
// delivery decision a user makes rests on these numbers being right.
//
// The signals are **generated**, not downloaded. Every case below is a sine at
// a stated level, or a sequence of them, so it can be constructed exactly in a
// few lines — which means the suite runs on a headless CI runner with no
// fixtures, no network and no WAV decoder, and the "expected" values are
// derived from the standard rather than copied from somebody's output. Phase 5
// adds the official WAV vectors as an independent second check once there is a
// decoder to read them with.
//
// Why the expected values are what they are, since every one of them is
// checkable by hand:
//
//   A sine of peak amplitude A has mean square A²/2, i.e. its RMS sits 3.0103
//   dB below its peak. BS.1770-4 sums the K-weighted mean square across
//   channels and takes -0.691 + 10·log10 of the result. The K filter's gain at
//   1 kHz is +0.691 dB, which cancels that offset exactly. So for a stereo
//   1 kHz sine at -23 dBFS peak:
//
//       per channel RMS   -23 - 3.0103        = -26.0103 dBFS
//       two channels sum  -26.0103 + 3.0103   = -23.0000
//       K gain and offset +0.691 - 0.691      =  0
//                                               -23.0 LUFS
//
//   The channel count is load-bearing: the same signal in mono reads -26.01
//   LUFS, not -23.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bel_engine/bel_engine.dart';
import 'package:test/test.dart';

const _sampleRate = 48000;

/// EBU Tech 3341 states its tolerance as ±0.1 LU.
const _tolerance = 0.1;

/// A segment of constant-level 1 kHz tone.
class _Segment {
  const _Segment(this.seconds, this.dbfs);

  /// Duration.
  final double seconds;

  /// Peak level of the sine, dBFS. Silence is represented by null.
  final double? dbfs;
}

/// Pushes a sequence of tone segments through an engine, one second at a time.
///
/// Phase is carried across chunk and segment boundaries so the signal is a
/// continuous sine rather than a series of restarts — a discontinuity every
/// second would be broadband energy the K filter would faithfully measure, and
/// the readings would drift off the expected values for a reason that had
/// nothing to do with the loudness code.
void _pushSegments(
  BelEngine engine,
  List<_Segment> segments, {
  int channels = 2,
  double frequency = 1000.0,
  List<double>? channelGainsDb,
}) {
  var phase = 0.0;
  final step = 2 * math.pi * frequency / _sampleRate;

  for (final segment in segments) {
    var remaining = (segment.seconds * _sampleRate).round();

    while (remaining > 0) {
      final frames = math.min(remaining, _sampleRate);
      final buffer = Float32List(frames * channels);

      if (segment.dbfs != null) {
        final base = math.pow(10.0, segment.dbfs! / 20.0).toDouble();
        for (var i = 0; i < frames; i++) {
          final value = math.sin(phase);
          phase += step;
          if (phase >= 2 * math.pi) phase -= 2 * math.pi;
          for (var c = 0; c < channels; c++) {
            final gain = channelGainsDb == null
                ? 1.0
                : math.pow(10.0, channelGainsDb[c] / 20.0).toDouble();
            buffer[i * channels + c] = base * gain * value;
          }
        }
      } else {
        // Silence still has to advance the phase, or the tone would jump when
        // it resumes.
        phase += step * frames;
        phase %= 2 * math.pi;
      }

      engine.push(buffer);
      remaining -= frames;
    }
  }
}

BelEngine _pushEngine({int channels = 2}) => BelEngine.start(
  source: BelSource.push,
  sampleRate: _sampleRate,
  channels: channels,
);

void main() {
  group('EBU Tech 3341 — integrated loudness', () {
    test('case 1: stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(20, -23.0)]);

      expect(engine.hasLoudness, isTrue);
      expect(engine.lufsIntegrated, closeTo(-23.0, _tolerance));
      expect(engine.lufsShort, closeTo(-23.0, _tolerance));
      expect(engine.lufsMomentary, closeTo(-23.0, _tolerance));
    });

    test('case 2: the same signal at -33 dBFS reads -33.0 LUFS', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(20, -33.0)]);

      expect(engine.lufsIntegrated, closeTo(-33.0, _tolerance));
      expect(engine.lufsShort, closeTo(-33.0, _tolerance));
    });

    test(
      'case 3: quiet lead-in and tail are excluded by the relative gate',
      () {
        // 10 s at -36, 60 s at -23, 10 s at -36. The ungated mean lands near
        // -24.2 LUFS, putting the relative gate at about -34.2 — above the -36
        // sections, which therefore contribute nothing.
        final engine = _pushEngine();
        addTearDown(engine.dispose);

        _pushSegments(engine, const [
          _Segment(10, -36.0),
          _Segment(60, -23.0),
          _Segment(10, -36.0),
        ]);

        expect(engine.lufsIntegrated, closeTo(-23.0, _tolerance));
      },
    );

    test(
      'case 4: material below -70 LUFS is excluded by the absolute gate',
      () {
        final engine = _pushEngine();
        addTearDown(engine.dispose);

        _pushSegments(engine, const [
          _Segment(10, -72.0),
          _Segment(10, -36.0),
          _Segment(60, -23.0),
          _Segment(10, -36.0),
          _Segment(10, -72.0),
        ]);

        expect(engine.lufsIntegrated, closeTo(-23.0, _tolerance));
      },
    );

    test('case 5: nothing is gated out when everything is close together', () {
      // 20 s at -26, 20.1 s at -20, 20 s at -26. The relative gate lands near
      // -33, below both levels, so every block counts and the result is simply
      // the mean energy — which works out to -23.0.
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [
        _Segment(20, -26.0),
        _Segment(20.1, -20.0),
        _Segment(20, -26.0),
      ]);

      expect(engine.lufsIntegrated, closeTo(-23.0, _tolerance));
    });
  });

  group('channel weighting', () {
    test('mono reads 3.01 LU below the same signal in stereo', () {
      // Two identical channels carry twice the energy of one, and 10·log10(2)
      // is 3.0103. This is the assertion that would catch a weight table that
      // had been applied to the wrong channel index.
      final mono = _pushEngine(channels: 1);
      addTearDown(mono.dispose);
      _pushSegments(mono, const [_Segment(10, -23.0)], channels: 1);

      final stereo = _pushEngine();
      addTearDown(stereo.dispose);
      _pushSegments(stereo, const [_Segment(10, -23.0)]);

      expect(mono.lufsIntegrated, closeTo(-26.0103, _tolerance));
      expect(stereo.lufsIntegrated, closeTo(-23.0, _tolerance));
      expect(
        stereo.lufsIntegrated - mono.lufsIntegrated,
        closeTo(3.0103, 0.05),
      );
    });

    test('LFE is excluded, and surrounds are weighted +1.5 dB', () {
      // 5.1, SMPTE order: L R C LFE Ls Rs. Only the LFE channel carries
      // signal, at a level that would dominate if it counted at all.
      final lfeOnly = _pushEngine(channels: 6);
      addTearDown(lfeOnly.dispose);
      _pushSegments(
        lfeOnly,
        const [_Segment(10, -10.0)],
        channels: 6,
        channelGainsDb: const [-200, -200, -200, 0, -200, -200],
      );

      // Everything below the absolute gate, because the only audible channel
      // is the one the standard says to ignore.
      expect(
        lfeOnly.lufsIntegrated.isNaN,
        isTrue,
        reason: 'LFE was counted towards loudness',
      );

      // A surround channel alone should read 1.5 dB hotter than the same
      // signal on a front channel.
      final front = _pushEngine(channels: 6);
      addTearDown(front.dispose);
      _pushSegments(
        front,
        const [_Segment(10, -23.0)],
        channels: 6,
        channelGainsDb: const [0, -200, -200, -200, -200, -200],
      );

      final surround = _pushEngine(channels: 6);
      addTearDown(surround.dispose);
      _pushSegments(
        surround,
        const [_Segment(10, -23.0)],
        channels: 6,
        channelGainsDb: const [-200, -200, -200, -200, 0, -200],
      );

      // 10·log10(1.41) = 1.4923 dB.
      expect(
        surround.lufsIntegrated - front.lufsIntegrated,
        closeTo(1.4923, 0.05),
      );
    });
  });

  group('EBU Tech 3342 — loudness range', () {
    test('20 s at -20 followed by 20 s at -30 gives an LRA near 10 LU', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(20, -20.0), _Segment(20, -30.0)]);

      // Tech 3342 states ±1 LU for its own cases.
      expect(engine.loudnessRange, closeTo(10.0, 1.0));
    });

    test('a constant level has essentially no range', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(30, -23.0)]);

      expect(engine.loudnessRange, lessThan(1.0));
    });

    test('the published percentiles are the ones the range is taken from', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(20, -20.0), _Segment(20, -30.0)]);

      // The histogram module draws these two as lines across the
      // distribution. If they were computed separately from `loudnessRange` —
      // a second percentile walk, a different gate — they would drift apart
      // under exactly the material that makes LRA interesting, and the plot
      // would start disagreeing with the number printed beside it.
      expect(
        engine.loudnessRangeHigh - engine.loudnessRangeLow,
        closeTo(engine.loudnessRange, 1e-6),
      );

      // Both percentiles are inside the programme, and the gate is below both.
      expect(engine.loudnessRangeLow, closeTo(-30.0, 1.5));
      expect(engine.loudnessRangeHigh, closeTo(-20.0, 1.5));
      expect(engine.loudnessRangeGate, lessThan(engine.loudnessRangeLow));
    });

    test('the distribution is a distribution', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(20, -20.0), _Segment(20, -30.0)]);

      final total = engine.histogram.fold<double>(0, (sum, bin) => sum + bin);
      expect(total, closeTo(1.0, 1e-4));

      // Two level plateaus, so the mass sits in two places with a gap between.
      // A distribution that had quietly become "everything in one bin" would
      // still sum to one.
      int binOf(double lufs) =>
          ((lufs - kBelHistogramMinLufs) /
                  (kBelHistogramMaxLufs - kBelHistogramMinLufs) *
                  kBelHistogramBins)
              .floor();

      expect(engine.histogram[binOf(-30)], greaterThan(0.2));
      expect(engine.histogram[binOf(-20)], greaterThan(0.2));
      expect(engine.histogram[binOf(-25)], lessThan(0.05));
    });

    test('nothing measured means an empty distribution, not a flat one', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(1, null)]);

      expect(engine.loudnessRange.isNaN, isTrue);
      expect(engine.loudnessRangeLow.isNaN, isTrue);
      for (final bin in engine.histogram) {
        expect(bin, 0.0);
      }
    });
  });

  group('true peak', () {
    test('inter-sample peaks above the highest sample are found', () {
      // A 12 kHz sine at 48 kHz lands four samples per cycle. Shifted by 45°,
      // every sample sits at ±sin(45°) = ±0.7071 — a sample peak of -3.01
      // dBFS — while the waveform itself still reaches full scale between
      // them. A meter reading only samples calls this signal 3 dB quieter than
      // it is, which is exactly the mistake true peak exists to prevent.
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      const frames = _sampleRate * 2;
      final buffer = Float32List(frames * 2);
      for (var i = 0; i < frames; i++) {
        final value = math.sin(
          2 * math.pi * 12000 * i / _sampleRate + math.pi / 4,
        );
        buffer[i * 2] = value;
        buffer[i * 2 + 1] = value;
      }
      engine.push(buffer);

      expect(engine.samplePeakMax, closeTo(-3.0103, 0.01));
      expect(engine.truePeakMax, closeTo(0.0, 0.2));
      expect(
        engine.truePeakMax,
        greaterThan(engine.samplePeakMax),
        reason: 'true peak must never read below sample peak',
      );
    });

    test('a full-scale sine at a benign frequency reads about 0 dBTP', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(2, 0.0)]);

      expect(engine.truePeakMax, closeTo(0.0, 0.2));
    });
  });

  group('sample rate independence', () {
    test('the same tone reads the same loudness at every supported rate', () {
      // This is the test that catches the single most tempting shortcut in the
      // whole engine: using the 48 kHz coefficient table ITU-R BS.1770-4
      // prints, instead of designing the filter from the analog prototype at
      // the stream's actual rate.
      //
      // That shortcut passes every 48 kHz test there is. At 44.1 kHz it shifts
      // both corner frequencies by nearly 9%, and the error is a fraction of a
      // dB — small enough to look like rounding, on the most common delivery
      // rate in music. Only a cross-rate comparison exposes it.
      double measureAt(int sampleRate) {
        final engine = BelEngine.start(
          source: BelSource.push,
          sampleRate: sampleRate,
          channels: 2,
        );
        addTearDown(engine.dispose);

        const seconds = 10;
        final amplitude = math.pow(10.0, -23.0 / 20.0).toDouble();
        for (var second = 0; second < seconds; second++) {
          final buffer = Float32List(sampleRate * 2);
          for (var i = 0; i < sampleRate; i++) {
            final n = second * sampleRate + i;
            final value =
                amplitude * math.sin(2 * math.pi * 1000 * n / sampleRate);
            buffer[i * 2] = value;
            buffer[i * 2 + 1] = value;
          }
          engine.push(buffer);
        }
        return engine.lufsIntegrated;
      }

      for (final rate in [44100, 48000, 88200, 96000, 192000]) {
        expect(
          measureAt(rate),
          closeTo(-23.0, _tolerance),
          reason: 'loudness drifted at $rate Hz',
        );
      }
    });
  });

  group('block size independence', () {
    test('the same audio measured in different chunk sizes agrees', () {
      // The gating windows are counted in samples, so the size of the buffers
      // a caller happens to hand over must not change the answer. If this ever
      // fails, a device with an unusual buffer size would silently measure
      // differently from a file.
      double measure(int chunkFrames) {
        final engine = BelEngine.start(
          source: BelSource.push,
          sampleRate: _sampleRate,
          channels: 2,
        );
        addTearDown(engine.dispose);

        const totalFrames = _sampleRate * 10;
        final amplitude = math.pow(10.0, -23.0 / 20.0).toDouble();
        var written = 0;
        while (written < totalFrames) {
          final frames = math.min(chunkFrames, totalFrames - written);
          final buffer = Float32List(frames * 2);
          for (var i = 0; i < frames; i++) {
            final value =
                amplitude *
                math.sin(2 * math.pi * 1000 * (written + i) / _sampleRate);
            buffer[i * 2] = value;
            buffer[i * 2 + 1] = value;
          }
          engine.push(buffer);
          written += frames;
        }
        return engine.lufsIntegrated;
      }

      final inOneGo = measure(_sampleRate * 10);
      final inTinyChunks = measure(377); // deliberately not a round number
      final inDeviceBlocks = measure(512);

      expect(inTinyChunks, closeTo(inOneGo, 0.001));
      expect(inDeviceBlocks, closeTo(inOneGo, 0.001));
    });
  });

  group('honesty', () {
    test('loudness is NaN before enough signal exists to define it', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      // 200 ms — less than the 400 ms a momentary reading needs.
      final buffer = Float32List((_sampleRate ~/ 5) * 2);
      engine.push(buffer);

      expect(engine.lufsMomentary.isNaN, isTrue);
      expect(engine.lufsShort.isNaN, isTrue);
      expect(engine.lufsIntegrated.isNaN, isTrue);
    });

    test('digital silence never clears the absolute gate', () {
      final engine = _pushEngine();
      addTearDown(engine.dispose);

      _pushSegments(engine, const [_Segment(5, null)]);

      // Momentary and short-term describe the signal and floor out; integrated
      // is gated and stays undefined, because no block was ever loud enough to
      // count.
      expect(engine.lufsIntegrated.isNaN, isTrue);
      expect(engine.lufsMomentary, lessThan(-70.0));
    });
  });
}
