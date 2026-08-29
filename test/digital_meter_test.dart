// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Digital Meter's bars are segmented, and a segment is lit whole or not at
// all.
//
// The segmentation was cosmetic through 0.14: the fill was drawn to the
// measurement and a buffer of panel-coloured lines was laid over it, so the
// top of every column was whatever fraction of a row the reading happened to
// land on — a sliver of ink above the last whole row, dimmer than every row
// under it because there was less of it, which reads as the paint thinning
// out rather than as a level. The peak's hairline had the same fault twice
// over: two pixels tall against a row of three, and free to sit across a gap,
// where it looked like a segment that had come loose from the grid.
//
// So both are quantised to the grid now, and this is what says so. The
// assertions are about the *runs of ink down one bar* and nothing else: every
// run the same height, every run on the same four-pixel pitch, and the peak's
// run clear of the column with unlit track between them. Nothing here copies
// a number out of the painter — not the pitch, not the row height, not where
// the track begins or which column a bar stands in. All of it is found in the
// picture, because a second copy of the geometry in the test is a copy that
// stops testing anything the day the first one moves.

import 'dart:typed_data';

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/digital_meter.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;

/// Tall enough for a column of fifty-odd rows and no wider than a real one.
const _size = Size(180, 300);

/// A stereo source parked at two levels. Nothing here moves: the meter is
/// photographed once and the question is only ever where the ink stops.
class _Levels implements MeterSource {
  _Levels({required double peakDb, required double rmsDb})
    : peak = Float32List.fromList([peakDb, peakDb]),
      rms = Float32List.fromList([rmsDb, rmsDb]);

  @override
  final Float32List peak;
  @override
  final Float32List rms;
  @override
  final Uint32List clip = Uint32List(2);

  @override
  int get channels => 2;
  @override
  Transport transport = Transport.none;
  @override
  int get generation => 1;
  @override
  bool refresh() => true;
  @override
  bool get hasOverrun => false;
  @override
  bool get isRunning => true;
  @override
  int get sampleRate => 48000;
  @override
  double get elapsedSeconds => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Harness extends StatefulWidget {
  const _Harness({required this.source, required this.boundary});

  final _Levels source;
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

  /// The module on the panel it is drawn on and nothing else — no frame, so
  /// the body is the whole picture and its rows land on whole pixels.
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
              child: DigitalMeterModule(engine: widget.source, clock: clock),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Ink, as opposed to anything the instrument is drawn *on*. The meter's fill
/// and its peak mark are the only coloured things inside the trough — the
/// track, the gridlines, the segment gaps and the channel labels are all
/// greys, none of them carrying a sixth of this much chroma.
bool _isInk(Color color) {
  final r = color.r, g = color.g, b = color.b;
  final high = r > g ? (r > b ? r : b) : (g > b ? g : b);
  final low = r < g ? (r < b ? r : b) : (g < b ? g : b);
  return (high - low) > 0.1;
}

class _Run {
  const _Run(this.top, this.height);

  final int top;
  final int height;

  int get bottom => top + height;
}

class _Pixels {
  const _Pixels(this._data, this.width, this.height);

  final ByteData _data;
  final int width;
  final int height;

  Color at(int x, int y) {
    final offset = ((y * width) + x) * 4;
    return Color.fromARGB(
      _data.getUint8(offset + 3),
      _data.getUint8(offset),
      _data.getUint8(offset + 1),
      _data.getUint8(offset + 2),
    );
  }

  /// The middle of the first channel's bar. The lowest row carrying any ink is
  /// the floor of the columns — nothing below the trough is coloured — and the
  /// first run of ink along it is the left-hand bar.
  int get barCentre {
    for (var y = height - 1; y >= 0; y--) {
      var left = -1;
      for (var x = 0; x < width; x++) {
        if (_isInk(at(x, y))) {
          if (left < 0) left = x;
        } else if (left >= 0) {
          return (left + x) ~/ 2;
        }
      }
    }
    fail('no ink anywhere in the picture');
  }

  /// The top of the trough in column [x]: the first three consecutive rows
  /// painted in the track's own colour. Three, because a single antialiased
  /// pixel of the numbers printed above could land on that value by accident
  /// and the trough is two hundred rows tall.
  int trackTop(int x) {
    var run = 0;
    for (var y = 0; y < height; y++) {
      run = at(x, y) == _colors.meterTrack ? run + 1 : 0;
      if (run == 3) return y - 2;
    }
    fail('no trough in column $x');
  }

  /// Every run of ink down column [x], from the top of the trough, in order.
  List<_Run> inkDown(int x) => runsDown(x, _isInk);

  /// The same, of whatever [match] accepts.
  List<_Run> runsDown(int x, bool Function(Color color) match) {
    final runs = <_Run>[];
    var start = -1;
    for (var y = trackTop(x); y < height; y++) {
      if (match(at(x, y))) {
        if (start < 0) start = y;
      } else if (start >= 0) {
        runs.add(_Run(start, y - start));
        start = -1;
      }
    }
    if (start >= 0) runs.add(_Run(start, height - start));
    return runs;
  }
}

Future<_Pixels> _photograph(
  WidgetTester tester, {
  required double peakDb,
  required double rmsDb,
}) async {
  final boundary = GlobalKey();
  await tester.pumpWidget(
    _Harness(
      source: _Levels(peakDb: peakDb, rmsDb: rmsDb),
      boundary: boundary,
    ),
  );
  await tester.pump(const Duration(milliseconds: 32));

  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late ByteData data;
  await tester.runAsync(() async {
    final image = await render.toImage();
    data = (await image.toByteData())!;
    image.dispose();
  });
  return _Pixels(data, render.size.width.round(), render.size.height.round());
}

void main() {
  testWidgets('the column lights whole segments and only whole segments', (
    tester,
  ) async {
    final pixels = await _photograph(tester, peakDb: -6.3, rmsDb: -20.7);
    final bar = pixels.barCentre;
    final runs = pixels.inkDown(bar);

    // The levels are deliberately not round numbers: on the tapered scale
    // neither of them lands on a row boundary, which is the whole case. A
    // column of this height carries dozens of rows, so a suite that found one
    // run has found something other than a bar.
    expect(
      runs.length,
      greaterThan(8),
      reason: 'the column is not drawn as segments at all',
    );
    expect(
      runs.map((run) => run.height).toSet(),
      hasLength(1),
      reason:
          'a partly lit row: the runs of ink down the bar are '
          '${runs.map((run) => run.height).toList()}',
    );

    // The pitch, off the two lowest rows — which are the bottom of the column
    // and can be nothing else.
    final floor = runs.last;
    final pitch = floor.top - runs[runs.length - 2].top;
    expect(pitch, greaterThan(floor.height), reason: 'the rows do not gap');
    for (final run in runs) {
      expect(
        (floor.top - run.top) % pitch,
        0,
        reason: 'a lit row off the segment grid, at ${run.top}',
      );
    }

    // And the peak is a mark rather than the top of the column: whole track
    // between it and the fill, so what stands between them is the crest
    // factor and not a gap in the paint.
    expect(
      runs[1].top - runs.first.bottom,
      greaterThan(pitch),
      reason: 'the peak mark is not clear of the column',
    );
  });

  testWidgets('the scale is ruled on the segments, not across them', (
    tester,
  ) async {
    final pixels = await _photograph(tester, peakDb: -6.3, rmsDb: -20.7);
    final bar = pixels.barCentre;

    // Every row of the column, lit and unlit alike. A scale line drawn on its
    // own value rather than on the ruling lands inside a row and cuts it in
    // two, which is a row of a size the meter has nowhere else — the two
    // rulings beating against each other is what this is about.
    final unlit = pixels.runsDown(bar, (color) => color == _colors.meterTrack);
    final lit = pixels.inkDown(bar);
    expect(unlit, isNotEmpty);
    expect(lit, isNotEmpty);

    // The first unlit run is cut by the top edge of the trough, which is a
    // property of the module's height and not of the ruling.
    expect(
      {
        ...unlit.skip(1).map((run) => run.height),
        ...lit.map((run) => run.height),
      },
      hasLength(1),
      reason: 'a row of a size of its own: a scale line landed inside one',
    );

    // And the scale is on the ruling rather than gone: its lines are the
    // graticule's colour, in the gaps the segments already leave.
    final ruled = pixels.runsDown(bar, (color) => color == _colors.hairline);
    expect(
      ruled.length,
      greaterThan(4),
      reason: 'the scale is not drawn across the bar at all',
    );
    expect(
      ruled.map((run) => run.height).toSet(),
      {1},
      reason: 'a scale line wider than the gap it stands in',
    );
  });

  testWidgets('a level under one segment lights none of it', (tester) async {
    final lit = await _photograph(tester, peakDb: -6.3, rmsDb: -20.7);
    final row = lit.inkDown(lit.barCentre).first.height;

    // Far below the scale's floor: a fill this short covers no row completely,
    // and the old drawing put a pixel and a half of ink at the bottom of the
    // trough. The peak mark holds the floor row instead of disappearing with
    // it — a fill is a quantity and may legitimately light nothing, but a
    // channel whose peak mark is missing reads as a channel with no signal.
    final quiet = await _photograph(tester, peakDb: -130, rmsDb: -130);
    final runs = quiet.inkDown(quiet.barCentre);

    expect(runs, hasLength(1), reason: 'something under one row is lit');
    expect(
      runs.single.height,
      row,
      reason: 'the peak mark is not a whole row at the floor of the scale',
    );
  });
}
