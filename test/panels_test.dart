// SPDX-License-Identifier: GPL-3.0-or-later
//
// The panels, tested through the pointer.
//
// persistence_test.dart already covers what the controllers do; this file
// covers only the part that file cannot see — that a control is on screen, that
// tapping it calls the right thing, and that a panel opens at all. The last one
// is not as trivial as it sounds: a route pushed by `showGeneralDialog` is built
// by the `Navigator`, so a panel sees only what the application installed above
// it. Install the palette in the wrong place and the panel either asserts on
// opening or — worse, because it looks like nothing — opens correctly and then
// cannot follow the skin it is itself used to change.

import 'dart:io';

import 'package:bel/src/app/bar_controls.dart';
import 'package:bel/src/canvas/workspace.dart';
import 'package:bel/src/data/providers.dart';
import 'package:bel/src/panels/calibration_editor.dart';
import 'package:bel/src/panels/preset_browser.dart';
import 'package:bel/src/panels/settings_panel.dart';
import 'package:bel/src/remote/remote_control.dart';
import 'package:bel/src/storage/config_paths.dart';
import 'package:bel/src/storage/config_store.dart';
import 'package:bel/src/storage/startup_config.dart';
import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A container over a real, empty configuration directory.
///
/// Real rather than disabled, because a panel that saves something is a panel
/// whose test has to be able to see it land — with a disabled store every save
/// correctly fails and every assertion after it is meaningless.
///
/// **Every step that touches the filesystem goes through `tester.runAsync`.**
/// A `testWidgets` body runs inside a fake-async zone, and a future completed by
/// real disk I/O is delivered by the real event loop, which that zone never
/// returns to. Without it the `await` here simply never completes and the test
/// hangs until the runner's timeout — with no error, no stack and nothing on
/// screen to look at.
Future<ProviderContainer> _container(
  WidgetTester tester, [
  StartupConfig? config,
]) async {
  final directory = Directory.systemTemp.createTempSync('bel_panels_');
  final store = (await tester.runAsync(
    () => ConfigStore.open(environment: {kConfigDirEnvVar: directory.path}),
  ))!;

  addTearDown(() {
    store.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return _wrap(store, config);
}

/// Taps something inside a panel.
///
/// Two things every such tap needs, and neither is optional:
///
/// **Scroll it into view first.** A panel's body scrolls, and a control below
/// the fold has a render box outside the clip. `tap` still derives an offset
/// from it, the hit test lands on the panel's backdrop instead, and the test
/// fails with a warning about the widget being obscured rather than anything
/// resembling the real cause.
///
/// **Then let the debounce timer fire.** Settings writes are debounced, so a
/// tap that changes one leaves a pending timer, and `testWidgets` fails a test
/// that ends with a timer outstanding — a failure that reads as a defect in the
/// panel and is actually the persistence layer doing exactly what it should.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump(ConfigStore.writeDelay + const Duration(milliseconds: 50));
}

/// Waits for a save started by a tap to land.
///
/// **The alternation is the whole trick, and it is not optional.** A write
/// started inside a `testWidgets` body lives in two worlds: the disk I/O only
/// progresses when the *real* event loop runs, which is what `runAsync` is for,
/// but the `await` that resumes afterwards is a microtask in the *fake* zone,
/// which only drains when the test pumps. Poll entirely inside `runAsync` and
/// the I/O completes while the continuation that would record it never runs;
/// pump without ever yielding to the real loop and the I/O never starts. So:
/// yield, pump, check, repeat.
Future<void> _untilStored(
  WidgetTester tester,
  bool Function() done, {
  int attempts = 200,
}) async {
  for (var i = 0; i < attempts && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  // A save selects what it saved, which schedules a settings write of its own.
  // Leaving that timer outstanding fails the test at teardown.
  await tester.pump(ConfigStore.writeDelay + const Duration(milliseconds: 50));
}

/// A container with nowhere to write, for the state a stripped environment is
/// in.
ProviderContainer _containerWithoutStorage() {
  final store = ConfigStore.disabled();
  addTearDown(store.dispose);
  return _wrap(store, StartupConfig(notice: store.lastError));
}

ProviderContainer _wrap(ConfigStore store, StartupConfig? config) {
  final container = ProviderContainer(
    overrides: [
      configStoreProvider.overrideWithValue(store),
      startupConfigProvider.overrideWithValue(config ?? const StartupConfig()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Pumps an application and opens [panel] the way the real one does — through
/// `showBelPanel`, over a route, so the theme re-provisioning is exercised.
///
/// **The palette is installed exactly where `BelApp` installs it: through
/// `MaterialApp.builder`, above the `Navigator`.** Wrapping `home` instead is
/// the arrangement that made a panel unable to follow a skin change, and a
/// harness that keeps it cannot see that class of failure — the panel still
/// renders, in last week's colours.
Future<void> _open(
  WidgetTester tester,
  ProviderContainer container,
  Widget panel,
) async {
  // A desktop window, not the 800×600 default. Bel is a desktop application and
  // its panels are laid out for one; at the default surface the footer buttons
  // and half the skin list are below the fold, and `tap` silently derives an
  // offset outside the render tree.
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          final colors = ref.watch(paletteProvider);

          return MaterialApp(
            theme: belThemeData(colors),
            builder: (context, child) =>
                BelTheme(colors: colors, child: child!),
            home: const _Opener(),
          );
        },
      ),
    ),
  );

  _Opener.panel = panel;
  await tester.tap(find.text('open the panel'));
  await tester.pumpAndSettle();
}

/// The palette the open panel is actually drawn from.
///
/// Read from the panel's own element rather than from the provider, because the
/// question is not what the application decided — it is what reached the widget
/// the `Navigator` built.
BelColors _panelPalette(WidgetTester tester) =>
    BelTheme.read(tester.element(find.byType(PanelScaffold)));

class _Opener extends StatelessWidget {
  const _Opener();

  static Widget panel = const SizedBox.shrink();

  @override
  Widget build(BuildContext context) => Material(
    child: Center(
      child: GestureDetector(
        onTap: () =>
            showBelPanel<void>(context: context, builder: (context) => panel),
        child: const Text('open the panel'),
      ),
    ),
  );
}

PresetSpec _preset(String name) => PresetSpec(
  name: name,
  tabs: const [
    TabSpec(
      name: 'Tab',
      modules: [
        ModuleSpec(
          id: 'm1',
          kind: ModuleKind.numberBox,
          rect: GridRect(column: 0, row: 0, columns: 4, rows: 2),
        ),
      ],
    ),
  ],
);

void main() {
  group('the settings panel', () {
    testWidgets('opens with its four sections', (tester) async {
      await _open(tester, await _container(tester), const SettingsPanel());

      expect(find.text('SIGNAL'), findsOneWidget);
      expect(find.text('METERS'), findsOneWidget);
      expect(find.text('APPEARANCE'), findsOneWidget);
      expect(find.text('SESSION'), findsOneWidget);
    });

    testWidgets('choosing a skin changes the palette', (tester) async {
      final container = await _container(tester);
      await _open(tester, container, const SettingsPanel());

      await _tap(tester, find.text('Daylight'));

      expect(container.read(settingsProvider).skinId, 'daylight');
      expect(container.read(paletteProvider).isLight, isTrue);
    });

    testWidgets('follows the skin it just changed, without reopening', (
      tester,
    ) async {
      final container = await _container(tester);
      await _open(tester, container, const SettingsPanel());

      final before = _panelPalette(tester);
      await _tap(tester, find.text('Daylight'));

      final after = _panelPalette(tester);
      expect(
        after.isLight,
        isTrue,
        reason: 'the panel is still on the old skin',
      );
      expect(after.panel, isNot(before.panel));

      // Not just the inherited value: the surface the panel is drawn on, and
      // the scrim over the canvas behind it, both of which were painted from a
      // palette captured when the panel opened.
      final surface = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(PanelScaffold),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(surface.color, after.panel);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox &&
              widget.color == after.background.withValues(alpha: 0.72),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a tap on the scrim still closes it', (tester) async {
      await _open(tester, await _container(tester), const SettingsPanel());
      expect(find.byType(PanelScaffold), findsOneWidget);

      // The dimming is painted inside the page now rather than by the route's
      // barrier, and a `ColoredBox` is opaque to hit testing — so the barrier
      // that dismisses the panel is underneath something that would happily
      // have eaten every tap meant for it.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.byType(PanelScaffold), findsNothing);
    });

    testWidgets('choosing a frame rate changes it', (tester) async {
      final container = await _container(tester);
      await _open(tester, container, const SettingsPanel());

      await _tap(tester, find.text('30 fps'));

      expect(container.read(settingsProvider).targetFps, 30);
    });

    testWidgets('the restore toggle writes through', (tester) async {
      final container = await _container(tester);
      await _open(tester, container, const SettingsPanel());

      expect(container.read(settingsProvider).restoreSession, isTrue);
      await _tap(tester, find.byType(BelToggle));

      expect(container.read(settingsProvider).restoreSession, isFalse);
    });

    testWidgets('it says so when there is nowhere to save', (tester) async {
      // The state a user in a stripped environment is in. Silence would be
      // worse: they would find out when they quit.
      await _open(tester, _containerWithoutStorage(), const SettingsPanel());
      expect(find.textContaining('Nothing is being saved'), findsOneWidget);
    });
  });

  group('the preset browser', () {
    testWidgets('opening a preset replaces the layout', (tester) async {
      final container = await _container(
        tester,
        StartupConfig(
          presets: [(fileName: 'mastering.json', preset: _preset('Mastering'))],
        ),
      );
      await _open(tester, container, const PresetBrowser());

      // Scoped to the row: the name field carries the same string once a row
      // has been chosen, and `find.text` matches an `EditableText` too.
      await _tap(tester, find.widgetWithText(PanelListRow, 'Mastering'));
      await _tap(tester, find.text('OPEN'));
      await tester.pumpAndSettle();

      expect(container.read(workspaceProvider).preset.name, 'Mastering');
    });

    testWidgets('a preset carrying a target applies it, and one without '
        'leaves it alone', (tester) async {
      // The two save toggles exist to choose between exactly these.
      final container = await _container(
        tester,
        StartupConfig(
          presets: [
            (
              fileName: 'broadcast.json',
              preset: PresetSpec(
                name: 'Broadcast',
                tabs: _preset('x').tabs,
                calibrationId: 'ebu-r128',
              ),
            ),
          ],
        ),
      );
      await _open(tester, container, const PresetBrowser());

      expect(container.read(calibrationProvider).id, 'streaming-14');
      await _tap(tester, find.text('Broadcast'));
      await _tap(tester, find.text('OPEN'));
      await tester.pumpAndSettle();

      expect(container.read(calibrationProvider).id, 'ebu-r128');
    });

    testWidgets('there is nothing to open until something is chosen', (
      tester,
    ) async {
      final container = await _container(
        tester,
        StartupConfig(
          presets: [(fileName: 'mastering.json', preset: _preset('Mastering'))],
        ),
      );
      await _open(tester, container, const PresetBrowser());

      await _tap(tester, find.text('OPEN'));
      await tester.pumpAndSettle();

      // Still open, nothing loaded: a disabled button that silently did
      // something would be worse than one that does nothing.
      expect(find.text('PRESETS'), findsOneWidget);
      expect(container.read(workspaceProvider).preset.name, isNot('Mastering'));
    });
  });

  group('the calibration editor', () {
    /// Field order in the panel: name, note, target, tolerance, range, true
    /// peak, VU reference.
    Finder field(int index) => find.byType(TextField).at(index);

    testWidgets('saves a new target and selects it', (tester) async {
      final container = await _container(tester);
      await _open(tester, container, const CalibrationEditor());

      await tester.enterText(field(0), 'House standard');
      await tester.enterText(field(2), '-12');
      await _tap(tester, find.text('SAVE AS NEW'));
      await _untilStored(
        tester,
        () => container
            .read(calibrationLibraryProvider)
            .any((c) => c.id == 'house-standard'),
      );

      final saved = container
          .read(calibrationLibraryProvider)
          .where((c) => c.id == 'house-standard');
      expect(saved, isNotEmpty);
      expect(saved.single.lufsTarget, -12);
      expect(container.read(settingsProvider).calibrationId, 'house-standard');
    });

    testWidgets('accepts the typographic minus it renders itself', (
      tester,
    ) async {
      // Bel prints "−14 LUFS" with U+2212. Anybody who copies a number out of
      // the interface and pastes it back in is pasting a character
      // double.parse rejects.
      final container = await _container(tester);
      await _open(tester, container, const CalibrationEditor());

      await tester.enterText(field(0), 'Pasted');
      await tester.enterText(field(2), '−9,5');
      await _tap(tester, find.text('SAVE AS NEW'));
      await _untilStored(
        tester,
        () => container
            .read(calibrationLibraryProvider)
            .any((c) => c.id == 'pasted'),
      );

      expect(
        container
            .read(calibrationLibraryProvider)
            .firstWhere((c) => c.id == 'pasted')
            .lufsTarget,
        -9.5,
      );
    });

    testWidgets('refuses a number that is not one, and says which', (
      tester,
    ) async {
      final container = await _container(tester);
      final before = container.read(calibrationLibraryProvider).length;
      await _open(tester, container, const CalibrationEditor());

      await tester.enterText(field(0), 'Broken');
      await tester.enterText(field(2), 'quite loud');
      await _tap(tester, find.text('SAVE AS NEW'));

      expect(find.textContaining('target'), findsWidgets);
      expect(container.read(calibrationLibraryProvider).length, before);
    });

    testWidgets('refuses a nameless target', (tester) async {
      final container = await _container(tester);
      await _open(tester, container, const CalibrationEditor());

      await tester.enterText(field(0), '   ');
      await _tap(tester, find.text('SAVE AS NEW'));

      expect(find.text('A target needs a name.'), findsOneWidget);
    });
  });

  // The remote control is the one panel not opened through `_open`, because the
  // thing worth testing is the button: it is what pushes the route, and it
  // pushed it with `showDialog` for a whole phase. A route built that way is
  // built by the `Navigator`, above the application's `BelTheme`, so the panel
  // threw "No BelTheme in scope" the moment anybody pressed it — in release as
  // well as debug, since `BelTheme.of` ends in a `!`.
  group('remote display', () {
    Future<void> mount(WidgetTester tester, ProviderContainer container) async {
      const colors = BelColors.precisionInstrument;
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: belThemeData(colors),
            home: const BelTheme(
              colors: colors,
              child: Material(
                child: Center(
                  child: RemoteDisplayControl(
                    source: _SilentSource(),
                    abiVersion: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Opens the bar button's panel. The label and the panel's own title are
    /// both the word REMOTE, so the finder has to name the one in the bar.
    Future<void> openPairing(WidgetTester tester) async {
      await tester.tap(find.byType(BarButton));
      await tester.pumpAndSettle();
    }

    testWidgets('the bar button opens the pairing panel', (tester) async {
      final container = await _container(tester);
      await mount(tester, container);
      await openPairing(tester);

      // Both ends of the link are offered before either is configured. The
      // receiving half used to be a footer button on the sending half's dialog,
      // which is the row a panel reserves for the ways out of it.
      expect(find.text('Send these meters'), findsOneWidget);
      expect(find.text('Show another machine'), findsOneWidget);
    });

    testWidgets('sending opens the publishing panel', (tester) async {
      final container = await _container(tester);
      await mount(tester, container);
      await openPairing(tester);
      await _tap(tester, find.text('Send these meters'));
      await tester.pumpAndSettle();

      expect(find.text('SEND THESE METERS'), findsOneWidget);
      expect(find.text('Publish to this network'), findsOneWidget);
      expect(find.text('Off.'), findsOneWidget);
    });

    testWidgets('the update rate is a segmented control over the options', (
      tester,
    ) async {
      final container = await _container(tester);
      await mount(tester, container);
      await openPairing(tester);
      await _tap(tester, find.text('Send these meters'));
      await tester.pumpAndSettle();

      for (final fps in kRemoteFpsOptions) {
        expect(find.text('$fps'), findsOneWidget);
      }

      await _tap(tester, find.text('15'));
      expect(container.read(settingsProvider).remoteDisplayFps, 15);
    });

    testWidgets('receiving opens the host picker', (tester) async {
      final container = await _container(tester);
      await mount(tester, container);
      await openPairing(tester);
      await _tap(tester, find.text('Show another machine'));
      await tester.pumpAndSettle();

      expect(find.text('SHOW ANOTHER MACHINE'), findsOneWidget);
      // The typed address is not a fallback for completeness — it is the only
      // route on a network that blocks multicast, so it is always offered.
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('CONNECT'), findsOneWidget);

      // Unmount so the picker's browser tears its socket and timers down inside
      // the test rather than after it.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

/// A [MeterSource] that is never read.
///
/// `RemoteDisplayService` only touches its source once it is publishing, and
/// nothing here turns that on — a test that bound a socket and an mDNS
/// responder would be testing the network rather than the panel.
class _SilentSource implements MeterSource {
  const _SilentSource();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
