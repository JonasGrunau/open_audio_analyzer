// SPDX-License-Identifier: GPL-3.0-or-later
//
// The spectrogram's age axis, held to the property that it stands still.
//
// The axis says how far back the record reaches, and it can only say it from a
// rate it measures: one column is one published measurement, and a publish is
// the engine's ~47 Hz or whatever a wire host runs at. That rate is a running
// mean, so it moves on every column — and an axis laid out straight from it
// moved with it, on every published frame. The ticks are hairlines drawn with
// antialiasing off, so a fraction of a pixel of drift snaps one from its pixel
// column to the next and back again, and the label above it shimmers under the
// same drift. It reads as a twitch, and it is a picture of the estimator
// settling rather than of anything the audio did.
//
// The replay below is the case that produces it: publishes paced by a
// monotonic clock over audio that arrives in whole device callbacks, so the
// span a column covers is quantised and nearly every column nudges the mean.
//
// **And the axis has to be the same picture on the next launch, which is a
// second property and the one the first fix did not have.** Holding still
// within a run is cheap: adopt the mean once and defend it. What that bought
// was an axis that photographed the device's spin-up — `elapsed` advances in
// whole callbacks, so a mean over the first columns lands on one of a handful
// of quantised values depending on where those callbacks fell against the
// publish clock, and the deadband then defended that value for the rest of the
// session instead of correcting it. Across launches differing in nothing else
// the adopted rate spread 2.2%, which at a 2 s rung puts the sixth tick
// anywhere in a 12 px band. It was reported as a scale that moves when the
// application is restarted, and every case above passed throughout.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/spectrogram.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// One publish of a replay: the analysis thread wakes on its own clock and
/// takes whatever whole device callbacks have arrived, which is what makes the
/// per-column span jitter even though nothing about the audio does.
List<double> _replay(
  ColumnRate rate, {
  double publishHz = 46.9,
  int frames = 3000,
  List<double>? measured,
  double phase = 0,
  int seedOffset = 0,
}) {
  const callback = 512 / 48000;
  final period = 1 / publishHz;
  // Where the device's callback boundaries fall against the first publish, and
  // which realisation of the pacing jitter this run gets. They are the whole
  // of what differs between two starts of the same application on the same
  // machine, and between them they are what the axis must not depend on.
  var wall = phase * callback;
  var delivered = 0.0;
  var seed = 20250828 + seedOffset * 7919;
  final axis = <double>[];
  for (var frame = 0; frame < frames; frame++) {
    // A tenth of pacing jitter: a monotonic timer is not hit exactly, and the
    // device's clock drifts against it. Seeded rather than random, so the run
    // is the same every time — but not a short cycle either, because a periodic
    // wobble averages out in a few periods and would leave the mean nothing to
    // keep moving with.
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    wall += period * (1 + (seed / 0x7fffffff - 0.5) / 5);
    while (delivered + callback <= wall) {
      delivered += callback;
    }
    rate.note(delivered);
    axis.add(rate.axisSeconds());
    measured?.add(rate.measured);
  }
  return axis;
}

/// The ages a display would print at [axisSeconds] per column, given the rung
/// it already holds. One column is one logical pixel — `columnWidth` — so the
/// rate and the seconds per pixel are the same number.
List<String> ageLabelsOf(double axisSeconds, {int held = 0}) {
  final interval = ageInterval(axisSeconds, held: held);
  return [for (var tick = 1; tick <= 4; tick++) ageLabel(tick * interval)];
}

int _changes(List<double> values) {
  var count = 0;
  for (var i = 1; i < values.length; i++) {
    if (values[i] != values[i - 1]) count++;
  }
  return count;
}

void main() {
  test('the age axis holds still while the mean under it moves', () {
    final rate = ColumnRate();
    final measured = <double>[];
    final axis = _replay(rate, measured: measured);

    // The mean this is taken from is what moves: it is re-derived from every
    // column, so it lands on a new value on nearly every published frame. If
    // this stops being true the case below has stopped testing anything.
    expect(
      _changes(measured),
      greaterThan(measured.length ~/ 2),
      reason: 'the measured mean held still, so there was no twitch to fix',
    );

    expect(
      _changes(axis),
      lessThan(8),
      reason: 'the axis followed the mean instead of settling on it',
    );

    // A minute of the run, after the settle window, with nothing moving at
    // all. A local engine never adopts at all now — it publishes within the
    // deadband of nominal, which is the whole of why two launches agree — so
    // what this holds is that nothing moves, not that something was adopted.
    final settled = axis.sublist(100);
    expect(
      settled.every((seconds) => seconds == settled.first),
      isTrue,
      reason: 'the axis was still moving after it had a second to settle',
    );

    // And it settled on the truth, not merely on something.
    expect(settled.first, closeTo(1 / 46.9, 1 / 46.9 * 0.02));
  });

  test('the axis takes the rate a host actually publishes at', () {
    // A wire display draws whatever the host sends it, and the nominal 47 Hz
    // is only what the axis is laid out at until a rate has been measured.
    final rate = ColumnRate();
    final axis = _replay(rate, publishHz: 30);
    expect(axis.first, closeTo(ColumnRate.nominal, 1e-12));
    expect(axis.last, closeTo(1 / 30, 1 / 30 * 0.03));
    expect(_changes(axis), lessThan(8));
  });

  test('two launches of the same engine draw the same axis', () {
    // **The report this file was reopened for.** The cases above hold the axis
    // still inside one run; this one holds it still across restarts, which is
    // the property a user actually sees — they close the application and open
    // it again, and the ticks are somewhere else.
    //
    // Nothing differs between these runs but the phase of the device's
    // callbacks and the jitter realisation. A rate adopted from the spin-up
    // spread 2.2% here and was then defended for the rest of each session, so
    // no two launches agreed and none of them converged.
    final adopted = [
      for (var launch = 0; launch < 24; launch++)
        _replay(
          ColumnRate(),
          publishHz: 47,
          frames: 400,
          phase: launch / 24,
          seedOffset: launch,
        ).last,
    ];

    expect(
      adopted.every((seconds) => seconds == adopted.first),
      isTrue,
      reason: 'the axis is laid out differently depending on how it started',
    );

    // And the rate they all agree on is the nominal one, exactly — because an
    // engine publishing within the deadband of it has nothing to correct, and
    // the correction is the only thing that could differ between launches.
    expect(adopted.first, ColumnRate.nominal);
  });

  test('a host far from nominal is still corrected to', () {
    // The other side of the case above: keeping nominal is right only while a
    // measurement agrees with it. A 30 Hz wire host is 36% away, so it is
    // adopted — once — and every launch adopts the same way.
    final adopted = [
      for (var launch = 0; launch < 8; launch++)
        _replay(
          ColumnRate(),
          publishHz: 30,
          frames: 400,
          phase: launch / 8,
          seedOffset: launch,
        ).last,
    ];

    for (final seconds in adopted) {
      expect(seconds, closeTo(1 / 30, 1 / 30 * ColumnRate.deadband));
    }
  });

  test('a stalled link is not folded into the rate', () {
    // A reset or a link that stopped and came back leaves one enormous gap on
    // the clock. Divided over the single column that spans it, it would misdate
    // the whole record — so it is skipped rather than averaged in.
    final rate = ColumnRate();
    var elapsed = 0.0;
    for (var column = 0; column < 200; column++) {
      elapsed += 1 / 47;
      rate.note(elapsed);
    }
    final before = rate.axisSeconds();

    elapsed += 30;
    rate.note(elapsed);
    for (var column = 0; column < 200; column++) {
      elapsed += 1 / 47;
      rate.note(elapsed);
    }

    // Four hundred columns appended, less the first — which has no
    // predecessor to be timed against — and less the one that spans the gap.
    expect(rate.columns, 399, reason: 'the gap was counted as a column');
    expect(rate.measured, closeTo(1 / 47, 1e-9));
    expect(rate.axisSeconds(), before);
  });

  test('the rung is not decided by the last digit of the rate', () {
    // **The other half of the report, and the half the cases above cannot
    // see.** They hold the *rate* still; this holds the labelling still, and
    // the two are not the same thing. The axis is labelled at the finest rung
    // whose ticks stay 60 px apart, and a column is one pixel and one
    // published measurement — so a rung lands on exactly 60 px whenever the
    // publish rate is a round number that divides into it. A 30 Hz wire host
    // stands the 2 s rung at exactly 60.0 px and a 60 Hz one stands the 1 s
    // rung at exactly 60.0, which are the two rates `kRemoteFpsOptions`
    // actually offers. Which side of the threshold an estimate landed on then
    // decided whether the axis read `2s 4s 6s` or `5s 10s 15s`, and it landed
    // differently on different launches.
    for (final hz in [30.0, 60.0]) {
      final labelled = <String>{};
      for (var launch = 0; launch < 12; launch++) {
        final rate = ColumnRate();
        _replay(
          rate,
          publishHz: hz,
          frames: 400,
          phase: launch / 12,
          seedOffset: launch,
        );
        labelled.add(ageLabelsOf(rate.axisSeconds()).join(' '));
      }
      expect(
        labelled,
        hasLength(1),
        reason:
            'a ${hz.toInt()} Hz host labels its axis differently per launch',
      );
    }
  });

  test(
    'a rate that moves inside its own deadband does not relabel the axis',
    () {
      // A rung held is a rung that does not flip on a rate correction the
      // deadband was always going to allow. Walk the rate across the threshold
      // by less than the error it is permitted to carry and the labelling must
      // not change; walk it far enough that the ticks genuinely no longer fit
      // and it must.
      final held = <String>[];
      // 2 s stands at exactly 60 px here, which is the worst case there is.
      for (final hz in [30.0, 30.3, 29.7, 30.1, 30.0]) {
        held.add(ageLabelsOf(1 / hz, held: 2).join(' '));
      }
      expect(
        held.toSet(),
        hasLength(1),
        reason:
            'the labelling changed while the rate stayed within its deadband',
      );

      // Half the rate is a rung that no longer fits by any margin, and that has
      // to move — an axis that never gave up a labelling would print ticks on
      // top of each other.
      expect(ageLabelsOf(1 / 15, held: 2), isNot(held.first.split(' ')));
    },
  );

  for (final fps in [30, 60]) {
    testWidgets('the record at $fps fps takes every published measurement', (
      tester,
    ) async {
      // **What put the axis on the threshold in the first place.** One column
      // is one published measurement, so the record has to advance per
      // publish — and it advanced per *repaint*, which is throttled to the
      // user's frame rate. At 30 fps against a ~47 Hz engine that is one
      // publish in three thrown away, and the rate the ages are dated by is
      // measured off the columns that were appended, so it came out as the
      // repaint rate: the same audio labelled 30 Hz here and 47 Hz on the same
      // machine set to 60. And 30 Hz stands the 2 s rung at 60.1 px against
      // the 60 px a label needs, which is what made the labelling itself a
      // coin toss.
      final source = _Jittery();
      await tester.pumpWidget(
        _Harness(
          source: source,
          fps: fps,
          child: (engine, clock) => SizedBox(
            width: 420,
            height: 200,
            child: SpectrogramModule(engine: engine, clock: clock),
          ),
        ),
      );

      const published = 400;
      for (var frame = 0; frame < published; frame++) {
        source.publish();
        await tester.pump(const Duration(milliseconds: 21));
        if (frame % 40 == 0) await _settle(tester);
      }
      await _settle(tester);

      final rate = columnRateOf(
        tester.state<State<SpectrogramModule>>(find.byType(SpectrogramModule)),
      );

      // Every publish but the first, which has no predecessor to be timed
      // against.
      expect(
        rate.columns,
        published - 1,
        reason: 'the record dropped published measurements at $fps fps',
      );
      expect(
        1 / rate.axisSeconds(),
        closeTo(46.9, 46.9 * ColumnRate.deadband),
        reason:
            'the axis measured the repaint rate rather than the publish rate '
            'at $fps fps',
      );
      expect(
        ageLabelsOf(rate.axisSeconds()),
        ['2s', '4s', '6s', '8s'],
        reason: 'the axis is labelled differently at $fps fps',
      );
    });
  }

  testWidgets('the painted age axis holds still while the record scrolls', (
    tester,
  ) async {
    // The cases above are the arithmetic; this is the module, and it is what
    // catches an axis laid out from the mean again. The band along the top of
    // the display carries the ticks and their labels and nothing else, so once
    // the rate has settled two paints of it must come out byte for byte
    // identical — while the record beneath it goes on scrolling, which is what
    // says the display was running at all.
    final source = _Jittery();
    final key = GlobalKey();
    await tester.pumpWidget(
      _Harness(
        source: source,
        child: (engine, clock) => RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 420,
            height: 200,
            child: SpectrogramModule(engine: engine, clock: clock),
          ),
        ),
      ),
    );

    Future<void> publish(int frames) async {
      for (var frame = 0; frame < frames; frame++) {
        source.publish();
        await tester.pump(const Duration(milliseconds: 17));
        // The image uploads are real asynchronous work, which a fake-async zone
        // never returns to the event loop to deliver.
        if (frame % 20 == 0) await _settle(tester);
      }
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 17));
    }

    await publish(100);
    final axis = await _shoot(tester, key, axis: true);
    final record = await _shoot(tester, key, axis: false);

    await publish(300);
    expect(
      await _shoot(tester, key, axis: true),
      axis,
      reason:
          'the age axis moved under a rate estimate that was still settling',
    );
    expect(
      await _shoot(tester, key, axis: false),
      isNot(record),
      reason: 'the record did not scroll, so the axis held still over nothing',
    );
  });
}

/// A source whose clock advances the way a device's does: audio arrives in
/// whole 512-frame callbacks and a publish takes however many have landed since
/// the last one, so the span a column covers is quantised. That is what keeps
/// nudging the mean, on a signal doing nothing unusual whatever.
class _Jittery implements MeterSource {
  static const double _callback = 512 / 48000;

  int _generation = 0;
  double _wall = 0;
  double _delivered = 0;

  final Float32List _spectrum = Float32List(MeterShape.spectrumBands);

  /// A tenth of pacing jitter: the analysis thread is paced by a monotonic
  /// clock and does not hit it exactly, and the device's clock drifts against
  /// that one. Seeded rather than random, so the run is the same every time —
  /// but not a short cycle either, because a periodic wobble averages out in a
  /// few periods and would leave the mean nothing to keep moving with.
  int _seed = 20250828;

  double _jitter() {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return 1 + (_seed / 0x7fffffff - 0.5) / 5;
  }

  void publish() {
    _generation++;
    _wall += (1 / 46.9) * _jitter();
    while (_delivered + _callback <= _wall) {
      _delivered += _callback;
    }
    // Something different every frame, so the record has a reason to change.
    for (var band = 0; band < _spectrum.length; band++) {
      _spectrum[band] = -84 + 70 * ((_generation + band) % 7) / 6;
    }
  }

  @override
  Transport transport = Transport.none;

  @override
  int get generation => _generation;

  @override
  double get elapsedSeconds => _delivered;

  @override
  bool refresh() => true;

  @override
  bool get hasOverrun => false;

  @override
  bool get hasSpectrum => true;

  @override
  Float32List get spectrum => _spectrum;

  @override
  Float32List spectrumOf(SpectrumSource source) => _spectrum;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Owns the clock for as long as the tree lives, as the workspace does. A
/// ticker created beside the tree outlives it and the binding then reports an
/// animation still running after disposal.
class _Harness extends StatefulWidget {
  const _Harness({required this.source, required this.child, this.fps = 60});

  final MeterSource source;
  final Widget Function(MeterSource engine, MeterClock clock) child;

  /// What the meters are allowed to repaint at. The record must not depend on
  /// it; that it did is the defect the case using this replays.
  final int fps;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final MeterClock clock = MeterClock(engine: widget.source, vsync: this)
    ..targetFps = widget.fps;

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

/// The band the painter reserves along the top for the age axis, in rows. Its
/// arithmetic, mirrored: the tick label's own height, the tick, and the gap on
/// either side of it. A crop measured by eye instead would start taking the
/// record in the first time the band moved.
final int _axisRows =
    (OaaType.tick.fontSize! + Space.xxs + Space.xs + Space.xxs).round();

/// The rendered pixels of [key]'s subtree: the axis band along the top, or
/// everything below it, which is the record.
///
/// `toImage` is a real asynchronous read and cannot be awaited inside the fake
/// async zone a `testWidgets` body runs in — hence `runAsync`.
Future<Uint8List> _shoot(
  WidgetTester tester,
  GlobalKey key, {
  required bool axis,
}) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late Uint8List pixels;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final all = data!.buffer.asUint8List(0, data.lengthInBytes);
    final band = image.width * 4 * _axisRows;
    pixels = Uint8List.fromList(
      axis ? all.sublist(0, band) : all.sublist(band),
    );
    image.dispose();
  });
  return pixels;
}

/// Lets the module's image uploads land — they complete on the event loop the
/// fake-async zone never returns to.
Future<void> _settle(WidgetTester tester) => tester.runAsync(
  () => Future<void>.delayed(const Duration(milliseconds: 20)),
);
