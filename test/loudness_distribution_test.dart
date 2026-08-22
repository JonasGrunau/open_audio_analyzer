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
//
// ---------------------------------------------------------------------------
// And the fitted axis, which is arithmetic and is tested as arithmetic
//
// `DistributionWindow` decides how much of the −60..0 LUFS range the module
// draws, and every property worth holding it to is a statement about numbers:
// it holds every occupied bin, it lands on round ticks, it is never narrower
// than a picture can use, and it stays where it is while the distribution does.
// The last case in the file is the one that has to be pixels, because what the
// setting is *for* — the distribution getting the width — is a claim about how
// much of the module the picture covers.

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
  /// is in its dimension-line arrangement rather than its narrow one. Fields
  /// rather than getters because the fitted axis is computed from them, and a
  /// case that moves the percentiles is how that gets checked.
  @override
  double loudnessRange = 12.5;
  @override
  double loudnessRangeLow = -22.0;
  @override
  double loudnessRangeHigh = -9.5;
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
  const _Harness({
    required this.source,
    required this.boundary,
    this.scale = DistributionScale.auto,
    super.key,
  });

  final MeterSource source;
  final GlobalKey boundary;
  final DistributionScale scale;

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
                scale: widget.scale,
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

  testWidgets('a fitted axis gives the distribution the width it has', (
    tester,
  ) async {
    // How many columns of the module the picture is drawn into, at each
    // setting. The same programme both times: a mode at −15.5 LUFS with its
    // percentiles either side of it, which is where a real pair sits — the
    // fake's default range is deliberately wider than its bins for the caliper
    // cases above, and that is not a distribution any programme produces.
    Future<int> inked(DistributionScale scale) async {
      final key = GlobalKey();
      final source = _Fake()
        ..loudnessRangeLow = -18
        ..loudnessRangeHigh = -13
        ..loudnessRange = 5;
      // Keyed, so the second setting gets its own state and therefore its own
      // clock: `_HarnessState` binds the clock to the source it was built with,
      // and a reused state would tick the previous case's engine while the
      // module read this one's — a module that never repaints and a picture
      // that is never drawn.
      await tester.pumpWidget(
        _Harness(
          key: ValueKey(scale),
          source: source,
          boundary: key,
          scale: scale,
        ),
      );
      source.mode(-15.5);
      await tester.pump(const Duration(milliseconds: 17));

      final pixels = await _shoot(tester, key);
      var columns = 0;
      for (var x = 0; x < _size.width.toInt(); x++) {
        for (var y = 0; y < _size.height.toInt(); y++) {
          if (_isPicture(pixels, x, y)) {
            columns++;
            break;
          }
        }
      }
      return columns;
    }

    final full = await inked(DistributionScale.full);
    final auto = await inked(DistributionScale.auto);

    expect(
      full,
      lessThan(_size.width * 0.2),
      reason:
          'a 8 LU distribution on a 60 LU axis should be a fifth of the module',
    );
    expect(
      auto,
      greaterThan(full * 2),
      reason:
          'the fitted axis draws the same distribution into no more of the '
          'module than the published range does — the columns are still being '
          'mapped to bins as though the axis were −60..0',
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

  group('the fitted window', () {
    /// A distribution occupying [low] to [high] LUFS and nothing else.
    Float32List bins(double low, double high) {
      final bins = Float32List(MeterShape.histogramBins);
      for (var bin = 0; bin < MeterShape.histogramBins; bin++) {
        final lufs = MeterShape.histogramMinLufs + bin * 0.5;
        if (lufs >= low && lufs <= high) bins[bin] = 1;
      }
      return bins;
    }

    MeterScale fitted(
      MeterScale current,
      Float32List bins, {
      double target = -14,
      double rangeLow = double.nan,
      double rangeHigh = double.nan,
    }) => DistributionWindow.next(
      current,
      bins: bins,
      target: target,
      rangeLow: rangeLow,
      rangeHigh: rangeHigh,
    );

    test('holds every occupied bin, and is narrower for doing it', () {
      final scale = fitted(
        DistributionWindow.full,
        bins(-20, -12),
        rangeLow: -19,
        rangeHigh: -13,
      );

      expect(scale.min, lessThanOrEqualTo(-20));
      expect(scale.max, greaterThanOrEqualTo(-12));
      expect(
        scale.span,
        lessThan(DistributionWindow.full.span / 2),
        reason: 'an axis fitted to 8 LU of programme is still most of 60',
      );
    });

    test('holds a delivery target the programme never reached', () {
      // Quiet material against a streaming target: the dashed line is drawn on
      // this axis, and an axis that clamped it would put it on the edge of the
      // plot as a reading that is simply wrong.
      final scale = fitted(DistributionWindow.full, bins(-40, -32));
      expect(scale.min, lessThanOrEqualTo(-40));
      expect(scale.max, greaterThanOrEqualTo(-14));
    });

    test('lands on round ticks, at every loudness a programme can sit at', () {
      for (var centre = -55.0; centre <= -5.0; centre += 1) {
        final scale = fitted(
          DistributionWindow.full,
          bins(centre - 4, centre + 4),
          target: centre,
        );
        final where = 'at $centre LUFS';

        expect(scale.min % scale.step, isZero, reason: where);
        expect(scale.max % scale.step, isZero, reason: where);
        expect(
          scale.ticks.length,
          lessThanOrEqualTo(DistributionWindow.maxIntervals + 1),
          reason: where,
        );
        expect(
          scale.span,
          greaterThanOrEqualTo(DistributionWindow.minSpan),
          reason: where,
        );
        expect(scale.min, greaterThanOrEqualTo(MeterShape.histogramMinLufs));
        expect(scale.max, lessThanOrEqualTo(MeterShape.histogramMaxLufs));
        expect(scale.min, lessThanOrEqualTo(centre - 4), reason: where);
        expect(scale.max, greaterThanOrEqualTo(centre + 4), reason: where);
      }
    });

    test('stays where it is while the distribution stays inside it', () {
      final first = fitted(DistributionWindow.full, bins(-20, -12));
      final second = fitted(first, bins(-19.5, -12.5));

      expect(
        identical(second, first),
        isTrue,
        reason:
            'the window was refitted for a distribution that had not left it, '
            'which is a scale that slides under the reader',
      );
    });

    test('and moves when the programme grows past it', () {
      final first = fitted(DistributionWindow.full, bins(-20, -12));
      final second = fitted(first, bins(-40, -12));

      expect(second, isNot(first));
      expect(second.min, lessThanOrEqualTo(-40));
    });

    test('a programme that used the whole range gets the whole axis', () {
      expect(
        fitted(DistributionWindow.full, bins(-59, -1)),
        DistributionWindow.full,
      );
    });

    test('and one that has not started yet opens on the target', () {
      final scale = fitted(
        DistributionWindow.full,
        Float32List(MeterShape.histogramBins),
      );

      expect(scale.min, lessThan(-14));
      expect(scale.max, greaterThan(-14));
      expect(scale.span, greaterThanOrEqualTo(DistributionWindow.minSpan));
    });
  });
}
