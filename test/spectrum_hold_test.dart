// SPDX-License-Identifier: GPL-3.0-or-later
//
// The analyser's peak hold across a change of `Source`.
//
// `_advance` reseats the curve and the hold together whenever the engine's
// clock is discontinuous, and says why in its own comment: "a hold carried
// across a discontinuity is a maximum of two different programmes". Switching
// which signal the bands are measured on is that sentence with *signals* for
// programmes, and the clock does not so much as stutter across it — so nothing
// caught it. The line over Right was the maximum of Right and whatever Left
// had just been doing, standing at a level Right never reached and sinking
// towards the truth at twelve decibels a second.
//
// The spectrogram, which reads the same bands from the same setting, has
// cleared its record on this since the setting existed. This is the other half
// of that.
//
// Asserted on pixels because the hold is drawn and held nowhere else: one
// signal is loud across every band and the other is at the floor, so a hold
// that survived stands in the top of a plot whose curve is on the bottom.

import 'dart:io';
import 'dart:typed_data';

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/spectrum_analyzer.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;
const Size _size = Size(420, 260);

/// Loud enough to draw near the top of a 90 dB plot, and quiet enough to sit
/// on its floor. Flat across every band, so the assertion does not depend on
/// which band a sample lands in.
const double _loudDb = -6;
const double _quietDb = -85;

class _Source implements MeterSource {
  _Source() {
    _loud.fillRange(0, _loud.length, _loudDb);
    _quiet.fillRange(0, _quiet.length, _quietDb);
  }

  final Float32List _loud = Float32List(MeterShape.spectrumBands);
  final Float32List _quiet = Float32List(MeterShape.spectrumBands);

  int _generation = 1;
  double _elapsed = 0;

  /// [SpectrumSource.all] is the loud signal and `left` the quiet one, so a
  /// change of source is a change of everything the plot is drawing.
  @override
  Float32List spectrumOf(SpectrumSource source) {
    _generation++;
    _elapsed += 1 / 47;
    return source == SpectrumSource.all ? _loud : _quiet;
  }

  @override
  bool get hasSpectrum => true;
  @override
  int get generation => _generation;
  @override
  double get elapsedSeconds => _elapsed;
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
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Harness extends StatefulWidget {
  const _Harness({
    required this.source,
    required this.boundary,
    required this.spectrumSource,
  });

  final _Source source;
  final GlobalKey boundary;
  final SpectrumSource spectrumSource;

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
              child: ModuleFrame(
                title: 'SPECTRUM',
                child: SpectrumAnalyzerModule(
                  engine: widget.source,
                  clock: clock,
                  source: widget.spectrumSource,
                  // Unaveraged, so the curve is the published frame exactly
                  // and the only thing that can still be high is the hold.
                  response: SpectrumResponse.fast,
                  tilt: SpectrumTilt.db0,
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
  testWidgets('a change of source does not carry the hold across', (
    tester,
  ) async {
    await _loadFonts();
    final source = _Source();
    final boundary = GlobalKey();

    Widget harness(SpectrumSource s) =>
        _Harness(source: source, boundary: boundary, spectrumSource: s);

    // The loud signal, long enough to put the hold at the top and leave it
    // there — it sits at its maximum for a second and a half before it starts
    // falling at all.
    await tester.pumpWidget(harness(SpectrumSource.all));
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump(const Duration(milliseconds: 32));

    expect(
      await _accentInkAcrossTheTop(tester, boundary),
      isTrue,
      reason: 'the loud signal never drew a curve in the top of the plot',
    );

    // The quiet one, in place, so the module's own State survives and
    // `didUpdateWidget` is what sees the change.
    await tester.pumpWidget(harness(SpectrumSource.left));
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump(const Duration(milliseconds: 32));

    expect(
      await _accentInkAcrossTheTop(tester, boundary),
      isFalse,
      reason:
          'the hold is still standing where the previous signal left it, over '
          'a curve on the floor',
    );
  });
}

/// Whether the curve or its hold is drawn across the top of the plot.
///
/// **Looked for by colour, not by "anything that is not the panel".** The plot
/// is full of chrome up there — the gridlines, the frequency labels along its
/// top edge — and all of it is neutral grey, where the curve, its fill and the
/// hold above it are the accent. Green clearly above red separates the two
/// with nothing in between, and it is the same test at every alpha the fill's
/// gradient runs through.
///
/// A band of the picture rather than one pixel: the hold is a polyline a pixel
/// or two thick, so a single sample would be asserting where the line is
/// rather than whether it is there. Taken left of centre, clear of the range
/// readout in the plot's top-right corner.
Future<bool> _accentInkAcrossTheTop(
  WidgetTester tester,
  GlobalKey boundary,
) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  var found = false;
  await tester.runAsync(() async {
    final image = await render.toImage();
    final data = (await image.toByteData())!;
    final width = render.size.width.round();
    final top = (ModuleFrame.titleBarHeight + Space.smd).round();
    final bottom = (_size.height * 0.33).round();
    for (var y = top; y < bottom && !found; y++) {
      for (var x = width ~/ 4; x < width ~/ 2; x++) {
        final offset = ((y * width) + x) * 4;
        final red = data.getUint8(offset);
        final green = data.getUint8(offset + 1);
        if (green > red + 8) {
          found = true;
          break;
        }
      }
    }
    image.dispose();
  });
  return found;
}

/// Without the real faces every glyph rasterises as a box, which is more ink
/// than any label and would reach samples it has no business reaching.
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
