// SPDX-License-Identifier: GPL-3.0-or-later
//
// The parts of the canvas that only a pointer can prove.
//
// The placement rules are covered in packages/oaa_core (grid_test.dart) and the
// edit semantics in workspace_test.dart. What is left here is everything that
// depends on real hit testing and real gesture arithmetic: that a drag by the
// title bar moves the module the pointer is over, that an overlapping drop is
// refused rather than nudged, and that the module body is not dead to the mouse
// — which it silently becomes if a painter forgets it is not a control.
//
// These run against a live engine on the silence source. That is deliberate:
// the canvas hands every module a real OaaEngine, and a fake would not exercise
// the one thing that makes this arrangement work — that measurements never pass
// through the widget tree at all.

import 'package:oaa/src/app/shortcuts.dart';
import 'package:oaa/src/canvas/grid_canvas.dart';
import 'package:oaa/src/canvas/module_host.dart';
import 'package:oaa/src/canvas/tab_strip.dart';
import 'package:oaa/src/canvas/workspace.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/spectrum_analyzer.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owns the engine and the clock for the duration of a test, exactly as the
/// real workspace does.
///
/// Not a `TestVSync` ticker created beside the widget tree: that ticker
/// outlives the tree, and the binding reports an animation still running after
/// disposal — which fails the test for a reason that has nothing to do with
/// what it was checking. Tying both to a [State] is also simply what the
/// application does, so the test exercises the same lifetime.
class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final OaaEngine engine = OaaEngine.start(source: OaaSource.silence);
  late final MeterClock clock = MeterClock(engine: engine, vsync: this);

  @override
  void dispose() {
    clock.dispose();
    engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OaaTheme(
    colors: OaaColors.precisionInstrument,
    child: Material(
      color: OaaColors.precisionInstrument.background,
      // The keyboard reaches the canvas from above it, exactly as it does in
      // the application — see lib/src/app/shortcuts.dart. Without this the
      // canvas is mouse-only, which is a fair description of what it would be
      // if somebody deleted the layer.
      child: OaaShortcuts(
        onReset: engine.reset,
        child: Column(
          children: [
            const TabStrip(),
            Expanded(
              child: GridCanvas(engine: engine, clock: clock),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Builds the canvas over a live engine and returns the container so a test can
/// read the layout back.
Future<ProviderContainer> _pump(WidgetTester tester) async {
  // The smallest window the application supports — `kMinimumWindow` in
  // `test/scaling_test.dart`, which is where that number is kept — rather than
  // the 800x600 the test binding defaults to. The canvas is a fixed 24x16 cells at every window
  // size, so the surface decides how many pixels a module gets: at 600 tall a
  // two-row Number Box has less body than a digit, and "every kind fits at its
  // default size" is a question with no answer until the window is one the
  // application would actually open. See test/scaling_test.dart.
  tester.view.physicalSize = const Size(960, 808) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: _Harness(),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Builds the canvas and switches to a **deliberately sparse** tab of the
/// tests' own making.
///
/// Not the default preset. What Open Audio Analyzer opens with is a product
/// decision — what a new user should see first — and it is dense on purpose.
/// Geometry tests that read strides off it and drag modules into the space
/// below it would fail the day somebody adds a meter, for a reason that has
/// nothing to do with dragging. Here the tests own their canvas and assert
/// geometry rather than taste.
///
/// Three number boxes at the top left, four columns apart and three rows tall,
/// with the rest of the grid empty.
Future<ProviderContainer> _pumpSparse(WidgetTester tester) async {
  final container = await _pump(tester);
  final controller = container.read(workspaceProvider.notifier);

  controller.addTab();
  for (final (index, metric) in const [
    Metric.lufsMomentary,
    Metric.lufsShort,
    Metric.loudnessRange,
  ].indexed) {
    controller.addModule(
      ModuleKind.numberBox,
      at: GridRect(column: index * 4, row: 0, columns: 4, rows: 3),
    );
    controller.setModuleOption(
      container.read(workspaceProvider).selectedModuleId!,
      'metric',
      metric.id,
    );
  }
  controller.select(null);

  await tester.pump();
  return container;
}

/// Advances time by a fixed amount.
///
/// Deliberately not `pumpAndSettle`, which never returns here: the meter clock
/// holds a [Ticker] that schedules a frame forever, by design, so the tree has
/// no settled state to wait for. Four hundred milliseconds covers a popup
/// route's transition with room to spare.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _moduleTitled(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ModuleHost));

/// The height of one grid row, in pixels, derived from a module on screen
/// rather than recomputed. The default preset's boxes are three rows tall and
/// the gutter between two modules is [Space.sm].
double _rowStride(WidgetTester tester) =>
    (tester.getRect(_moduleTitled('LUFS-M')).height + Space.sm) / 3;

/// The width of one grid column, derived from the gap between two modules that
/// are four columns apart.
double _columnStride(WidgetTester tester) =>
    (tester.getRect(_moduleTitled('LUFS-S')).left -
        tester.getRect(_moduleTitled('LUFS-M')).left) /
    4;

Offset _titleBarOf(WidgetTester tester, String title) {
  final rect = tester.getRect(_moduleTitled(title));
  // Left of centre, to stay clear of the frame's own menu button.
  return Offset(
    rect.left + rect.width / 3,
    rect.top + ModuleFrame.titleBarHeight / 2,
  );
}

/// How far below a module's top edge to aim for the touch-only part of the
/// move handle: past the painted bar, inside the target under it.
const double _belowTheBar = ModuleFrame.titleBarHeight + Space.sm;

ModuleSpec _spec(ProviderContainer container, Metric metric) => container
    .read(workspaceProvider)
    .tab
    .modules
    .firstWhere((module) => module.metric == metric);

void main() {
  testWidgets('the default preset arrives on screen', (tester) async {
    final container = await _pump(tester);
    final preset = container.read(workspaceProvider).preset;

    expect(preset.tabs, hasLength(2));
    expect(
      find.byType(ModuleHost),
      findsNWidgets(preset.tabs.first.modules.length),
    );
    expect(find.text('LUFS-I'), findsOneWidget);
    expect(find.text('TP MAX'), findsOneWidget);

    // Every module on both tabs is legible at the size the preset gives it.
    // This is the assertion that catches a default layout laid out against a
    // module's old minimum: the symptom is a new user greeted by a canvas of
    // "TOO SMALL" placeholders, and it is invisible until somebody launches
    // the app.
    for (var tab = 0; tab < preset.tabs.length; tab++) {
      container.read(workspaceProvider.notifier).selectTab(tab);
      await tester.pump();

      expect(
        find.byType(ModuleTooSmall),
        findsNothing,
        reason: 'tab "${preset.tabs[tab].name}" has a module below its minimum',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a module is selected by clicking its body, not just its bar', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);

    // The regression this guards: CustomPainter.hitTest defaults to absorbing
    // pointer events, which makes the whole face of every meter dead to the
    // mouse while the title bar still works. See MeterPainter.
    await tester.tapAt(tester.getCenter(_moduleTitled('LUFS-M')));
    await tester.pump();

    expect(
      container.read(workspaceProvider).selectedModuleId,
      _spec(container, Metric.lufsMomentary).id,
    );

    final frame = tester.widget<ModuleFrame>(
      find.ancestor(
        of: find.text('LUFS-M'),
        matching: find.byType(ModuleFrame),
      ),
    );
    expect(frame.selected, isTrue);
  });

  testWidgets('a slider on a module moves the value and not the module', (
    tester,
  ) async {
    // The oscilloscope is the one module with controls of its own, and they sit
    // *inside* a stack whose other layers all drag the module. What is checked
    // here is that the strip takes the gesture and nothing else does: an opaque
    // detector over the selection catcher, clear of the corner grip, and a
    // value written back to the layout once.
    final container = await _pumpSparse(tester);
    final controller = container.read(workspaceProvider.notifier);
    controller.addModule(
      ModuleKind.oscilloscope,
      at: const GridRect(column: 0, row: 4, columns: 12, rows: 6),
    );
    final id = container.read(workspaceProvider).selectedModuleId!;
    await tester.pump();

    final before = container.read(workspaceProvider).tab.moduleById(id)!;
    expect(before.scopeZoom, ScopeZoom.defaultScale);

    final slider = find.descendant(
      of: _moduleTitled('OSCILLOSCOPE'),
      matching: find.byType(OaaSlider),
    );
    expect(slider, findsOneWidget, reason: 'the strip is not on the module');

    await tester.drag(
      slider,
      const Offset(Space.xl, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    final after = container.read(workspaceProvider).tab.moduleById(id)!;
    expect(
      after.rect.column,
      before.rect.column,
      reason: 'dragging the slider carried the module with it',
    );
    expect(after.rect.row, before.rect.row);
    // Pressed at the middle of the track and dragged a little to the right of
    // it, so the height is above the default and short of the top.
    expect(after.scopeZoom, greaterThan(ScopeZoom.defaultScale));
    expect(after.scopeZoom, lessThan(ScopeZoom.max));
  });

  testWidgets('dragging the title bar moves the module by whole cells', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);
    final rows = _rowStride(tester);
    final id = _spec(container, Metric.lufsMomentary).id;

    expect(container.read(workspaceProvider).tab.moduleById(id)!.rect.row, 0);

    await tester.dragFrom(
      _titleBarOf(tester, 'LUFS-M'),
      Offset(0, rows * 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    // Exactly three rows, not two and not four. The pan slop would eat the
    // first 36 pixels of this drag if the detectors did not use
    // DragStartBehavior.down, and the module would land a row short.
    expect(container.read(workspaceProvider).tab.moduleById(id)!.rect.row, 3);
  });

  testWidgets('a two-finger trackpad gesture drags nothing', (tester) async {
    final container = await _pumpSparse(tester);
    final rows = _rowStride(tester);
    final id = _spec(container, Metric.lufsMomentary).id;
    final handle = _titleBarOf(tester, 'LUFS-M');

    // A trackpad pan is not a button press, so a drag recogniser's button
    // filter never sees it: it arrives as a pan-zoom sequence, which
    // `supportedDevices` alone admits, and it is accepted on the *start* event
    // with no slop to cross. On macOS a two-finger tap is how a trackpad sends
    // a right click, so this fired whenever somebody opened a module's menu —
    // the placement grid flashed on screen — and a two-finger scroll over a
    // title bar moved the module. See `kDragDevices`.
    final bar = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await bar.panZoomStart(handle);
    await bar.panZoomUpdate(handle, pan: Offset(0, rows * 3));
    await tester.pump();
    await bar.panZoomEnd();
    await tester.pump();

    expect(container.read(workspaceProvider).tab.moduleById(id)!.rect.row, 0);
    // A drag selects the module it picks up, so an untouched selection is the
    // other half of "nothing began".
    expect(container.read(workspaceProvider).selectedModuleId, isNull);

    // The corner grip is a second detector with the same hole in it.
    final corner =
        tester.getRect(_moduleTitled('LUFS-M')).bottomRight -
        const Offset(Space.sm, Space.sm);
    final grip = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await grip.panZoomStart(corner);
    await grip.panZoomUpdate(corner, pan: Offset(0, rows * 3));
    await tester.pump();
    await grip.panZoomEnd();
    await tester.pump();

    expect(container.read(workspaceProvider).tab.moduleById(id)!.rect.rows, 3);

    // And the two touch layers beneath them, which admit an even narrower set.
    // A trackpad is not in `kTouchDragDevices` by construction rather than by
    // exclusion, but this is the test that would catch somebody widening it.
    final rect = tester.getRect(_moduleTitled('LUFS-M'));
    for (final point in [
      Offset(rect.left + rect.width / 3, rect.top + _belowTheBar),
      rect.bottomRight - const Offset(Space.lg, Space.lg),
    ]) {
      final touch = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await touch.panZoomStart(point);
      await touch.panZoomUpdate(point, pan: Offset(0, rows * 3));
      await tester.pump();
      await touch.panZoomEnd();
      await tester.pump();
    }

    final unmoved = container.read(workspaceProvider).tab.moduleById(id)!.rect;
    expect(unmoved.row, 0);
    expect(unmoved.rows, 3);
  });

  testWidgets('alt-dragging leaves the original behind and drops a copy', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);
    final rows = _rowStride(tester);
    final id = _spec(container, Metric.lufsMomentary).id;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.dragFrom(
      _titleBarOf(tester, 'LUFS-M'),
      Offset(0, rows * 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    final workspace = container.read(workspaceProvider);
    expect(workspace.tab.modules, hasLength(4));

    // The original has not moved. That is the whole difference between this
    // and a plain drag, and getting it backwards would silently destroy a
    // layout the user was trying to extend.
    expect(workspace.tab.moduleById(id)!.rect.row, 0);

    final copy = workspace.tab.moduleById(workspace.selectedModuleId!)!;
    expect(copy.id, isNot(id));
    expect(copy.rect.row, 3);
    expect(copy.metric, Metric.lufsMomentary);
  });

  testWidgets('a drop that would overlap is refused, and nothing moves', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);
    final columns = _columnStride(tester);
    final id = _spec(container, Metric.lufsMomentary).id;
    final before = container.read(workspaceProvider).tab.moduleById(id)!.rect;

    // One column right puts it under its neighbour.
    await tester.dragFrom(
      _titleBarOf(tester, 'LUFS-M'),
      Offset(columns, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(container.read(workspaceProvider).tab.moduleById(id)!.rect, before);
  });

  testWidgets('the corner grip resizes without moving the module', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);
    final rows = _rowStride(tester);
    final rect = tester.getRect(_moduleTitled('LUFS-M'));
    final id = _spec(container, Metric.lufsMomentary).id;

    await tester.dragFrom(
      rect.bottomRight - const Offset(Space.sm, Space.sm),
      Offset(0, rows * 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    final after = container.read(workspaceProvider).tab.moduleById(id)!.rect;
    expect(after.rows, 6);
    expect(after.column, 0);
    expect(after.row, 0);
  });

  // --- The targets a finger gets, and the ones it does not ------------------
  //
  // Both affordances draw less than they accept, for touch and stylus only. The
  // pairs below are the whole contract: the finger case proves the enlarged
  // target exists, and the mouse case beside it proves it was not handed to a
  // pointer that never needed it. See `kTouchDragDevices`.

  testWidgets('a finger resizes from outside the painted grip', (tester) async {
    final container = await _pumpSparse(tester);
    final rows = _rowStride(tester);
    final rect = tester.getRect(_moduleTitled('LUFS-M'));
    final id = _spec(container, Metric.lufsMomentary).id;

    // Clear of the sixteen pixels the ticks live in, inside the thirty-two a
    // finger gets. Nothing is drawn here.
    await tester.dragFrom(
      rect.bottomRight - const Offset(Space.lg, Space.lg),
      Offset(0, rows * 3),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();

    expect(container.read(workspaceProvider).tab.moduleById(id)!.rect.rows, 6);
  });

  testWidgets('a mouse outside the painted grip resizes nothing', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);
    final rows = _rowStride(tester);
    final rect = tester.getRect(_moduleTitled('LUFS-M'));
    final id = _spec(container, Metric.lufsMomentary).id;

    await tester.dragFrom(
      rect.bottomRight - const Offset(Space.lg, Space.lg),
      Offset(0, rows * 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(container.read(workspaceProvider).tab.moduleById(id)!.rect.rows, 3);
    // A resize selects what it picks up, so an untouched selection is the other
    // half of "nothing began".
    expect(container.read(workspaceProvider).selectedModuleId, isNull);
  });

  testWidgets('a finger moves the module from below the title bar', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);
    final rows = _rowStride(tester);
    final rect = tester.getRect(_moduleTitled('LUFS-M'));
    final id = _spec(container, Metric.lufsMomentary).id;

    await tester.dragFrom(
      Offset(rect.left + rect.width / 3, rect.top + _belowTheBar),
      Offset(0, rows * 3),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();

    final after = container.read(workspaceProvider).tab.moduleById(id)!.rect;
    expect(after.row, 3);
    expect(after.rows, 3);
  });

  testWidgets('a mouse below the title bar moves nothing', (tester) async {
    final container = await _pumpSparse(tester);
    final rows = _rowStride(tester);
    final rect = tester.getRect(_moduleTitled('LUFS-M'));
    final id = _spec(container, Metric.lufsMomentary).id;

    // The body stays reserved for the pointer that can hit a title bar. See
    // the note on the drag strip in grid_canvas.dart.
    await tester.dragFrom(
      Offset(rect.left + rect.width / 3, rect.top + _belowTheBar),
      Offset(0, rows * 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(container.read(workspaceProvider).tab.moduleById(id)!.rect.row, 0);
    expect(container.read(workspaceProvider).selectedModuleId, isNull);
  });

  testWidgets('a tap on the grip selects the module', (tester) async {
    final container = await _pumpSparse(tester);
    final rect = tester.getRect(_moduleTitled('LUFS-M'));

    // The grip is opaque, so it takes this hit from the selection catcher
    // underneath it. Before it had an onTap of its own, the corner of every
    // module was the one place a tap did nothing at all.
    await tester.tapAt(rect.bottomRight - const Offset(Space.sm, Space.sm));
    await tester.pump();

    expect(
      container.read(workspaceProvider).selectedModuleId,
      _spec(container, Metric.lufsMomentary).id,
    );
  });

  testWidgets('the cursor still admits only what a mouse can grab', (
    tester,
  ) async {
    await _pumpSparse(tester);
    final rect = tester.getRect(_moduleTitled('LUFS-M'));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    Future<MouseCursor> cursorAt(Offset point) async {
      await mouse.moveTo(point);
      await tester.pump();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;
    }

    // The painted affordances keep their cursors.
    expect(
      await cursorAt(_titleBarOf(tester, 'LUFS-M')),
      SystemMouseCursors.move,
    );
    expect(
      await cursorAt(rect.bottomRight - const Offset(Space.sm, Space.sm)),
      SystemMouseCursors.resizeDownRight,
    );

    // The touch-only margins around them do not, and that is the point: a
    // cursor that promised a drag the mouse cannot start would be a worse lie
    // than the small target it replaced. Neither touch layer takes a
    // `MouseRegion`, and this is what says so.
    expect(
      await cursorAt(
        Offset(rect.left + rect.width / 3, rect.top + _belowTheBar),
      ),
      SystemMouseCursors.basic,
    );
    expect(
      await cursorAt(rect.bottomRight - const Offset(Space.lg, Space.lg)),
      SystemMouseCursors.basic,
    );
  });

  testWidgets('the touch targets are clamped out of the title bar', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);

    // Short enough that an unclamped thirty-two pixel grip would reach the
    // title bar, where it sits above the frame and would take both the menu
    // button and the move strip — a drag by the bar would resize.
    tester.view.physicalSize = const Size(960, 360) * 3;
    await tester.pump();

    final rect = tester.getRect(_moduleTitled('LUFS-M'));

    // Four pixels below where an unclamped grip's top edge would fall, and left
    // of the frame's own menu button. The clamp is what keeps this in the title
    // bar rather than in the corner target.
    final aim = Offset(
      rect.right - Space.lg,
      rect.bottom - Space.xl + Space.xs,
    );
    expect(
      aim.dy - rect.top,
      lessThan(ModuleFrame.titleBarHeight),
      reason:
          'this case is vacuous unless an unclamped touch grip would reach '
          'into the title bar; make the window shorter, not the assertion '
          'weaker',
    );

    final rows = _rowStride(tester);
    final id = _spec(container, Metric.lufsMomentary).id;

    await tester.dragFrom(
      aim,
      Offset(0, rows * 3),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();

    final after = container.read(workspaceProvider).tab.moduleById(id)!.rect;
    expect(after.row, 3, reason: 'the bar should still move the module');
    expect(after.rows, 3, reason: 'and never resize it');
  });

  testWidgets('right-clicking empty canvas adds a module where you clicked', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);

    // Below the six default boxes, which occupy the top three rows.
    final canvas = tester.getRect(find.byType(GridCanvas));
    await tester.tapAt(
      Offset(canvas.left + canvas.width / 4, canvas.bottom - canvas.height / 4),
      buttons: kSecondaryButton,
    );
    await _settle(tester);

    expect(find.textContaining('Spectrum Analyzer'), findsOneWidget);
    await tester.tap(find.textContaining('Spectrum Analyzer'));
    await _settle(tester);

    final workspace = container.read(workspaceProvider);
    expect(workspace.tab.modules, hasLength(4));

    final added = workspace.tab.moduleById(workspace.selectedModuleId!)!;
    expect(added.kind, ModuleKind.spectrumAnalyzer);
    expect(added.rect.row, greaterThanOrEqualTo(3));

    // And it is a real analyser, not a placeholder. Every one of the fourteen
    // kinds the menu offers now draws something.
    expect(find.byType(SpectrumAnalyzerModule), findsOneWidget);
  });

  // The three tests below pump **one frame with no elapsed time** on purpose.
  // Both of these gestures used to be double clicks, and a
  // `DoubleTapGestureRecognizer` holds the gesture arena from the first tap
  // until `kDoubleTapTimeout` expires — a held arena is never swept, so the
  // tap recogniser underneath could not be resolved for 300 ms. Every one of
  // these assertions passed with a `pump(Duration(milliseconds: 400))` while
  // the application felt broken to use. Advance no time and the wait is the
  // failure.

  testWidgets('long-pressing empty canvas adds a module where you pressed', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);

    // The route a tablet takes: there is no second mouse button there, and
    // this replaced the double tap that used to be the answer.
    final canvas = tester.getRect(find.byType(GridCanvas));
    await tester.longPressAt(
      Offset(canvas.left + canvas.width / 4, canvas.bottom - canvas.height / 4),
    );
    await _settle(tester);

    await tester.tap(find.textContaining('Spectrum Analyzer'));
    await _settle(tester);

    final workspace = container.read(workspaceProvider);
    expect(workspace.tab.modules, hasLength(4));
    expect(
      workspace.tab.moduleById(workspace.selectedModuleId!)!.rect.row,
      greaterThanOrEqualTo(3),
    );
  });

  testWidgets('clicking empty canvas clears the selection at once', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);
    final selected = _spec(container, Metric.loudnessRange).id;
    container.read(workspaceProvider.notifier).select(selected);
    await tester.pump();

    final canvas = tester.getRect(find.byType(GridCanvas));
    await tester.tapAt(
      Offset(canvas.left + canvas.width / 4, canvas.bottom - canvas.height / 4),
    );
    await tester.pump();

    expect(container.read(workspaceProvider).selectedModuleId, isNull);
  });

  testWidgets('a tab switches at once, and long-pressing one opens its menu', (
    tester,
  ) async {
    final container = await _pump(tester);
    final tabs = container.read(workspaceProvider).preset.tabs;
    expect(tabs.length, greaterThan(1));
    expect(container.read(workspaceProvider).activeTab, 0);

    final second = find.descendant(
      of: find.byType(TabStrip),
      matching: find.text(tabs[1].name.toUpperCase()),
    );

    await tester.tap(second);
    await tester.pump();
    expect(container.read(workspaceProvider).activeTab, 1);

    // The menu is what a long press opens now — rename was a double click, and
    // a tablet could reach neither it nor duplicate and delete.
    await tester.longPress(second);
    await _settle(tester);
    expect(find.text('Rename'), findsOneWidget);

    await tester.tap(find.text('Rename'));
    await _settle(tester);
    expect(find.byType(EditableText), findsOneWidget);
  });

  testWidgets('every module kind the menu offers actually builds', (
    tester,
  ) async {
    // The exhaustive switch in ModuleHost makes *omitting* a kind a compile
    // error, which is most of the protection. What it cannot catch is a
    // painter that throws on its first frame — a null label cache, a division
    // by a zero-height module — so every kind is placed and painted here.
    //
    // One tab per kind, because fourteen modules at their default sizes do not
    // fit on one and the canvas would correctly refuse half of them.
    final container = await _pump(tester);
    final controller = container.read(workspaceProvider.notifier);

    for (final kind in ModuleKind.values) {
      controller.addTab();
      controller.addModule(kind);
      await _settle(tester);

      expect(
        tester.takeException(),
        isNull,
        reason: '${kind.label} threw while painting',
      );
      expect(
        find.byType(ModuleHost),
        findsOneWidget,
        reason: '${kind.label} did not reach the canvas',
      );
      expect(
        find.byType(ModuleTooSmall),
        findsNothing,
        reason: '${kind.label} does not fit at its own default size',
      );
    }
  });

  testWidgets('delete removes the selection and undo brings it back', (
    tester,
  ) async {
    final container = await _pumpSparse(tester);

    await tester.tapAt(tester.getCenter(_moduleTitled('LRA')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(find.byType(ModuleHost), findsNWidgets(2));
    expect(find.text('LRA'), findsNothing);
    expect(container.read(workspaceProvider).selectedModuleId, isNull);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.text('LRA'), findsOneWidget);
  });

  testWidgets('a new tab is empty, and says so', (tester) async {
    final container = await _pump(tester);
    final before = container.read(workspaceProvider).preset.tabs.length;
    final firstTab = container.read(workspaceProvider).tab.modules.length;

    // By tooltip, not by glyph. Two controls in the strip are a `+` — this one
    // and the plus inside `+ MODULE` — and `find.text('+')` matched both the
    // day the second stopped being part of one string.
    await tester.tap(find.byTooltip('New tab'));
    await _settle(tester);

    expect(container.read(workspaceProvider).activeTab, before);
    expect(find.byType(ModuleHost), findsNothing);
    expect(find.text('EMPTY TAB'), findsOneWidget);

    // Back to the first tab by keyboard, as Decibel does it.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump();

    expect(container.read(workspaceProvider).activeTab, 0);
    expect(find.byType(ModuleHost), findsNWidgets(firstTab));
  });
}
