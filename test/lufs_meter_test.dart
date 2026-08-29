// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the LUFS meter does when the music stops.
//
// Both cases here were one bug reported as three. The engine floored its two
// window readings by comparing against -inf rather than against the floor, so
// a window holding nothing but the tail of the K-weighting filters' ringing
// read -1860 LUFS and kept falling — and then jumped back *up* to -144 seconds
// later, as the last of the ringing aged out. On screen: bars that fell off
// the bottom of the scale, went, and then put a hairline of fill back at the
// foot of the track. Two display faults were underneath it, and both outlive
// the engine's: a tapered scale puts -144 at 0.4% of the track rather than at
// the end of it, and the readout band was sized from whatever the readings
// happened to print, so a six-glyph number on the way down shortened the bars
// under it.
//
// Nothing here copies a number out of the painter. The trough is found in the
// picture, and the assertions are about where the ink stops and whether the
// geometry moved.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/lufs_meter.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;
const _target = BuiltInCalibrations.streaming;

/// The size the module ships at, near enough — wide enough for three bars and
/// tall enough that the readings are drawn under them.
const _size = Size(260, 340);

/// Three loudness readings and nothing else moving.
class _Loudness implements MeterSource {
  _Loudness(this.lufsMomentary, this.lufsShort, this.lufsIntegrated);

  @override
  final double lufsMomentary;
  @override
  final double lufsShort;
  @override
  final double lufsIntegrated;

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

  final _Loudness source;
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
              child: LufsMeterModule(
                engine: widget.source,
                clock: clock,
                calibration: _target,
              ),
            ),
          ),
        ),
      ),
    ),
  );
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

  /// The row the trough stops at, in column [x].
  ///
  /// A trough is opaque and starts at the top of the body, and the module
  /// paints nothing at all between its foot and the numbers — the boundary
  /// photographed here is above the panel the module is drawn on, so the ground
  /// comes out transparent. The first fully transparent row is therefore the
  /// foot of the bars. Read from the top for that reason: below the trough are
  /// the numbers, and looking up from the bottom finds a digit before it finds
  /// the geometry.
  ///
  /// The trough is drawn whatever the reading is, so this is the one measure of
  /// the module's layout that a silent meter and a loud one both answer.
  int troughBottom(int x) {
    for (var y = 0; y < height; y++) {
      if (at(x, y).a == 0) return y;
    }
    fail('column $x is opaque all the way down');
  }

  /// Whether anything in column [x] between [from] and [to] carries colour, as
  /// opposed to being one of the greys the instrument is drawn in.
  bool hasInk(int x, int from, int to) {
    for (var y = from; y < to; y++) {
      final c = at(x, y);
      final high = [c.r, c.g, c.b].reduce((a, b) => a > b ? a : b);
      final low = [c.r, c.g, c.b].reduce((a, b) => a < b ? a : b);
      if ((high - low) > 0.1) return true;
    }
    return false;
  }
}

Future<_Pixels> _render(WidgetTester tester, _Loudness source) async {
  final boundary = GlobalKey();
  await tester.pumpWidget(_Harness(source: source, boundary: boundary));
  await tester.pump(const Duration(milliseconds: 16));

  late _Pixels pixels;
  await tester.runAsync(() async {
    final object =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await object.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    pixels = _Pixels(data, image.width, image.height);
    image.dispose();
  });
  return pixels;
}

/// The centre of the momentary bar — the leftmost of the three.
///
/// Found rather than computed: the bar's own fill is the only colour at the
/// foot of a trough, so a live reading photographs where the bars stand.
int _momentaryCentre(_Pixels pixels) {
  final y = pixels.troughBottom(pixels.width ~/ 2) - 3;
  var left = -1;
  for (var x = 0; x < pixels.width; x++) {
    if (pixels.hasInk(x, y, y + 1)) {
      if (left < 0) left = x;
    } else if (left >= 0) {
      return (left + x) ~/ 2;
    }
  }
  fail('no bar found at the foot of the troughs');
}

void main() {
  testWidgets('silence empties the bars instead of leaving a line of fill', (
    tester,
  ) async {
    final playing = await _render(tester, _Loudness(-17.6, -18.2, -18.0));
    final centre = _momentaryCentre(playing);
    final foot = playing.troughBottom(centre);

    // The probe first: a bar that is reading has ink at the foot of its
    // trough, or the silent case below proves nothing at all.
    expect(
      playing.hasInk(centre, foot - 4, foot),
      isTrue,
      reason: 'a bar at -17.6 LUFS should be lit at the foot of its trough',
    );

    final silent = await _render(
      tester,
      _Loudness(MeterShape.dbFloor, MeterShape.dbFloor, MeterShape.dbFloor),
    );
    expect(
      silent.troughBottom(centre),
      foot,
      reason: 'silence must not move the geometry',
    );
    expect(
      silent.hasInk(centre, foot - 4, foot),
      isFalse,
      reason:
          'a level at the floor is the bottom of a tapered scale, not four '
          'tenths of a percent above it',
    );
  });

  testWidgets('a reading below -100 does not shorten the bars', (tester) async {
    final playing = await _render(tester, _Loudness(-17.6, -18.2, -18.0));
    final centre = _momentaryCentre(playing);
    final foot = playing.troughBottom(centre);

    // Six glyphs where the band is built for five. The bars stand on that
    // band, so sizing it from the reading is what moved them.
    final falling = await _render(tester, _Loudness(-100.3, -18.2, -18.0));
    expect(
      falling.troughBottom(centre),
      foot,
      reason: 'the readout band is fitted to a fixed budget, not to the text',
    );

    final silent = await _render(
      tester,
      _Loudness(MeterShape.dbFloor, MeterShape.dbFloor, MeterShape.dbFloor),
    );
    expect(silent.troughBottom(centre), foot);
  });
}
