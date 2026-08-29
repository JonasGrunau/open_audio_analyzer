// SPDX-License-Identifier: GPL-3.0-or-later
//
// The em dash is grey, and it is grey in every module.
//
// [colorForState] has said so since it was written, and the modules that ask
// it — the Number Box, the Alert Meter, the Validator — printed the dash in
// [OaaColors.textMuted] all along. The four below never asked it. Each prints
// a reading no verdict applies to, so each took [OaaColors.accent] once per
// palette and never looked at the number again: the LUFS meter's momentary and
// short-term columns, the Digital Meter's peaks and RMS, the Super Meter's
// short-term pair, the loudness distribution's LRA. Before a signal arrives —
// which is every launch, and every moment a link is quiet — those dashes went
// out in the signal hue, the one colour on the measurement surface that means
// *this is a measurement*, while a Number Box beside them wrote the same
// statement in grey.
//
// Three of the four ask [inkForReading] now. The fourth left the question
// behind: the distribution's LRA is printed in the caliper's own grey whether
// it was measured or not, because it is a part of that dimension line rather
// than a reading standing on its own — see `_paintCaliper`. Its case below is
// unchanged by that and worth no less: what it holds is the picture, and the
// accent returning to this module would fail it whichever state brought it.
//
// So the assertion is a count over the whole picture rather than a lookup of
// one colour: with nothing measured, **no pixel anywhere may be the accent**.
// It is what the reader sees, it needs no geometry copied from any painter,
// and it catches the next module to print a reading without asking where its
// ink comes from.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/digital_meter.dart';
import 'package:oaa/src/modules/loudness_distribution.dart';
import 'package:oaa/src/modules/lufs_meter.dart';
import 'package:oaa/src/modules/super_meter.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

const _colors = OaaColors.precisionInstrument;
const _target = BuiltInCalibrations.streaming;

/// The fonts the application ships, so the dash is a dash rather than the
/// placeholder font's em box. Read with `readAsBytesSync`: an awaited real read
/// inside a `testWidgets` body never completes.
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

/// An engine that is running and has measured nothing — a link that has just
/// come up, or a build that computes none of this. Every quantity is NaN, which
/// is the contract: see `MeterSource`.
class _Nothing implements MeterSource {
  int _generation = 0;
  double _elapsed = 0;

  void publish() {
    _generation++;
    _elapsed += 1;
  }

  @override
  Transport transport = Transport.none;
  @override
  double get lufsMomentary => double.nan;
  @override
  double get lufsShort => double.nan;
  @override
  double get lufsIntegrated => double.nan;
  @override
  double get loudnessRange => double.nan;
  @override
  double get loudnessRangeLow => double.nan;
  @override
  double get loudnessRangeHigh => double.nan;
  @override
  double get odrIntegrated => double.nan;
  @override
  double get odrShort => double.nan;
  @override
  double get truePeakMax => double.nan;
  @override
  Float32List get peak => Float32List.fromList([double.nan, double.nan]);
  @override
  Float32List get rms => Float32List.fromList([double.nan, double.nan]);
  @override
  Uint32List get clip => Uint32List(2);
  @override
  Float32List get histogram => Float32List(MeterShape.histogramBins);
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
  const _Harness({
    required this.source,
    required this.boundary,
    required this.size,
    required this.module,
  });

  final _Nothing source;
  final GlobalKey boundary;
  final Size size;
  final Widget Function(MeterSource, MeterClock) module;

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
              width: widget.size.width,
              height: widget.size.height,
              child: widget.module(widget.source, clock),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Pixels of the accent's *hue* in what [module] drew, at any weight.
///
/// A family and not an exact value, which this file learned the hard way: an
/// em dash is a rule one or two pixels thick, it lands off the pixel grid at
/// most sizes, and set in the accent it produced **not one pixel of exactly
/// the accent** — every last one of it was an antialiased blend. An
/// exact-match count passed with the defect deliberately put back, which is a
/// test that would have watched this ship.
///
/// Everything else on these four modules with nothing measured is grey: the
/// panel, the hairlines, the labels, the unlit segments, the tick numbers. The
/// two saturated colours the palette has left are `warn` and `over`, and both
/// are the other side of the wheel. So a saturated pixel anywhere near the
/// accent's hue is the accent or a shade of it, and there should not be one.
///
/// [insideTheRings] is for the Super Meter alone, whose two tip names — LUFS-S
/// and ODR-S, engraved along the arc — are drawn in the meters' ink *by
/// design*: they are names riding the rings, not readings, and they are the
/// one thing on that module in this family that should be there. The geometry
/// to exclude them is found in the image rather than copied from the painter,
/// the way `super_meter_test.dart` finds it: the gauge is symmetric about the
/// middle of the module and its outer ring reaches furthest left at exactly
/// the centre's height, so the leftmost *grey* ink — the names are the only
/// saturated thing outside the ring — gives both the centre and the outer
/// radius. Everything the centre prints lives inside 0.66 of it.
Future<int> _accentPixels(
  WidgetTester tester,
  Size size,
  Widget Function(MeterSource, MeterClock) module, {
  bool insideTheRings = false,
}) async {
  await _loadFonts();
  final source = _Nothing();
  final key = GlobalKey();
  await tester.pumpWidget(
    _Harness(source: source, boundary: key, size: size, module: module),
  );
  // Three publishes a second apart, so nothing is being caught mid-ease: an
  // arc that has not arrived anywhere yet draws nothing either.
  for (var i = 0; i < 3; i++) {
    source.publish();
    await tester.pump(const Duration(milliseconds: 100));
  }

  var found = 0;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // At 3×, so that a glyph as thin as an em dash lands enough fully covered
    // pixels to be counted at all: at 1× the Digital Meter's rules were
    // entirely antialiased edge, and the defect this file exists to catch went
    // undetected there while the LUFS meter's larger dashes caught it.
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final hue = HSLColor.fromColor(_colors.accent).hue;
    final width = image.width;

    bool isAccent(int i) {
      if (bytes[i + 3] != 255) return false;
      final pixel = HSLColor.fromColor(
        Color.fromARGB(255, bytes[i], bytes[i + 1], bytes[i + 2]),
      );
      return pixel.saturation >= 0.25 &&
          pixel.lightness > 0.12 &&
          (pixel.hue - hue).abs() <= 8;
    }

    bool isBackground(int i) =>
        bytes[i + 3] != 255 ||
        (bytes[i] == (_colors.background.r * 255).round() &&
            bytes[i + 1] == (_colors.background.g * 255).round() &&
            bytes[i + 2] == (_colors.background.b * 255).round());

    var centreY = 0;
    var inside = double.infinity;
    if (insideTheRings) {
      var leftmost = width;
      for (var x = 0; x < width && leftmost == width; x++) {
        for (var y = 0; y < image.height; y++) {
          final i = (y * width + x) * 4;
          if (!isBackground(i) && !isAccent(i)) {
            leftmost = x;
            centreY = y;
            break;
          }
        }
      }
      inside = (width / 2 - leftmost) * 0.66;
    }

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < width; x++) {
        if (insideTheRings) {
          final dx = x - width / 2, dy = y - centreY;
          if (dx * dx + dy * dy > inside * inside) continue;
        }
        if (isAccent((y * width + x) * 4)) found++;
      }
    }
    image.dispose();
  });
  return found;
}

void main() {
  testWidgets('the LUFS meter prints its three dashes in grey', (tester) async {
    expect(
      await _accentPixels(
        tester,
        const Size(260, 360),
        (engine, clock) =>
            LufsMeterModule(engine: engine, clock: clock, calibration: _target),
      ),
      0,
      reason:
          'momentary and short-term take the accent for a reading, and '
          'there is no reading',
    );
  });

  testWidgets('the Digital Meter prints its peaks and RMS in grey', (
    tester,
  ) async {
    expect(
      await _accentPixels(
        tester,
        const Size(260, 360),
        (engine, clock) => DigitalMeterModule(engine: engine, clock: clock),
      ),
      0,
    );
  });

  testWidgets('the Super Meter prints its whole stack in grey', (tester) async {
    expect(
      await _accentPixels(
        tester,
        const Size(420, 420),
        (engine, clock) => SuperMeterModule(
          engine: engine,
          clock: clock,
          calibration: _target,
        ),
        insideTheRings: true,
      ),
      0,
      reason:
          'the short-term pair is judged by nothing, which is not the '
          'same as being a measurement',
    );
  });

  testWidgets('the loudness distribution prints its range in grey', (
    tester,
  ) async {
    expect(
      await _accentPixels(
        tester,
        const Size(420, 260),
        (engine, clock) => LoudnessDistributionModule(
          engine: engine,
          clock: clock,
          calibration: _target,
        ),
      ),
      0,
      reason:
          'a guard rather than a reproduction: the caliper is only drawn '
          'once the percentiles exist, and the range is gated from the same '
          'material, so this module could not show the defect the other '
          'three did — and its reading is the caliper\'s grey in every state '
          'now, which is not a reason to stop looking',
    );
  });
}
