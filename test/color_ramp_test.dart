// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two modules that draw a colour rather than a length, held to what
// `ColorRamp` is allowed to change.
//
// `Full RGB` is the only setting in the application whose whole product is a
// colour, and that is exactly what makes it hard to check by inspection: every
// widget assertion passes at both settings, both pictures look plausible, and a
// ramp fed the wrong quantity draws a picture of precisely the right shape in
// precisely the wrong colours, which nobody can tell is lying.
//
// The two modules are fed different quantities on purpose — the spectrogram's
// colour is its *level*, because its axes already carry the frequency, and the
// oscilloscope's is the *balance of its bands*, because nothing else there can
// carry one. Each group below holds its module to its own quantity, and both
// hold the setting to changing nothing but colour.
//
// The reads are hue comparisons rather than colour equalities. Both shipped
// skins put their accent and their warn well above their blue, so the skin ramp
// never draws a pixel whose red or blue dominates its green; the frequency ramp
// does both, at opposite ends of the spectrum. That holds whatever the skin is,
// which a test naming `0x35E0C4` would not.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/oscilloscope.dart';
import 'package:oaa/src/modules/spectrogram.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

const _colors = OaaColors.precisionInstrument;
const _rate = 48000;
const _block = MeterShape.scopePoints;
const _width = 400;
const _height = 120;
const _size = Size(400, 120);

/// A source the test drives by hand, publishing one analysis block at a time
/// the way the engine does.
///
/// The spectrum and the waveform are set independently, which is not a
/// simplification but the point: the oscilloscope's colour comes from the
/// *spectrum* of the block its samples came from, so a test that could not put
/// a known band under a known waveform could not tell a working hue from a
/// coincidence.
class _Fake implements MeterSource {
  _Fake({this.spectrumAvailable = true});

  @override
  Transport transport = Transport.none;

  final bool spectrumAvailable;

  int _generation = 0;
  int _frames = 0;

  final Float32List _spectrum = Float32List(MeterShape.spectrumBands);
  final Float32List _scope = Float32List(_block * 2);

  /// Publishes a block.
  ///
  /// [band] concentrates the spectrum on one band, as a fraction of the axis —
  /// 0 is 20 Hz and 1 is 20 kHz — which is what the oscilloscope's colour is
  /// taken from. Null spreads it flat across every band, so that every row of
  /// the spectrogram is at the same level and its colour can be read off any of
  /// them. [db] is that level.
  void publish({double? band, double db = -20}) {
    _generation++;
    for (var i = 0; i < _spectrum.length; i++) {
      if (band == null) {
        _spectrum[i] = db;
      } else {
        final at = (band * (_spectrum.length - 1)).round();
        // A narrow peak rather than a single bin: the centroid is a weighted
        // mean and a peak two bands wide is what any real tone looks like to a
        // 512-band analyser.
        _spectrum[i] = (i - at).abs() <= 1 ? db : MeterShape.dbFloor;
      }
    }
    for (var i = 0; i < _block; i++) {
      final value = math.sin(2 * math.pi * 400 * (_frames + i) / _rate) * 0.95;
      _scope[i * 2] = value;
      _scope[i * 2 + 1] = value;
    }
    _frames += _block;
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
  bool get hasSpectrum => spectrumAvailable;
  @override
  int get channels => 1;
  @override
  int get sampleRate => _rate;
  @override
  double get elapsedSeconds => _frames / _rate;
  @override
  Float32List get spectrum => _spectrum;
  @override
  Float32List get spectrumPeak => _spectrum;

  @override
  Float32List spectrumOf(SpectrumSource source) => spectrum;

  @override
  Float32List spectrumPeakOf(SpectrumSource source) => spectrumPeak;
  @override
  Float32List get scope => _scope;
  @override
  int get scopeFrames => _scope.length ~/ 2;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Owns the clock for as long as the tree lives, as the workspace does. A ticker
/// created beside the tree outlives it and the binding then reports an animation
/// still running after disposal.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.source,
    required this.boundary,
    required this.child,
    super.key,
  });

  final MeterSource source;
  final GlobalKey boundary;
  final Widget Function(MeterSource engine, MeterClock clock) child;

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
            // No `ModuleFrame`, so the boundary is the plot and a pixel
            // coordinate here is a coordinate in the painter.
            child: SizedBox(
              width: _size.width,
              height: _size.height,
              child: widget.child(widget.source, clock),
            ),
          ),
        ),
      ),
    ),
  );
}

/// One frame of the application's clock, and a gap of real time after it.
///
/// **Both halves, every frame.** The spectrogram's picture is an image built
/// asynchronously off the frame that recorded it, and a `testWidgets` body runs
/// in a fake-async zone: the awaits inside that build are only delivered by real
/// time, which is what `runAsync` provides, and the continuations after them are
/// only drained by a pump. A run of pumps followed by a run of `runAsync` gaps
/// advances the chain by one await per gap rather than completing it — which
/// reads as a module that drew nothing at all.
Future<void> _frame(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 17));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 2)),
  );
}

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

int _r(Uint8List p, int x, int y) => p[(y * _width + x) * 4];
int _g(Uint8List p, int x, int y) => p[(y * _width + x) * 4 + 1];
int _b(Uint8List p, int x, int y) => p[(y * _width + x) * 4 + 2];

/// A margin the skin ramp's own colours clear in the other direction,
/// antialiased edges included.
const int _margin = 60;

/// The bass end of the frequency ramp. Red over *both* of the other channels,
/// which is what separates it from the skin ramp's amber `warn`.
bool _isRed(Uint8List p, int x, int y) =>
    _r(p, x, y) - _g(p, x, y) > _margin && _r(p, x, y) - _b(p, x, y) > _margin;

/// The middle of it.
bool _isGreen(Uint8List p, int x, int y) =>
    _g(p, x, y) - _r(p, x, y) > _margin && _g(p, x, y) - _b(p, x, y) > _margin;

/// The top of it. The teals and blues; the white at the very top of the axis is
/// caught by neither this nor [_isRed], which is correct — it is not a hue.
bool _isBlue(Uint8List p, int x, int y) =>
    _b(p, x, y) - _r(p, x, y) > _margin && _b(p, x, y) - _g(p, x, y) > 40;

/// Ink of any colour, which is what makes a geometry comparison possible
/// between two pictures drawn in different palettes: every colour either ramp
/// produces is chromatic, and every piece of chrome these modules draw — the
/// graticule, the centre lines, the labels, the grounds — is grey.
bool _isInk(Uint8List p, int x, int y) {
  final r = _r(p, x, y), g = _g(p, x, y), b = _b(p, x, y);
  return math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)) > 40;
}

bool _any(Uint8List p, bool Function(Uint8List, int, int) test) {
  for (var x = 0; x < _width; x++) {
    for (var y = 0; y < _height; y++) {
      if (test(p, x, y)) return true;
    }
  }
  return false;
}

/// The topmost inked row in each column, or null where the column is bare. The
/// outline of the picture, independent of what colour it was drawn in.
List<int?> _outline(Uint8List p) => [
  for (var x = 0; x < _width; x++)
    () {
      for (var y = 0; y < _height; y++) {
        if (_isInk(p, x, y)) return y;
      }
      return null;
    }(),
];

void main() {
  group('the spectrogram', () {
    Future<Uint8List> shot(
      WidgetTester tester,
      ColorRamp ramp, {
      double db = -20,
    }) async {
      final source = _Fake();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        _Harness(
          // A key per shot, because two of these run inside one test body: the
          // harness owns the clock, and a `State` the framework reused would
          // hand the second module a clock still reading the first source —
          // which publishes nothing ever again, so the module draws nothing.
          key: ValueKey('$ramp$db'),
          source: source,
          boundary: boundary,
          child: (engine, clock) =>
              SpectrogramModule(engine: engine, clock: clock, ramp: ramp),
        ),
      );
      // A flat spectrum, so every row of the display differs from every other
      // in nothing but its frequency.
      for (var i = 0; i < 8; i++) {
        source.publish(db: db);
        await _frame(tester);
      }
      return _shoot(tester, boundary);
    }

    testWidgets('draws the skin and nothing but the skin by default', (
      tester,
    ) async {
      final pixels = await shot(tester, ColorRamp.skin);
      expect(
        _any(pixels, _isRed) || _any(pixels, _isBlue),
        isFalse,
        reason:
            'The frequency ramp is being drawn at the default setting, which '
            'is the one thing this default exists to prevent.',
      );
      expect(
        _any(pixels, _isInk),
        isTrue,
        reason:
            'Nothing chromatic was drawn at all, so the read above passed '
            'against an empty module.',
      );
    });

    testWidgets('runs the whole rainbow up the level range', (tester) async {
      // Three flat spectra, so the only thing that differs between the shots is
      // how loud they are. The claim is that the *level* picks the colour, and
      // it fails in two directions: a ramp fed the frequency instead paints all
      // three of these the same, and one fed the level backwards paints them in
      // each other's colours.
      final quiet = await shot(tester, ColorRamp.rgb, db: -66);
      final middle = await shot(tester, ColorRamp.rgb, db: -40);
      final loud = await shot(tester, ColorRamp.rgb, db: -16);
      const at = _width - 2;
      // Not the middle of the module: the 1 kHz gridline of the spectrogram's
      // new frequency axis lands there, and a hairline over the field mutes
      // the very hue being asserted.
      const row = 40;

      expect(
        _isBlue(quiet, at, row),
        isTrue,
        reason: 'a quiet band is not at the cool end of the ramp',
      );
      expect(
        _isGreen(middle, at, row),
        isTrue,
        reason: 'a band halfway up the range is not green',
      );
      expect(
        _isRed(loud, at, row),
        isTrue,
        reason: 'a loud band is not at the hot end of the ramp',
      );
    });

    testWidgets('paints every row of a flat spectrum the same', (tester) async {
      // The other half of the same claim, and the one that catches a hue per
      // row: at one level across every band, a spectrogram of this ramp is one
      // colour from top to bottom. Anything that varied down the height would be
      // a colour saying what the y axis has already said.
      final pixels = await shot(tester, ColorRamp.rgb, db: -40);
      const at = _width - 2;
      // Rows spread over the plot, dodging what is not field: the time band
      // along the top and the 10k / 1k / 100 Hz gridlines of the frequency
      // axis, which mute the hue where they cross.
      for (final row in [18, 40, 75, 112]) {
        expect(
          _isGreen(pixels, at, row),
          isTrue,
          reason: 'row $row of a flat spectrum is not the colour of its level',
        );
      }
    });

    testWidgets('leaves a cell nothing reached as the ramp\'s own ground', (
      tester,
    ) async {
      // The left of the display is what the module has not measured yet, and it
      // has to be the same colour as the background painted under it, or there
      // is a seam down the picture where one becomes the other. Sampled inside
      // the plot — x 0 is the frequency axis's gutter now — and clear of the
      // gridlines, which are deliberately drawn over the field.
      final pixels = await shot(tester, ColorRamp.rgb);
      final ground = ColorRamp.rgb.groundOf(_colors);
      expect(_isInk(pixels, 40, 55), isFalse);
      expect(_r(pixels, 40, 55), (ground.r * 255).round());
      expect(_g(pixels, 40, 55), (ground.g * 255).round());
      expect(_b(pixels, 40, 55), (ground.b * 255).round());
    });
  });

  group('the oscilloscope', () {
    Future<Uint8List> shot(
      WidgetTester tester,
      ColorRamp ramp, {
      double? band,
      bool spectrum = true,
    }) async {
      final source = _Fake(spectrumAvailable: spectrum);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        _Harness(
          // See the spectrogram's. Same reason, same trap.
          key: ValueKey('$ramp$band$spectrum'),
          source: source,
          boundary: boundary,
          child: (engine, clock) => OscilloscopeModule(
            engine: engine,
            clock: clock,
            // Triggered, so the picture is one window of the tone found the
            // same way every frame and stands still between two runs.
            timeBase: ScopeTimeBase.ms20,
            ramp: ramp,
          ),
        ),
      );
      // Enough to fill the kept window, so the trigger has somewhere to search.
      for (var i = 0; i < 40; i++) {
        source.publish(band: band);
        await _frame(tester);
      }
      return _shoot(tester, boundary);
    }

    testWidgets('draws one hue at the default setting', (tester) async {
      final pixels = await shot(tester, ColorRamp.skin, band: 0.05);
      expect(
        _any(pixels, _isRed) || _any(pixels, _isBlue),
        isFalse,
        reason: 'the frequency ramp is being drawn at the default setting',
      );
      expect(_any(pixels, _isInk), isTrue, reason: 'nothing was drawn');
    });

    testWidgets('draws a bass block red and a treble block blue', (
      tester,
    ) async {
      // The same waveform both times — a 400 Hz tone at the same amplitude —
      // with the published spectrum moved from the bottom of the axis to the
      // top. Nothing about the picture changes but its colour, which is the
      // claim: the hue is the *band the energy sat in*, not the shape of the
      // trace and not its level.
      final bass = await shot(tester, ColorRamp.rgb, band: 0.05);
      expect(_any(bass, _isRed), isTrue, reason: 'a bass block is not red');
      expect(_any(bass, _isBlue), isFalse, reason: 'a bass block is blue');

      final treble = await shot(tester, ColorRamp.rgb, band: 0.85);
      expect(
        _any(treble, _isBlue),
        isTrue,
        reason: 'a treble block is not blue',
      );
      expect(_any(treble, _isRed), isFalse, reason: 'a treble block is red');
    });

    testWidgets('gives a block with no spectrum no hue at all', (tester) async {
      // A hue here is a statement about frequency, and a source that publishes
      // no spectrum has not made one. The trace falls back to the accent rather
      // than to the middle of the ramp, which would be a colour claiming a band
      // nobody measured.
      final pixels = await shot(tester, ColorRamp.rgb, spectrum: false);
      expect(_any(pixels, _isInk), isTrue, reason: 'nothing was drawn');
      expect(_any(pixels, _isRed), isFalse);
      expect(_any(pixels, _isBlue), isFalse);
    });

    testWidgets('changes the colour of the picture and nothing else', (
      tester,
    ) async {
      // The whole claim of the setting. Same source, same window, same trigger:
      // the outline of the trace has to be the same picture, or the ramp is
      // doing something to the geometry — a column sorted into the wrong
      // bucket, or a `Paint` whose stroke width came along with its colour.
      final skin = _outline(await shot(tester, ColorRamp.skin, band: 0.05));
      final rgb = _outline(await shot(tester, ColorRamp.rgb, band: 0.05));

      var compared = 0;
      for (var x = 0; x < _width; x++) {
        expect(
          skin[x] == null,
          rgb[x] == null,
          reason: 'column $x is inked in one ramp and bare in the other',
        );
        if (skin[x] == null) continue;
        compared++;
        // A pixel of tolerance: the two palettes have different luminance
        // against the panel, so an antialiased edge can round the other way.
        expect(
          (skin[x]! - rgb[x]!).abs(),
          lessThanOrEqualTo(1),
          reason: 'the trace moved in column $x: ${skin[x]} to ${rgb[x]}',
        );
      }
      expect(
        compared,
        greaterThan(_width ~/ 2),
        reason: 'too little of the width was inked for this to mean anything',
      );
    });
  });
}
