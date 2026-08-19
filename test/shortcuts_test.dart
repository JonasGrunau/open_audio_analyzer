// SPDX-License-Identifier: GPL-3.0-or-later
//
// The keyboard, and the one document that describes it.
//
// Two kinds of test live here, guarding different things.
//
// The first group is about the *table* in lib/src/app/shortcuts.dart: that no
// two shortcuts claim the same chord, and that docs/site/keyboard.md still says
// what the table says. Neither is catchable by using the application — a
// duplicated chord fires both callbacks in an order nobody chose, and a stale
// documentation page is only ever wrong on somebody else's machine.
//
// The second group drives real keys at a real widget tree, because the
// interesting part of a shortcut layer is not that a callback runs. It is where
// it runs *from*: above the canvas rather than inside it, so a shortcut still
// works when focus has wandered off it, and standing aside when the thing with
// focus is a text field.

import 'dart:io';

import 'package:oaa/src/app/shortcuts.dart';
import 'package:oaa/src/canvas/canvas_notice.dart';
import 'package:oaa/src/canvas/grid_canvas.dart';
import 'package:oaa/src/canvas/tab_strip.dart';
import 'package:oaa/src/canvas/workspace.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The application's own arrangement: the shortcut layer above something that
/// is not the canvas, the tab strip and the canvas.
///
/// The something matters. Half of what is under test here is that a key pressed
/// while focus is elsewhere still reaches the canvas — which is exactly what
/// the canvas-local bindings could not do.
class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final OaaEngine engine = OaaEngine.start(source: OaaSource.silence);
  late final MeterClock clock = MeterClock(engine: engine, vsync: this);

  /// Stands in for the status bar: focusable, and not the canvas.
  final FocusNode elsewhere = FocusNode(debugLabel: 'elsewhere');

  int resets = 0;

  @override
  void dispose() {
    elsewhere.dispose();
    clock.dispose();
    engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OaaTheme(
    colors: OaaColors.precisionInstrument,
    child: Material(
      color: OaaColors.precisionInstrument.background,
      child: OaaShortcuts(
        onReset: () {
          resets++;
        },
        child: Column(
          children: [
            SizedBox(
              height: 24,
              child: Focus(
                focusNode: elsewhere,
                child: const SizedBox.expand(),
              ),
            ),
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

Future<(ProviderContainer, _HarnessState)> _pump(WidgetTester tester) async {
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

  return (container, tester.state<_HarnessState>(find.byType(_Harness)));
}

/// A tab of the test's own making: one module, with room on every side of it.
Future<(ProviderContainer, _HarnessState)> _pumpOneModule(
  WidgetTester tester,
) async {
  final (container, state) = await _pump(tester);
  final controller = container.read(workspaceProvider.notifier);

  controller.addTab();
  controller.addModule(
    ModuleKind.numberBox,
    at: const GridRect(column: 4, row: 4, columns: 4, rows: 2),
  );
  await tester.pump();
  return (container, state);
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool shift = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// The canvas holds a live `MeterClock`, so `pumpAndSettle` never settles —
/// there is always another frame scheduled. Two pumps past any transition is
/// what the canvas tests use and what the application actually does.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

GridRect _rectOf(ProviderContainer container) =>
    container.read(workspaceProvider).tab.modules.single.rect;

String _idOf(ProviderContainer container) =>
    container.read(workspaceProvider).tab.modules.single.id;

void main() {
  group('the table', () {
    test('no chord is claimed twice', () {
      // Two shortcuts on one chord is not a compile error and not visible in
      // use: CallbackShortcuts invokes every binding that matches, so both fire,
      // in map order. The symptom is a keystroke that does two things, one of
      // which nobody asked for.
      final seen = <String, String>{};

      for (final shortcut in oaaShortcuts) {
        for (final chord in shortcut.chords) {
          for (final activator in chord.activators) {
            final key =
                '${activator.trigger.keyId}'
                ' ctrl=${activator.control}'
                ' meta=${activator.meta}'
                ' shift=${activator.shift}'
                ' alt=${activator.alt}';
            expect(
              seen[key],
              isNull,
              reason:
                  '"${shortcut.description}" and "${seen[key]}" both claim '
                  '${chord.label(apple: false)}',
            );
            seen[key] = shortcut.description;
          }
        }
      }
    });

    test('every shortcut has somewhere to be printed', () {
      for (final shortcut in oaaShortcuts) {
        expect(shortcut.chords, isNotEmpty, reason: shortcut.description);
        expect(shortcut.keys(apple: true), isNotEmpty);
        expect(shortcut.keys(apple: false), isNotEmpty);
        // A trailing full stop reads as prose in a table of fragments. Cheap to
        // assert, and invisible in review.
        expect(shortcut.description, isNot(endsWith('.')));
      }
    });

    test('docs/site/keyboard.md is what the table says', () {
      final file = File('docs/site/keyboard.md');
      final generated = shortcutsMarkdown();

      // The regeneration path, and the whole workflow: change a binding, run
      // the suite with UPDATE_DOCS=1, commit the diff beside the change.
      if (Platform.environment['UPDATE_DOCS'] == '1') {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(generated);
        return;
      }

      const how = 'Run: UPDATE_DOCS=1 flutter test test/shortcuts_test.dart';

      expect(
        file.existsSync(),
        isTrue,
        reason: 'docs/site/keyboard.md is missing. $how',
      );
      expect(
        file.readAsStringSync(),
        generated,
        reason: 'The shortcut table changed and the page did not. $how',
      );
    });
  });

  group('the layer', () {
    testWidgets('undo works when focus is not on the canvas', (tester) async {
      final (container, state) = await _pumpOneModule(tester);
      final before = _rectOf(container);

      // The case the canvas-local bindings could not serve, and the reason the
      // table moved above the canvas.
      state.elsewhere.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, state.elsewhere);

      container
          .read(workspaceProvider.notifier)
          .placeModule(
            _idOf(container),
            const GridRect(column: 10, row: 10, columns: 4, rows: 2),
          );
      await tester.pump();
      expect(_rectOf(container), isNot(before));

      await _press(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(_rectOf(container), before);
    });

    testWidgets('arrows move the selection one cell, and stop at the edge', (
      tester,
    ) async {
      final (container, _) = await _pumpOneModule(tester);
      container.read(workspaceProvider.notifier).select(_idOf(container));
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_rectOf(container).column, 5);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_rectOf(container).row, 3);

      // Up to the top edge, and then one press past it. A refusal, not a clamp
      // that silently succeeds — see _nudge.
      for (var i = 0; i < 3; i++) {
        await _press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(_rectOf(container).row, 0);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_rectOf(container).row, 0);
    });

    testWidgets('shift and an arrow resizes, and refuses below the minimum', (
      tester,
    ) async {
      final (container, _) = await _pumpOneModule(tester);
      container.read(workspaceProvider.notifier).select(_idOf(container));
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.arrowRight, shift: true);
      expect(_rectOf(container).columns, 5);

      for (var i = 0; i < 6; i++) {
        await _press(tester, LogicalKeyboardKey.arrowLeft, shift: true);
      }
      expect(_rectOf(container).columns, ModuleKind.numberBox.minColumns);
    });

    testWidgets('nothing is selected, nothing moves', (tester) async {
      final (container, _) = await _pumpOneModule(tester);
      container.read(workspaceProvider.notifier).select(null);
      await tester.pump();

      final before = _rectOf(container);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_rectOf(container), before);
    });

    testWidgets('a bare digit is ignored while a tab name is being typed', (
      tester,
    ) async {
      final (container, _) = await _pump(tester);
      container.read(workspaceProvider.notifier).addTab();
      await tester.pump();

      final tabs = container.read(workspaceProvider).preset.tabs;
      final last = tabs.length - 1;
      expect(container.read(workspaceProvider).activeTab, last);

      // Right-click the tab and rename it. This is the only way in — a long
      // press opens the same menu, and there is no longer a double tap.
      await tester.tap(
        find.text(tabs[last].name.toUpperCase()),
        buttons: kSecondaryButton,
        warnIfMissed: false,
      );
      await _settle(tester);
      await tester.tap(find.text('Rename'));
      await _settle(tester);
      await _settle(tester);
      expect(find.byType(EditableText), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
        reason: 'the rename field opened without taking focus',
      );

      await _press(tester, LogicalKeyboardKey.digit1);
      expect(
        container.read(workspaceProvider).activeTab,
        last,
        reason: 'typing a 1 into a tab name switched to the first tab',
      );

      // And the guard is not "digits never work": with the field gone, the same
      // key does what the sheet says it does.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester);
      expect(find.byType(EditableText), findsNothing);

      // The keyboard has to survive the field going away. Focus does not move
      // to a new node when one is removed — it falls to the enclosing scope,
      // and OaaShortcuts installs one below its own bindings precisely so that
      // this keystroke still has somewhere to travel up from.
      await _press(tester, LogicalKeyboardKey.digit1);
      expect(container.read(workspaceProvider).activeTab, 0);
    });

    testWidgets('reset reaches the engine', (tester) async {
      final (_, state) = await _pump(tester);

      await _press(tester, LogicalKeyboardKey.keyR, control: true);
      expect(state.resets, 1);
    });

    testWidgets('the tab cycle wraps', (tester) async {
      final (container, _) = await _pump(tester);
      final count = container.read(workspaceProvider).preset.tabs.length;
      container.read(workspaceProvider.notifier).selectTab(count - 1);
      await tester.pump();

      await _press(tester, LogicalKeyboardKey.tab, control: true);
      expect(container.read(workspaceProvider).activeTab, 0);

      await _press(tester, LogicalKeyboardKey.tab, control: true, shift: true);
      expect(container.read(workspaceProvider).activeTab, count - 1);
    });

    testWidgets('? opens the sheet, and it lists every shortcut', (
      tester,
    ) async {
      await _pump(tester);

      await _press(tester, LogicalKeyboardKey.slash, shift: true);
      await _settle(tester);

      expect(find.text('KEYBOARD SHORTCUTS'), findsOneWidget);
      for (final shortcut in oaaShortcuts) {
        expect(
          find.text(shortcut.description),
          findsOneWidget,
          reason: '"${shortcut.description}" is bound and not listed',
        );
      }
    });

    testWidgets('adding a module onto a full tab says so', (tester) async {
      final (container, _) = await _pump(tester);
      final controller = container.read(workspaceProvider.notifier);

      // Two full-width analysers fill the grid exactly, which leaves nowhere
      // for anything — even a Number Box, which is the smallest thing there is.
      controller.addTab();
      controller.addModule(
        ModuleKind.spectrumAnalyzer,
        at: const GridRect(column: 0, row: 0, columns: kGridColumns, rows: 8),
      );
      controller.addModule(
        ModuleKind.spectrumAnalyzer,
        at: const GridRect(column: 0, row: 8, columns: kGridColumns, rows: 8),
      );
      await tester.pump();
      expect(container.read(workspaceProvider).tab.modules, hasLength(2));
      expect(container.read(canvasNoticeProvider), isNull);

      await _press(tester, LogicalKeyboardKey.keyN, control: true);
      await _settle(tester);

      await tester.tap(find.text(ModuleKind.vuMeter.label));
      await _settle(tester);

      // Said out loud rather than swallowed, through the same channel a refused
      // drop uses.
      expect(container.read(canvasNoticeProvider), contains('No room'));
      expect(find.textContaining('No room'), findsOneWidget);

      // And it goes away by itself. Pumped past rather than left running: a
      // notice still counting down when the tree is torn down fails the test
      // with a pending timer, which is a fair description of a toast that
      // outlives the window it was shown in.
      await tester.pump(CanvasNoticeController.visible);
      await tester.pump();
      expect(container.read(canvasNoticeProvider), isNull);
      expect(find.textContaining('No room'), findsNothing);
    });
  });
}
