// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Alert Meter's latch, and the rule that a setting change drops it.
//
// The latch is the whole module: every other meter answers "what is it doing
// now", and the one moment true peak went over is three minutes in the past by
// the time anybody looks. So it is held until the engine is reset — and until
// the module is asked to show something else, which is what these cases are
// about. A latched number that outlives what gave it meaning is worse than no
// latch at all: it is a reading, in the module built to be believed from across
// a room, that nothing on the canvas measured.
//
// **And the rule that it does not latch at all** on a metric the engine
// already accumulates over the programme. Those five are the engine's to
// hold, and three of them converge rather than climb, so the extremum of the
// trajectory is a fact about the first seconds of a session. The pair of ODR
// cases below is that rule: the same two readings, against the same floor,
// held on ODR-S and read on ODR-I.
//
// **Asserted in ink, because the module is painted and there is no string to
// find.** The latch is the module's one reading, drawn in the latched state's
// colour. Once a peak has gone over and the signal has fallen back, red is the
// one thing on the module that nothing else could have put there — so a latch
// that is held is red pixels in the picture and a latch that was dropped is
// none. Counted by channel difference rather than by colour, because text is
// anti-aliased onto the panel and only the middle of a stroke is ever `over`
// exactly; the margin is wide enough to exclude `warn`, which is the one other
// colour with more red in it than green.
//
// **The wash says the same thing at a hundred times the area, and these cases
// hold the two together.** It followed the *live* reading for one revision, so
// a module printing a red `−2.5 LU` sat on an amber panel — read not as two
// facts but as a light that had come loose from its number, and reported as
// one. Every wash case below therefore asserts the wash and the ink in the
// same photograph, and the last of them is the one that could only fail under
// the coupling: dropping the latch has to put the light out too, or the module
// keeps a verdict it no longer prints.

import 'dart:io';

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/alert_meter.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;

/// −14 LUFS ±0.5, true peak −1.0 dBTP, LRA 20.
const _streaming = BuiltInCalibrations.streaming;

/// The same, with a ceiling nothing in these cases comes near. Switching to it
/// is a target change that a latched true peak can be seen to survive or not.
const _generous = Calibration(
  id: 'test_generous',
  name: 'Generous',
  lufsTarget: -14,
  lufsTolerance: 0.5,
  truePeakMax: 6.0,
  loudnessRangeMax: 20,
);

/// A target that states both dynamics floors, which no built-in does:
/// `dynamic-master` states the short one and nothing states the integrated
/// one. It is what lets the pair of cases below judge ODR-I and ODR-S against
/// the same line, which is the only way the difference between them is the
/// module's doing rather than the target's.
const _dynamicsFloors = Calibration(
  id: 'test_dynamics_floors',
  name: 'Dynamics floors',
  lufsTarget: -14,
  lufsTolerance: 0.5,
  truePeakMax: -1.0,
  loudnessRangeMax: 20,
  odrIntegratedFloor: 8.0,
  odrShortFloor: 8.0,
);

const double _margin = 8;
const Size _size = Size(320, 180);

class _Source implements MeterSource {
  /// The **live** true peak, over the engine's three-second window, which is
  /// the reading the latch is for: it falls back the moment the transient is
  /// out of the window, and by the time anybody looks up it is gone.
  ///
  /// It was `truePeakMax` until 0.14.1, driven from −0.2 down to −12.0 — which
  /// no engine can do. A maximum since reset only ever climbs, and a fake that
  /// walks one backwards is a fake asserting a latch over a quantity that
  /// cannot need one. The Alert Meter reads those rather than latching them
  /// now, so the cases below would have been asserting the behaviour of a
  /// signal that does not exist. See [Metric.isAccumulated].
  double dbtp = -0.2;

  /// Both dynamics ratios, off one field, because the pair of cases about
  /// [Metric.isAccumulated] turns on the two of them being handed *the same readings*.
  ///
  /// It moves the opposite way to a peak, its limit being a floor: 7.6 is
  /// under the 8 LU one and 12.0 is clear of it by more than the 1 LU warning
  /// band. 7.6 is the value the real master's ODR-I actually swung to in its
  /// first second — see `does not latch a metric the engine accumulates`.
  ///
  /// ODR-S is also the only metric that both latches *and* has a line for
  /// Delta to measure from, which one case below needs.
  double odr = 7.6;

  int _generation = 1;

  /// Every read advances the generation, because the clock repaints only on a
  /// published measurement and a latch that is never painted is never updated.
  double _read(double value) {
    _generation++;
    return value;
  }

  @override
  double get truePeak => _read(dbtp);

  @override
  double get odrShort => _read(odr);

  @override
  double get odrIntegrated => _read(odr);

  /// Comfortably inside every target here, and accumulated rather than
  /// latched: what a module shows after it has been asked to watch something
  /// else.
  @override
  double get lufsIntegrated => _read(-18.0);

  @override
  int get generation => _generation;
  @override
  Transport transport = Transport.none;
  @override
  bool refresh() => true;
  @override
  bool get hasOverrun => false;
  @override
  bool get isRunning => true;
  @override
  int get sampleRate => 48000;
  @override
  int get channels => 2;

  /// Never runs backwards. A reset is the other thing that clears the latch,
  /// and these cases are about the settings — so the clock is held forwards to
  /// keep the two apart.
  @override
  double get elapsedSeconds => 10;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Harness extends StatefulWidget {
  const _Harness({
    required this.source,
    required this.boundary,
    required this.metric,
    required this.calibration,
    required this.delta,
  });

  final _Source source;
  final GlobalKey boundary;
  final Metric metric;
  final Calibration calibration;
  final bool delta;

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
            child: Padding(
              padding: const EdgeInsets.all(_margin),
              child: SizedBox(
                width: _size.width,
                height: _size.height,
                child: ModuleFrame(
                  title: 'TRUE PEAK',
                  bleed: true,
                  child: AlertMeterModule(
                    engine: widget.source,
                    clock: clock,
                    metric: widget.metric,
                    calibration: widget.calibration,
                    delta: widget.delta,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  /// Latches a reading that is over the line, then lets the signal recover
  /// well clear of it — both metrics at once, each in its own direction,
  /// because a case names the metric it is about and the other reading costs
  /// nothing.
  ///
  /// Both halves matter. The recovery is what makes the latch visible at all —
  /// a module still reading its own worst case cannot be told from one that
  /// has forgotten it — and it is what makes a cleared latch land somewhere
  /// else, since the reading it re-acquires on the very next frame is the
  /// healthy one.
  Future<void> latchThenFall(WidgetTester tester, _Source source) async {
    await tester.pump(const Duration(milliseconds: 32));
    source.dbtp = -12.0;
    source.odr = 12.0;
    await tester.pump(const Duration(milliseconds: 32));
  }

  /// One photograph, and the two things this file reads off it: the colour of
  /// the wash, and how much of the module is printed in the over colour.
  Future<({Color wash, int overInk})> shoot(
    WidgetTester tester,
    GlobalKey boundary,
  ) async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late Color wash;
    var overInk = 0;
    await tester.runAsync(() async {
      final image = await render.toImage();
      final data = (await image.toByteData())!;

      // In the frame's inset at half height: the wash is there, and no module
      // ever draws text there.
      const x = _margin + 4;
      final y = (_margin + ModuleFrame.titleBarHeight + _size.height) ~/ 2;
      final offset = ((y * render.size.width.round()) + x.round()) * 4;
      wash = Color.fromARGB(
        data.getUint8(offset + 3),
        data.getUint8(offset),
        data.getUint8(offset + 1),
        data.getUint8(offset + 2),
      );

      // Anywhere at all, because where the latched reading is printed is the
      // module's arithmetic and not this file's business. A hundred either
      // side of the green and the blue: `over` is 178 clear of both, and
      // `warn` — the only other colour here with more red in it than green —
      // is 66 clear of the green and so is not counted.
      for (var i = 0; i < data.lengthInBytes; i += 4) {
        final r = data.getUint8(i);
        final g = data.getUint8(i + 1);
        final b = data.getUint8(i + 2);
        if (r - g > 100 && r - b > 100) overInk++;
      }

      image.dispose();
    });
    return (wash: wash, overInk: overInk);
  }

  final isWashedInTheAccent = predicate<Color>(
    (c) => c.g > c.r,
    'a panel washed in the accent',
  );

  final isWashedInTheOverColour = predicate<Color>(
    (c) => c.r > c.g && c.r > c.b,
    'a panel washed in the over colour',
  );

  Future<({Color wash, int overInk})> run(
    WidgetTester tester, {
    required Metric metric,
    required Calibration calibration,
    required bool delta,
    Metric? thenMetric,
    Calibration? thenCalibration,
    bool? thenDelta,
    bool fall = true,
    double from = -0.2,
  }) async {
    await _loadFonts();
    final source = _Source()..dbtp = from;
    final boundary = GlobalKey();
    Widget harness({
      required Metric metric,
      required Calibration calibration,
      required bool delta,
    }) => _Harness(
      source: source,
      boundary: boundary,
      metric: metric,
      calibration: calibration,
      delta: delta,
    );

    await tester.pumpWidget(
      harness(metric: metric, calibration: calibration, delta: delta),
    );
    if (fall) {
      await latchThenFall(tester, source);
    } else {
      await tester.pump(const Duration(milliseconds: 32));
    }

    // Rebuilt in place, so the module's own State survives and
    // `didUpdateWidget` is what sees the change — which is the whole point.
    await tester.pumpWidget(
      harness(
        metric: thenMetric ?? metric,
        calibration: thenCalibration ?? calibration,
        delta: thenDelta ?? delta,
      ),
    );
    await tester.pump(const Duration(milliseconds: 32));
    return shoot(tester, boundary);
  }

  testWidgets('the wash and the digits carry one verdict', (tester) async {
    // Both halves of the same photograph, and the pair is the point. The peak
    // that went over is still the module's number — there is red on it — and
    // the panel is still lit in the over colour three seconds after the signal
    // fell back under the ceiling, because a module whose subject is the worst
    // moment of the programme goes on saying so until the engine is reset.
    //
    // **The wash followed the live reading for one revision**, which put a red
    // number on an accent panel here. It was reported as a light that had come
    // loose from its number, and this case is what fails if it comes back.
    final shot = await run(
      tester,
      metric: Metric.truePeak,
      calibration: _streaming,
      delta: false,
    );

    expect(shot.wash, isWashedInTheOverColour);
    expect(shot.overInk, isPositive);
  });

  testWidgets('the wash turns over the moment the reading does', (
    tester,
  ) async {
    // The other side of it: the light has to arrive when the peak does, or the
    // module says nothing at the only moment it matters. No fall, so the
    // latched state is the one that went through the ceiling on the first
    // frame.
    final shot = await run(
      tester,
      metric: Metric.truePeak,
      calibration: _streaming,
      delta: false,
      fall: false,
    );

    expect(shot.wash, isWashedInTheOverColour);
  });

  testWidgets('a module that has caught nothing is not lit in alarm', (
    tester,
  ) async {
    // The control for the two above, and the reason the wash is not simply
    // painted red and left there: a peak that never came near the ceiling is
    // an accent panel with no red ink anywhere on it. A wash that only
    // appeared once something went over would be a module that looked broken
    // until it did, so the light is always on and only its colour is the
    // verdict — the same bargain the Number Box makes.
    final shot = await run(
      tester,
      metric: Metric.truePeak,
      calibration: _streaming,
      delta: false,
      from: -12.0,
      fall: false,
    );

    expect(shot.wash, isWashedInTheAccent);
    expect(shot.overInk, isZero);
  });

  testWidgets('holds the worst reading when nothing about it changed', (
    tester,
  ) async {
    // The control, and the case the other three must not break: a peak that
    // happened is still the peak that happened three seconds later.
    final shot = await run(
      tester,
      metric: Metric.truePeak,
      calibration: _streaming,
      delta: false,
    );

    expect(shot.overInk, isPositive);
  });

  testWidgets('drops it when the metric changes', (tester) async {
    // The latched number is a true-peak maximum in dBTP. Kept, it would be
    // printed under LUFS-I as the worst loudness the programme reached.
    final shot = await run(
      tester,
      metric: Metric.truePeak,
      calibration: _streaming,
      delta: false,
      thenMetric: Metric.lufsIntegrated,
    );

    expect(shot.overInk, isZero);
    // And the light with it. The wash is decided from the same latch as the
    // digits, so a module that has forgotten its peak but is still washed in
    // red is one carrying a verdict it no longer prints — the one failure the
    // coupling introduces, and the only one no ink assertion can see.
    expect(shot.wash, isNot(isWashedInTheOverColour));
  });

  testWidgets('drops it when the unit changes', (tester) async {
    // Delta is the same measurement re-expressed, so the latch would survive
    // this one honestly. It goes anyway: "changing what this module shows
    // clears what it held" is a rule that can be learnt, where "except that
    // one" is a surprise the module springs the first time it matters.
    //
    // **On ODR-S under `dynamic-master`, because this is the one case that
    // needs both halves at once**: a metric the module latches, and a target
    // that draws a line for Delta to measure from. The live true peak the
    // other cases use has no such line — the distance is only defined against
    // the maximum — so asked for a delta it would print an em dash, and a case
    // reading "no red ink" would pass on a module that had printed nothing at
    // all.
    final shot = await run(
      tester,
      metric: Metric.odrShort,
      calibration: BuiltInCalibrations.dynamicMaster,
      delta: false,
      thenDelta: true,
    );

    expect(shot.overInk, isZero);
  });

  testWidgets('does not latch a metric the engine accumulates', (tester) async {
    // ODR-I is `TP Max − LUFS-I`, and integrated loudness clears the −70 LUFS
    // absolute gate while a track is still room tone. On a real master —
    // `test_audio/citizens-apathy.flac`, 322 s, ODR-I 8.6 LU — the reading
    // swung between 33.5 and 7.6 inside the first second, and the module
    // latched 7.6 for the remaining five minutes: a number the Number Box
    // beside it, the Validator and the delivery report all disagreed with, and
    // red under a floor the programme cleared. Those are the two readings
    // below.
    //
    // The extremum of a converging estimator is a property of how it
    // converged. What the engine holds *is* the answer, so the module reads
    // it — and the light follows, because both come off the same latch.
    final shot = await run(
      tester,
      metric: Metric.odrIntegrated,
      calibration: _dynamicsFloors,
      delta: false,
      fall: true,
    );

    expect(shot.overInk, isZero);
    expect(shot.wash, isNot(isWashedInTheOverColour));
  });

  testWidgets('and still latches one measured moment by moment', (
    tester,
  ) async {
    // The control for the case above, and the pair is the point: the same two
    // readings, in the same order, under the same floor — held this time,
    // because a three-second window is a passage of the programme and its
    // worst is the module's whole subject. If [Metric.isAccumulated] ever grows an arm
    // it should not have, this is what fails.
    final shot = await run(
      tester,
      metric: Metric.odrShort,
      calibration: _dynamicsFloors,
      delta: false,
      fall: true,
    );

    expect(shot.overInk, isPositive);
    expect(shot.wash, isWashedInTheOverColour);
  });

  testWidgets('drops it when the delivery target changes', (tester) async {
    // The latched *state* is what colours the module's digits, and it was
    // decided against a line that has moved. A peak latched as over a −1.0 ceiling
    // stayed red under a +6.0 one until a worse peak arrived to be judged —
    // which on a programme already past its loudest never happens.
    final shot = await run(
      tester,
      metric: Metric.truePeak,
      calibration: _streaming,
      delta: false,
      thenCalibration: _generous,
    );

    expect(shot.overInk, isZero);
  });
}

/// Without the real faces every glyph rasterises as a box, which is more ink
/// than any digit and would reach samples it has no business reaching. Read
/// with `readAsBytesSync`: an awaited real read inside a `testWidgets` body
/// never completes.
Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      loader.addFont(
        Future<ByteData>.value(
          ByteData.sublistView(File(path).readAsBytesSync()),
        ),
      );
    }
    await loader.load();
  }

  await load('Inter', [
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
  ]);
  await load('Google Sans Code', [
    'assets/fonts/GoogleSansCode-Regular.ttf',
    'assets/fonts/GoogleSansCode-Medium.ttf',
  ]);
}
