// SPDX-License-Identifier: GPL-3.0-or-later
//
// The spectrum analyser's Response and Tilt settings, held to what they
// promise.
//
// The engine publishes a transform every 1024 samples — about 47 a second — and
// drawing each one untouched makes the curve flicker hard enough that the shape
// of a balance is difficult to read. Response averages the *drawn* level over a
// time constant instead of drawing fewer frames, and Tilt rotates what is drawn
// about 1 kHz so that a mix is roughly horizontal rather than a ramp. Five
// things are worth proving:
//
//   - Fast is not an average at all. The curve is where the last published
//     frame put it, which is what it was before the setting existed.
//   - A slower setting arrives. A one-pole that lags and then never quite gets
//     there is a meter that reads low on steady programme.
//   - The hold sits above the curve after a transient and then comes down to
//     it. It is the envelope of the drawn curve, so it moves with it by
//     construction — what has to be shown is that it holds at all, and that it
//     lets itself down again afterwards.
//   - The hold cannot exceed the curve, and says so by reading *lower* than
//     the engine's own peak on a transient a slow response smoothed away. That
//     is the whole cost of holding what the reader can see, and `Fast` is the
//     setting that catches a click.
//   - A tilt rotates the picture in the direction and by the amount the
//     setting names, and takes the hold line with it. A tilt applied to the
//     curve and not to the line above it would bury the line under the fill at
//     the top of the range and nothing would look broken.
//
// These are pixel reads for the reason `histogram_test.dart` gives — a level
// folded into the wrong buffer passes every widget assertion there is.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/spectrum_analyzer.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A spectrum source the test drives by hand.
class _Fake implements MeterSource {
  /// **The floor, not zero.** A `Float32List` starts full of 0.0, and 0.0 dB is
  /// full scale — so a source that had published nothing yet described a
  /// moment of digital silence as the loudest one there is, and the first paint
  /// snapped the curve to the top of the plot. Harmless for the curve, which
  /// eases away from it within a frame or two, and not at all harmless for a
  /// *hold*, which is entitled to sit at the top for a second and a half and
  /// then let itself down at 12 dB a second. The real engine says
  /// `hasSpectrum: false` until it has one and this module draws nothing.
  _Fake() {
    _spectrum.fillRange(0, _spectrum.length, -96);
    _spectrumPeak.fillRange(0, _spectrumPeak.length, -96);
  }

  final Float32List _spectrum = Float32List(MeterShape.spectrumBands);
  final Float32List _spectrumPeak = Float32List(MeterShape.spectrumBands);

  int _generation = 0;
  double _elapsed = 0;

  /// One published frame [seconds] later, with every band at [db].
  ///
  /// [peakDb] fills the engine's own per-band hold, which the analyser no
  /// longer draws — the line above the curve is the envelope of the curve. It
  /// is still published, still on the wire and still what a report carries, so
  /// a test that sets it and then finds nothing on screen holding it is part of
  /// what is being proved.
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
  Float32List spectrumOf(SpectrumSource source) => spectrum;

  @override
  Float32List spectrumPeakOf(SpectrumSource source) => spectrumPeak;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _colors = OaaColors.precisionInstrument;
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
/// `OaaStroke.mark` stroke at full alpha and reads about 150; the peak-hold
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
    this.tilt = SpectrumTilt.db0,
  }) : super(key: UniqueKey());

  final MeterSource source;
  final GlobalKey boundary;
  final SpectrumResponse response;

  /// **Flat unless a test is about the tilt**, where the module itself defaults
  /// to 4.5 dB/oct. Every reading below is a pixel row at one x, and a tilt
  /// offsets that row by however many octaves the x stands for — which would
  /// leave each response assertion quietly measuring a level nobody chose.
  final SpectrumTilt tilt;

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
              width: _size.width,
              height: _size.height,
              child: SpectrumAnalyzerModule(
                engine: widget.source,
                clock: clock,
                response: widget.response,
                tilt: widget.tilt,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Two columns to read the tilt between, well inside the plot at either end.
///
/// The plot is the module's width less the gutter the dB labels reserve, so
/// neither of these is a frequency the test can name — which is the point of
/// asserting one tilt against another rather than against a number of
/// decibels.
const int _xLow = 100;
const int _xHigh = 400;

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
      reason:
          'Normal jumped most of the way in one frame — it is not averaging',
    );
    expect(
      stepped,
      lessThan(quiet),
      reason: 'Normal did not move at all — the fold is not running',
    );

    // Seven-tenths of a second is nearly six time constants. It has to
    // actually get there: a one-pole that stops short reads low on steady
    // programme forever. Six rather than four because the tapered scale gives
    // the top of the range about five pixels per decibel, so the same
    // two-pixel tolerance is a finer statement in decibels than it used to be.
    for (var i = 0; i < 35; i++) {
      source.publish(0.02, db: -12);
      await _frame(tester);
    }
    expect(
      (_topAt(await _shoot(tester, key)) - loud).abs(),
      lessThanOrEqualTo(2),
      reason: 'Normal never arrived at the level being published',
    );
  });

  testWidgets('the hold sits above the curve and then comes down to it', (
    tester,
  ) async {
    final loud = await _settled(tester, SpectrumResponse.fast, -12);

    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(
      _Harness(source: source, boundary: key, response: SpectrumResponse.fast),
    );

    for (var i = 0; i < 60; i++) {
      source.publish(0.02, db: -60);
      await _frame(tester);
    }
    final quiet = _topAt(await _shoot(tester, key));
    expect(
      quiet,
      greaterThan(loud + 20),
      reason: 'the two levels were not far enough apart to prove anything',
    );

    // The programme goes loud for one frame and then quiet again. On Fast the
    // curve is back at the floor the very next frame; the line has to stay up
    // there, which is the entire purpose of a hold.
    source.publish(0.02, db: -12);
    await _frame(tester);
    for (var i = 0; i < 10; i++) {
      source.publish(0.02, db: -60);
      await _frame(tester);
    }
    final held = _topAt(await _shoot(tester, key), ink: 32);
    expect(
      (held - loud).abs(),
      lessThanOrEqualTo(3),
      reason: 'the hold did not stay at the level the curve reached',
    );

    // And then it lets itself down: a second and a half at the top, and 12 dB
    // a second after that. Eight seconds is comfortably past the five and a
    // half that 48 dB of fall takes. A hold that never falls is a high-water
    // mark for the session, which is a different instrument.
    for (var i = 0; i < 400; i++) {
      source.publish(0.02, db: -60);
      await _frame(tester);
    }
    expect(
      (_topAt(await _shoot(tester, key), ink: 32) - quiet).abs(),
      lessThanOrEqualTo(3),
      reason: 'the hold never came back down to the curve',
    );
  });

  testWidgets('the hold holds the curve, which is lower and says so', (
    tester,
  ) async {
    final loud = await _settled(tester, SpectrumResponse.fast, -12);

    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(
      _Harness(source: source, boundary: key, response: SpectrumResponse.slow),
    );

    for (var i = 0; i < 60; i++) {
      source.publish(0.02, db: -60, peakDb: -60);
      await _frame(tester);
    }

    // One frame of programme at −12 dB, which a 500 ms pole barely moves the
    // curve for, and the engine's own hold latched to it. The line above the
    // curve cannot reach that: it is holding the curve, and the curve never
    // went there.
    source.publish(0.02, db: -12, peakDb: -12);
    await _frame(tester);
    for (var i = 0; i < 30; i++) {
      source.publish(0.02, db: -60, peakDb: -12);
      await _frame(tester);
    }

    expect(
      _topAt(await _shoot(tester, key), ink: 32),
      greaterThan(loud + 10),
      reason:
          'the line reached a level the drawn curve never did, so it is not '
          'holding the curve',
    );
  });

  testWidgets('a tilt rotates the picture by what the setting says', (
    tester,
  ) async {
    // A flat spectrum is the one input a tilt is legible against: whatever the
    // curve does across the width is the tilt, and nothing else.
    Future<(int, int)> ends(SpectrumTilt tilt) async {
      final key = GlobalKey();
      final source = _Fake();
      await tester.pumpWidget(
        _Harness(
          source: source,
          boundary: key,
          response: SpectrumResponse.fast,
          tilt: tilt,
        ),
      );
      for (var i = 0; i < 10; i++) {
        source.publish(0.02, db: -40);
        await _frame(tester);
      }
      final pixels = await _shoot(tester, key);
      return (_topAt(pixels, x: _xLow), _topAt(pixels, x: _xHigh));
    }

    final (flatLow, flatHigh) = await ends(SpectrumTilt.db0);
    expect(
      (flatLow - flatHigh).abs(),
      lessThanOrEqualTo(1),
      reason: '0 dB/oct drew a flat spectrum as something other than flat',
    );

    // Up to the right, because that is where the energy of a mix is missing.
    // Smaller y is higher on the screen.
    final (steepLow, steepHigh) = await ends(SpectrumTilt.db4p5);
    expect(
      steepHigh,
      lessThan(steepLow - 40),
      reason: '4.5 dB/oct did not lift the top of the range',
    );
    expect(
      steepLow,
      greaterThan(flatLow),
      reason:
          'the rotation lifted the bottom of the range as well as the '
          'top, so it is an offset and not a tilt',
    );

    // Two settings, one ratio. Asserted against each other rather than in
    // decibels, because the alternative is a test that has to know how wide
    // the plot is and where the graticule's gutter starts — and would then
    // pass or fail on the width of a tick label.
    final (midLow, midHigh) = await ends(SpectrumTilt.db3);
    final steep = steepLow - steepHigh;
    final mid = midLow - midHigh;
    expect(
      steep / mid,
      closeTo(1.5, 0.15),
      reason: '4.5 dB/oct is not one and a half times 3 dB/oct',
    );
  });

  testWidgets('the tilt takes the hold line with it', (tester) async {
    // The steepest setting, and a reading at the top of the range where it
    // lifts the curve by nearly twenty decibels. A hold left untilted would
    // sit that far *below* the curve, under the fill, where the eye reads a
    // module with no hold at all rather than a bug.
    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(
      _Harness(
        source: source,
        boundary: key,
        response: SpectrumResponse.fast,
        tilt: SpectrumTilt.db6,
      ),
    );

    for (var i = 0; i < 30; i++) {
      source.publish(0.02, db: -60);
      await _frame(tester);
    }
    source.publish(0.02, db: -24);
    await _frame(tester);
    for (var i = 0; i < 10; i++) {
      source.publish(0.02, db: -60);
      await _frame(tester);
    }

    final pixels = await _shoot(tester, key);
    final curve = _topAt(pixels, x: _xHigh);
    final hold = _topAt(pixels, x: _xHigh, ink: 32);
    expect(
      hold,
      lessThan(curve - 20),
      reason: 'the hold is not above the curve at the top of a tilted range',
    );
  });
}
