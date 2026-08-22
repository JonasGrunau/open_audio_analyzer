// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one thing a VU face must not do: draw a needle for a reading nobody
// measured.
//
// `MeterSource.vu` is NaN in two situations that both reach a user. The engine
// may not measure it in a given build, and a remote display whose link has gone
// quiet fills every per-channel array with NaN — `WireSnapshot.clear`. The
// module used to hand that straight to the arithmetic, where NaN clamped to the
// bottom of the scale, and the tablet's dial rested confidently at −20 VU with
// the same authority it reads a real quiet passage with.
//
// The assertion counts pixels of `textPrimary` over the whole picture rather
// than probing the angle the needle would be at, because that angle is a copy
// of the painter's layout, and a copy has to be kept in step with the original
// and silently stops testing anything the day it is not. A needle is two orders
// of magnitude more of that colour than the 0 VU mark and its label, which are
// the only other things drawn in it.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/vu_meter.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;

/// Streaming: 0 VU is −18 dBFS, which is this calibration's default.
const _target = BuiltInCalibrations.streaming;

class _Levels implements MeterSource {
  _Levels(double dbfs) {
    vu[0] = dbfs;
    vu[1] = dbfs;
  }

  @override
  final Float32List vu = Float32List(MeterShape.maxChannels);

  @override
  Transport transport = Transport.none;
  int _generation = 0;
  double _elapsed = 0;

  void publish() {
    _generation++;
    _elapsed += 1 / 60;
  }

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
              height: 200,
              child: VuMeterModule(
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

/// The real faces, so the scale labels are glyphs and not the test binding's
/// square placeholder — which is several times the ink of a real digit and
/// would swamp the difference being measured. Read with `readAsBytesSync`: an
/// awaited real read inside a `testWidgets` body never completes.
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

/// Pixels of [OaaColors.textPrimary] in the module, to the nearest whole
/// channel. Antialiased edges are not counted, which is fine: the question is
/// whether a shape the length of the radius is there at all.
Future<int> _needleInk(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  var count = 0;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final r = (_colors.textPrimary.r * 255).round();
    final g = (_colors.textPrimary.g * 255).round();
    final b = (_colors.textPrimary.b * 255).round();
    for (var i = 0; i < bytes.length; i += 4) {
      if (bytes[i] == r && bytes[i + 1] == g && bytes[i + 2] == b) count++;
    }
    image.dispose();
  });
  return count;
}

Future<int> _inkFor(WidgetTester tester, double dbfs) async {
  final source = _Levels(dbfs);
  final key = GlobalKey();
  await tester.pumpWidget(_Harness(source: source, boundary: key));
  for (var i = 0; i < 30; i++) {
    source.publish();
    await tester.pump(const Duration(milliseconds: 16));
  }
  return _needleInk(tester, key);
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('a VU reading draws a needle', (tester) async {
    // −20 dBFS is −2 VU against this calibration: most of the way up the face,
    // and nowhere near either end of it.
    expect(await _inkFor(tester, -20), greaterThan(200));
  });

  testWidgets('an unmeasured VU draws none', (tester) async {
    final measured = await _inkFor(tester, -20);
    final unmeasured = await _inkFor(tester, double.nan);
    expect(unmeasured * 4, lessThan(measured));
  });
}
