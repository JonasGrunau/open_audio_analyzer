// SPDX-License-Identifier: GPL-3.0-or-later
//
// The parts of the canvas that only a pointer can prove.
//
// The placement rules are covered in packages/bel_core (grid_test.dart) and the
// edit semantics in workspace_test.dart. What is left here is everything that
// depends on real hit testing and real gesture arithmetic: that a drag by the
// title bar moves the module the pointer is over, that an overlapping drop is
// refused rather than nudged, and that the module body is not dead to the mouse
// — which it silently becomes if a painter forgets it is not a control.
//
// These run against a live engine on the silence source. That is deliberate:
// the canvas hands every module a real BelEngine, and a fake would not exercise
// the one thing that makes this arrangement work — that measurements never pass
// through the widget tree at all.

import 'package:bel/src/canvas/grid_canvas.dart';
import 'package:bel/src/canvas/module_host.dart';
import 'package:bel/src/canvas/tab_strip.dart';
import 'package:bel/src/canvas/workspace.dart';
import 'package:bel/src/clock/meter_clock.dart';
import 'package:bel_core/bel_core.dart';
import 'package:bel_engine/bel_engine.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/gestures.dart';
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
  late final BelEngine engine = BelEngine.start(source: BelSource.silence);
  late final MeterClock clock = MeterClock(engine: engine, vsync: this);

  @override
  void dispose() {
    clock.dispose();
    engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BelTheme(
    colors: BelColors.precisionInstrument,
    child: Material(
      color: BelColors.precisionInstrument.background,
      child: Column(
        children: [
          const TabStrip(),
          Expanded(
            child: GridCanvas(engine: engine, clock: clock),
          ),
        ],
      ),
    ),
  );
}

/// Builds the canvas over a live engine and returns the container so a test can
/// read the layout back.
Future<ProviderContainer> _pump(WidgetTester tester) async {
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

ModuleSpec _spec(ProviderContainer container, Metric metric) => container
    .read(workspaceProvider)
    .tab
    .modules
    .firstWhere((module) => module.metric == metric);

void main() {
  testWidgets('the default preset arrives on screen', (tester) async {
    await _pump(tester);

    expect(find.byType(ModuleHost), findsNWidgets(6));
    expect(find.text('LUFS-I'), findsOneWidget);
    expect(find.text('TP MAX'), findsOneWidget);

    // No module says "too small" at the default window size. A minimum that
    // the default layout violates would greet every new user with six
    // placeholders.
    expect(find.byType(ModuleTooSmall), findsNothing);
  });

  testWidgets('a module is selected by clicking its body, not just its bar', (
    tester,
  ) async {
    final container = await _pump(tester);

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

  testWidgets('dragging the title bar moves the module by whole cells', (
    tester,
  ) async {
    final container = await _pump(tester);
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

  testWidgets('alt-dragging leaves the original behind and drops a copy', (
    tester,
  ) async {
    final container = await _pump(tester);
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
    expect(workspace.tab.modules, hasLength(7));

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
    final container = await _pump(tester);
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
    final container = await _pump(tester);
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

  testWidgets('right-clicking empty canvas adds a module where you clicked', (
    tester,
  ) async {
    final container = await _pump(tester);

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
    expect(workspace.tab.modules, hasLength(7));

    final added = workspace.tab.moduleById(workspace.selectedModuleId!)!;
    expect(added.kind, ModuleKind.spectrumAnalyzer);
    expect(added.rect.row, greaterThanOrEqualTo(3));

    // And it is honest about not existing yet rather than showing an empty
    // panel, which reads as a meter that is broken.
    expect(find.text('NOT BUILT YET'), findsOneWidget);
  });

  testWidgets('delete removes the selection and undo brings it back', (
    tester,
  ) async {
    final container = await _pump(tester);

    await tester.tapAt(tester.getCenter(_moduleTitled('LRA')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(find.byType(ModuleHost), findsNWidgets(5));
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

    await tester.tap(find.text('+'));
    await _settle(tester);

    expect(container.read(workspaceProvider).activeTab, 1);
    expect(find.byType(ModuleHost), findsNothing);
    expect(find.text('EMPTY TAB'), findsOneWidget);

    // Back to the first tab by keyboard, as Decibel does it.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump();

    expect(container.read(workspaceProvider).activeTab, 0);
    expect(find.byType(ModuleHost), findsNWidgets(6));
  });
}
