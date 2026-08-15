// SPDX-License-Identifier: GPL-3.0-or-later
//
// Changing the source has to actually change the source.
//
// This is here because the failure it guards against is silent and looks like
// a hardware problem. `_Workspace` mixed in `SingleTickerProviderStateMixin`,
// which allows one `createTicker` per State for the life of the State —
// disposing the ticker does not buy another. So the source chosen at launch
// worked and every change after it threw a `FlutterError` out of the `setState`
// callback in `_openFor`, which catches `BelEngineException` and nothing else.
//
// Nothing visible happened. The engine had already been created and started, so
// a capture device was opened and held with nothing reading it, while the
// window went on painting the previous source — same label, same elapsed clock,
// still running. Selecting a microphone appeared to do nothing at all.
//
// `flutter analyze` cannot see it and no test that stops at one source can
// either. The assertion that matters is the *second* one.

import 'package:bel/src/app/bel_app.dart';
import 'package:bel/src/data/providers.dart';
import 'package:bel/src/storage/config_store.dart';
import 'package:bel/src/storage/startup_config.dart';
import 'package:bel_core/bel_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('every source change opens a new engine, not just the first', (
    tester,
  ) async {
    // A desktop surface. The status bar ellipsises the source label when the
    // window is narrow, and a truncated label is not the string being matched.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = ConfigStore.disabled();
    addTearDown(store.dispose);

    final container = ProviderContainer(
      overrides: [
        configStoreProvider.overrideWithValue(store),
        startupConfigProvider.overrideWithValue(
          StartupConfig(notice: store.lastError),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BelApp()),
    );
    await tester.pump();

    expect(find.text('TEST TONE'), findsOneWidget);

    final controller = container.read(settingsProvider.notifier);

    // First change. This is the one that used to throw.
    controller.setSource(AudioSourceKind.silence);
    await tester.pump();
    await tester.pump();

    expect(find.text('SILENCE'), findsOneWidget);
    expect(find.text('TEST TONE'), findsNothing);

    // And again, because "works once more" is not the property wanted — the
    // old ticker has now been disposed, and disposing it is what does *not*
    // release the single-ticker mixin's slot.
    controller.setSource(AudioSourceKind.testTone);
    await tester.pump();
    await tester.pump();

    expect(find.text('TEST TONE'), findsOneWidget);
    expect(find.text('SILENCE'), findsNothing);
  });
}
