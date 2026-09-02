// SPDX-License-Identifier: GPL-3.0-or-later
//
// What each of the fourteen modules costs the UI thread per published frame.
//
//     flutter test tool/bench_modules.dart
//
// ---------------------------------------------------------------------------
// Why this file exists at all
//
// A tablet was reported as laggy and the first suspect was the wire: a remote
// display decodes 15,056 bytes thirty times a second. `tool/bench_wire.dart`
// measured that and cleared it — 4 µs a frame before it was made a memmove,
// 0.4 µs after, against a 33,000 µs budget. Whatever makes a display slow is
// not the bytes arriving, so the next question is what happens to them, and
// this is the file that answers it rather than guessing.
//
// Every module is driven through the **remote** path deliberately: the source
// is a `WireSnapshot` filled by decoding a real snapshot payload, which is
// exactly what a tablet holds. No engine, no FFI, no native library — so these
// figures are a tablet's arithmetic run on whatever machine you are sitting at,
// and the ranking between modules transfers even though the absolute numbers
// do not.
//
// What is timed is `tester.pump()`: build, layout and paint *recording*. That
// is the UI thread, which is the thread that makes an application feel slow.
// Rasterisation happens on another one and is not measured here; a module that
// records cheaply can still be expensive to draw, and `bench_spectrogram.dart`
// exists partly because that distinction was once got wrong in this repository.
//
// The material is jagged on purpose. The engine takes the peak bin per band, so
// adjacent bands really do disagree, and smooth synthetic data flatters
// anything that coalesces runs — the mistake that made a spectrogram look 6x
// cheaper than it was for a whole phase.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/canvas/module_host.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'bench_material.dart';

const _colors = OaaColors.precisionInstrument;

/// An 11" iPad in logical pixels — the tablet this feature is aimed at.
const Size _canvas = Size(1194, 834);

/// Frames timed per module, after the warm-up.
const int _frames = 240;

/// Rasterisations timed per module. Fewer, because each one is a full
/// software rasterise and they do not vary the way a record does.
const int _rasterFrames = 20;

class _Harness extends StatefulWidget {
  const _Harness({
    required this.source,
    required this.spec,
    required this.size,
    required this.boundary,
  });

  final MeterSource source;
  final ModuleSpec spec;
  final Size size;
  final GlobalKey boundary;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final MeterClock clock = MeterClock(engine: widget.source, vsync: this);

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: OaaTheme(
      colors: _colors,
      child: Material(
        color: _colors.background,
        child: Center(
          child: RepaintBoundary(
            key: widget.boundary,
            child: SizedBox(
              width: widget.size.width,
              height: widget.size.height,
              child: ModuleHost(
                spec: widget.spec,
                engine: widget.source,
                clock: clock,
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

/// The pixel size a module of this kind gets at its default cell span on
/// [_canvas]. The canvas is always 24x16 cells, whatever the screen.
Size _sizeOf(ModuleKind kind) => Size(
  _canvas.width / kGridColumns * kind.defaultColumns,
  _canvas.height / kGridRows * kind.defaultRows,
);

void main() {
  final records = <ModuleKind, double>{};
  final rasters = <ModuleKind, double>{};
  final inked = <ModuleKind, int>{};

  for (final kind in ModuleKind.values) {
    testWidgets('${kind.id} paint cost', (tester) async {
      final size = _sizeOf(kind);
      tester.view.physicalSize = _canvas * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      final material = BenchMaterial();
      final spec = ModuleSpec(
        id: 'bench',
        kind: kind,
        rect: GridRect(
          column: 0,
          row: 0,
          columns: kind.defaultColumns,
          rows: kind.defaultRows,
        ),
      );

      final boundary = GlobalKey();
      await tester.pumpWidget(
        _Harness(
          source: material.snapshot,
          spec: spec,
          size: size,
          boundary: boundary,
        ),
      );

      // Warm-up: JIT, first-paint allocations, and the history-bearing modules
      // filling their rings. A spectrogram measured before its buffer is full
      // is a spectrogram measured doing less work than it will do.
      for (var i = 0; i < 120; i++) {
        material.publish();
        await tester.pump(const Duration(milliseconds: 21));
      }

      final watch = Stopwatch();
      for (var i = 0; i < _frames; i++) {
        material.publish();
        watch.start();
        await tester.pump(const Duration(milliseconds: 21));
        watch.stop();
      }

      records[kind] = watch.elapsedMicroseconds / _frames;

      // **A benchmark that cannot see what it measured is a random number
      // generator.** A module that draws nothing still lays out, still records
      // an empty picture and still reports a plausible, stable, low figure —
      // and this harness did exactly that once, when a protocol change made the
      // payload it hands `decode` an illegal length. Every number below is
      // published beside the count of pixels that were actually inked.
      await tester.runAsync(() async {
        final shot =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await shot.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        final pixels = data!.buffer.asUint8List();
        final bg = _colors.background;
        var count = 0;
        for (var i = 0; i < pixels.length; i += 4) {
          if ((pixels[i] - (bg.r * 255).round()).abs() > 6 ||
              (pixels[i + 1] - (bg.g * 255).round()).abs() > 6 ||
              (pixels[i + 2] - (bg.b * 255).round()).abs() > 6) {
            count++;
          }
        }
        inked[kind] = count;
      });

      expect(
        inked[kind],
        greaterThan(500),
        reason:
            '${kind.id} inked ${inked[kind]} pixels — it drew nothing, so its '
            'timing measures an empty picture',
      );

      // Rasterisation, on the other thread. `flutter test` has no GPU — this
      // is Skia's software backend — so these numbers rank work rather than
      // predict a tablet's frame time. That is still the question being asked:
      // recording was cleared above, and what is left is which module hands
      // the raster thread the most to do.
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          (await object.toImage()).dispose();
        }
        final rasterWatch = Stopwatch()..start();
        for (var i = 0; i < _rasterFrames; i++) {
          (await object.toImage()).dispose();
        }
        rasterWatch.stop();
        rasters[kind] = rasterWatch.elapsedMicroseconds / _rasterFrames;
      });

      expect(records[kind], greaterThan(0));
      expect(rasters[kind], greaterThan(0));
    });
  }

  tearDownAll(() {
    final ranked = records.keys.toList()
      ..sort(
        (a, b) =>
            (records[b]! + rasters[b]!).compareTo(records[a]! + rasters[a]!),
      );
    final recordTotal = records.values.fold(0.0, (a, b) => a + b);
    final rasterTotal = rasters.values.fold(0.0, (a, b) => a + b);

    String us(double v) => v.toStringAsFixed(0).padLeft(6);

    final lines = <String>[
      '',
      'Per published frame, per module '
          '(${_canvas.width.toInt()}x${_canvas.height.toInt()}, default sizes)',
      '',
      '  ${'module'.padRight(24)}${'record'.padLeft(6)}'
          '${'raster'.padLeft(9)}${'total'.padLeft(9)}'
          '${'inked px'.padLeft(10)}',
    ];
    for (final kind in ranked) {
      lines.add(
        '  ${kind.id.padRight(24)}'
        '${us(records[kind]!)}'
        '${us(rasters[kind]!).padLeft(9)}'
        '${us(records[kind]! + rasters[kind]!).padLeft(9)}'
        '${(inked[kind] ?? 0).toString().padLeft(10)}',
      );
    }
    lines
      ..add('')
      ..add(
        '  ${'all fourteen'.padRight(24)}'
        '${us(recordTotal)}'
        '${us(rasterTotal).padLeft(9)}'
        '${us(recordTotal + rasterTotal).padLeft(9)}   µs',
      )
      ..add('')
      ..add('  A 30 fps budget is 33,333 µs a frame; 60 fps is 16,667 µs.')
      ..add('  Record is the UI thread. Raster is software here, not a GPU:')
      ..add('  read it as a ranking of work handed over, not as a frame time.')
      ..add('');

    // ignore: avoid_print
    print(lines.join('\n'));
  });
}
