// SPDX-License-Identifier: GPL-3.0-or-later
//
// The measurements behind the figures in `lib/src/modules/spectrogram.dart`.
//
//     flutter test tool/bench_spectrogram.dart
//
// ---------------------------------------------------------------------------
// Why this file exists at all
//
// The spectrogram's doc comment claims costs, and a claim with no way to
// re-run it is one nobody can contradict. That is not hypothetical here: an
// earlier "205 µs" figure was quoted in this repository for a whole phase
// after the benchmark that produced it had been deleted, and it turned out to
// be a *recording* cost being read as a frame cost. This exists so the same
// thing cannot happen to the numbers that replaced it.
//
// The first test compares the run-length strategy against one drawRect per
// run — the comparison that justified [PointBuckets], which the stereo cloud
// still draws through. The second is the measurement that retired the
// run-length strategy from the *spectrogram*: its cost model assumed smooth
// columns of ~25 runs, and a real signal — the engine takes the peak bin per
// band — jitters a palette step between most adjacent rows. It prints the run
// counts at increasing band jitter, what the run-length path paid for them per
// published frame, and what the pixel path that replaced it pays regardless.
//
// ---------------------------------------------------------------------------
// Why it prints controls, and why it prints rasterised figures nobody quotes
//
// Recording and rasterising are different costs and the interesting one is not
// always the one being measured. Sorting 30 000 marks into 48 `drawRawPoints`
// calls is dramatically cheaper to *record* than 30 000 `drawRect` calls — and
// once the picture is actually rasterised, that advantage is mostly gone. Both
// pairs are printed together so the reader cannot mistake one for the other,
// and the empty-picture controls are printed so the reader can see how much of
// each figure is fixed overhead rather than work.
//
// ---------------------------------------------------------------------------
// What this does NOT measure
//
// `flutter test` rasterises on the CPU. The application draws through Impeller
// on a GPU, where a wide fill is far cheaper and the ratios below do not hold.
// Treat the *recording* numbers as portable — they are Dart and engine-call
// overhead — and treat the rasterised numbers as a warning about the shape of
// the cost, never as the application's frame budget. The pixel path's image
// instantiation is likewise a CPU-side copy here where the application also
// pays a GPU upload; what is portable is that it is a constant, and the
// run-length path's cost is not.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shape the spectrogram's comment is about: a wide display, one column per
/// published measurement, each column coalesced into a few dozen runs.
const int _columns = 1200;
const int _runsPerColumn = 25;
const int _steps = 48;

const double _width = 1200;
const double _height = 300;

/// Every run in the display, as parallel arrays — the same shape the module
/// keeps its history in, so neither strategy pays for boxing inside a timed
/// region.
class _Runs {
  _Runs(this.step, this.x, this.top, this.bottom);

  final Int32List step;
  final Float32List x;
  final Float32List top;
  final Float32List bottom;

  int get length => step.length;
}

_Runs _buildRuns() {
  const count = _columns * _runsPerColumn;
  final step = Int32List(count);
  final x = Float32List(count);
  final top = Float32List(count);
  final bottom = Float32List(count);

  final columnWidth = _width / _columns;
  final runHeight = _height / _runsPerColumn;

  for (var i = 0; i < count; i++) {
    final column = i ~/ _runsPerColumn;
    final run = i % _runsPerColumn;
    // Spread across the palette without landing every column on the same step,
    // which would coalesce into far fewer buckets than a real signal does.
    step[i] = (column * 7 + run * 13) % _steps;
    x[i] = column * columnWidth;
    top[i] = run * runHeight;
    bottom[i] = (run + 1) * runHeight;
  }
  return _Runs(step, x, top, bottom);
}

/// The module's palette, mirrored: one paint per brightness step, stroked to a
/// column's width, antialiasing off because the columns tile exactly.
List<Paint> _buildPalette() => [
  for (var i = 0; i < _steps; i++)
    Paint()
      ..color = Color.fromARGB(255, 20 + i * 4, 40 + i * 3, 80 + i * 2)
      ..strokeWidth = _width / _columns
      ..isAntiAlias = false,
];

/// One `drawRect` per run. One engine crossing per mark.
void _drawNaive(Canvas canvas, _Runs runs, List<Paint> palette) {
  final columnWidth = _width / _columns;
  for (var i = 0; i < runs.length; i++) {
    canvas.drawRect(
      Rect.fromLTRB(
        runs.x[i],
        runs.top[i],
        runs.x[i] + columnWidth,
        runs.bottom[i],
      ),
      palette[runs.step[i]],
    );
  }
}

/// Refill the buckets from the stored runs. This is on the frame path — the
/// module re-emits whenever the data shifts — so it belongs in the bucketed
/// total rather than being hidden by pre-built buffers.
void _emit(PointBuckets marks, _Runs runs) {
  marks.clear();
  for (var i = 0; i < runs.length; i++) {
    marks.run(runs.step[i], runs.x[i], runs.top[i], runs.bottom[i]);
  }
}

ui.Picture _record(void Function(Canvas) draw) {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  return recorder.endRecording();
}

/// Median rather than mean: one scheduling hiccup should not move the figure
/// that ends up in a doc comment.
int _median(int runs, void Function() body) {
  final samples = <int>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    body();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

Future<int> _medianAsync(int runs, Future<void> Function() body) async {
  final samples = <int>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    await body();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

Future<void> _rasterise(ui.Picture picture) async {
  final image = await picture.toImage(_width.toInt(), _height.toInt());
  image.dispose();
}

void _row(String label, int micros) =>
    stdout.writeln('  ${label.padRight(38)}${'$micros'.padLeft(7)} us');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'spectrogram: recording and rasterising, naive against bucketed',
    () async {
      final runs = _buildRuns();
      final palette = _buildPalette();
      final marks = PointBuckets(_steps);

      // Warm every path before timing any of it: the first record allocates the
      // bucket buffers, and the first rasterise builds engine-side caches.
      _emit(marks, runs);
      await _rasterise(
        _record((c) => marks.draw(c, ui.PointMode.lines, palette)),
      );
      await _rasterise(_record((c) => _drawNaive(c, runs, palette)));

      final emptyRecord = _median(50, () => _record((_) {}).dispose());
      final emptyRaster = await _medianAsync(10, () async {
        final picture = _record((_) {});
        await _rasterise(picture);
        picture.dispose();
      });

      final naiveRecord = _median(20, () {
        _record((c) => _drawNaive(c, runs, palette)).dispose();
      });
      final naiveTotal = await _medianAsync(10, () async {
        final picture = _record((c) => _drawNaive(c, runs, palette));
        await _rasterise(picture);
        picture.dispose();
      });

      final emitCost = _median(50, () => _emit(marks, runs));
      final bucketRecord = _median(20, () {
        _emit(marks, runs);
        _record((c) => marks.draw(c, ui.PointMode.lines, palette)).dispose();
      });
      final bucketTotal = await _medianAsync(10, () async {
        _emit(marks, runs);
        final picture = _record(
          (c) => marks.draw(c, ui.PointMode.lines, palette),
        );
        await _rasterise(picture);
        picture.dispose();
      });

      final marksDrawn = runs.length;
      stdout.writeln();
      stdout.writeln(
        'spectrogram: $_columns columns x $_runsPerColumn runs '
        '= $marksDrawn marks, ${_width.toInt()}x${_height.toInt()}, '
        '$_steps palette steps',
      );
      stdout.writeln();
      stdout.writeln('  RECORDING (UI thread, builds the display list)');
      _row('empty picture (control)', emptyRecord);
      _row('naive, one drawRect per run', naiveRecord);
      _row('bucketed, emit + 48x drawRawPoints', bucketRecord);
      _row('  of which: emit into buckets', emitCost);
      stdout.writeln();
      stdout.writeln('  RECORDING + RASTERISING (CPU path, not the GPU app)');
      _row('empty picture (control)', emptyRaster);
      _row('naive', naiveTotal);
      _row('bucketed', bucketTotal);
      stdout.writeln();
      stdout.writeln('  The recording pair is what spectrogram.dart quotes.');
      stdout.writeln('  The rasterised pair is why it says "recording".');
      stdout.writeln();

      // Not assertions about the timings — those would fail on a loaded runner,
      // which is how a benchmark becomes something people delete. This only
      // checks the benchmark drew what it claims to have drawn.
      expect(marksDrawn, _columns * _runsPerColumn);
      expect(marks.isEmpty, isFalse);
      expect(marks.bucketCount, _steps);
    },
  );

  test(
    'spectrogram: run-length cost against band jitter, and the pixel path',
    () async {
      final palette = _buildPalette();
      const rows = 300;
      const bands = 512;
      const floorDb = -84.0;
      const ceilingDb = -6.0;
      final rowHeight = _height / rows;

      int stepAt(Float32List spectrum, int row) {
        final band = ((rows - 1 - row) / (rows - 1) * (bands - 1)).round();
        final db = spectrum[band];
        if (db <= floorDb) return 0;
        final level = ((db - floorDb) / (ceilingDb - floorDb)).clamp(0.0, 1.0);
        return (level * (_steps - 1)).round();
      }

      // A musical envelope with a moving bump, plus per-band jitter — the shape
      // the engine's peak-per-bin bands actually have. Deterministic, so the run
      // counts printed here are the same on every machine.
      void fill(Float32List out, int seed, double jitterDb, int t) {
        var state = seed * 2654435761 + t;
        double noise() {
          state = (state * 1103515245 + 12345) & 0x7fffffff;
          return state / 0x7fffffff * 2 - 1;
        }

        for (var band = 0; band < bands; band++) {
          final f = band / (bands - 1);
          final slope = -18.0 - 38.0 * f;
          final bump =
              10.0 * math.exp(-math.pow((f - 0.35) / 0.18, 2).toDouble());
          out[band] = (slope + bump + noise() * jitterDb).clamp(-96.0, 0.0);
        }
      }

      stdout.writeln();
      for (final jitter in [0.0, 1.0, 2.0]) {
        // The run-length path: coalesce every column, emit and record the lot,
        // the work it did on every published frame.
        final spectrum = Float32List(bands);
        final ends = Uint16List(_columns * rows);
        final steps = Uint8List(_columns * rows);
        final runCounts = Uint16List(_columns);
        var totalRuns = 0;
        for (var column = 0; column < _columns; column++) {
          fill(spectrum, 1, jitter, column);
          final base = column * rows;
          var count = 0;
          var current = stepAt(spectrum, 0);
          for (var row = 1; row <= rows; row++) {
            final step = row < rows ? stepAt(spectrum, row) : -1;
            if (step == current) continue;
            ends[base + count] = row;
            steps[base + count] = current;
            count++;
            current = step;
          }
          runCounts[column] = count;
          totalRuns += count;
        }

        final marks = PointBuckets(_steps);
        void emit() {
          marks.clear();
          for (var column = 0; column < _columns; column++) {
            final x = _columns - column - 0.5;
            final base = column * rows;
            var top = 0;
            for (var run = 0; run < runCounts[column]; run++) {
              final end = ends[base + run];
              final step = steps[base + run];
              if (step > 0) {
                marks.run(step, x, top * rowHeight, end * rowHeight);
              }
              top = end;
            }
          }
        }

        emit();
        final runLength = _median(20, () {
          emit();
          _record((c) => marks.draw(c, ui.PointMode.lines, palette)).dispose();
        });

        stdout.writeln(
          '  jitter ±${jitter.toStringAsFixed(0)} dB: '
          '${(totalRuns / _columns).toStringAsFixed(0)} runs/column, '
          'run-length emit+record ${'$runLength'.padLeft(5)} us '
          'and ~${(totalRuns * 16 / 1024 / 1024).toStringAsFixed(1)} MB of '
          'display list, per published frame',
        );
      }

      // The pixel path: shift, write one column through the palette, copy out,
      // instantiate. The same numbers whatever the signal does.
      final pixels = Uint8List(_columns * rows * 4);
      final staging = Uint8List(pixels.length);
      final append = _median(50, () {
        pixels.setRange(0, pixels.length - 4, pixels, 4);
        for (var row = 0; row < rows; row++) {
          final p = (row * _columns + _columns - 1) * 4;
          pixels[p] = row;
          pixels[p + 1] = row >> 1;
          pixels[p + 2] = row >> 2;
          pixels[p + 3] = 255;
        }
        staging.setAll(0, pixels);
      });
      ui.Image? image;
      final instantiate = await _medianAsync(20, () async {
        final buffer = await ui.ImmutableBuffer.fromUint8List(staging);
        final descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: _columns,
          height: rows,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        final codec = await descriptor.instantiateCodec();
        final frame = await codec.getNextFrame();
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
        image?.dispose();
        image = frame.image;
      });
      final record = _median(50, () {
        _record(
          (c) => c.drawImageRect(
            image!,
            const Rect.fromLTWH(0, 0, _width, rows * 1.0),
            const Rect.fromLTWH(0, 0, _width, _height),
            Paint(),
          ),
        ).dispose();
      });
      image?.dispose();

      stdout.writeln(
        '  pixel path, any signal: append $append us, '
        'image ${'$instantiate'.padLeft(5)} us, record ${'$record'.padLeft(3)} us, '
        'per published frame',
      );
      stdout.writeln();

      expect(pixels.length, _columns * rows * 4);
    },
  );
}
