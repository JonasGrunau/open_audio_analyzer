// SPDX-License-Identifier: GPL-3.0-or-later
//
// The official test vectors, read off disk and driven through the engine.
//
// Two sets, from the two bodies that define the measurement:
//
//   OAA_VECTORS      the EBU Loudness Test Set — every case in Table 1 of EBU
//                    Tech 3341 and of EBU Tech 3342.
//   OAA_VECTORS_ITU  the compliance material of Report ITU-R BS.2217 — the
//                    ITU's own files for Recommendation ITU-R BS.1770.
//
// `conformance_test.dart` beside this file generates its signals, which is what
// lets it gate every push on every platform with no fixtures and no network.
// These read WAVs somebody else synthesised, through `oaa_decode.c`, and that is
// the one thing the generated suite cannot be: a signal we construct and a
// reading we compute can agree with each other and both be wrong about the
// standard. Only material we did not make can say otherwise. It found two
// things on its first run — see the momentary grid in `oaa_loudness.h` and the
// 7.1 weights in `oaa_kweight.c`, neither of which the generated cases could
// have asked about.
//
// ---------------------------------------------------------------------------
// Why this is not a gate
//
// Licensing, not technique. Neither set may be redistributed from this
// repository — the EBU's is 91 MB, the ITU's 720 MB — and fetching them in CI
// would put the network in front of the one suite that must never be flaky. So
// each group skips unless its variable names an unzipped copy:
//
//   OAA_VECTORS=~/ebu-loudness-test-set dart test test/vectors_test.dart
//
// The EBU set is published at
// https://tech.ebu.ch/publications/ebu_loudness_test_set (v05, 30 March 2016).
// The ITU material is linked from Report ITU-R BS.2217 itself, as 48 archives at
// https://www.itu.int/oth/R1102000001/en.
//
// Every expected value below is from Table 1 of EBU Tech 3341, Table 1 of EBU
// Tech 3342 (2023 editions) or the table of Report ITU-R BS.2217-2, and so is
// every tolerance: ±0.1 LU for loudness, +0.2/−0.4 dBTP for true peak, ±1 LU for
// LRA, ±0.1 LKFS for everything in the ITU set. The asymmetry in the true-peak
// tolerance is the standard's and not a rounding convenience: over-reading an
// inter-sample peak costs a user headroom, under-reading it costs them a
// rejected master.
//
// ---------------------------------------------------------------------------
// Three things about the material itself
//
// The files are exactly what each body ships, including the eighteen EBU names
// that end `.wav.wav` in v05 and the ITU's programme files, which arrive under
// two spellings — spaces in some archives, underscores in others. Renaming them
// locally would make this suite pass against a directory nobody else has, so
// [_vector] resolves the variants instead.
//
// The tones are not mathematically exact. seq-3341-1 is nominally a 1 kHz sine
// at −23.0 dBFS and its sample peak is −22.936 dBFS, so a correct meter reads a
// shade above −23.0 on it. That is the point of measuring somebody else's file:
// the reading tracks the signal that is actually there, and the ±0.1 the
// standard allows is what absorbs the difference.
//
// Six ITU files are wider than 7.1 — 10, 12 and 24 channels — and the engine
// carries eight. They are asserted to be *refused*, because a measurement of a
// layout this engine cannot weight would be a number nobody should read.

import 'dart:io';
import 'dart:math' as math;

import 'package:oaa_engine/oaa_engine.dart';
import 'package:test/test.dart';

/// EBU Tech 3341 states its tolerance as ±0.1 LU, and BS.2217 as ±0.1 LKFS.
/// The two units are the same measurement under two names.
const _lu = 0.1;

/// EBU Tech 3342 states its own as ±1 LU.
const _lra = 1.0;

/// Both sets are synthesised at 48 kHz, so this is 5 ms of signal.
///
/// Every "Max" in Tech 3341's Table 1 is accumulated by the caller as blocks go
/// past — see the note in `offline.dart` — so the cadence the caller pushes at
/// is a floor under the resolution of the answer. Pushing 5 ms at a time keeps
/// this suite measuring the engine rather than measuring its own block size.
const _blockFrames = 240;

const _fine = Duration(milliseconds: 5);

String? _root(String variable) {
  final path = Platform.environment[variable];
  if (path == null || path.isEmpty) return null;
  return Directory(path).existsSync() ? path : null;
}

/// Resolves one vector by its stem, tolerating the spellings each body ships.
String _vector(String root, String stem) {
  final candidates = <String>[
    '$stem.wav',
    '$stem.wav.wav', // the EBU's v05 doubled extension
    '${stem.replaceAll('_', ' ')}.wav', // the ITU's spaced programme names
  ];
  for (final name in candidates) {
    final file = File('$root/$name');
    if (file.existsSync()) return file.path;
  }
  fail('the test set at $root has no $stem.wav');
}

OfflineResult _analyse(String root, String stem, {Duration? timeline}) =>
    analyseFile(
      _vector(root, stem),
      blockFrames: _blockFrames,
      timelineInterval: timeline ?? const Duration(milliseconds: 100),
    );

/// The highest [reading] the timeline holds inside `[from, to)`.
///
/// Tech 3341's tests 11 and 14 state a *sequence* of maxima rather than one, so
/// each has to be read out of its own segment. The segments are equal divisions
/// of the file — 6 s in test 11, 800 ms in test 14 — because that is how the
/// standard describes their construction.
double _segmentMax(
  OfflineResult result,
  double Function(OfflineTimelinePoint) reading,
  double from,
  double to,
) {
  var best = double.nan;
  for (final point in result.timeline) {
    if (point.seconds < from || point.seconds >= to) continue;
    final value = reading(point);
    if (value.isNaN) continue;
    best = best.isNaN ? value : math.max(best, value);
  }
  return best;
}

/// Tech 3341 states tests 11 and 14 as "−38.0, −37.0, … −19.0 LUFS, successive
/// values".
final List<double> _ladder = List<double>.generate(20, (i) => -38.0 + i);

void main() {
  _ebuGroups(_root('OAA_VECTORS'));
  _ituGroups(_root('OAA_VECTORS_ITU'));
}

/// One skipped test rather than none: a file that reports no tests at all reads
/// as "nothing to check here" rather than as "not run".
void _skipped(String name, String variable, String where) {
  test(name, () {}, skip: 'set $variable to an unzipped copy of $where');
}

void _ebuGroups(String? root) {
  if (root == null) {
    _skipped(
      'EBU Tech 3341 and 3342, against the official WAV vectors',
      'OAA_VECTORS',
      'the EBU Loudness Test Set '
          '(https://tech.ebu.ch/publications/ebu_loudness_test_set)',
    );
    return;
  }

  group('EBU Tech 3341 — Table 1, integrated loudness', () {
    test('1: stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS in M, S and I', () {
      final r = _analyse(root, 'seq-3341-1-16bit');
      expect(r.lufsIntegrated, closeTo(-23.0, _lu));
      expect(r.shortTermMax, closeTo(-23.0, _lu));
      expect(r.momentaryMax, closeTo(-23.0, _lu));
    });

    test('2: the same signal at -33 dBFS reads -33.0 LUFS in M, S and I', () {
      final r = _analyse(root, 'seq-3341-2-16bit');
      expect(r.lufsIntegrated, closeTo(-33.0, _lu));
      expect(r.shortTermMax, closeTo(-33.0, _lu));
      expect(r.momentaryMax, closeTo(-33.0, _lu));
    });

    test('3: the relative gate discards the two -36 dBFS tails', () {
      expect(
        _analyse(root, 'seq-3341-3-16bit-v02').lufsIntegrated,
        closeTo(-23.0, _lu),
      );
    });

    test('4: the absolute gate discards the two -72 dBFS tails as well', () {
      expect(
        _analyse(root, 'seq-3341-4-16bit-v02').lufsIntegrated,
        closeTo(-23.0, _lu),
      );
    });

    test('5: nothing is gated out when every level is close together', () {
      expect(
        _analyse(root, 'seq-3341-5-16bit-v02').lufsIntegrated,
        closeTo(-23.0, _lu),
      );
    });

    test('6: five channels, with the surrounds weighted +1.5 dB', () {
      expect(
        _analyse(root, 'seq-3341-6-5channels-16bit').lufsIntegrated,
        closeTo(-23.0, _lu),
      );
    });

    test('6: and the same signal with an LFE channel added reads the same', () {
      // The EBU ships this case twice so that a meter which includes the LFE has
      // somewhere to fail. BS.1770 excludes it, so the two files must not merely
      // both land inside the tolerance — they must agree.
      final five = _analyse(root, 'seq-3341-6-5channels-16bit');
      final six = _analyse(root, 'seq-3341-6-6channels-WAVEEX-16bit');
      expect(six.lufsIntegrated, closeTo(-23.0, _lu));
      expect(six.lufsIntegrated, closeTo(five.lufsIntegrated, 0.001));
    });

    test('7: authentic programme, narrow loudness range', () {
      expect(
        _analyse(root, 'seq-3341-7_seq-3342-5-24bit').lufsIntegrated,
        closeTo(-23.0, _lu),
      );
    });

    test('8: authentic programme, wide loudness range', () {
      expect(
        _analyse(root, 'seq-3341-2011-8_seq-3342-6-24bit-v02').lufsIntegrated,
        closeTo(-23.0, _lu),
      );
    });
  });

  group('EBU Tech 3341 — Table 1, short-term loudness', () {
    test('9: S settles at -23.0 LUFS and stays there after 3 s', () {
      final r = _analyse(root, 'seq-3341-9-24bit', timeline: _fine);
      final settled = r.timeline.where(
        (p) => p.seconds >= 3.0 && !p.shortTerm.isNaN,
      );
      expect(settled, isNotEmpty);
      for (final point in settled) {
        expect(
          point.shortTerm,
          closeTo(-23.0, _lu),
          reason: 'S at ${point.seconds.toStringAsFixed(3)} s',
        );
      }
    });

    for (var i = 1; i <= 20; i++) {
      test('10-$i: Max S is -23.0 LUFS however the tone is offset', () {
        // Twenty files, each shifting a 3 s tone by another 150 ms. A meter
        // whose short-term window only advances on a coarse grid reads low
        // here, by more the coarser the grid.
        expect(
          _analyse(root, 'seq-3341-10-$i-24bit').shortTermMax,
          closeTo(-23.0, _lu),
        );
      });
    }

    test('11: twenty successive Max S readings, -38.0 LUFS up to -19.0', () {
      final r = _analyse(root, 'seq-3341-11-24bit', timeline: _fine);
      for (var i = 0; i < _ladder.length; i++) {
        expect(
          _segmentMax(r, (p) => p.shortTerm, 6.0 * i, 6.0 * (i + 1)),
          closeTo(_ladder[i], _lu),
          reason: 'segment ${i + 1}',
        );
      }
    });
  });

  group('EBU Tech 3341 — Table 1, momentary loudness', () {
    test('12: M settles at -23.0 LUFS and stays there after 1 s', () {
      final r = _analyse(root, 'seq-3341-12-24bit', timeline: _fine);
      final settled = r.timeline.where(
        (p) => p.seconds >= 1.0 && !p.momentary.isNaN,
      );
      expect(settled, isNotEmpty);
      for (final point in settled) {
        expect(
          point.momentary,
          closeTo(-23.0, _lu),
          reason: 'M at ${point.seconds.toStringAsFixed(3)} s',
        );
      }
    });

    for (var i = 1; i <= 20; i++) {
      test('13-$i: Max M is -23.0 LUFS however the tone is offset', () {
        // The momentary counterpart of test 10, and much sharper: the window is
        // 400 ms, the tone is 400 ms, and each file moves it another 20 ms, so
        // the tone lies inside exactly one window and no other. This is the case
        // that found the 100 ms grid.
        expect(
          _analyse(root, 'seq-3341-13-$i-24bit').momentaryMax,
          closeTo(-23.0, _lu),
        );
      });
    }

    test('14: twenty successive Max M readings, -38.0 LUFS up to -19.0', () {
      final r = _analyse(root, 'seq-3341-14-24bit', timeline: _fine);
      for (var i = 0; i < _ladder.length; i++) {
        expect(
          _segmentMax(r, (p) => p.momentary, 0.8 * i, 0.8 * (i + 1)),
          closeTo(_ladder[i], _lu),
          reason: 'segment ${i + 1}',
        );
      }
    });
  });

  group('EBU Tech 3341 — Table 1, true peak', () {
    // The tolerance is +0.2/−0.4 dBTP rather than ±0.1 LU, and it is not
    // symmetric, so `closeTo` is the wrong matcher for every case here.
    void expectTruePeak(String stem, double expected) {
      final peak = _analyse(root, stem).truePeakMax;
      expect(
        peak,
        inInclusiveRange(expected - 0.4, expected + 0.2),
        reason: '$stem read ${peak.toStringAsFixed(3)} dBTP',
      );
    }

    test('15: fs/4 at 0.50 FFS, phase 0°, reads -6.0 dBTP', () {
      expectTruePeak('seq-3341-15-24bit', -6.0);
    });

    test('16: fs/4 at 0.50 FFS, phase 45°', () {
      expectTruePeak('seq-3341-16-24bit', -6.0);
    });

    test('17: fs/6 at 0.50 FFS, phase 60°', () {
      expectTruePeak('seq-3341-17-24bit', -6.0);
    });

    test('18: fs/8 at 0.50 FFS, phase 67.5°', () {
      expectTruePeak('seq-3341-18-24bit', -6.0);
    });

    test('19: fs/4 at 1.41 FFS, phase 45°, reads +3.0 dBTP', () {
      // The one case above full scale. A meter that clamps at 0 dBFS anywhere in
      // its true-peak path fails here and nowhere else.
      expectTruePeak('seq-3341-19-24bit', 3.0);
    });

    for (var offset = 0; offset <= 3; offset++) {
      final number = 20 + offset;
      test(
        '$number: a single fs/4 period, downsampled $offset samples off',
        () {
          // Four downsampling offsets of the same signal, which is how the
          // standard checks that the polyphase filter has no blind phase.
          expectTruePeak('seq-3341-$number-24bit', 0.0);
        },
      );
    }
  });

  group('EBU Tech 3342 — Table 1, loudness range', () {
    test('1: two tones 10 dB apart give an LRA of 10 LU', () {
      expect(
        _analyse(root, 'seq-3342-1-16bit').loudnessRange,
        closeTo(10.0, _lra),
      );
    });

    test('2: five dB apart, 5 LU', () {
      expect(
        _analyse(root, 'seq-3342-2-16bit').loudnessRange,
        closeTo(5.0, _lra),
      );
    });

    test('3: twenty dB apart, 20 LU', () {
      expect(
        _analyse(root, 'seq-3342-3-16bit').loudnessRange,
        closeTo(20.0, _lra),
      );
    });

    test('4: five segments spanning 30 dB give 15 LU, not 30', () {
      // The percentiles are what make this 15 rather than 30: the -50 dBFS
      // segments fall below the range gate and the -35 ones sit inside the 10th
      // and 95th.
      expect(
        _analyse(root, 'seq-3342-4-16bit').loudnessRange,
        closeTo(15.0, _lra),
      );
    });

    test('5: authentic programme, narrow loudness range', () {
      expect(
        _analyse(root, 'seq-3341-7_seq-3342-5-24bit').loudnessRange,
        closeTo(5.0, _lra),
      );
    });

    test('6: authentic programme, wide loudness range', () {
      expect(
        _analyse(root, 'seq-3341-2011-8_seq-3342-6-24bit-v02').loudnessRange,
        closeTo(15.0, _lra),
      );
    });
  });
}

void _ituGroups(String? root) {
  if (root == null) {
    _skipped(
      'ITU-R BS.2217, against the ITU compliance material',
      'OAA_VECTORS_ITU',
      "Report ITU-R BS.2217's compliance material "
          '(https://www.itu.int/oth/R1102000001/en)',
    );
    return;
  }

  // BS.2217 states one expectation per file — the file-based measurement — and
  // one tolerance for all of them. So unlike Tech 3341, every case here is the
  // integrated reading and nothing else.
  void expectIntegrated(String stem, double expected) {
    expect(
      _analyse(root, stem).lufsIntegrated,
      closeTo(expected, _lu),
      reason: stem,
    );
  }

  group('ITU-R BS.2217 — tones', () {
    for (final level in [23, 24]) {
      for (final hz in ['25', '100', '500', '1000', '2000', '10000']) {
        test('a $hz Hz sine at -$level LKFS', () {
          // The frequency is the point of these twelve. 1 kHz sits on a filter
          // slope, 25 Hz is where the RLB high-pass is doing all the work, and
          // 10 kHz is up on the shelf — its file peaks near -27 dBFS to land at
          // -23 LKFS, so a wrong shelf gain shows here and in almost nothing
          // else anybody plays through a meter.
          expectIntegrated(
            '1770-2_Comp_${level}LKFS_${hz}Hz_2ch',
            -level.toDouble(),
          );
        });
      }
    }

    test('a sweep whose loudness is constant at -18 LKFS throughout', () {
      // A gain error of 1 dB in a third-octave band of the K filter shows up
      // here as roughly half a LU, which is what makes this the one file that
      // checks the filter's shape rather than its value at a point.
      expectIntegrated('1770-2_Comp_18LKFS_FrequencySweep', -18.0);
    });
  });

  group('ITU-R BS.2217 — gating', () {
    test('the relative gate test reads -10.0 LKFS', () {
      expectIntegrated('1770-2_Comp_RelGateTest', -10.0);
    });

    test('the absolute gate test reads -69.5 LKFS', () {
      // Below the -70 LUFS absolute gate the quiet part of this file
      // disappears; a meter with no absolute gate reads lower.
      expectIntegrated('1770-2_Comp_AbsGateTest', -69.5);
    });
  });

  group('ITU-R BS.2217 — channels', () {
    for (final level in [23, 24]) {
      for (final channel in ['Left', 'Right', 'Centre', 'Ls', 'Rs']) {
        test('$channel alone at -$level LKFS in 5.1', () {
          expectIntegrated(
            '1770-2_Comp_${level}LKFS_ChannelCheck$channel',
            -level.toDouble(),
          );
        });
      }

      test('all six channels summing to -$level LKFS', () {
        expectIntegrated(
          '1770-2_Comp_${level}LKFS_SummingTest',
          -level.toDouble(),
        );
      });

      test('the LFE alone measures nothing at all (-$level file)', () {
        // "Since the LFE channel is not included in a Rec. BS.1770
        // measurement, a compliant meter shall indicate the lowest resolvable
        // value, or -infinity." Nothing here clears the absolute gate, so the
        // engine reports NaN and the interface draws an em dash, which is that
        // — and is deliberately not the -144 dB floor, because "nothing was
        // measured" is a different fact from "something very quiet was".
        expect(
          _analyse(
            root,
            '1770-2_Comp_${level}LKFS_ChannelCheckLFE',
          ).lufsIntegrated.isNaN,
          isTrue,
        );
      });

      test('eight channels summing to -$level LKFS', () {
        // 7.1, and the case that found the rear surrounds carrying the
        // surround weight: it read 0.35 LU high, which is three and a half
        // times the tolerance.
        expectIntegrated('1770Conf-${level}LKFS-8channel', -level.toDouble());
      });
    }

    for (final channels in [10, 12, 24]) {
      test('$channels channels are refused rather than mismeasured', () {
        // Wider than 7.1, which this engine does not carry. A refusal is the
        // only honest answer: it has no weights for those layouts, and a
        // number produced without them would be read as if it meant something.
        expect(
          () => _analyse(root, '1770Conf-23LKFS-${channels}channel'),
          throwsA(isA<OaaFileException>()),
        );
      });
    }
  });

  group('ITU-R BS.2217 — programme material', () {
    for (final level in [23, 24]) {
      for (final stem in [
        '1770-2_Conf_6ch_VinCntr',
        '1770-2_Conf_6ch_VinL+R',
        '1770-2_Conf_6ch_VinL-R-C',
        '1770-2_Conf_Stereo_VinL+R',
        '1770-2_Conf_Mono_Voice+Music',
      ]) {
        test('${stem.substring(11)} at -$level LKFS', () {
          expectIntegrated('$stem-${level}LKFS', -level.toDouble());
        });
      }
    }
  });
}
