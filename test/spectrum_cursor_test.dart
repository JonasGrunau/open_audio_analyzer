// SPDX-License-Identifier: GPL-3.0-or-later
//
// The analyser's cursor: where a press puts it, what moves it, what dismisses
// it, and that it is drawn at all.
//
// The last one is the test that matters most and looks least like it. The
// clock notifies a painter only when the engine has published a new frame, so
// a cursor whose only repaint source was the clock would appear the next time
// the signal moved and not before — invisible on a stopped device or a
// finished file, and indistinguishable from a press that did nothing. The
// source below publishes only when told to, so the picture can be compared
// across a press with the engine's generation held still.
//
// The catcher behind the module is the canvas's: an opaque tap detector that
// selects the module and opens its menu. The cursor takes its input through a
// translucent `Listener` so that a press on the plot still reaches it, and the
// harness lays one under the frame to prove that it does.

import 'dart:async';

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/spectrum_analyzer.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;
const Size _size = Size(420, 260);

class _Source implements MeterSource {
  _Source() {
    _spectrum.fillRange(0, _spectrum.length, -20);
  }

  final Float32List _spectrum = Float32List(MeterShape.spectrumBands);

  /// Advances only when [publish] is called, so a test can hold the engine
  /// still across a press.
  int _generation = 1;
  double _elapsed = 0;

  void publish() {
    _generation++;
    _elapsed += 1 / 47;
  }

  @override
  Float32List spectrumOf(SpectrumSource source) => _spectrum;
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
    required this.cursor,
    required this.boundary,
    required this.onSelect,
    this.group,
  });

  final _Source source;
  final SpectrumCursor cursor;
  final GlobalKey boundary;
  final VoidCallback onSelect;

  /// When set, the frame stands in a canvas slot's tap group of this id — the
  /// arrangement `_ModuleSlot` builds — so the module's own chrome is not
  /// "away" from its cursor. Null is the remote display: no slot, no group.
  final Object? group;

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
  Widget build(BuildContext context) {
    Widget module = SpectrumAnalyzerModule(
      engine: widget.source,
      clock: clock,
      cursor: widget.cursor,
      response: SpectrumResponse.fast,
      tilt: SpectrumTilt.db0,
    );
    final group = widget.group;
    if (group != null) module = ModuleTapGroup(id: group, child: module);

    Widget slot = Stack(
      fit: StackFit.expand,
      children: [
        // The canvas's select-and-menu catcher, behind the module.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
        ),
        ModuleFrame(title: 'SPECTRUM', child: module),
      ],
    );
    if (group != null) slot = TapRegion(groupId: group, child: slot);

    return MaterialApp(
      home: OaaTheme(
        colors: _colors,
        child: Material(
          color: _colors.background,
          // A press on bare `Material` hits nothing, and the tap-region
          // surface ignores a press that hit nothing — so the window has a
          // floor, as the application's does.
          child: ColoredBox(
            color: _colors.background,
            child: Center(
              child: RepaintBoundary(
                key: widget.boundary,
                child: SizedBox(
                  width: _size.width,
                  height: _size.height,
                  child: slot,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The plot, in global coordinates — the input layer is laid over exactly it.
Rect _plot(WidgetTester tester) => tester.getRect(
  find.descendant(
    of: find.byType(SpectrumAnalyzerModule),
    matching: find.byType(Listener),
  ),
);

/// Where a press [fraction] of the way across the plot lands, and the band the
/// module should put the cursor on for it.
Offset _across(Rect plot, double fraction) =>
    Offset(plot.left + plot.width * fraction, plot.center.dy);
int _bandAt(double fraction) => (fraction * MeterShape.spectrumBands).floor();

/// The centre of [band], where the cursor's line is drawn.
double _xOf(Rect plot, int band) =>
    plot.left + (band + 0.5) * plot.width / MeterShape.spectrumBands;

Future<Uint8List> _picture(WidgetTester tester, GlobalKey boundary) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late Uint8List bytes;
  await tester.runAsync(() async {
    final image = await render.toImage();
    bytes = (await image.toByteData())!.buffer.asUint8List();
    image.dispose();
  });
  return bytes;
}

void main() {
  late _Source source;
  late SpectrumCursor cursor;
  late GlobalKey boundary;
  var selected = 0;

  Future<void> mount(WidgetTester tester, {Object? group}) async {
    source = _Source();
    cursor = SpectrumCursor();
    boundary = GlobalKey();
    selected = 0;
    await tester.pumpWidget(
      _Harness(
        source: source,
        cursor: cursor,
        boundary: boundary,
        onSelect: () => selected++,
        group: group,
      ),
    );
    // One published frame, so the buffers hold the signal.
    source.publish();
    await tester.pump(const Duration(milliseconds: 32));
  }

  testWidgets('a press places the cursor on the band under it, and the '
      'canvas behind the module still sees the press', (tester) async {
    await mount(tester);
    final plot = _plot(tester);

    await tester.tapAt(_across(plot, 0.4));
    await tester.pump();

    expect(cursor.band, _bandAt(0.4));
    expect(selected, 1, reason: 'the press did not reach the catcher behind');
  });

  testWidgets('a drag carries it, and off the end it parks on the last band', (
    tester,
  ) async {
    await mount(tester);
    final plot = _plot(tester);

    final gesture = await tester.startGesture(_across(plot, 0.3));
    expect(cursor.band, _bandAt(0.3));

    await gesture.moveTo(_across(plot, 0.6));
    expect(cursor.band, _bandAt(0.6));

    await gesture.moveTo(Offset(plot.right + 40, plot.center.dy));
    expect(cursor.band, MeterShape.spectrumBands - 1);

    await gesture.up();
    expect(cursor.band, MeterShape.spectrumBands - 1);
  });

  testWidgets('a press on the line dismisses it, a press beside it moves it', (
    tester,
  ) async {
    await mount(tester);
    final plot = _plot(tester);

    await tester.tapAt(_across(plot, 0.5), kind: PointerDeviceKind.mouse);
    final placed = cursor.band!;

    // Two pixels off the line, with a mouse: on it, for a hairline.
    await tester.tapAt(
      Offset(_xOf(plot, placed) + 2, plot.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    expect(cursor.band, isNull);

    await tester.tapAt(_across(plot, 0.5), kind: PointerDeviceKind.mouse);
    expect(cursor.band, placed);

    // Twenty pixels off it is a new place, not a dismissal — with a finger
    // too, whose slop is eighteen.
    await tester.tapAt(Offset(_xOf(plot, placed) + 20, plot.center.dy));
    expect(cursor.band, isNotNull);
    expect(cursor.band, isNot(placed));
  });

  testWidgets('a press away from the plot dismisses it, on the press', (
    tester,
  ) async {
    await mount(tester);
    final plot = _plot(tester);
    await tester.tapAt(_across(plot, 0.5));
    expect(cursor.band, isNotNull);

    // With no slot around it — the remote display — the module's own title
    // bar is away. Held rather than tapped: it is the press that dismisses.
    final frame = tester.getRect(find.byType(ModuleFrame));
    final gesture = await tester.startGesture(
      Offset(frame.center.dx, frame.top + ModuleFrame.titleBarHeight / 2),
    );
    expect(cursor.band, isNull);
    await gesture.up();
  });

  testWidgets('in its module\'s group, its own chrome is not away', (
    tester,
  ) async {
    await mount(tester, group: 'the-module');
    final plot = _plot(tester);
    await tester.tapAt(_across(plot, 0.5));
    final placed = cursor.band;
    expect(placed, isNotNull);

    // The title bar is the module: a press there — a drag, say — keeps the
    // cursor where it was.
    final frame = tester.getRect(find.byType(ModuleFrame));
    await tester.tapAt(
      Offset(frame.center.dx, frame.top + ModuleFrame.titleBarHeight / 2),
    );
    expect(cursor.band, placed);

    // Off the module altogether is away.
    await tester.tapAt(Offset(frame.left - 20, frame.top - 20));
    expect(cursor.band, isNull);
  });

  testWidgets('a press on a menu or panel standing above is not away', (
    tester,
  ) async {
    await mount(tester);
    final plot = _plot(tester);
    await tester.tapAt(_across(plot, 0.5));
    final placed = cursor.band;

    // A route above the module, as its menu and every panel are, filling the
    // window with something a press can hit.
    final context = tester.element(find.byType(SpectrumAnalyzerModule));
    final navigator = Navigator.of(context);
    unawaited(
      navigator.push(
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (_, _, _) => const ColoredBox(color: Color(0x80000000)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tapAt(Offset(plot.left - 20, plot.top - 20));
    expect(cursor.band, placed, reason: 'the press was the route\'s, not away');

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(Offset(plot.left - 20, plot.top - 20));
    expect(cursor.band, isNull);
  });

  testWidgets('a secondary press is the module menu and places nothing', (
    tester,
  ) async {
    await mount(tester);
    final plot = _plot(tester);

    await tester.tapAt(
      _across(plot, 0.5),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    expect(cursor.band, isNull);
  });

  testWidgets('the cursor is drawn without a new frame from the engine', (
    tester,
  ) async {
    await mount(tester);
    final plot = _plot(tester);
    final before = await _picture(tester, boundary);

    // The engine publishes nothing from here on; only the cursor moves.
    await tester.tapAt(_across(plot, 0.5), kind: PointerDeviceKind.mouse);
    await tester.pump();
    final withCursor = await _picture(tester, boundary);
    expect(
      listEquals(withCursor, before),
      isFalse,
      reason:
          'the press left the picture unchanged — the cursor waited for '
          'the clock, which had nothing new to say',
    );

    await tester.tapAt(_xOfPlaced(plot, cursor), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(cursor.band, isNull);
    final after = await _picture(tester, boundary);
    expect(
      listEquals(after, before),
      isTrue,
      reason:
          'dismissing the cursor did not restore the picture it was placed '
          'on',
    );
  });
}

Offset _xOfPlaced(Rect plot, SpectrumCursor cursor) =>
    Offset(_xOf(plot, cursor.band!), plot.center.dy);
