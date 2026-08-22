// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bare-key shortcuts stand aside for a text field, and it has to be by being
// absent rather than by declining.
//
// `Chord(LogicalKeyboardKey.backspace)` deletes the selected module, and the
// shortcut table has always said that a chord carrying neither Cmd nor Ctrl
// must not fire while an `EditableText` holds focus. It checked — inside the
// callback, which is one layer too late. `CallbackShortcuts` marks a key
// handled the instant an activator matches, whatever the callback then decides,
// so the guard returned, the event stopped there, and it never travelled on to
// `DefaultTextEditingShortcuts` — which is *above* the canvas, because key
// events climb from the focused node and Flutter installs its own text editing
// bindings up at `WidgetsApp`.
//
// Backspace in the tab rename field did nothing. Neither did Delete or the
// arrows. Characters were fine throughout, which is what hid it: text arrives
// through the platform's input connection and never touches a shortcut map, so
// typing a name looked completely normal right up to the first correction.
//
// The assertion that matters is that the binding is *missing* while a field has
// focus. A test that only pressed Backspace and looked at the canvas would pass
// against a callback that declines.

import 'package:oaa/src/app/shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A field under the application's bindings, which is where a tab rename sits.
Widget _fieldUnderShortcuts(TextEditingController controller) => ProviderScope(
  child: MaterialApp(
    home: Material(
      child: OaaShortcuts(
        onReset: () {},
        child: TextField(controller: controller, autofocus: true),
      ),
    ),
  ),
);

void main() {
  testWidgets('Backspace edits the field rather than deleting a module', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Mix 2');
    addTearDown(controller.dispose);

    await tester.pumpWidget(_fieldUnderShortcuts(controller));
    await tester.pump();

    controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(
      controller.text,
      'Mix ',
      reason: 'Backspace was consumed by the canvas bindings',
    );
  });

  testWidgets('Delete and the arrow keys reach the field too', (tester) async {
    final controller = TextEditingController(text: 'Mix');
    addTearDown(controller.dispose);

    await tester.pumpWidget(_fieldUnderShortcuts(controller));
    await tester.pump();

    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(controller.text, 'ix', reason: 'Delete was consumed');

    // An arrow moves the selected module, guarded by the same rule, so here it
    // has to be the caret that moves.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      controller.selection.baseOffset,
      1,
      reason: 'the caret did not move',
    );
  });

  testWidgets('a guarded chord is absent from the map, not merely inert', (
    tester,
  ) async {
    late Map<ShortcutActivator, VoidCallback> canvas;
    late Map<ShortcutActivator, VoidCallback> editing;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final scope = ShortcutScope(
                context: context,
                ref: ref,
                onReset: () {},
              );
              canvas = oaaShortcutBindings(scope);
              editing = oaaShortcutBindings(scope, editingText: true);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    // Scanned rather than looked up: `SingleActivator` does not implement value
    // equality, so a freshly constructed one is never `containsKey` of a map
    // built from different instances.
    bool bare(Map<ShortcutActivator, VoidCallback> map, LogicalKeyboardKey k) =>
        map.keys.any(
          (a) =>
              a is SingleActivator &&
              a.trigger == k &&
              !a.control &&
              !a.meta &&
              !a.shift &&
              !a.alt,
        );

    expect(bare(canvas, LogicalKeyboardKey.backspace), isTrue);
    expect(
      bare(editing, LogicalKeyboardKey.backspace),
      isFalse,
      reason: 'present-but-declining is the defect; it must be absent',
    );

    // A chord carrying Cmd or Ctrl is safe without the guard and has to stay
    // bound — Flutter's own field shortcuts claim those before we see them.
    expect(
      editing.keys.any(
        (a) => a is SingleActivator && a.trigger == LogicalKeyboardKey.keyZ,
      ),
      isTrue,
      reason: 'the modified chords were dropped along with the bare ones',
    );
  });
}
