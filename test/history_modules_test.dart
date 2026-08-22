// SPDX-License-Identifier: GPL-3.0-or-later
//
// The four modules that keep a history, held to the property whose absence
// crashed the application.
//
// Open Audio Analyzer used to accumulate the spectrogram, the phase trail and
// the stereo cloud into an image kept between frames, taken with
// `Picture.toImageSync`. That image is a handle to a display list the engine
// has not rasterised yet, and it holds that display list for as long as the
// image lives — so frame *n* pinned frame *n−1*, back to the first frame, and
// disposing the Dart handle released none of it. The application leaked a
// full-size image per published frame and died on the raster thread with a
// stack overflow, recursing 3,286 destructors deep through the chain as it was
// finally dropped.
//
// The property that prevents the crash is not "no images" — it is **no
// unbounded retention**. The phase trail, the stereo cloud and the
// oscilloscope keep their history as data and redraw it, creating no images at
// all. The spectrogram
// keeps its history as pixels and uploads them as an image per published
// frame — a *pixel-backed* image from `ImageDescriptor.raw`, which holds no
// display list and no chain, and which replaces a predecessor that is disposed
// on the spot. The first test below is the one that would have caught the
// crash: run long enough to have killed the application, the number of images
// still alive must stay a small constant. The second is the behaviour every
// rewrite has had to preserve — the display advances on new audio and on
// nothing else.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/oscilloscope.dart';
import 'package:oaa/src/modules/phase_scope.dart';
import 'package:oaa/src/modules/spectrogram.dart';
import 'package:oaa/src/modules/stereo_cloud.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A source the test drives by hand, so a thousand published frames take no
/// real time. The modules cannot tell it from the engine — that is the point of
/// [MeterSource] — and it is the only way to run the history long enough to
/// matter inside a widget test.
class _Fake implements MeterSource {
  int _generation = 0;

  /// One analysis block per publish, which is what the engine does — and what
  /// makes `elapsedSeconds` and the scope buffer describe the same audio.
  int _frames = 0;

  final Float32List _spectrum = Float32List(MeterShape.spectrumBands);
  final Float32List _pan = Float32List(MeterShape.spectrumBands);
  final Float32List _scope = Float32List(MeterShape.scopePoints * 2);

  /// Publishes one frame of something that is different from the last one, so
  /// the displays have a reason to change.
  void publish() {
    _generation++;
    _frames += MeterShape.scopePoints;
    for (var band = 0; band < _spectrum.length; band++) {
      final tilt = band / _spectrum.length;
      _spectrum[band] = -84 + 70 * (1 - tilt) * ((_generation + band) % 7) / 6;
      _pan[band] = ((_generation + band) % 11) / 5 - 1;
    }
    for (var i = 0; i < _scope.length; i += 2) {
      _scope[i] = ((_generation + i) % 13) / 13 - 0.5;
      _scope[i + 1] = ((_generation + i) % 17) / 17 - 0.5;
    }
  }

  @override
  int get generation => _generation;

  @override
  bool refresh() => true;

  @override
  bool get hasOverrun => false;

  @override
  bool get hasSpectrum => true;

  @override
  int get channels => 2;

  @override
  int get sampleRate => 48000;

  @override
  double get elapsedSeconds => _frames / 48000;

  @override
  double get correlation => 0.5;

  @override
  Float32List get spectrum => _spectrum;

  @override
  Float32List get spectrumPeak => _spectrum;

  @override
  Float32List get spectrumPan => _pan;

  @override
  Float32List get scope => _scope;

  @override
  int get scopeFrames => _scope.length ~/ 2;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Owns the clock for as long as the tree lives, as the workspace does. A
/// ticker created beside the tree outlives it and the binding then reports an
/// animation still running after disposal — see the note in canvas_test.dart.
class _Harness extends StatefulWidget {
  const _Harness({required this.source, required this.child});

  final MeterSource source;
  final Widget Function(MeterSource engine, MeterClock clock) child;

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
      colors: OaaColors.precisionInstrument,
      child: Material(
        color: OaaColors.precisionInstrument.background,
        child: Center(child: widget.child(widget.source, clock)),
      ),
    ),
  );
}

/// Four of these stack inside the 800×600 the test binding gives a window.
const _size = Size(320, 140);

Widget _sized(Widget child) =>
    SizedBox(width: _size.width, height: _size.height, child: child);

/// One frame of the application's clock.
Future<void> _frame(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 17));

void main() {
  test('an image being created is something this file can see', () {
    // A guard on the guard below. It asserts that nothing created an image,
    // which is also what it would report if `Image.onCreate` had quietly
    // stopped firing — a test that cannot fail is worse than no test, and this
    // one is watching for a defect that took a crash report to find.
    final created = <ui.Image>[];
    final previous = ui.Image.onCreate;
    ui.Image.onCreate = created.add;
    addTearDown(() => ui.Image.onCreate = previous);

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawPaint(ui.Paint());
    final picture = recorder.endRecording();
    picture.toImageSync(8, 8).dispose();
    picture.dispose();

    expect(created, hasLength(1));
  });

  testWidgets('the modules that keep a history retain no images', (
    tester,
  ) async {
    // Every `ui.Image` in the process, from any code. The four modules below
    // are the only things drawing, so anything that lands here was created by
    // one of them. The spectrogram legitimately creates one pixel-backed image
    // per published frame — what it must never do is keep them: a module whose
    // alive count grows with the session is the defect this file exists to
    // prevent.
    final alive = <ui.Image>{};
    var createdEver = 0;
    // Four modules now, and only one of them uploads anything. The bound below
    // is on what is *alive*, not on what was made, so adding a module that
    // creates no images cannot loosen it.
    final previousCreate = ui.Image.onCreate;
    final previousDispose = ui.Image.onDispose;
    ui.Image.onCreate = (image) {
      createdEver++;
      alive.add(image);
    };
    ui.Image.onDispose = alive.remove;
    addTearDown(() {
      ui.Image.onCreate = previousCreate;
      ui.Image.onDispose = previousDispose;
    });

    final source = _Fake();
    await tester.pumpWidget(
      _Harness(
        source: source,
        child: (engine, clock) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sized(SpectrogramModule(engine: engine, clock: clock)),
            _sized(PhaseScopeModule(engine: engine, clock: clock)),
            _sized(StereoCloudModule(engine: engine, clock: clock)),
            _sized(OscilloscopeModule(engine: engine, clock: clock)),
          ],
        ),
      ),
    );

    // Comfortably longer than the ring buffers, and longer than the seventy
    // seconds of audio it took to kill the application. The image uploads are
    // real asynchronous work that a fake-async zone never delivers, so the
    // pumps are interleaved with `runAsync` gaps that let them land — without
    // those, nothing would be created and the test would pass vacuously.
    for (var frame = 0; frame < 500; frame++) {
      source.publish();
      await _frame(tester);
      if (frame % 20 == 0) await _settle(tester);
    }
    await _settle(tester);

    expect(
      createdEver,
      greaterThan(0),
      reason:
          'No image was ever created, so the uploads never ran and the bound '
          'below was not exercised.',
    );
    expect(
      alive,
      hasLength(lessThanOrEqualTo(3)),
      reason:
          'A module kept images between frames. An image that retains its '
          'predecessor — the way toImageSync retains the display list that '
          'drew it — retains every frame before it, which is the leak that '
          'crashed the raster thread.',
    );
  });

  testWidgets('the spectrogram advances on new audio and on nothing else', (
    tester,
  ) async {
    final source = _Fake();
    final key = GlobalKey();

    await tester.pumpWidget(
      _Harness(
        source: source,
        child: (engine, clock) => RepaintBoundary(
          key: key,
          child: _sized(SpectrogramModule(engine: engine, clock: clock)),
        ),
      ),
    );

    for (var frame = 0; frame < 20; frame++) {
      source.publish();
      await _frame(tester);
    }
    // Let the asynchronous image upload land, then paint it: the columns above
    // reach the screen on the repaint after their upload completes.
    await _settle(tester);
    source.publish();
    await _frame(tester);
    final scrolled = await _shoot(tester, key);

    // Repaints without new audio. A display that aged on these would be
    // inventing time that no audio passed through.
    for (var frame = 0; frame < 20; frame++) {
      await _frame(tester);
    }
    expect(
      await _shoot(tester, key),
      scrolled,
      reason: 'the spectrogram scrolled on a repaint that carried no audio',
    );

    source.publish();
    await _frame(tester);
    expect(
      await _shoot(tester, key),
      isNot(scrolled),
      reason: 'the spectrogram did not scroll when a measurement arrived',
    );
  });

  testWidgets('the oscilloscope rolls on new audio and on nothing else', (
    tester,
  ) async {
    // The same property as the test above and worth stating twice, because the
    // oscilloscope reaches it by different arithmetic: it does not advance by
    // a column per publish, it advances by however many frames
    // `elapsedSeconds` says were measured. A display keyed on paint instead
    // would scroll during a resize or a skin change, and a waveform that
    // scrolls without audio is a picture of time that did not pass.
    final source = _Fake();
    final key = GlobalKey();

    await tester.pumpWidget(
      _Harness(
        source: source,
        child: (engine, clock) => RepaintBoundary(
          key: key,
          // A rolling base, because a triggered one re-acquires its window
          // from the samples it kept and would move for a reason that has
          // nothing to do with scrolling.
          child: _sized(
            OscilloscopeModule(
              engine: engine,
              clock: clock,
              timeBase: ScopeTimeBase.s1,
            ),
          ),
        ),
      ),
    );

    for (var frame = 0; frame < 20; frame++) {
      source.publish();
      await _frame(tester);
    }
    final rolled = await _shoot(tester, key);

    for (var frame = 0; frame < 20; frame++) {
      await _frame(tester);
    }
    expect(
      await _shoot(tester, key),
      rolled,
      reason: 'the oscilloscope rolled on a repaint that carried no audio',
    );

    source.publish();
    await _frame(tester);
    expect(
      await _shoot(tester, key),
      isNot(rolled),
      reason: 'the oscilloscope did not roll when a measurement arrived',
    );
  });
}

/// Lets real asynchronous work land — the spectrogram's image uploads complete
/// on the event loop the fake-async zone never returns to. The same trick as
/// [_shoot], without wanting pixels back.
Future<void> _settle(WidgetTester tester) => tester.runAsync(
  () => Future<void>.delayed(const Duration(milliseconds: 20)),
);

/// The rendered pixels of [key]'s subtree.
///
/// `toImage` is a real asynchronous read and cannot be awaited inside the fake
/// async zone a `testWidgets` body runs in — hence `runAsync`.
Future<Uint8List> _shoot(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late Uint8List pixels;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    pixels = data!.buffer.asUint8List(0, data.lengthInBytes);
    image.dispose();
  });
  return pixels;
}
