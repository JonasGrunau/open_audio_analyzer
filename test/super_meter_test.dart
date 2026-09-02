// SPDX-License-Identifier: GPL-3.0-or-later
//
// The super meter's inner ring, which is the one that gets delivered.
//
// It is drawn in the meters' accent along its whole length, whatever the
// reading stands at against the target; the target is a red tick, and how far
// past the tick the arc reaches is the miss. The ring has worn two other
// schemes and these hold the line against both: for a time it took its
// verdict's colour for its whole length, so a mix over its target ran red from
// the bottom of the scale to the reading with its own target tick stranded in
// the middle of it; then it was cut at the tick and redrawn in `over` past it,
// a warning laid over a level on a gauge whose centre already prints the
// verdict. The verdict lives in the centre's numbers and nowhere on the ring.
//
// The assertions count colours over the whole picture rather than sampling the
// arc, because the question is only ever "what colours is the ring drawn in".
// The ink is counted as a *family* rather than a value: the arc runs from the
// ink at its tip to a deepened floor colour at the silent end — `MeterFill`'s
// ramp, swept — so much of it is not the ink exactly, and what stays true
// along it is a hue between the two. No radius, sweep or centre is
// copied from the painter — the little geometry `_tally` needs, it finds in
// the image. A second copy of the layout living in the test is a copy that
// has to be kept in step with the first, and silently stops testing anything
// the day it is not.

import 'dart:math' as math;
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
  _Levels(this.integrated, {this.step = 1, this.shortTerm = -30});

  final double integrated;

  /// The outer ring's reading. −30 for every case that is about the inner
  /// ring, and NaN for the one that is about an empty dial — a Super Meter
  /// that has measured nothing at all, which is what every launch starts as.
  final double shortTerm;

  /// Engine seconds a publish advances the clock by. A second settles the
  /// arcs in one publish; the arrival test uses a block's worth to watch them
  /// travel.
  final double step;

  @override
  Transport transport = Transport.none;
  int _generation = 0;
  double _elapsed = 0;

  void publish() {
    _generation++;
    _elapsed += step;
  }

  // The outer ring sits far below the target, so the only `over` pixels in
  // the annulus besides the ring under test's are the target tick's own — a
  // radial hairline, well under a segment's worth of ink.
  @override
  double get lufsMomentary => shortTerm;
  @override
  double get lufsShort => shortTerm;
  @override
  double get lufsIntegrated => integrated;

  // **Deliberately not measured.** A loudness range inside its maximum is a
  // *neutral* reading, and a neutral reading is the accent — one of the very
  // colours these cases count. The LRA readout is 35 by 12 pixels of it in the
  // middle of the module, comfortably over the floors below, so it would have
  // carried two of these three tests on its own whatever the ring did.
  // Unmeasured draws an em dash in `textMuted` instead.
  @override
  double get loudnessRange => double.nan;

  /// Unmeasured for the same reason as the range: the readouts under it would
  /// be the accent against a target with no floor, in the middle of the
  /// module, and carry the tests that are about the ring. Unmeasured dynamics
  /// also leave the right-hand arcs undrawn, so every arc pixel in the annulus
  /// belongs to loudness.
  @override
  double get odrIntegrated => double.nan;
  @override
  double get odrShort => double.nan;

  /// Unmeasured, so the TRUEPEAK MAX row is an em dash and the ceiling zone is
  /// judged against nothing.
  @override
  double get truePeakMax => double.nan;

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
  const _Harness({required this.source, required this.boundary, super.key});

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
                naming: DynamicsNaming.defaultNaming,
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
/// antialiased edges land on none of them and simply are not counted, and so
/// does the ceiling zone, which is translucent over the track by design.
///
/// **Everything inside the rings is excluded, and has to be.** The readouts in
/// the middle and the tick values inside the rings are drawn in their
/// readings' own verdict colours — `-11.0` against a −14 target is five glyphs
/// of `over`, which in a test with no fonts loaded are five solid boxes and
/// thousands of red pixels. Counted, they swamped the arcs: the red segment
/// came out larger than the whole rest of the ring, which is the opposite of
/// what the picture shows.
///
/// The geometry to do it is *found*, not copied from the painter. The gauge is
/// symmetric about the middle of the module and its outer ring reaches furthest
/// left at exactly the centre's height, so the leftmost ink gives both the
/// centre and the outer radius without knowing anything about how the module
/// lays itself out. The two rings live between 0.67 and 1.0 of that radius and
/// everything printed lives inside 0.66 of it, so counting the annulus outside
/// 0.70 keeps most of both rings and none of the text.
Future<Map<Color, int>> _tally(
  WidgetTester tester,
  double integrated,
  List<Color> of,
) async {
  final source = _Levels(integrated);
  final key = GlobalKey();
  await tester.pumpWidget(_Harness(source: source, boundary: key));
  // Three publishes a second apart: the first puts the arc at the silent end,
  // and a second of engine time is enough for the next to carry it the whole
  // way to its reading.
  for (var i = 0; i < 3; i++) {
    source.publish();
    await tester.pump(const Duration(milliseconds: 100));
  }
  return _count(tester, key, of);
}

/// Whether [rgb] is the meters' ink, anywhere along the arc's ramp: between
/// the ink and its deepened floor colour in hue, saturated, and no lighter or
/// darker than either end. The ring's grey track, the red tick and the
/// near-white text all fall outside it; so does the pass colour, which is the
/// ink's hue at a lightness the arc never reaches.
bool _isInk(int rgb) {
  final ink = HSLColor.fromColor(_colors.meterAccent);
  final floor = HSLColor.fromColor(OaaColors.deepen(_colors.meterAccent));
  final pixel = HSLColor.fromColor(Color(0xFF000000 | rgb));
  final lo = math.min(ink.hue, floor.hue) - 4;
  final hi = math.max(ink.hue, floor.hue) + 4;
  return pixel.hue >= lo &&
      pixel.hue <= hi &&
      pixel.saturation >= 0.25 &&
      pixel.lightness >= math.min(ink.lightness, floor.lightness) - 0.03 &&
      pixel.lightness <= math.max(ink.lightness, floor.lightness) + 0.03;
}

/// [_tally]'s count, over whatever the tree under [key] is showing now. Every
/// colour is matched exactly except the meters' ink, which is matched as a
/// family by [_isInk].
Future<Map<Color, int>> _count(
  WidgetTester tester,
  GlobalKey key,
  List<Color> of,
) async {
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
    final rings = outer * 0.70;

    final wanted = {
      for (final color in of)
        (color.r * 255).round() << 16 |
                (color.g * 255).round() << 8 |
                (color.b * 255).round():
            color,
    };
    final ink = _colors.meterAccent;
    final countInk = of.contains(ink);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = x - cx, dy = y - centreY;
        if (dx * dx + dy * dy < rings * rings) continue;
        final rgb = at(x, y);
        final color = wanted[rgb];
        if (color != null && color != ink) {
          counts[color] = counts[color]! + 1;
        } else if (countInk && _isInk(rgb)) {
          counts[ink] = counts[ink]! + 1;
        }
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

  testWidgets('with nothing measured, no name stands at full scale', (
    tester,
  ) async {
    // The two tip names ride their arcs' ends, and ODR-S's default end used to
    // be the end of the *sweep* — so before a note was played it sat at the
    // right of the dial, where a gauge face reads as a tip at the ceiling.
    // That is the one thing a meter may never claim for a quantity nobody has
    // measured, and it then jumped the whole width of the dial on the first
    // frame of audio. The dynamics arc is stacked on the loudness tip, so with
    // no dynamics reading its name belongs beside LUFS-S at the silent end.
    //
    // Counted as a hue family across the two halves of the picture rather than
    // as a colour: LUFS-S is the meters' ink and ODR-S is that ink lifted
    // towards the text colour, and naming the second here would be a copy of
    // the painter's recipe that has to be kept in step with it. With nothing
    // measured there is no arc, so the names are the only thing in the family
    // on the dial at all.
    final source = _Levels(double.nan, shortTerm: double.nan);
    final key = GlobalKey();
    await tester.pumpWidget(_Harness(source: source, boundary: key));
    source.publish();
    await tester.pump(const Duration(milliseconds: 100));

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    var left = 0, right = 0;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      final hue = HSLColor.fromColor(_colors.meterAccent).hue;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final i = (y * image.width + x) * 4;
          if (bytes[i + 3] != 255) continue;
          final pixel = HSLColor.fromColor(
            Color.fromARGB(255, bytes[i], bytes[i + 1], bytes[i + 2]),
          );
          if (pixel.saturation < 0.25 || (pixel.hue - hue).abs() > 8) continue;
          if (x < image.width / 2) {
            left++;
          } else {
            right++;
          }
        }
      }
      image.dispose();
    });

    expect(left, greaterThan(segment), reason: 'both names are at rest');
    expect(
      right,
      0,
      reason: 'ODR-S at the right of an empty dial is a tip at full scale',
    );
  });

  testWidgets('over the target, the ring keeps its ink past the tick', (
    tester,
  ) async {
    // −11 against −14: the arc runs past the target and its tip is over.
    final ink = _colors.meterAccent;
    final counts = await _tally(tester, -11.0, [_colors.over, ink]);

    expect(counts[ink], greaterThan(segment));
    // Not zero: the target's own tick is red by design. A tick is a hairline
    // and a segment of arc is not, which is what the floor separates.
    expect(
      counts[_colors.over],
      lessThan(segment),
      reason:
          'the part past the target is a level, not a warning — the verdict '
          'is the centre\'s to show',
    );
  });

  testWidgets('in spec, the ring is the meters\' accent and nothing else', (
    tester,
  ) async {
    final ink = _colors.meterAccent;
    final counts = await _tally(tester, -14.0, [
      ink,
      _colors.over,
      _colors.accent,
      _colors.textPrimary,
    ]);

    expect(counts[ink], greaterThan(segment));
    expect(
      counts[_colors.over],
      lessThan(segment),
      reason: 'nothing is over the target',
    );
    // The verdict is the centre's to show. A ring that turned the pass colour
    // was a light the size of the module, and the green number beside it
    // vanished into it.
    expect(counts[_colors.accent], lessThan(segment));
    expect(counts[_colors.textPrimary], lessThan(segment));
  });

  testWidgets('under the target, nothing is red', (tester) async {
    final ink = _colors.meterAccent;
    final counts = await _tally(tester, -20.0, [_colors.over, ink]);

    expect(counts[ink], greaterThan(segment));
    // Not zero: the target's own tick is red by design. A tick is a hairline
    // and a segment of arc is not, which is what the floor separates.
    expect(
      counts[_colors.over],
      lessThan(segment),
      reason: 'quiet is not over',
    );
  });

  testWidgets('a reading that has just appeared arrives from the silent end', (
    tester,
  ) async {
    // LUFS-S takes three seconds of programme to exist and LUFS-I a gated
    // block; when a reading appears, its arc sweeps in from the left end over
    // about half a second rather than popping into the middle of the dial.
    // The integrated ring is watched because it is the ring the tally reads;
    // the rule is the same for all four arcs.
    final ink = _colors.meterAccent;

    // The outer ring's LUFS-S name rides its tip in the same ink, and with no
    // fonts loaded its glyphs are solid boxes — so a dial with *no* arc still
    // counts a few hundred pixels of it. Measured once, on a reading that is
    // not defined, and subtracted rather than guessed at.
    final empty = _Levels(double.nan, step: 0.02);
    final emptyKey = GlobalKey();
    await tester.pumpWidget(_Harness(source: empty, boundary: emptyKey));
    empty.publish();
    await tester.pump(const Duration(milliseconds: 20));
    final baseline = (await _count(tester, emptyKey, [ink]))[ink]!;

    // A second harness with a key of its own, or the first's element — and
    // its clock, still ticking on the first source — is reused under it.
    final source = _Levels(-14.0, step: 0.02);
    final key = GlobalKey();
    await tester.pumpWidget(
      _Harness(key: const ValueKey('arriving'), source: source, boundary: key),
    );

    Future<int> run(int publishes) async {
      for (var i = 0; i < publishes; i++) {
        source.publish();
        await tester.pump(const Duration(milliseconds: 20));
      }
      return (await _count(tester, key, [ink]))[ink]!;
    }

    final first = await run(1);
    expect(
      first - baseline,
      lessThan(segment),
      reason: 'on the frame a reading appears its arc is at the silent end',
    );

    final midway = await run(10);
    expect(
      midway - first,
      greaterThan(segment),
      reason: 'a fifth of a second in, the arc is on its way',
    );

    final settled = await run(60);
    expect(
      settled - midway,
      greaterThan(segment),
      reason:
          'and it keeps travelling towards the reading rather than having '
          'jumped there',
    );
  });
}
