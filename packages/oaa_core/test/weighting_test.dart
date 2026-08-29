// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:oaa_core/oaa_core.dart';
import 'package:test/test.dart';

void main() {
  group('aWeightingDb', () {
    test('is exactly zero at 1 kHz', () {
      expect(aWeightingDb(1000), 0.0);
    });

    // IEC 61672-1:2013 Table 3, the A column, at the exact third-octave
    // centres 10^(n/10) rather than the nominal ones printed beside them —
    // 19.95 Hz, not 20 — because the table is computed at the exact ones and
    // the curve is steep enough at the bottom for the difference to show at
    // the tenth of a decibel the table is printed to. Every row from 20 Hz to
    // 20 kHz, which is the analyser's range.
    const table = <int, double>{
      13: -50.5, // 20 Hz
      14: -44.7,
      15: -39.4,
      16: -34.6,
      17: -30.2,
      18: -26.2,
      19: -22.5,
      20: -19.1, // 100 Hz
      21: -16.1,
      22: -13.4,
      23: -10.9,
      24: -8.6,
      25: -6.6,
      26: -4.8,
      27: -3.2,
      28: -1.9,
      29: -0.8,
      30: 0.0, // 1 kHz
      31: 0.6,
      32: 1.0,
      33: 1.2,
      34: 1.3,
      35: 1.2,
      36: 1.0,
      37: 0.5,
      38: -0.1,
      39: -1.1,
      40: -2.5, // 10 kHz
      41: -4.3,
      42: -6.6,
      43: -9.3, // 20 kHz
    };

    for (final MapEntry(key: n, value: expected) in table.entries) {
      final hz = math.pow(10, n / 10).toDouble();
      test('matches the standard at ${hz.toStringAsFixed(1)} Hz', () {
        expect(aWeightingDb(hz), closeTo(expected, 0.05));
      });
    }

    test('peaks a little above zero between 2 and 4 kHz', () {
      var best = double.negativeInfinity;
      var at = 0.0;
      for (var hz = 20.0; hz <= 20000; hz *= 1.01) {
        final db = aWeightingDb(hz);
        if (db > best) {
          best = db;
          at = hz;
        }
      }
      expect(best, closeTo(1.27, 0.05));
      expect(at, inInclusiveRange(2000, 4000));
    });
  });
}
