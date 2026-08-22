// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Loudness Distribution's reading, held to the property that it is legible
// at every size the module has.
//
// The mode of a distribution reaches the top of the plot *by construction* — the
// bars are scaled to the tallest bin — so whatever sits at the top of the plot
// is sitting on the busiest loudness of the programme on every programme, not on
// an unlucky one. Two things keep the LRA reading out from under it: a strip the
// bars are kept out of, measured against the label rather than taken as a
// fraction of the plot, and painting the annotation after the fill. The strip
// was a bare 12% before, which is thinner than a line of text on a module near
// its minimum height — and that is the size these cases are at.
//
// Of the two, only the strip is separately observable, and that is worth knowing
// rather than pretending otherwise: with the strip correct, the annotation being
// on top or underneath changes the label's own pixels not at all, because
// nothing is drawn where it is. So the cases below hold the strip — the reading
// is there, and the fill does not reach into the rows it lives in — and paint
// order is belt to the strip's braces.
//
// Pixel reads because nothing else can see either one. A label composited under
// a translucent accent fill is laid out at exactly the same offset as one on top
// of it.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/loudness_distribution.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A distribution the test shapes by hand. The module reads five things and
/// this provides exactly those; anything else it grows a use for should fail
/// loudly here rather than read as zero.
class _Fake implements MeterSource {
  int _generation = 0;

  @override
  final Float32List histogram = Float32List(MeterShape.histogramBins);

  /// A single tall bin at [lufs], which is where a mode is, and enough
  /// neighbours that the silhouette is a shape rather than a spike.
  void mode(double lufs) {
    final centre =
        ((lufs - MeterShape.histogramMinLufs) /
                (MeterShape.histogramMaxLufs - MeterShape.histogramMinLufs) *
                MeterShape.histogramBins)
            .round();
    for (var bin = 0; bin < MeterShape.histogramBins; bin++) {
      final distance = (bin - centre).abs();
      histogram[bin] = distance > 8 ? 0 : 1 - distance / 9;
    }
    _generation++;
  }

  @override
  int get generation => _generation;
  @override
  double get elapsedSeconds => _generation * 0.021;
  @override
  bool get hasLoudness => true;
  @override
  double get lufsShort => -14;
  @override
  double get lufsMomentary => -12;
  @override
  double get lufsIntegrated => -14;

  /// A range wide enough to hold the reading between its ends, so the caliper
  /// is in its dimension-line arrangement rather than its narrow one.
  @override
  double get loudnessRange => 12.5;
  @override
  double get loudnessRangeLow => -22.0;
  @override
  double get loudnessRangeHigh => -9.5;
  @override
  double get loudnessRangeGate => -34;

  @override
  bool refresh() => true;
  @override
  bool get hasOverrun => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Owns the clock for as long as the tree lives, as the workspace does — a
/// ticker created beside the tree outlives it and the binding then reports an
/// animation still running after disposal.
class _Harness extends StatefulWidget {
  const _Harness({required this.source, required this.boundary});

  final MeterSource source;
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
        color: _colors.panel,
        child: Center(
          child: RepaintBoundary(
            key: widget.boundary,
            child: SizedBox(
              width: _size.width,
              height: _size.height,
              child: LoudnessDistributionModule(
                engine: widget.source,
                clock: clock,
                calibration: BuiltInCalibrations.streaming,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

const _colors = OaaColors.precisionInstrument;

/// Near [ModuleKind.loudnessDistribution]'s minimum body height, which is where
/// a strip taken as a fraction of the plot stops being tall enough for a label.
const _size = Size(520, 74);

/// One frame of the module, as raw RGBA.
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

/// Whether the pixel at [x], [y] is the reading rather than the picture.
///
/// `textPrimary` is `0xFFE6E8EB` — bright and very nearly neutral. The accent
/// the fill is drawn in is `0xFF35E0C4`, which is 171 counts more green than
/// red, and the over colour is redder than either by as much. So a bright pixel
/// whose channels agree is text, and a bright pixel composited *under* an
/// accent fill at 0.70 alpha is not: it would come out green-dominant by more
/// than a hundred counts.
bool _isReading(Uint8List pixels, int x, int y) {
  final i = (y * _size.width.toInt() + x) * 4;
  final r = pixels[i];
  final g = pixels[i + 1];
  final b = pixels[i + 2];
  return r > 150 && (g - r).abs() < 24 && (b - r).abs() < 24;
}

/// Whether the pixel at [x], [y] belongs to the distribution's fill or its
/// edge — accent, which is far more green than red, or the over colour, which is
/// far more red than green. Either way the channels disagree by a great deal,
/// which is exactly what text does not do.
bool _isPicture(Uint8List pixels, int x, int y) {
  final i = (y * _size.width.toInt() + x) * 4;
  return (pixels[i + 1] - pixels[i]).abs() > 40;
}

/// How many pixels of reading there are, and how many pixels of picture share a
/// row with any of them.
///
/// Deliberately not an assertion about which rows those are. Where the strip
/// starts depends on the height of a laid-out label and on the graticule's
/// gutter, and a test that hard-codes either fails the next time one of them is
/// measured differently rather than when the reading is buried.
(int, int) _readingAndCollisions(Uint8List pixels) {
  final width = _size.width.toInt();
  final rows = <int>{};
  var reading = 0;
  for (var y = 0; y < _size.height.toInt(); y++) {
    for (var x = 0; x < width; x++) {
      if (_isReading(pixels, x, y)) {
        reading++;
        rows.add(y);
      }
    }
  }

  var collisions = 0;
  for (final y in rows) {
    for (var x = 0; x < width; x++) {
      if (_isPicture(pixels, x, y)) collisions++;
    }
  }
  return (reading, collisions);
}

void main() {
  testWidgets('the mode does not reach the strip the reading lives in', (
    tester,
  ) async {
    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(_Harness(source: source, boundary: key));

    // A mode in the middle of the gated range, so the tallest bins are directly
    // under the caliper's label — which is not an unlucky case, because the
    // tallest bin reaches the top of the bars whatever loudness it sits at.
    source.mode(-15.5);
    await tester.pump(const Duration(milliseconds: 17));
    final (reading, collisions) = _readingAndCollisions(
      await _shoot(tester, key),
    );

    expect(reading, greaterThan(40), reason: 'no LRA reading drawn at all');
    expect(
      collisions,
      isZero,
      reason:
          'the distribution is drawn into the rows the reading lives in — on a '
          'module this short a strip taken as a fraction of the plot is thinner '
          'than a line of text',
    );
  });

  testWidgets('an empty distribution still says what the range is', (
    tester,
  ) async {
    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(_Harness(source: source, boundary: key));
    await tester.pump(const Duration(milliseconds: 17));

    // Nothing has been measured, so there are no bins to draw and the module is
    // a graticule. The range still has a reading, and a module that drew
    // nothing at all here would read as one that had failed.
    final (reading, _) = _readingAndCollisions(await _shoot(tester, key));
    expect(
      reading,
      greaterThan(40),
      reason: 'no reading on a module with no distribution yet',
    );
  });
}
