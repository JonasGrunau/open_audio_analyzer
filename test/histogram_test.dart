// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Histogram's resting line, held to the property that it is always there.
//
// The short-term curve used to be drawn only over the columns the programme
// had reached, so an empty display had no line on it at all and a part-filled
// one had a line over part of its width. Straight after a reset — the moment
// somebody is most likely to be looking at it — the module was an empty box,
// which reads as a meter that has failed rather than one that is waiting.
//
// The line now rests on the floor of the scale and runs the full width of the
// plot. These tests are pixel reads because that is the only thing that can
// see it: a curve painted into the wrong half of a `Float32List` passes every
// widget assertion there is.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/histogram.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A loudness source the test drives by hand. The histogram reads five things
/// and this provides exactly those; anything else it grew a use for should fail
/// loudly here rather than read as zero.
class _Fake implements MeterSource {
  int _generation = 0;
  double _short = -70;
  double _momentary = -70;
  double _elapsed = 0;

  /// One published frame, [seconds] into the programme.
  void publish(double seconds, {double short = -70, double momentary = -70}) {
    _generation++;
    _elapsed = seconds;
    _short = short;
    _momentary = momentary;
  }

  /// What the transport's reset does: the clock goes back to zero, and the
  /// history has to notice that it is a new programme rather than draw the new
  /// one onto the end of the old.
  void reset() => publish(0);

  @override
  int get generation => _generation;

  @override
  bool refresh() => true;

  @override
  bool get hasOverrun => false;

  @override
  bool get hasLoudness => true;

  @override
  double get lufsShort => _short;

  @override
  double get lufsMomentary => _momentary;

  @override
  double get elapsedSeconds => _elapsed;

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
    this.smoothing = HistogramSmoothing.normal,
    this.calibration = BuiltInCalibrations.streaming,
    super.key,
  });

  final MeterSource source;
  final GlobalKey boundary;

  /// Defaulted to what ships, so the resting-curve cases below exercise the
  /// setting a module actually opens with.
  final HistogramSmoothing smoothing;

  /// The smoothing cases hand in [_lowTarget] instead: the target's dashes and
  /// axis value are drawn in `over` red, which [_isCurve] cannot tell from the
  /// curve's own over-target colour, so a target in the middle of the scale
  /// would cap every `_curveTop` read at its own row. Moving the target out of
  /// the way keeps those tests about the curve; the resting cases read only
  /// the plot floor and keep the shipped target.
  final Calibration calibration;

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
              child: HistogramModule(
                engine: widget.source,
                clock: clock,
                calibration: widget.calibration,
                smoothing: widget.smoothing,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

const _colors = OaaColors.precisionInstrument;
const _size = Size(480, 220);

/// A target below everything the smoothing cases draw — see
/// [_Harness.calibration].
const _lowTarget = Calibration(
  id: 'test-low',
  name: 'Out of the way',
  lufsTarget: -40,
  lufsTolerance: 0.5,
  truePeakMax: -1,
  loudnessRangeMax: 20,
);

/// The plot's floor row: the module keeps an overview strip under the plot,
/// and the resting curve rests on the plot's own bottom edge above it. Derived
/// from the module's arithmetic rather than copied as a number, so a resized
/// strip moves the tests with it.
int _plotFloor() {
  final overview = HistogramModule.overviewHeight(_size.height);
  return (_size.height - (overview > 0 ? overview + Space.xs : 0)).floor();
}

Future<void> _frame(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 17));

/// One frame of the histogram, as raw RGBA.
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

/// Whether the pixel at [x], [y] is the curve, in **either** of its colours.
///
/// The curve is `accent` up to the delivery target and `over` past it, so a
/// predicate that knows only one of them stops finding the curve halfway up the
/// plot — which is not a failure, it is a *lower* reading: `_curveTop` returns
/// the target's row instead of the peak's, and a test comparing two heights
/// quietly compares one height against a constant.
///
/// Both colours are far off the grey axis in opposite directions — accent
/// `0xFF35E0C4` is much greener than red, over `0xFFFF4D4D` much redder than
/// green — and nothing else the module draws **near the plot floor** is
/// either. The graticule is a near-black hairline; the tick labels are grey,
/// where the two channels are within a few counts; the fill under the curve
/// fades to 0.14 alpha of a background-leaning tint at the floor, under 20
/// counts apart. A margin of 64 separates the stroke from all of them,
/// including where an antialiased end covers half a pixel. What the margin
/// **cannot** exclude is the target's own furniture — its dashes and axis
/// value are `over` red by design — which is why the cases reading anywhere
/// but the floor move the target out of the way; see [_Harness.calibration].
bool _isCurve(Uint8List pixels, int x, int y) {
  final i = (y * _size.width.toInt() + x) * 4;
  return (pixels[i + 1] - pixels[i]).abs() > 64;
}

/// The x of every column carrying the curve within [rows] of the plot floor —
/// the bottom of the *plot*, which sits above the overview strip.
List<int> _curveColumns(Uint8List pixels, {int rows = 3}) {
  final floor = _plotFloor();
  return [
    for (var x = 0; x < _size.width.toInt(); x++)
      if ([
        for (var y = floor - rows; y < floor; y++) y,
      ].any((y) => _isCurve(pixels, x, y)))
        x,
  ];
}

/// The highest row any curve pixel reaches. Smaller is higher up the plot.
int _curveTop(Uint8List pixels) {
  final width = _size.width.toInt();
  for (var y = 0; y < _size.height.toInt(); y++) {
    for (var x = 0; x < width; x++) {
      if (_isCurve(pixels, x, y)) return y;
    }
  }
  return _size.height.toInt();
}

/// A hundred columns of quiet, one loud column, a hundred more of quiet.
///
/// Five publishes to a column at 50 ms apart, so the spike is one closed column
/// and not a fraction of two — the property under test is what happens to a
/// single column, and a spike smeared across a boundary by the harness would
/// pass either way.
Future<Uint8List> _spike(
  WidgetTester tester,
  HistogramSmoothing smoothing,
) async {
  final key = GlobalKey();
  final source = _Fake();
  await tester.pumpWidget(
    _Harness(
      key: ValueKey(smoothing),
      source: source,
      boundary: key,
      smoothing: smoothing,
      calibration: _lowTarget,
    ),
  );

  for (var publish = 1; publish <= 1005; publish++) {
    final loud = publish > 500 && publish <= 505;
    source.publish(
      publish * 0.02,
      short: loud ? -6 : -24,
      momentary: loud ? -6 : -24,
    );
    await _frame(tester);
  }
  return _shoot(tester, key);
}

void main() {
  testWidgets('the curve spans the plot before any audio arrives', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(_Harness(source: _Fake(), boundary: key));
    await _frame(tester);

    final columns = _curveColumns(await _shoot(tester, key));
    _expectSpansThePlot(columns, 'nothing has been measured yet');
  });

  testWidgets('the curve spans the plot again after a reset', (tester) async {
    final key = GlobalKey();
    final source = _Fake();
    await tester.pumpWidget(_Harness(source: source, boundary: key));

    // Six seconds of loud programme, which is sixty closed columns — sixty
    // pixels of curve at the right edge, lifted well clear of the floor. The
    // rest of the plot is still resting, and that is the point: measured and
    // unmeasured share one line.
    for (var frame = 1; frame <= 300; frame++) {
      source.publish(frame * 0.02, short: -12, momentary: -10);
      await _frame(tester);
    }
    expect(
      _curveColumns(await _shoot(tester, key)),
      isNot(contains(_size.width.toInt() - 1)),
      reason: 'a programme at −12 LUFS drew its newest column on the floor',
    );

    source.reset();
    await _frame(tester);

    final columns = _curveColumns(await _shoot(tester, key));
    _expectSpansThePlot(columns, 'the history was cleared by a reset');
  });

  // --- Smoothing ------------------------------------------------------------
  //
  // The setting is a centred mean over columns of measured signal, applied when
  // the ring is read rather than when it is written. Two properties are worth
  // holding: it costs height on a short event, and it costs nothing at all on a
  // steady one. Both are pixel reads because both are claims about the drawn
  // curve, and a mean computed into the wrong half of a `Float32List` passes
  // every widget assertion there is.

  testWidgets('a one-column spike is drawn lower with smoothing on', (
    tester,
  ) async {
    final off = _curveTop(await _spike(tester, HistogramSmoothing.off));
    final broad = _curveTop(await _spike(tester, HistogramSmoothing.broad));

    // −6 LUFS against a −24 body over a 21-column window averages to about
    // −23.1, which is most of the plot's height further down. Asserted as a
    // distance rather than against a row, because where the plot starts depends
    // on the width of a laid-out label.
    expect(
      broad - off,
      greaterThan(40),
      reason: 'Broad drew the spike at nearly the height Off did',
    );
    expect(
      off,
      lessThan(broad),
      reason: 'the smoothed curve reached higher than the measured one',
    );
  });

  testWidgets('a steady programme is drawn at the same height at every '
      'setting', (tester) async {
    final tops = <HistogramSmoothing, int>{};
    for (final smoothing in HistogramSmoothing.values) {
      final key = GlobalKey();
      final source = _Fake();
      await tester.pumpWidget(
        _Harness(
          key: ValueKey(smoothing),
          source: source,
          boundary: key,
          smoothing: smoothing,
          calibration: _lowTarget,
        ),
      );
      for (var publish = 1; publish <= 600; publish++) {
        source.publish(publish * 0.02, short: -18, momentary: -18);
        await _frame(tester);
      }
      tops[smoothing] = _curveTop(await _shoot(tester, key));
    }

    // A constant is its own mean, so a level that has not moved must be drawn
    // where it was measured whatever the window is. This is the assertion that
    // a smoother has not quietly become a gain.
    expect(
      tops.values.toSet(),
      hasLength(1),
      reason:
          'the drawn level of a steady −18 LUFS depends on the window: $tops',
    );
  });
}

/// The curve reaches the right edge, runs unbroken, and gives up only the scale
/// gutter on the left.
///
/// Deliberately not an assertion about where the plot starts: that depends on
/// the width of a laid-out label, and a test that hard-codes it fails the next
/// time the gutter is measured differently rather than when the line breaks.
void _expectSpansThePlot(List<int> columns, String when) {
  final width = _size.width.toInt();
  expect(columns, isNotEmpty, reason: 'no resting curve at all when $when');
  expect(
    columns.last,
    width - 1,
    reason: 'the resting curve stops short of the right edge when $when',
  );
  expect(
    columns.length,
    columns.last - columns.first + 1,
    reason: 'the resting curve has a gap in it when $when',
  );
  expect(
    columns.length,
    greaterThan((width * 0.7).round()),
    reason: 'the resting curve covers less than the plot when $when',
  );
}
