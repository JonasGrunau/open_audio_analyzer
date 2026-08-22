// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a remote display pays to turn a snapshot back into a measurement.
//
//     flutter test tool/bench_wire.dart
//
// ---------------------------------------------------------------------------
// Why this file exists at all
//
// A tablet was reported as laggy and the wire was the obvious suspect: a remote
// display decodes and repaints thirty times a second. This is the measurement
// that cleared it — the codec costs single-digit microseconds against a 33,000
// µs budget — and sent the search to `bench_modules.dart`, which found the
// answer in one module's rasterising. The number is kept re-runnable because a
// suspect cleared by a figure nobody can reproduce is a suspect that comes
// back.
//
// It once measured something else: protocol versions 1 to 3 carried every array
// as float32, so a decode was a memmove written as 3,736 accessor calls, and
// this file compared the two. Version 4 made the plotted arrays fixed point and
// ended that — the conversion is per element whichever way it is written — so
// what is left is the honest cost of the codec as it now stands.

import 'package:flutter_test/flutter_test.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_wire/oaa_wire.dart';

import 'bench_material.dart';

/// Median of [runs] timings of [body], each averaging [inner] iterations.
///
/// Median rather than mean: a benchmark sharing a machine with everything else
/// on it collects outliers that say more about the machine than the code.
double _medianMicros(int runs, int inner, void Function() body) {
  final samples = <double>[];
  for (var run = 0; run < runs; run++) {
    final watch = Stopwatch()..start();
    for (var i = 0; i < inner; i++) {
      body();
    }
    watch.stop();
    samples.add(watch.elapsedMicroseconds / inner);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

String _row(String label, double micros) {
  final perSecond = [
    for (final fps in kRemoteFpsOptions)
      '${(micros * fps / 1000).toStringAsFixed(2)} ms',
  ];
  return '  ${label.padRight(20)}'
      '${micros.toStringAsFixed(2).padLeft(8)} µs/frame'
      '   ${perSecond.join('   ')}';
}

void main() {
  test('the codec costs, both ends of the link', () {
    final material = BenchMaterial();

    // Warm the JIT, and confirm there is something here to measure — a codec
    // benchmark on an all-NaN snapshot would be measuring the same branches
    // every time. See `tool/AGENTS.md` on benchmarks that cannot see their own
    // subject.
    for (var i = 0; i < 500; i++) {
      material.publish();
    }
    expect(material.snapshot.generation, greaterThan(0));
    expect(material.snapshot.scopeFrames, MeterShape.scopePoints);
    expect(material.snapshot.spectrum.any((v) => v.isFinite), isTrue);
    expect(material.snapshot.scope.any((v) => v != 0), isTrue);

    // The codec alone. Timing `publish` would fold in the cost of inventing a
    // measurement — 3,736 random values — which is several times the codec and
    // belongs to the harness, not to the wire.
    final encode = _medianMicros(
      9,
      2000,
      () => SnapshotWire.encode(material.source, material.payload),
    );
    final decode = _medianMicros(
      9,
      2000,
      () => material.snapshot.decode(material.payload),
    );

    // ignore: avoid_print
    print('''

Snapshot codec — ${SnapshotWire.payloadBytes} bytes, one analysis block
                                        cost at ${kRemoteFpsOptions.join('/')} fps
${_row('encode (desktop)', encode)}
${_row('decode (tablet)', decode)}

  A 30 fps budget is 33,333 µs a frame. This is the reason the wire was
  ruled out: see tool/bench_modules.dart for where the time actually goes.
''');

    expect(encode, greaterThan(0));
    expect(decode, greaterThan(0));
  });
}
