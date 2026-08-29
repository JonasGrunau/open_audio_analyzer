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
  double loudnessRange = _startingRange;
  @override
  double loudnessRangeLow = -22.0;
  @override
  double loudnessRangeHigh = -9.5;

  /// A new number for the caliper to print, with the percentiles, the bins and
  /// the axis where they were. The generation moves with it because the clock
  /// publishes nothing when it has not — see [MeterClock] — and this is how the
  /// cases below find the reading in the frame.
  void range(double lra) {
    loudnessRange = lra;
    _generation++;
  }

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

/// Whether the two frames differ at [x], [y].
///
/// Every case here is a difference between two frames of the same module with
/// one thing changed, so this is the whole of the measurement: the same
/// graticule, the same range band and the same caliper are drawn in the same
/// places both times, and every pixel that moved belongs to the thing that
/// changed.
bool _differs(Uint8List before, Uint8List after, int x, int y) {
  final i = (y * _size.width.toInt() + x) * 4;
  for (var channel = 0; channel < 4; channel++) {
    if (before[i + channel] != after[i + channel]) return true;
  }
  return false;
}

/// The reading, found by changing it.
///
/// It used to be found by hue. The accent is `0xFF35E0C4`, 171 counts more
/// green than red, where every other thing in a module with no distribution in
/// it is very nearly neutral — so a green-dominant pixel was the LRA reading
/// and nothing else. The reading is the caliper's own grey now, the same ink as
/// the two marks it sits between, and no pixel says on its own which of them it
/// belongs to. So the number is moved instead: [_Fake.range] changes what is
/// printed and nothing else at all, and both values print at the same width
/// because every figure in the application is tabular — the caliper's break and
/// the label's offset are identical, and what moved is a glyph of the reading.
class _Reading {
  const _Reading(this.rows, this.pixels);

  /// The rows of the frame the reading is drawn into. Deliberately not an
  /// assertion about which rows those are. Where the strip starts depends on
  /// the height of a laid-out label and on the graticule's gutter, and a test
  /// that hard-coded either would fail the next time one of them was measured
  /// differently rather than when the reading was buried.
  final Set<int> rows;

  /// How many pixels of it there are, which is how a module that has stopped
  /// printing the number is told from one that prints it somewhere unexpected.
  final int pixels;

  static _Reading between(Uint8List before, Uint8List after) {
    final rows = <int>{};
    var pixels = 0;
    for (var y = 0; y < _size.height.toInt(); y++) {
      for (var x = 0; x < _size.width.toInt(); x++) {
        if (_differs(before, after, x, y)) {
          rows.add(y);
          pixels++;
        }
      }
    }
    return _Reading(rows, pixels);
  }
}

/// How many pixels of picture share a row with any pixel of the reading.
int _collisions(Uint8List empty, Uint8List drawn, Set<int> rows) {
  final width = _size.width.toInt();
  var collisions = 0;
  for (final y in rows) {
    for (var x = 0; x < width; x++) {
      if (_differs(empty, drawn, x, y)) collisions++;
    }
  }
  return collisions;
}

/// The reading the fake starts at, and one that prints at a **different
/// width** — which is not a detail, it is the whole of what a pixel read can
/// see here. A widget test runs in the test font, where every glyph is a box
/// of the same size, so `12.5` and `19.8` are the same pixels in the same
/// places and a frame that swapped one for the other would be byte-identical.
/// A reading one figure shorter is not: the label is narrower, the caliper
/// breaks in different places, and a module printing a fixed string instead of
/// the number it was handed shows as the zero it should.
///
/// The pair is deliberately not consistent with the fake's percentiles — those
/// stay where they are so that the caliper's arrangement does, and what these
/// cases are about is the reading's pixels rather than a programme that adds
/// up.
const _startingRange = 12.5;
const _otherRange = 9.9;

void main() {
  testWidgets('the mode does not reach the strip the reading lives in', (
    tester,
  ) async {
    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(_Harness(source: source, boundary: key));

    // The same module with nothing measured: its graticule, its range band and
    // its caliper, and no bars at all. Every pixel that moves from here is the
    // distribution.
    await tester.pump(const Duration(milliseconds: 17));
    final empty = await _shoot(tester, key);

    // Where in that frame the reading is — see [_Reading] — and then back to
    // the number the empty frame was taken at, so the two the picture is
    // measured against differ by the picture alone.
    source.range(_otherRange);
    await tester.pump(const Duration(milliseconds: 17));
    final reading = _Reading.between(empty, await _shoot(tester, key));
    source.range(_startingRange);
    await tester.pump(const Duration(milliseconds: 17));

    // A mode in the middle of the gated range, so the tallest bins are directly
    // under the caliper's label — which is not an unlucky case, because the
    // tallest bin reaches the top of the bars whatever loudness it sits at.
    source.mode(-15.5);
    await tester.pump(const Duration(milliseconds: 17));
    final drawn = await _shoot(tester, key);

    expect(
      reading.pixels,
      greaterThan(60),
      reason: 'no LRA reading drawn at all',
    );
    expect(
      _collisions(empty, drawn, reading.rows),
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
      // The module before it has anything to draw, for the same reason as the
      // caliper case above: what the setting is for is how much of the module
      // the *picture* covers, and the chrome is in both frames either way.
      await tester.pump(const Duration(milliseconds: 17));
      final empty = await _shoot(tester, key);
      source.mode(-15.5);
      await tester.pump(const Duration(milliseconds: 17));

      final drawn = await _shoot(tester, key);
      var columns = 0;
      for (var x = 0; x < _size.width.toInt(); x++) {
        for (var y = 0; y < _size.height.toInt(); y++) {
          if (_differs(empty, drawn, x, y)) {
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
    final first = await _shoot(tester, key);

    // Nothing has been measured, so there are no bins to draw and the module is
    // a graticule. The range still has a reading, and a module that drew
    // nothing at all here would read as one that had failed — so the number is
    // changed, and a frame that did not change with it is a frame with no
    // number in it.
    source.range(_otherRange);
    await tester.pump(const Duration(milliseconds: 17));
    expect(
      _Reading.between(first, await _shoot(tester, key)).pixels,
      greaterThan(60),
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
