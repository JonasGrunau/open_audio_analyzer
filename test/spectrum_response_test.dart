// SPDX-License-Identifier: GPL-3.0-or-later
//
// The spectrum analyser's Response setting, held to what it promises.
//
// The engine publishes a transform every 1024 samples — about 47 a second — and
// drawing each one untouched makes the curve flicker hard enough that the shape
// of a balance is difficult to read. Response averages the *drawn* level over a
// time constant instead of drawing fewer frames, and the three things worth
// proving are the three that make that an honest trade:
//
//   - Fast is not an average at all. The curve is where the last published
//     frame put it, which is what it was before the setting existed.
//   - A slower setting arrives. A one-pole that lags and then never quite gets
//     there is a meter that reads low on steady programme.
//   - The peak-hold line is never averaged, at any setting. It is what keeps a
//     slow curve honest: the curve says where the programme mostly sits, the
//     line above it says how far it actually went.
//
// These are pixel reads for the reason `histogram_test.dart` gives — a level
// folded into the wrong buffer passes every widget assertion there is.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bel/src/clock/meter_clock.dart';
import 'package:bel/src/modules/spectrum_analyzer.dart';
import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A spectrum source the test drives by hand.
class _Fake implements MeterSource {
  final Float32List _spectrum = Float32List(MeterShape.spectrumBands);
  final Float32List _spectrumPeak = Float32List(MeterShape.spectrumBands);

  int _generation = 0;
  double _elapsed = 0;

  /// One published frame [seconds] later, with every band at [db] and the hold
  /// at [peakDb].
  void publish(double seconds, {required double db, double peakDb = -96}) {
    _generation++;
    _elapsed += seconds;
    _spectrum.fillRange(0, _spectrum.length, db);
    _spectrumPeak.fillRange(0, _spectrumPeak.length, peakDb);
  }

  @override
  int get generation => _generation;

  @override
  bool refresh() => true;

  @override
  bool get hasSpectrum => true;

  @override
  bool get hasOverrun => false;

  @override
  double get elapsedSeconds => _elapsed;

  @override
  Float32List get spectrum => _spectrum;

  @override
  Float32List get spectrumPeak => _spectrumPeak;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _colors = BelColors.precisionInstrument;
const _size = Size(480, 220);

/// A published frame, and the frame that draws it.
Future<void> _frame(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 17));

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

/// Whether the pixel at [x], [y] is drawn in the accent.
///
/// The same read `histogram_test.dart` makes, and for the same reason: accent
/// is `0xFF35E0C4` and everything else the analyser draws — the graticule
/// hairlines, the frequency labels — is grey, where red and green are within a
/// few counts of each other.
///
/// [ink] is how much of the accent has to be there. The curve is a
/// `BelStroke.mark` stroke at full alpha and reads about 150; the peak-hold
/// line is a *hairline* at 0.45 alpha and reads 57 where it covers a whole
/// pixel row and less where it straddles two, so a test looking for the hold
/// has to ask for less than one looking for the curve. Grey is under 5 either
/// way.
bool _isAccent(Uint8List pixels, int x, int y, int ink) {
  final i = (y * _size.width.toInt() + x) * 4;
  return pixels[i + 1] - pixels[i] > ink;
}

/// The topmost accent row in a column near the middle of the plot.
///
/// Smaller is higher on the screen and therefore louder. The band fill runs
/// from the curve down to the floor, so the first accent pixel from the top is
/// the curve — unless the hold line is above it, which is exactly what the last
/// test looks for.
int _topAt(Uint8List pixels, {int x = 200, int ink = 64}) {
  for (var y = 0; y < _size.height.toInt(); y++) {
    if (_isAccent(pixels, x, y, ink)) return y;
  }
  return _size.height.toInt();
}

/// **A fresh key every time, and it is load-bearing.** A second `pumpWidget` of
/// the same widget type reuses the element — so the clock stays bound to the
/// first test's source and the analyser keeps the levels it had already folded.
/// The reference reading is then taken from the previous test's tree.
class _Harness extends StatefulWidget {
  _Harness({
    required this.source,
    required this.boundary,
    required this.response,
  }) : super(key: UniqueKey());

  final MeterSource source;
  final GlobalKey boundary;
  final SpectrumResponse response;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with SingleTickerProviderStateMixin {
  late final MeterClock clock = MeterClock(engine: widget.source, vsync: this);

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: BelTheme(
      colors: _colors,
      child: Material(
        color: _colors.background,
        child: Center(
          child: RepaintBoundary(
            key: widget.boundary,
            child: SizedBox(
              width: _size.width,
              height: _size.height,
              child: SpectrumAnalyzerModule(
                engine: widget.source,
                clock: clock,
                response: widget.response,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Where the curve sits with [db] published steadily at [response].
Future<int> _settled(
  WidgetTester tester,
  SpectrumResponse response,
  double db,
) async {
  final key = GlobalKey();
  final source = _Fake();
  await tester.pumpWidget(
    _Harness(source: source, boundary: key, response: response),
  );
  for (var i = 0; i < 120; i++) {
    source.publish(0.02, db: db);
    await _frame(tester);
  }
  return _topAt(await _shoot(tester, key));
}

void main() {
  testWidgets('Fast draws the frame it was handed', (tester) async {
    final loud = await _settled(tester, SpectrumResponse.fast, -12);

    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(
      _Harness(source: source, boundary: key, response: SpectrumResponse.fast),
    );

    for (var i = 0; i < 20; i++) {
      source.publish(0.02, db: -60);
      await _frame(tester);
    }
    final quiet = _topAt(await _shoot(tester, key));
    expect(
      quiet,
      greaterThan(loud + 20),
      reason: '−60 dB should be drawn well below −12 dB',
    );

    // One published frame at the new level, and the curve is there.
    source.publish(0.02, db: -12);
    await _frame(tester);
    expect(
      (_topAt(await _shoot(tester, key)) - loud).abs(),
      lessThanOrEqualTo(1),
      reason: 'Fast is not an average — the step should land in one frame',
    );
  });

  testWidgets('a slower response lags the step and then arrives', (
    tester,
  ) async {
    final loud = await _settled(tester, SpectrumResponse.normal, -12);

    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(
      _Harness(
        source: source,
        boundary: key,
        response: SpectrumResponse.normal,
      ),
    );

    for (var i = 0; i < 60; i++) {
      source.publish(0.02, db: -60);
      await _frame(tester);
    }
    final quiet = _topAt(await _shoot(tester, key));

    // One 20 ms frame into a 120 ms time constant covers about 15% of the
    // step. Asserted as "still in the bottom half of the move" rather than as
    // a pixel, so that changing the constant does not fail the property.
    source.publish(0.02, db: -12);
    await _frame(tester);
    final stepped = _topAt(await _shoot(tester, key));
    expect(
      stepped,
      greaterThan(quiet - (quiet - loud) ~/ 2),
      reason: 'Normal jumped most of the way in one frame — it is not averaging',
    );
    expect(
      stepped,
      lessThan(quiet),
      reason: 'Normal did not move at all — the fold is not running',
    );

    // Half a second is four time constants. It has to actually get there: a
    // one-pole that stops short reads low on steady programme forever.
    for (var i = 0; i < 25; i++) {
      source.publish(0.02, db: -12);
      await _frame(tester);
    }
    expect(
      (_topAt(await _shoot(tester, key)) - loud).abs(),
      lessThanOrEqualTo(2),
      reason: 'Normal never arrived at the level being published',
    );
  });

  testWidgets('the peak hold is not averaged at any response', (tester) async {
    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(
      _Harness(source: source, boundary: key, response: SpectrumResponse.slow),
    );

    for (var i = 0; i < 60; i++) {
      source.publish(0.02, db: -60, peakDb: -60);
      await _frame(tester);
    }
    final quiet = _topAt(await _shoot(tester, key));

    // The programme goes loud for one frame. On Slow the curve has barely
    // moved — and the hold has to be at the top of the move regardless, which
    // is the whole reason a slow curve is allowed to exist.
    source.publish(0.02, db: -12, peakDb: -12);
    await _frame(tester);
    final top = _topAt(await _shoot(tester, key), ink: 32);

    final loud = await _settled(tester, SpectrumResponse.fast, -12);
    expect(
      (top - loud).abs(),
      lessThanOrEqualTo(2),
      reason: 'the hold line lagged the transient it exists to catch',
    );
    expect(
      quiet,
      greaterThan(loud + 20),
      reason: 'the two levels were not far enough apart to prove anything',
    );
  });
}
