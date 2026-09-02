// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two glows, which are the only things in the application painted past the
// module frame's inset: the Number Box's, rising out of the panel's foot under
// the digits, and the Alert Meter's, rising out of the panel's left edge behind
// the reading. One shader draws both — `EdgeGlow` — and this file is the reason
// it is one: every defect below was a property of the *shape*, so a second copy
// of the shape would be a second copy of all of them.
//
// Two defects, both of them nothing but pixels, and both invisible to every
// other test in the suite:
//
//   - The wash stopped a twelve-pixel inset short of every edge. That inset is
//     a margin for *content*; light fenced inside it is a lit rectangle in a
//     dark gutter, and it reads as a clipping fault rather than as light. So
//     the module paints to the panel and `ModuleFrame` is asked for `bleed`,
//     which adds the rounded clip that keeps the wash inside the module — the
//     boundary is the frame's to hold, not the module's arithmetic.
//
//   - The gradient was a circle sized off the *width* alone, so it fell out at
//     four fifths of the height on one shape of module and nowhere at all on
//     the rest. A Number Box three times wider than it is tall sat entirely
//     inside the crown: a flat sheet of colour with the shader's own edge
//     across it. It is an ellipse scaled on both axes now, and the assertion
//     that it fades before the title rule is made on the two shapes furthest
//     from the one that used to be right.
//
// The samples are equalities rather than tolerances, and can be: a gutter
// pixel with no glow on it is exactly what the bare frame paints there,
// everything outside the panel is painted by nothing at all, and the far end
// of the ramp is clamped to a transparency that leaves the fill it lies on
// untouched. "What the bare frame paints there" is a second photograph — a
// frame of the same size with nothing in it — rather than `colors.panel`,
// because the frame lights its panel from the top-left corner and the flat
// panel colour is only what that light fades to. Every sample *was*
// `colors.panel` before the light existed, and the bare frame is the same
// claim made under it: nothing but the frame painted here.
//
// The last case is the frame's own light, and it lives here because the three
// are the only lights on a module and this file already knows how to look at
// one: brightest behind the title, since the bar is the top of the panel and
// not a strip laid over it, fading down the left edge, and gone at the far
// foot.
//
// The Alert Meter's half checks the same things about the other axis, and one
// more that is only true of it: there is no longer a rule down its left edge.
// A two-pixel stripe said what the wash says now, in a hundredth of the area
// and a gutter inside the panel's own edge — so the sample that used to assert
// the rule asserts its absence, and would fail on the stripe coming back.
//
// And one rule the two hold jointly: **a module with no reading has no light.**
// The wash is a verdict on a number, so an em dash — nothing measured yet, a
// link gone quiet, a quantity this build does not compute — leaves the panel
// dark. Lit, it says the module is doing something it is not, in the accent,
// which is the same colour it uses for a measurement that simply has no target
// to be judged against.

import 'dart:io';

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/alert_meter.dart';
import 'package:oaa/src/modules/number_box.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;

/// The margin of background photographed around the module, which is where the
/// clip is checked. Wider than the bleed it is checking for.
const double _margin = 8;

/// The frame's own inset, which is exactly how far the glow is asked to reach
/// past the body it is handed.
const double _inset = Space.smd;

class _Source implements MeterSource {
  /// Comfortably inside every streaming target, so the glow is the accent and
  /// the test is not also a test of the verdict colours. Both metrics, because
  /// the two modules do not watch the same one — the Alert Meter is a latch,
  /// and a latch is worth nothing on a number that only ever climbs to a
  /// target.
  @override
  double get lufsIntegrated => -18.0;

  @override
  double get truePeakMax => -6.0;

  /// Not measured, which is what the engine says with a NaN — the case the
  /// dark-panel test below is about.
  @override
  double get odrShort => double.nan;

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
  int get channels => 2;
  @override
  double get elapsedSeconds => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Harness extends StatefulWidget {
  const _Harness({
    required this.source,
    required this.boundary,
    required this.size,
    required this.title,
    required this.module,
  });

  final _Source source;
  final GlobalKey boundary;
  final Size size;
  final String title;

  /// The module under the frame. Built here rather than handed in as a widget
  /// so that it is given the clock this harness owns.
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
            child: Padding(
              padding: const EdgeInsets.all(_margin),
              child: SizedBox(
                width: widget.size.width,
                height: widget.size.height,
                child: ModuleFrame(
                  title: widget.title,
                  // The canvas sets this for these two kinds and no others —
                  // see `ModuleHost`.
                  bleed: true,
                  child: widget.module(widget.source, clock),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The frame with nothing in it: what every gutter sample is compared against.
Widget _bare(MeterSource source, MeterClock clock) => const SizedBox.expand();

Future<_Pixels> _frame(
  WidgetTester tester,
  Size size, {
  required String title,
}) => _photograph(tester, size, title: title, module: _bare);

/// [pixels] at ([x], [y]) is something other than what the bare [frame] paints
/// there: a glow reached it.
void _expectLit(
  _Pixels pixels,
  _Pixels frame,
  double x,
  double y,
  String why,
) => expect(pixels.at(x, y), isNot(frame.at(x, y)), reason: why);

/// [pixels] at ([x], [y]) is exactly what the bare [frame] paints there: no
/// glow reached it.
void _expectDark(
  _Pixels pixels,
  _Pixels frame,
  double x,
  double y,
  String why,
) => expect(pixels.at(x, y), frame.at(x, y), reason: why);

/// HSL lightness, which is what the frame's light is measured in.
double _lightness(Color color) => HSLColor.fromColor(color).lightness;

/// The Number Box, watching a metric comfortably in spec.
const String _boxTitle = 'LUFS-I';

Widget _box(MeterSource source, MeterClock clock) => NumberBoxModule(
  engine: source,
  clock: clock,
  metric: Metric.lufsIntegrated,
  calibration: BuiltInCalibrations.streaming,
  naming: DynamicsNaming.defaultNaming,
);

/// A module watching something this source does not measure. Both kinds take
/// one, because the rule is theirs jointly.
Widget _unmeasuredBox(MeterSource source, MeterClock clock) => NumberBoxModule(
  engine: source,
  clock: clock,
  metric: Metric.odrShort,
  calibration: BuiltInCalibrations.streaming,
  naming: DynamicsNaming.defaultNaming,
);

Widget _unmeasuredAlert(MeterSource source, MeterClock clock) =>
    AlertMeterModule(
      engine: source,
      clock: clock,
      metric: Metric.odrShort,
      calibration: BuiltInCalibrations.streaming,
      naming: DynamicsNaming.defaultNaming,
    );

/// The Alert Meter, watching a maximum the engine holds itself — the one
/// reading a latch cannot change, which is what keeps this file about the
/// light and not about the latch. See [Metric.isAccumulated].
const String _alertTitle = 'TRUE PEAK';

Widget _alert(MeterSource source, MeterClock clock) => AlertMeterModule(
  engine: source,
  clock: clock,
  metric: Metric.truePeakMax,
  calibration: BuiltInCalibrations.streaming,
  naming: DynamicsNaming.defaultNaming,
);

void main() {
  const size = Size(320, 180);

  testWidgets('the glow fills the panel to its edges and stops there', (
    tester,
  ) async {
    final frame = await _frame(tester, size, title: _boxTitle);
    final pixels = await _photograph(
      tester,
      size,
      title: _boxTitle,
      module: _box,
    );

    // Inside the frame's inset on the three sides the light actually reaches.
    // One pixel further in is the body the module has always been handed;
    // these are the gutter, where nothing but the frame paints.
    final foot = size.height + _margin - OaaStroke.hairline - 1;

    _expectLit(
      pixels,
      frame,
      _margin + size.width / 2,
      foot,
      'the glow stops short of the panel\'s foot',
    );
    _expectLit(
      pixels,
      frame,
      _margin + _inset / 2,
      foot - _inset,
      'the glow stops short of the panel\'s left edge',
    );
    _expectLit(
      pixels,
      frame,
      _margin + size.width - _inset / 2,
      foot - _inset,
      'the glow stops short of the panel\'s right edge',
    );

    // And none of it outside the module. The wash is drawn a full inset past
    // the edges, so an unclipped one lands squarely on these three samples —
    // which on the canvas is the module next door. They are *transparent*
    // rather than the background colour: the boundary photographed here sits
    // above the screen's ground, so a pixel nothing painted has no colour at
    // all, and the glow escaping is the only thing that could give it one.
    // Sampled clear of the panel's own corners, where the radius leaves a
    // blend of fill and ground that says nothing about the glow either way.
    const nothing = Color(0x00000000);

    expect(
      pixels.at(_margin / 2, foot - _inset),
      nothing,
      reason: 'the glow leaks out past the panel\'s left edge',
    );
    expect(
      pixels.at(_margin + size.width + _margin / 2, foot - _inset),
      nothing,
      reason: 'the glow leaks out past the panel\'s right edge',
    );
    expect(
      pixels.at(_margin + size.width / 2, size.height + _margin + _margin / 2),
      nothing,
      reason: 'the glow leaks out below the panel',
    );

    // The outermost pixel of the foot's left corner, which the panel's radius
    // cuts away — nothing in the frame paints there, so anything that arrives
    // is the wash's square corner standing outside the panel's round one. It
    // is the one sample the clip alone answers for: the bleed is the width of
    // the inset exactly, so along the straight edges the wash lands on the
    // panel's own outline whether it is clipped or not.
    expect(
      pixels.at(_margin, size.height + _margin - 1),
      nothing,
      reason: 'the glow squares off the panel\'s corner',
    );
  });

  // The two shapes a width-driven circle got wrong, and it got them wrong in
  // opposite directions: the chip drowned in the crown with the shader's edge
  // laid across it, and the column's light died a third of the way up a module
  // it should have climbed. Both are checked by the same three samples, which
  // is the point — the wash is a share of the module's own height now, so one
  // description fits every size.
  for (final shape in const [
    ('a chip far wider than it is tall', Size(320, 86)),
    ('a column far taller than it is wide', Size(150, 300)),
  ]) {
    testWidgets('the glow rises and falls within ${shape.$1}', (tester) async {
      final size = shape.$2;
      final frame = await _frame(tester, size, title: _boxTitle);
      final pixels = await _photograph(
        tester,
        size,
        title: _boxTitle,
        module: _box,
      );

      final foot = size.height + _margin - OaaStroke.hairline - 1;
      // Just under the rule, and along the panel's left edge rather than up
      // the middle, where the metric's name is drawn on a short module.
      final underTheRule =
          _margin + ModuleFrame.titleBarHeight + OaaStroke.hairline + 1;

      _expectLit(
        pixels,
        frame,
        _margin + size.width / 2,
        foot,
        'the glow does not reach the foot of this module',
      );
      _expectLit(
        pixels,
        frame,
        _margin + _inset / 2,
        (foot + underTheRule) / 2,
        'the glow is out before this module is halfway up',
      );
      _expectDark(
        pixels,
        frame,
        _margin + _inset / 2,
        underTheRule,
        'the glow is still lit where the module ends',
      );
    });
  }

  for (final kind in [
    ('the Number Box', _boxTitle, _unmeasuredBox),
    ('the Alert Meter', _alertTitle, _unmeasuredAlert),
  ]) {
    testWidgets('${kind.$1} goes dark when there is no reading', (
      tester,
    ) async {
      final frame = await _frame(tester, size, title: kind.$2);
      final pixels = await _photograph(
        tester,
        size,
        title: kind.$2,
        module: kind.$3,
      );

      // The two places the two washes are brightest, so whichever module this
      // is, one of them is where its light would be. The bare frame at both:
      // the glow is the only other thing that paints there, and it did not.
      final foot = size.height + _margin - OaaStroke.hairline - 1;
      final middle = _margin + (ModuleFrame.titleBarHeight + size.height) / 2;

      _expectDark(
        pixels,
        frame,
        _margin + size.width / 2,
        foot,
        'the panel is lit at its foot under a reading nobody took',
      );
      _expectDark(
        pixels,
        frame,
        _margin + _inset / 2,
        middle,
        'the panel is lit at its edge under a reading nobody took',
      );
    });
  }

  testWidgets('the Alert Meter lights its own left edge and stops there', (
    tester,
  ) async {
    final frame = await _frame(tester, size, title: _alertTitle);
    final pixels = await _photograph(
      tester,
      size,
      title: _alertTitle,
      module: _alert,
    );

    final middle = _margin + (ModuleFrame.titleBarHeight + size.height) / 2;
    final foot = size.height + _margin - OaaStroke.hairline - 1;
    final underTheRule =
        _margin + ModuleFrame.titleBarHeight + OaaStroke.hairline + 1;

    // The gutter the frame's inset leaves, which the body never reaches and
    // which nothing but the frame paints without the bleed.
    _expectLit(
      pixels,
      frame,
      _margin + _inset / 2,
      middle,
      'the glow stops short of the panel\'s left edge',
    );

    // **No rule.** The two pixels at the panel's own edge carried the latched
    // state at full strength, and now carry the crown of the wash — which is
    // the same colour at 0.28 over the fill, not the colour itself. Sampling
    // for the saturated value is what fails if the stripe returns.
    expect(
      pixels.at(_margin + 0.5, middle),
      isNot(_colors.accent),
      reason: 'the latched-state rule is back down the left edge',
    );

    // Lit for the whole height of the body rather than in a band across the
    // middle of it: the spread runs half again as far as the panel is tall, so
    // only the corners fall away.
    _expectLit(
      pixels,
      frame,
      _margin + _inset / 2,
      foot,
      'the glow does not reach the foot of this module',
    );
    _expectLit(
      pixels,
      frame,
      _margin + _inset / 2,
      underTheRule,
      'the glow does not reach the top of this module',
    );

    // And out well before the far side. The reading is drawn over this wash,
    // so a glow that crossed the module would be a module tinted end to end
    // and no light at all.
    _expectDark(
      pixels,
      frame,
      _margin + size.width - _inset / 2,
      middle,
      'the glow crosses the whole module',
    );

    // None of it outside, and the corner is the sample the clip alone answers
    // for — the bleed is exactly the width of the inset, so along the straight
    // edges the wash lands on the panel's own outline whether it is clipped or
    // not. Transparent rather than the background colour, for the reason the
    // Number Box's case gives.
    const nothing = Color(0x00000000);
    expect(
      pixels.at(_margin / 2, middle),
      nothing,
      reason: 'the glow leaks out past the panel\'s left edge',
    );
    expect(
      pixels.at(_margin, size.height + _margin - 1),
      nothing,
      reason: 'the glow squares off the panel\'s corner',
    );
  });

  testWidgets('the panel is lit from its top-left corner, title bar included', (
    tester,
  ) async {
    final frame = await _frame(tester, size, title: _boxTitle);

    // Inside the border and left of the title's first glyph, halfway down the
    // bar: the brightest place the frame paints that has no ink over it. The
    // bar is where the light has to be, because the panel is one surface and
    // the bar is the top of it.
    final corner = frame.at(
      _margin + OaaStroke.hairline + 1,
      _margin + ModuleFrame.titleBarHeight / 2,
    );
    // Halfway down the left gutter, under the body.
    final halfway = frame.at(
      _margin + _inset / 2,
      _margin + (ModuleFrame.titleBarHeight + size.height) / 2,
    );
    // The gutter at the far foot, which the light does not reach.
    final far = frame.at(
      _margin + size.width - _inset / 2,
      size.height + _margin - OaaStroke.hairline - 1,
    );

    expect(far, _colors.panel, reason: 'the far corner is lit');
    expect(
      _lightness(halfway),
      greaterThan(_lightness(far)),
      reason: 'the light does not reach halfway down the left edge',
    );
    expect(
      _lightness(corner),
      greaterThan(_lightness(halfway)),
      reason: 'the panel is not brightest behind the title',
    );
    // Most of the lift a pixel in from the corner, and never a step over it:
    // the panel's own colour lifted, not a colour of its own.
    expect(
      _lightness(corner),
      greaterThan(_lightness(_colors.panel) + OaaColors.panelLift * 0.75),
      reason: 'the corner is lit by less than the palette says',
    );
    expect(
      _lightness(corner),
      lessThanOrEqualTo(_lightness(_colors.panelLit) + 1 / 255),
      reason: 'the corner is lit by more than the palette says',
    );
  });
}

/// The module, rendered at one device pixel per logical pixel so that a sample
/// taken at a logical offset is the pixel that offset names.
Future<_Pixels> _photograph(
  WidgetTester tester,
  Size size, {
  required String title,
  required Widget Function(MeterSource, MeterClock) module,
}) async {
  await _loadFonts();
  final boundary = GlobalKey();
  await tester.pumpWidget(
    _Harness(
      source: _Source(),
      boundary: boundary,
      size: size,
      title: title,
      module: module,
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
  return _Pixels(data, render.size.width.round());
}

class _Pixels {
  const _Pixels(this._data, this._width);

  final ByteData _data;
  final int _width;

  Color at(double x, double y) {
    final offset = ((y.floor() * _width) + x.floor()) * 4;
    return Color.fromARGB(
      _data.getUint8(offset + 3),
      _data.getUint8(offset),
      _data.getUint8(offset + 1),
      _data.getUint8(offset + 2),
    );
  }
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
