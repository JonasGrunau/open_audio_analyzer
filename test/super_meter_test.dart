// SPDX-License-Identifier: GPL-3.0-or-later
//
// The super meter's innermost ring, which is the one that gets delivered.
//
// It takes its verdict's colour for its whole length — a green ring when the
// integrated reading is in spec, not a green tip — and that rule collided with
// the one that paints everything past the delivery target in `over`: a mix over
// its target made the verdict red, so the ring ran red from the bottom of the
// scale to the reading with its own target tick stranded in the middle of it,
// the same colour on both sides. Three quarters of the arc claimed to be over
// when a quarter of it was.
//
// The assertions count colours over the whole picture rather than sampling the
// arc, because the question is only ever "is the ring drawn in one colour or
// two". No radius, sweep or centre is copied from the painter — the little
// geometry `_tally` needs, it finds in the image. A second copy of the layout
// living in the test is a copy that has to be kept in step with the first, and
// silently stops testing anything the day it is not.

import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/super_meter.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;

/// Streaming: −14 LUFS, ±0.5.
const _target = BuiltInCalibrations.streaming;

class _Levels implements MeterSource {
  _Levels(this.integrated);

  final double integrated;

  @override
  Transport transport = Transport.none;
  int _generation = 0;
  double _elapsed = 0;

  void publish() {
    _generation++;
    _elapsed += 1;
  }

  // The two outer rings sit far below the target, so no pixel of `over` in the
  // picture belongs to anything but the ring under test.
  @override
  double get lufsMomentary => -30;
  @override
  double get lufsShort => -30;
  @override
  double get lufsIntegrated => integrated;

  // **Deliberately not measured.** A loudness range inside its maximum is a
  // *neutral* reading, and neutral is `textPrimary` — the same colour the ring
  // under test is drawn in below the target. The LRA readout is 35 by 12 pixels
  // of it in the middle of the module, comfortably over the floors below, so it
  // would have carried two of these three tests on its own whatever the ring
  // did. Unmeasured draws an em dash in `textMuted` instead.
  @override
  double get loudnessRange => double.nan;

  @override
  int get generation => _generation;
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
  @override
  double get elapsedSeconds => _elapsed;
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
              width: 320,
              height: 320,
              child: SuperMeterModule(
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

/// How many pixels of each colour the module drew **in its rings**.
///
/// Exact matches only. Every colour asked about below is laid down by an opaque
/// paint over an opaque backdrop, so it survives compositing unchanged; the
/// antialiased edges land on none of them and simply are not counted.
///
/// **The centre is excluded, and has to be.** The readout in the middle is
/// drawn in the integrated reading's own verdict colour — `-11.0` against a −14
/// target is five glyphs of `over`, which in a test with no fonts loaded are
/// five solid boxes and thousands of red pixels. Counted, they swamped the
/// arcs: the red segment came out larger than the whole rest of the ring, which
/// is the opposite of what the picture shows.
///
/// The geometry to do it is *found*, not copied from the painter. The gauge is
/// symmetric about the middle of the module and its outer ring reaches furthest
/// left at exactly the centre's height, so the leftmost ink gives both the
/// centre and the outer radius without knowing anything about how the module
/// lays itself out. The rings live between 0.46 and 1.0 of that radius and the
/// readout inside 0.37 of it, so a cut at 0.42 separates them with room on both
/// sides.
Future<Map<Color, int>> _tally(
  WidgetTester tester,
  double integrated,
  List<Color> of,
) async {
  final source = _Levels(integrated);
  final key = GlobalKey();
  await tester.pumpWidget(_Harness(source: source, boundary: key));
  for (var i = 0; i < 3; i++) {
    source.publish();
    await tester.pump(const Duration(milliseconds: 100));
  }

  final counts = {for (final color in of) color: 0};
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final width = image.width;
    final background =
        (_colors.background.r * 255).round() << 16 |
        (_colors.background.g * 255).round() << 8 |
        (_colors.background.b * 255).round();

    int at(int x, int y) {
      final i = (y * width + x) * 4;
      if (bytes[i + 3] != 255) return background;
      return bytes[i] << 16 | bytes[i + 1] << 8 | bytes[i + 2];
    }

    // The leftmost ink: its column is the outer radius in from the middle, and
    // its row is the centre's.
    final cx = width / 2;
    var leftmost = width, centreY = 0;
    for (var x = 0; x < width; x++) {
      for (var y = 0; y < image.height; y++) {
        if (at(x, y) != background) {
          leftmost = x;
          centreY = y;
          break;
        }
      }
      if (leftmost < width) break;
    }
    final outer = cx - leftmost;
    final readout = outer * 0.42;

    final wanted = {
      for (final color in of)
        (color.r * 255).round() << 16 |
                (color.g * 255).round() << 8 |
                (color.b * 255).round():
            color,
    };
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = x - cx, dy = y - centreY;
        if (dx * dx + dy * dy < readout * readout) continue;
        final color = wanted[at(x, y)];
        if (color != null) counts[color] = counts[color]! + 1;
      }
    }
    image.dispose();
  });
  return counts;
}

void main() {
  // A pixel count is a shape, not a measurement, so these are floors rather
  // than equalities: enough ink to be a segment of an arc rather than an
  // antialiased edge.
  const segment = 200;

  testWidgets('over the target, the ring is drawn in two colours', (
    tester,
  ) async {
    // −11 against −14: most of the drawn arc is under the target, its tip is
    // over.
    final counts = await _tally(tester, -11.0, [
      _colors.over,
      _colors.textPrimary,
    ]);

    expect(
      counts[_colors.over],
      greaterThan(segment),
      reason: 'the part past the target has to be there',
    );
    expect(
      counts[_colors.textPrimary],
      greaterThan(segment),
      reason:
          'and so does the part below it — a ring painted entirely in its '
          'verdict says the whole reading is over when only its tip is',
    );
    // The miss is 3 LU on a 48 LU scale and the arc runs to −11, so the part
    // below the target is much the larger of the two. An ordering rather than a
    // ratio: it holds at any module size and needs no geometry.
    expect(
      counts[_colors.textPrimary]!,
      greaterThan(counts[_colors.over]!),
      reason: 'the red segment is the size of the miss, not of the reading',
    );
  });

  testWidgets('in spec, the ring is entirely the accent', (tester) async {
    final counts = await _tally(tester, -14.0, [
      _colors.accent,
      _colors.over,
      _colors.textPrimary,
    ]);

    expect(counts[_colors.accent], greaterThan(segment));
    expect(
      counts[_colors.over],
      lessThan(segment),
      reason: 'nothing is over the target',
    );
    expect(
      counts[_colors.textPrimary],
      lessThan(segment),
      reason: 'an in-spec reading is a green ring, not a green tip',
    );
  });

  testWidgets('under the target, nothing is red', (tester) async {
    final counts = await _tally(tester, -20.0, [
      _colors.over,
      _colors.textPrimary,
    ]);

    expect(counts[_colors.textPrimary], greaterThan(segment));
    expect(
      counts[_colors.over],
      lessThan(segment),
      reason: 'quiet is not over',
    );
  });
}
