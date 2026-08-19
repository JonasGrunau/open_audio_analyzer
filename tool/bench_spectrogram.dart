// SPDX-License-Identifier: GPL-3.0-or-later
//
// The measurement behind the two figures in `lib/src/modules/spectrogram.dart`.
//
//     flutter test tool/bench_spectrogram.dart
//
// ---------------------------------------------------------------------------
// Why this file exists at all
//
// The spectrogram's doc comment claims a recording cost, and a claim with no
// way to re-run it is one nobody can contradict. That is not hypothetical here:
// an earlier "205 µs" figure was quoted in this repository for a whole phase
// after the benchmark that produced it had been deleted, and it turned out to
// be a *recording* cost being read as a frame cost. This exists so the same
// thing cannot happen to the numbers that replaced it.
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
// overhead, and that is what the spectrogram's comment quotes — and treat the
// rasterised numbers as a warning about the shape of the cost, never as the
// application's frame budget.

import 'dart:io';
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
}
