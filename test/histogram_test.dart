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
import 'package:flutter/gestures.dart';
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
/// and the resting curve rests on the plot's own bottom edge above it. Asked of
/// the module rather than recomputed here, so a resized strip or a wider gap
/// below the plot moves the tests with it.
int _plotFloor() => HistogramModule.plotFloor(_size.height).floor();

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

/// The x of every column whose curve is drawn in the upper half of the plot.
///
/// The programme the scrolling cases publish is silence with one loud run in
/// it, so this is "how much of the plot is showing the loud run" — which is
/// what both a scroll and a zoom change, and neither of them changes anything
/// a widget assertion can see.
List<int> _loudColumns(Uint8List pixels) {
  final floor = _plotFloor();
  final half = floor ~/ 2;
  return [
    for (var x = 0; x < _size.width.toInt(); x++)
      if ([for (var y = 0; y < half; y++) y].any((y) => _isCurve(pixels, x, y)))
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

/// Two hundred columns of quiet, one loud column, two hundred more of quiet.
///
/// The publishes run at 20 ms and a column closes every 50 ms, so the loud run
/// ends exactly on a boundary and closes one column at −6: the property under
/// test is what happens to a *single* column, and a spike smeared across a
/// boundary by the harness would pass either way.
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

/// A programme long enough to scroll: silence, then a loud run at the end.
///
/// Longer than the plot's own window on purpose — a recording that fits inside
/// the window has nothing to scroll to, and the module clamps the frame against
/// the right-hand edge rather than letting it slide off the start of the
/// recording.
Future<_Fake> _longProgramme(WidgetTester tester, GlobalKey key) async {
  final source = _Fake();
  await tester.pumpWidget(
    _Harness(source: source, boundary: key, calibration: _lowTarget),
  );

  // 900 closed columns at 50 ms — 45 seconds — of which the last 100 are loud.
  for (var publish = 1; publish <= 2250; publish++) {
    final loud = publish > 2000;
    source.publish(
      publish * 0.02,
      short: loud ? -6 : -70,
      momentary: loud ? -6 : -70,
    );
    await _frame(tester);
  }
  return source;
}

/// The middle of the overview strip, in global coordinates.
Offset _stripCentre(WidgetTester tester) {
  final module = tester.getRect(find.byType(HistogramModule));
  return Offset(
    module.center.dx,
    module.bottom - HistogramModule.overviewHeight(_size.height) / 2,
  );
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

  // --- The overview strip as a control --------------------------------------
  //
  // Dragging the frame scrolls the plot and the wheel resizes it. Both are pixel
  // reads for the same reason the smoothing cases are: the window is view state
  // with no widget of its own, and a frame drawn at the wrong offset — or a
  // plot that quietly went on following the newest column — passes every widget
  // assertion there is.

  testWidgets('dragging the overview strip scrolls the plot off the newest '
      'column, and dragging it back re-attaches', (tester) async {
    final key = GlobalKey();
    await _longProgramme(tester, key);

    final live = _loudColumns(await _shoot(tester, key));
    expect(live, isNotEmpty, reason: 'the loud run was not on screen at all');

    // Left by the strip's whole width, which is the whole recording — the
    // module clamps it at the oldest column the ring still holds.
    await tester.dragFrom(_stripCentre(tester), const Offset(-480, 0));
    await _frame(tester);

    expect(
      _loudColumns(await _shoot(tester, key)),
      isEmpty,
      reason: 'the plot still showed the loud run after scrolling to the start',
    );

    await tester.dragFrom(_stripCentre(tester), const Offset(480, 0));
    await _frame(tester);

    expect(
      _loudColumns(await _shoot(tester, key)),
      isNotEmpty,
      reason: 'the plot did not come back to the newest column',
    );
  });

  testWidgets('a scrolled plot keeps following once it is back against the '
      'right edge', (tester) async {
    final key = GlobalKey();
    final source = await _longProgramme(tester, key);

    await tester.dragFrom(_stripCentre(tester), const Offset(-480, 0));
    await tester.dragFrom(_stripCentre(tester), const Offset(480, 0));
    await _frame(tester);
    final before = _loudColumns(await _shoot(tester, key));

    // Another five seconds of silence — a hundred columns, and at a column to
    // the pixel a hundred pixels. A view that had stopped following would hold
    // the loud run exactly where it is; one that is following again carries it
    // that far towards the left edge.
    for (var publish = 2251; publish <= 2500; publish++) {
      source.publish(publish * 0.02, short: -70, momentary: -70);
      await _frame(tester);
    }
    final after = _loudColumns(await _shoot(tester, key));

    expect(before, isNotEmpty, reason: 'the drag back showed no loud run');
    expect(after, isNotEmpty, reason: 'the loud run left the plot entirely');
    expect(
      after.last,
      lessThan(before.last - 50),
      reason:
          'the plot stopped following the newest column after a scroll: the '
          'loud run ended at ${before.last} and then at ${after.last}',
    );
  });

  testWidgets('the wheel over the strip narrows the window the plot shows', (
    tester,
  ) async {
    final key = GlobalKey();
    await _longProgramme(tester, key);

    final before = _loudColumns(await _shoot(tester, key)).length;

    // Up is in. Far enough to reach the narrowest window the module allows,
    // which is a hundred columns — the loud run itself.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final at = _stripCentre(tester);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -900)));
    await _frame(tester);

    final after = _loudColumns(await _shoot(tester, key)).length;
    expect(
      after,
      greaterThan(before * 3),
      reason:
          'zooming in did not widen the loud run: $before columns before, '
          '$after after',
    );
  });

  // A trackpad and a Magic Mouse send no scroll event at all on macOS — the
  // platform marks a scroll off a touch surface with a phase and Flutter turns
  // those into pan-zoom events. Wiring only the signal left the zoom working on
  // a click-wheel mouse and on nothing else, which is why both of these exist.

  testWidgets('a two-finger scroll over the strip zooms it', (tester) async {
    final key = GlobalKey();
    await _longProgramme(tester, key);

    final before = _loudColumns(await _shoot(tester, key)).length;

    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final at = _stripCentre(tester);
    await tester.sendEventToBinding(pointer.panZoomStart(at));
    // Fingers moving *down* is a wheel scrolling up, which is in.
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(at, pan: const Offset(0, 900)),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await _frame(tester);

    expect(
      _loudColumns(await _shoot(tester, key)).length,
      greaterThan(before * 3),
      reason: 'a trackpad scroll over the strip did nothing',
    );
  });

  testWidgets('a pinch over the strip zooms it, from where the fingers went '
      'down', (tester) async {
    final key = GlobalKey();
    await _longProgramme(tester, key);

    final before = _loudColumns(await _shoot(tester, key)).length;

    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final at = _stripCentre(tester);
    await tester.sendEventToBinding(pointer.panZoomStart(at));
    // Cumulative, and a pinch reports it as such: three updates ending at 4x
    // are one zoom to 4x, not one to 64x. That is the whole reason a pinch is
    // applied to the span the gesture began at.
    for (final scale in [1.5, 2.5, 4.0]) {
      await tester.sendEventToBinding(pointer.panZoomUpdate(at, scale: scale));
    }
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await _frame(tester);

    final after = _loudColumns(await _shoot(tester, key)).length;
    expect(
      after,
      greaterThan(before * 3),
      reason: 'a pinch over the strip did not zoom in',
    );
    expect(
      after,
      lessThan(_size.width.toInt()),
      reason:
          'a 4x pinch reached the narrowest window there is, so the scale was '
          'compounded rather than applied to the span it started from',
    );
  });
}

/// The curve reaches the right edge, runs unbroken, and gives up only the scale
/// gutter on the left.
///
/// Deliberately not an assertion about where the plot starts: that depends on
/// the width of a laid-out label, and a test that hard-codes it fails the next
/// time the gutter is measured differently rather than when the line breaks.
///
/// The right edge is the module's less the hairline its box takes. The plot is
/// drawn *inside* that box — see `PlotBorder` — so a curve that reached the
/// module's own last column would be a curve drawn under its border.
void _expectSpansThePlot(List<int> columns, String when) {
  final width = _size.width.toInt();
  expect(columns, isNotEmpty, reason: 'no resting curve at all when $when');
  expect(
    columns.last,
    width - 2,
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
