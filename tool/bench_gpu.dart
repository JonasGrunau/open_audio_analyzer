// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-module frame cost on a real GPU, read off the engine's own timings.
//
//     flutter run -d macos --profile -t tool/bench_gpu.dart
//
// ---------------------------------------------------------------------------
// Why this exists next to bench_modules.dart
//
// `bench_modules.dart` runs under `flutter test`, which has no GPU: its
// rasterise column is Skia's software backend. That is enough to rank work and
// it named the phase scope — 24 ms against a 0.08 ms spectrogram — but points
// are the primitive a GPU is best at, so a software figure for a module that
// draws 40,960 of them overstates it by an unknown factor. Acting on that
// number without this one would mean rewriting a module against a rasteriser
// nobody runs.
//
// This is the same fourteen modules, the same synthetic material, the same
// `WireSnapshot` source a tablet holds — measured through
// `addTimingsCallback`, which reports what the engine actually spent on the UI
// thread and the raster thread for each frame it presented.
//
// Run it in **profile**. A debug build's raster times are not the product's.
//
// ---------------------------------------------------------------------------
// Measure one module at a time before you believe a number
//
// A full sweep is fourteen modules back to back, and this machine throttles
// over that: `stereo_cloud`, unchanged between two sweeps, read 3,121 µs in one
// and 15,726 µs in the next, and 4,596 / 4,663 µs when measured on its own
// twice. The sweep is for *ranking*; `--dart-define=only=<id>` is for a figure
// you are going to quote or act on. Nothing here is quoted from a sweep.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:oaa/src/canvas/module_host.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'bench_material.dart';

const _colors = OaaColors.precisionInstrument;
const Size _canvas = Size(1194, 834);

/// Frames measured per module, and frames discarded first.
const int _measure = 180;
const int _warmUp = 90;

/// `--dart-define=only=phase_scope` measures one module instead of fourteen,
/// which is what you want while changing one of them.
const String _only = String.fromEnvironment('only');

List<ModuleKind> get _kinds => _only.isEmpty
    ? ModuleKind.values
    : ModuleKind.values.where((k) => k.id == _only).toList();

/// `WireSnapshot` a remote display runs. Identical to `bench_modules.dart`'s,
/// deliberately: the two files must be measuring the same material.

class _Reading {
  final List<double> build = [];
  final List<double> raster = [];

  /// Pixels that are not the background colour, the last time this module was
  /// looked at. See [_BenchAppState._inked].
  int inked = 0;
}

void main() {
  runApp(const _BenchApp());
}

class _BenchApp extends StatefulWidget {
  const _BenchApp();

  @override
  State<_BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<_BenchApp>
    with SingleTickerProviderStateMixin {
  final BenchMaterial _material = BenchMaterial();
  final Map<ModuleKind, _Reading> _readings = {};

  late final MeterClock _clock = MeterClock(
    engine: _material.snapshot,
    vsync: this,
  );

  int _index = 0;
  int _seen = 0;
  Timer? _publisher;

  final GlobalKey _boundary = GlobalKey();

  ModuleKind get _kind => _kinds[_index];

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // The engine's real cadence: one analysis block every 21.3 ms.
    _publisher = Timer.periodic(const Duration(milliseconds: 21), (_) {
      _material.publish();
    });
  }

  @override
  void dispose() {
    _publisher?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _clock.dispose();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    final reading = _readings.putIfAbsent(_kind, _Reading.new);
    for (final timing in timings) {
      _seen++;
      if (_seen <= _warmUp) continue;
      reading.build.add(timing.buildDuration.inMicroseconds.toDouble());
      reading.raster.add(timing.rasterDuration.inMicroseconds.toDouble());
      if (reading.raster.length >= _measure) {
        unawaited(_finishModule());
        return;
      }
    }
  }

  /// Counts pixels that are not the background.
  ///
  /// **A benchmark that cannot see what it measured is a random number
  /// generator.** A profile build renders a build failure as a plain grey
  /// rectangle rather than the red box a debug build shows, and a window that
  /// draws nothing still presents frames and still reports timings — perfectly
  /// plausible ones, low and stable. So every figure in the table below is
  /// published next to the number of pixels that were actually drawn, and a
  /// module that inked nothing is reported as having measured nothing.
  Future<int> _inked() async {
    final object =
        _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (object == null) return 0;

    final image = await object.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (data == null) return 0;

    final pixels = data.buffer.asUint8List();
    final bg = _colors.background;
    var count = 0;
    for (var i = 0; i < pixels.length; i += 4) {
      // A tolerance, because the module frame's fills sit a shade off the
      // background and antialiasing lands between the two.
      if ((pixels[i] - (bg.r * 255).round()).abs() > 6 ||
          (pixels[i + 1] - (bg.g * 255).round()).abs() > 6 ||
          (pixels[i + 2] - (bg.b * 255).round()).abs() > 6) {
        count++;
      }
    }
    return count;
  }

  bool _advancing = false;

  Future<void> _finishModule() async {
    if (_advancing) return;
    _advancing = true;
    _readings[_kind]!.inked = await _inked();
    _advancing = false;

    _seen = 0;
    if (_index + 1 >= _kinds.length) {
      _report();
      return;
    }
    setState(() => _index++);
  }

  /// Median, not mean. A benchmark sharing a machine with a compositor collects
  /// outliers that say more about the machine than about the module.
  double _median(List<double> values) {
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  void _report() {
    final ranked = _readings.keys.toList()
      ..sort(
        (a, b) => _median(
          _readings[b]!.raster,
        ).compareTo(_median(_readings[a]!.raster)),
      );

    final buffer = StringBuffer()
      ..writeln()
      ..writeln(
        'GPU frame cost per module, median of $_measure presented '
        'frames',
      )
      ..writeln(
        '(${_canvas.width.toInt()}x${_canvas.height.toInt()} canvas, '
        'default module sizes, profile build)',
      )
      ..writeln()
      ..writeln(
        '  ${'module'.padRight(24)}${'build'.padLeft(9)}'
        '${'raster'.padLeft(10)}',
      );
    for (final kind in ranked) {
      final inked = _readings[kind]!.inked;
      buffer.writeln(
        '  ${kind.id.padRight(24)}'
        '${_median(_readings[kind]!.build).toStringAsFixed(0).padLeft(7)} µs'
        '${_median(_readings[kind]!.raster).toStringAsFixed(0).padLeft(8)} µs'
        '${inked.toString().padLeft(10)}'
        '${inked < 500 ? '   <-- DREW NOTHING, timing is meaningless' : ''}',
      );
    }
    buffer
      ..writeln()
      ..writeln('  A 60 fps budget is 16,667 µs; 30 fps is 33,333 µs.')
      ..writeln(
        '  Only one module is on screen at a time, so these do not '
        'add up to a',
      )
      ..writeln('  canvas — they rank what each one hands the raster thread.');

    // ignore: avoid_print
    print(buffer);
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    final size = Size(
      _canvas.width / kGridColumns * kind.defaultColumns,
      _canvas.height / kGridRows * kind.defaultRows,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OaaTheme(
        colors: _colors,
        child: Material(
          color: _colors.background,
          child: Center(
            child: RepaintBoundary(
              key: _boundary,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: ModuleHost(
                  key: ValueKey(kind),
                  spec: ModuleSpec(
                    id: 'bench',
                    kind: kind,
                    rect: GridRect(
                      column: 0,
                      row: 0,
                      columns: kind.defaultColumns,
                      rows: kind.defaultRows,
                    ),
                  ),
                  engine: _material.snapshot,
                  clock: _clock,
                  calibration: BuiltInCalibrations.fallback,
                  naming: DynamicsNaming.defaultNaming,
                  selected: false,
                  onMenu: null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
