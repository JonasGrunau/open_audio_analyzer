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

import 'package:oaa/src/app/bar_controls.dart';
import 'package:oaa/src/data/providers.dart';
import 'package:oaa/src/panels/calibration_editor.dart';
import 'package:oaa/src/panels/settings_panel.dart';
import 'package:oaa/src/plugin/plugin_link.dart';
import 'package:oaa/src/remote/host_picker.dart';
import 'package:oaa/src/remote/mdns/host_discovery.dart';
import 'package:oaa/src/remote/pair_link.dart';
import 'package:oaa/src/remote/remote_control.dart';
import 'package:oaa/src/remote/remote_display_service.dart';
import 'package:oaa/src/storage/config_store.dart';
import 'package:oaa/src/storage/startup_config.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final directory = Directory.systemTemp.createTempSync('oaa_panels_');
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
/// `showOaaPanel`, over a route, so the theme re-provisioning is exercised.
///
/// **The palette is installed exactly where `OaaApp` installs it: through
/// `MaterialApp.builder`, above the `Navigator`.** Wrapping `home` instead is
/// the arrangement that made a panel unable to follow a skin change, and a
/// harness that keeps it cannot see that class of failure — the panel still
/// renders, in last week's colours.
Future<void> _open(
  WidgetTester tester,
  ProviderContainer container,
  Widget panel,
) async {
  // A desktop window, not the 800×600 default. Open Audio Analyzer is a desktop
  // application and its panels are laid out for one; at the default surface the
  // footer buttons and half the skin list are below the fold, and `tap`
  // silently derives an offset outside the render tree.
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
            theme: oaaThemeData(colors),
            builder: (context, child) =>
                OaaTheme(colors: colors, child: child!),
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
OaaColors _panelPalette(WidgetTester tester) =>
    OaaTheme.read(tester.element(find.byType(PanelScaffold)));

class _Opener extends StatelessWidget {
  const _Opener();

  static Widget panel = const SizedBox.shrink();

  @override
  Widget build(BuildContext context) => Material(
    child: Center(
      child: GestureDetector(
        onTap: () =>
            showOaaPanel<void>(context: context, builder: (context) => panel),
        child: const Text('open the panel'),
      ),
    ),
  );
}

/// A delivery target the user wrote, for the cases about removing one.
const _houseTarget = Calibration(
  id: 'house',
  name: 'House standard',
  lufsTarget: -12,
  lufsTolerance: 0.5,
  truePeakMax: -1,
  loudnessRangeMax: 14,
);

/// A publish service for a panel that has to be handed one.
///
/// The settings panel takes one because its Publish section reads live state
/// off it. Nothing in these cases publishes: it is constructed, never started,
/// and disposed with the test — a case that bound a socket and an mDNS
/// responder would be testing the network rather than the panel.
RemoteDisplayService _remoteService() {
  final service = RemoteDisplayService(const _SilentSource(), abiVersion: 1);
  addTearDown(service.dispose);
  return service;
}

/// A plugin link for the panel's DAW plugin row, for the same reason.
///
/// Constructing one binds nothing — `start()` is what opens the port — so a
/// case that wants an empty list of sessions gets one for free, and no case
/// here goes near a socket.
PluginLink _pluginLink() {
  final link = PluginLink(port: 0);
  addTearDown(link.dispose);
  return link;
}

void main() {
  group('the settings panel', () {
    testWidgets('opens with its five sections', (tester) async {
      await _open(
        tester,
        await _container(tester),
        SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
      );

      // Signal in, then the meters, then where those meters go, then how they
      // look, then what is kept between launches.
      expect(find.text('SIGNAL'), findsOneWidget);
      expect(find.text('METERS'), findsOneWidget);
      expect(find.text('PUBLISH'), findsOneWidget);
      expect(find.text('APPEARANCE'), findsOneWidget);
      expect(find.text('SESSION'), findsOneWidget);
    });

    // The switch is in the menu bar and nowhere else, so the section says
    // where it is rather than offering a second one that could disagree with
    // it. What it does carry is the live state, which the bar has no room to
    // print.
    testWidgets('the publish section states where the switch is', (
      tester,
    ) async {
      final service = _remoteService();
      await _open(
        tester,
        await _container(tester),
        SettingsPanel(remote: service, plugins: _pluginLink()),
      );

      expect(
        find.text('Off. The switch is PUBLISH, in the menu bar.'),
        findsOneWidget,
      );

      service.isPublishing.value = true;
      service.clients.value = 2;
      await tester.pumpAndSettle();

      expect(find.text('Publishing. 2 displays attached.'), findsOneWidget);
    });

    testWidgets('choosing a skin changes the palette', (tester) async {
      final container = await _container(tester);
      await _open(
        tester,
        container,
        SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
      );

      await _tap(tester, find.text('Daylight'));

      expect(container.read(settingsProvider).skinId, 'daylight');
      expect(container.read(paletteProvider).isLight, isTrue);
    });

    testWidgets('follows the skin it just changed, without reopening', (
      tester,
    ) async {
      final container = await _container(tester);
      await _open(
        tester,
        container,
        SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
      );

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
      await _open(
        tester,
        await _container(tester),
        SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
      );
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
      await _open(
        tester,
        container,
        SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
      );

      // Uppercase: a segment sets its own label the way a button does.
      await _tap(tester, find.text('30 FPS'));

      expect(container.read(settingsProvider).targetFps, 30);
    });

    // The one destructive action in the application that asks in a dialog
    // rather than by taking a second press — see `lib/src/panels/AGENTS.md` for
    // why this one is the exception.
    group('resetting the delivery targets', () {
      /// Scoped to the confirmation, because the settings panel behind it still
      /// has its own `RESET` in the tree and an unscoped `find.text` matches
      /// both. The dialog is the newest route, so its scaffold is the last one.
      Finder inDialog(String text) => find.descendant(
        of: find.byType(PanelScaffold).last,
        matching: find.text(text),
      );

      /// The settings panel with one saved target, and its file on disk for the
      /// reset to find.
      Future<(ProviderContainer, ConfigStore)> open(WidgetTester tester) async {
        final container = await _container(
          tester,
          const StartupConfig(calibrations: [_houseTarget]),
        );
        final store = container.read(configStoreProvider);
        await tester.runAsync(
          () => store.writeJson(
            '${ConfigDir.calibrations}/house.json',
            _houseTarget.toJson(),
          ),
        );
        await _open(
          tester,
          container,
          SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
        );
        return (container, store);
      }

      testWidgets('asks first, and deletes when told to', (tester) async {
        final (container, store) = await open(tester);
        Iterable<String> ids() =>
            container.read(calibrationLibraryProvider).map((c) => c.id);
        expect(ids(), contains('house'));

        await _tap(tester, find.text('RESET'));
        expect(find.text('RESET DELIVERY TARGETS'), findsOneWidget);
        // Nothing has happened yet. A dialog that opened after the deletion
        // would be a receipt, not a confirmation.
        expect(ids(), contains('house'));

        await _tap(tester, inDialog('RESET'));
        await _untilStored(tester, () => !ids().contains('house'));

        expect(ids().length, BuiltInCalibrations.all.length);
        expect(
          await tester.runAsync(
            () => store.readJson('${ConfigDir.calibrations}/house.json'),
          ),
          isNull,
        );
        expect(find.textContaining('One saved target removed'), findsOneWidget);
      });

      testWidgets('cancelling touches nothing', (tester) async {
        final (container, store) = await open(tester);

        await _tap(tester, find.text('RESET'));
        await _tap(tester, inDialog('CANCEL'));
        await tester.pumpAndSettle();

        expect(
          container.read(calibrationLibraryProvider).map((c) => c.id),
          contains('house'),
        );
        expect(
          await tester.runAsync(
            () => store.readJson('${ConfigDir.calibrations}/house.json'),
          ),
          isNotNull,
        );
        // Back to the settings panel, with the dialog gone rather than stacked.
        expect(find.text('RESET DELIVERY TARGETS'), findsNothing);
        expect(find.text('SETTINGS'), findsOneWidget);
      });

      // Escape pops a route with no value at all, which is neither true nor
      // false. Read as yes, that is a destructive action performed by the key
      // people press to get out of things.
      testWidgets('dismissing is a no', (tester) async {
        final (container, _) = await open(tester);

        await _tap(tester, find.text('RESET'));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.text('RESET DELIVERY TARGETS'), findsNothing);
        expect(
          container.read(calibrationLibraryProvider).map((c) => c.id),
          contains('house'),
        );
      });
    });

    testWidgets('the restore toggle writes through', (tester) async {
      final container = await _container(tester);
      await _open(
        tester,
        container,
        SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
      );

      expect(container.read(settingsProvider).restoreSession, isTrue);
      await _tap(tester, find.byType(OaaToggle));

      expect(container.read(settingsProvider).restoreSession, isFalse);
    });

    testWidgets('it says so when there is nowhere to save', (tester) async {
      // The state a user in a stripped environment is in. Silence would be
      // worse: they would find out when they quit.
      await _open(
        tester,
        _containerWithoutStorage(),
        SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
      );
      expect(find.textContaining('Nothing is being saved'), findsOneWidget);
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
      // Open Audio Analyzer prints "−14 LUFS" with U+2212. Anybody who copies a
      // number out of the interface and pastes it back in is pasting a
      // character double.parse rejects.
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

  group('list rows', () {
    // **A mark is a `CustomPaint`, and a `CustomPaint` swallows every pointer
    // event that lands on it** unless its painter refuses — `hitTest` returns
    // null by default and `RenderCustomPaint` reads that as true. So a row that
    // gained a leading mark and a trailing chevron is a row with two dead spots
    // in it, which is the kind of defect that ships: the row still works
    // everywhere else, and nothing about the rendering says why the two ends of
    // it do not.
    testWidgets('a mark inside a row does not eat the row’s tap', (
      tester,
    ) async {
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: OaaTheme(
            colors: OaaColors.precisionInstrument,
            child: Material(
              child: PanelListRow(
                title: 'Send these meters',
                mark: OaaMark.broadcast,
                opens: true,
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      );

      // `tapAt` the mark's own centre rather than `tap` on the finder: a glyph
      // that correctly refuses hits is not itself in the hit-test path, and
      // `tap` warns about exactly that. What is being asked here is what a
      // finger asks — press this pixel, and see whether the row answers.
      for (final glyph in [OaaMark.broadcast, OaaMark.chevron]) {
        await tester.tapAt(
          tester.getCenter(
            find.byWidgetPredicate(
              (widget) => widget is OaaGlyph && widget.mark == glyph,
            ),
          ),
        );
      }

      expect(taps, 2);
    });
  });

  group('notes', () {
    // A note that carries a mark is a paragraph, and every one of them wraps —
    // two lines beside the password warning in the sending panel, three on a
    // phone-shaped display. Pinned to the top of the block the mark reads as
    // belonging to the first line rather than to the note, which is what it
    // looked like against two lines of orange.
    testWidgets('a marked note centres its mark on the whole note', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: OaaTheme(
            colors: OaaColors.precisionInstrument,
            child: Material(
              child: Center(
                child: SizedBox(
                  width: 240,
                  child: PanelNote(
                    'There is no password on the connection. Anyone on this '
                    'network who can find it can watch these meters.',
                    mark: OaaMark.warning,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final note = tester.getRect(find.textContaining('no password'));
      final mark = tester.getRect(
        find.byWidgetPredicate(
          (widget) => widget is OaaGlyph && widget.mark == OaaMark.warning,
        ),
      );

      // Wrapped, or the assertion below holds trivially.
      expect(note.height, greaterThan(mark.height * 1.5));
      expect(mark.center.dy, closeTo(note.center.dy, 0.5));
    });
  });

  // One bar, on the platforms that would otherwise supply a second one
  // themselves. `MaterialScrollBehavior` wraps every vertical scrollable in a
  // `Scrollbar` on macOS, Windows and Linux without being asked, so the
  // settings panel — the tallest in the application and the one that always
  // scrolls — carried the skin's thumb and Material's grey one side by side.
  //
  // The default platform in a widget test is Android, where that behaviour adds
  // nothing, so every panel test in this file passed throughout. Parameterised
  // over all five for that reason: the count is one everywhere, and Android and
  // iOS are here to catch a fix that suppressed the panel's own bar along with
  // the ambient one.
  group("a panel has one scrollbar", () {
    for (final platform in TargetPlatform.values) {
      testWidgets('on ${platform.name}', (tester) async {
        // Reset inside the body rather than in a tear-down: the binding checks
        // for a still-set foundation debug variable before tear-downs run.
        debugDefaultTargetPlatformOverride = platform;
        try {
          await _open(
            tester,
            await _container(tester),
            SettingsPanel(remote: _remoteService(), plugins: _pluginLink()),
          );

          // The panel's own viewport, which is the outermost of several: every
          // `EditableText` in the body builds a `Scrollable` of its own, and
          // `SelectableText` — the configuration path, in the Session section —
          // is multiline, which is a case `EditableText` deliberately gives a
          // bar of its own whatever the ambient configuration says. Its content
          // fits, so nothing is ever drawn for it; counting by *type* over the
          // whole tree would fail on it and say nothing about the panel.
          final scrollable = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(PanelScaffold),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          // It scrolls, or there is nothing for a bar to be drawn for and the
          // count below is one about nothing.
          expect(scrollable.position.maxScrollExtent, greaterThan(0));

          // One bar drives *this* viewport. Counted by the controller rather
          // than by the widget type, because the second bar was neither a
          // `RawScrollbar` nor findable as one: `MaterialScrollBehavior` builds
          // a `Scrollbar` around a private subclass, Cupertino's builds
          // another, and both are handed the same controller the panel gave its
          // scroll view. That is the thing that makes a bar this panel's.
          final controller = scrollable.widget.controller;
          expect(controller, isNotNull);
          expect(
            find.byWidgetPredicate(
              (widget) => switch (widget) {
                RawScrollbar(controller: final c) => c == controller,
                Scrollbar(controller: final c) => c == controller,
                _ => false,
              },
            ),
            findsOneWidget,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });

  // The keyboard, which is a thing only a tablet has and therefore a thing no
  // desktop run can show you. The host picker is the panel this was reported
  // against and the worst case in the application: its address field is the
  // last row above the footer, so a panel centred on the whole screen puts it
  // and the caret behind an iPad's keyboard — everything typed is invisible.
  //
  // Both mountings are here because the fix reads the inset from the context
  // and the two contexts disagree on purpose: a route sees the keyboard, and a
  // `Scaffold` body has already been shrunk by it and is handed a MediaQuery
  // with the inset removed. One of those has to add the height and the other
  // must not, or the panel is squashed to nothing.
  group('a panel and the software keyboard', () {
    // An iPad Pro in landscape, and the keyboard iPadOS puts up on it.
    const view = Size(1194, 834);
    const keyboard = 353.0;

    /// The bottom of the space the keyboard leaves.
    final above = view.height - keyboard;

    Widget picker({int found = 0}) => HostPickerPanel(
      onConnect: (_, _) {},
      discovery: _StaticDiscovery(
        found: [
          for (var i = 0; i < found; i++)
            DiscoveredHost(
              instanceName: 'studio-$i',
              address: '192.168.1.2$i',
              port: 45678,
              txt: const {'name': 'Studio', 'sr': '48000', 'ch': '2'},
              seenAt: DateTime.utc(2026),
            ),
        ],
      ),
    );

    /// The panel's own bordered surface.
    ///
    /// Not `PanelScaffold`'s box, which is the `Center` at its root and so is
    /// whatever it was handed — the whole screen over the canvas, and the
    /// whole body inside the display screen's `Scaffold`. Measuring that one
    /// passes every assertion below while the panel sits behind the keyboard.
    Rect surface(WidgetTester tester) => tester.getRect(
      find
          .descendant(
            of: find.byType(PanelScaffold),
            matching: find.byType(ClipRRect),
          )
          .first,
    );

    void sizeTablet(WidgetTester tester) {
      tester.view.physicalSize = view;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Future<void> raiseKeyboard(WidgetTester tester) async {
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
    }

    testWidgets('a panel over the canvas moves above it', (tester) async {
      sizeTablet(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: oaaThemeData(OaaColors.precisionInstrument),
          builder: (context, child) =>
              OaaTheme(colors: OaaColors.precisionInstrument, child: child!),
          home: const _Opener(),
        ),
      );
      _Opener.panel = picker();
      await tester.tap(find.text('open the panel'));
      await tester.pumpAndSettle();

      // Where it was before: the full height it is allowed, centred, with its
      // lower half in the space the keyboard is about to take.
      expect(surface(tester).bottom, greaterThan(above));

      await raiseKeyboard(tester);

      final panel = surface(tester);
      expect(panel.bottom, lessThanOrEqualTo(above));
      // Moved rather than crushed. A panel that answered the keyboard by
      // shrinking to a title bar would satisfy the line above.
      expect(panel.height, greaterThan(300));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('and the field being typed into comes with it', (tester) async {
      sizeTablet(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: oaaThemeData(OaaColors.precisionInstrument),
          builder: (context, child) =>
              OaaTheme(colors: OaaColors.precisionInstrument, child: child!),
          home: const _Opener(),
        ),
      );
      // With hosts in the list, which is where the address row actually sits
      // on a network that has any: an empty picker is short enough that the
      // field clears the keyboard by a few pixels even unfixed, and a
      // regression test that only just fails is one that will pass again for
      // the wrong reason.
      _Opener.panel = picker(found: 2);
      await tester.tap(find.text('open the panel'));
      await tester.pumpAndSettle();

      // Tapped, the way somebody who is about to type an address taps it.
      await tester.ensureVisible(find.byType(OaaTextField));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(OaaTextField));
      await tester.pumpAndSettle();

      await raiseKeyboard(tester);

      // The panel moving is not the point on its own — the point is that the
      // row somebody is typing into ends up in front of them, which the
      // panel's own scroll view is what delivers.
      final field = tester.getRect(find.byType(OaaTextField));
      expect(field.bottom, lessThanOrEqualTo(above));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a panel that is a screen does not subtract it twice', (
      tester,
    ) async {
      sizeTablet(tester);
      // The remote display screen's arrangement: the picker *is* the screen
      // while there is no host, inside a `Scaffold` whose
      // `resizeToAvoidBottomInset` has already taken the keyboard out of the
      // body's height — and which therefore hands the body a MediaQuery with
      // the inset removed, so the panel's own padding adds nothing here.
      await tester.pumpWidget(
        MaterialApp(
          theme: oaaThemeData(OaaColors.precisionInstrument),
          home: OaaTheme(
            colors: OaaColors.precisionInstrument,
            child: Scaffold(body: SafeArea(child: picker())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await raiseKeyboard(tester);

      final panel = surface(tester);
      expect(panel.bottom, lessThanOrEqualTo(above));
      // Centred in the space the Scaffold left, at the height that space
      // allows. A panel that took the keyboard out of it a second time would
      // be 64 px tall and sit high, which is what these two pin.
      expect(panel.height, greaterThan(300));
      expect(panel.center.dy, closeTo(above / 2, 1));

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // The remote control is the one panel not opened through `_open`, because the
  // thing worth testing is the button: it is what pushes the route, and it
  // pushed it with `showDialog` for a whole phase. A route built that way is
  // built by the `Navigator`, above the application's `OaaTheme`, so the panel
  // threw "No OaaTheme in scope" the moment anybody pressed it — in release as
  // well as debug, since `OaaTheme.of` ends in a `!`.
  group('remote display', () {
    Future<RemoteDisplayService> mount(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      const colors = OaaColors.precisionInstrument;
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // The service is constructed here rather than by the controls, which are
      // views onto one: it holds a socket and a publish timer keyed to the
      // engine, and the controls that show it are dropped whenever the window
      // is narrow. See `RemoteDisplayScope`.
      final service = RemoteDisplayService(
        const _SilentSource(),
        abiVersion: 1,
      );
      addTearDown(service.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: oaaThemeData(colors),
            home: OaaTheme(
              colors: colors,
              child: Material(
                child: Center(
                  // The three the menu bar builds, in the order it builds
                  // them. Not the whole bar: this group is about what the
                  // controls do, and `test/scaling_test.dart` is what holds
                  // whether they fit.
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PublishSwitch(service: service),
                      PairingCodeButton(service: service),
                      const AttachButton(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return service;
    }

    /// The pairing code's button, which carries a mark rather than a word and
    /// so cannot be found by its text.
    Finder pairingCodeButton() => find.byWidgetPredicate(
      (widget) => widget is BarButton && widget.mark == OaaMark.qr,
    );

    /// Opens the host picker the way the bar does.
    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.text('ATTACH'));
      await tester.pumpAndSettle();
    }

    /// Lets `localIPv4Addresses` land.
    ///
    /// It is real I/O, and a `testWidgets` body runs in a fake-async zone the
    /// disk never returns to — so the answer only arrives if the test
    /// alternates `runAsync` with a pump to drain the continuation. Without
    /// this the pairing code is permanently unavailable and every assertion
    /// about it would be testing the fake-async zone instead.
    Future<void> settleAddresses(
      WidgetTester tester,
      bool Function() done,
    ) async {
      for (var attempt = 0; attempt < 20 && !done(); attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
    }

    // Both ends of the link are offered at once, without being asked which end
    // this machine is. They used to be two rows on a panel behind one button,
    // which put the tablet half two presses deep behind a question the person
    // pressing had already answered.
    testWidgets('the bar offers both ends of the link', (tester) async {
      final container = await _container(tester);
      await mount(tester, container);

      expect(find.text('PUBLISH'), findsOneWidget);
      expect(find.text('ATTACH'), findsOneWidget);
      expect(pairingCodeButton(), findsOneWidget);
    });

    // Brightness, not hue — see `BarSwitch`. What this holds is the wiring:
    // the switch reports the service rather than a copy of it, so a session
    // started from anywhere else shows here too.
    testWidgets('the switch follows the service', (tester) async {
      final container = await _container(tester);
      final service = await mount(tester, container);

      expect(tester.widget<BarSwitch>(find.byType(BarSwitch)).value, isFalse);

      service.isPublishing.value = true;
      await tester.pumpAndSettle();

      expect(tester.widget<BarSwitch>(find.byType(BarSwitch)).value, isTrue);
    });

    // Present and inert rather than absent: a code nothing is listening at is a
    // tablet that scans, connects and times out, which reads as a broken
    // feature rather than as a switch that is not on.
    testWidgets('the pairing code is disabled until publishing', (
      tester,
    ) async {
      final container = await _container(tester);
      final service = await mount(tester, container);

      expect(tester.widget<BarButton>(pairingCodeButton()).onPressed, isNull);

      service.isPublishing.value = true;
      await tester.pumpAndSettle();
      await settleAddresses(
        tester,
        () => tester.widget<BarButton>(pairingCodeButton()).onPressed != null,
      );

      // A machine with no non-loopback address — a runner with the network
      // down — legitimately has nothing to encode, and the button stays
      // disabled and says why. Both outcomes are correct; what may not happen
      // is a panel with an empty square in it.
      final button = tester.widget<BarButton>(pairingCodeButton());
      if (button.onPressed == null) {
        expect(button.tooltip, contains('No network address'));
        return;
      }

      await _tap(tester, pairingCodeButton());
      await tester.pumpAndSettle();

      expect(find.text('PAIRING CODE'), findsOneWidget);
      expect(find.byType(OaaQrCode), findsOneWidget);
    });

    // Publishing and unfindable, which is the state a refused local-network
    // permission leaves behind: the port is open, a display handed the address
    // connects to it and works, and the only screen that knows is the tablet.
    // The notifiers are driven directly for the same reason the source here is
    // never read — a test that bound a socket and an mDNS responder would be
    // testing the network rather than the place this has to appear.
    testWidgets('a host that cannot announce itself says so', (tester) async {
      final container = await _container(tester);
      final service = _remoteService();

      service.isPublishing.value = true;
      service.advertisementFailure.value =
          'macOS is not letting Open Audio Analyzer announce itself on the '
          'local network. Allow it under System Settings › Privacy & Security '
          '› Local Network.';

      await _open(
        tester,
        container,
        SettingsPanel(remote: service, plugins: _pluginLink()),
      );

      expect(find.textContaining('Privacy & Security'), findsOneWidget);
      // Not "could not publish": publishing is exactly what did work.
      expect(find.textContaining('Could not publish'), findsNothing);
      // And the heading still reports the state that is true, rather than the
      // fault standing in for it.
      expect(find.text('Publishing. No displays attached.'), findsOneWidget);
    });

    testWidgets('the update rate is a segmented control over the options', (
      tester,
    ) async {
      final container = await _container(tester);
      final service = _remoteService();
      await _open(
        tester,
        container,
        SettingsPanel(remote: service, plugins: _pluginLink()),
      );

      for (final fps in kRemoteFpsOptions) {
        expect(find.text('$fps'), findsOneWidget);
      }

      await _tap(tester, find.text('15'));
      expect(container.read(settingsProvider).remoteDisplayFps, 15);
    });

    testWidgets('ATTACH opens the host picker', (tester) async {
      final container = await _container(tester);
      await mount(tester, container);
      await openPicker(tester);

      expect(find.text('SHOW ANOTHER MACHINE'), findsOneWidget);
      // The typed address is not a fallback for completeness — it is the only
      // route on a network that blocks multicast, so it is always offered.
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('CONNECT'), findsOneWidget);

      // Unmount so the picker's browser tears its socket and timers down inside
      // the test rather than after it.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // The camera is a capability, not a preference: `mobile_scanner` has no
    // Windows or Linux implementation, so the row is absent there rather than
    // disabled. A row that can never be pressed is a promise the product does
    // not keep, and a row that throws `UnimplementedError` when it is pressed
    // is worse.
    for (final (platform, offered) in const [
      (TargetPlatform.iOS, true),
      (TargetPlatform.android, true),
      (TargetPlatform.macOS, true),
      (TargetPlatform.windows, false),
      (TargetPlatform.linux, false),
    ]) {
      testWidgets(
        'the picker offers the camera on ${platform.name}: $offered',
        (tester) async {
          // Reset before the body ends rather than in a tear-down: the test
          // binding checks that no foundation debug variable is still set, and
          // it checks before tear-downs run.
          debugDefaultTargetPlatformOverride = platform;
          try {
            final container = await _container(tester);
            await mount(tester, container);
            await openPicker(tester);

            expect(
              find.text('Scan a QR code'),
              offered ? findsOneWidget : findsNothing,
            );
            // Whatever the answer, the address is still there. It is the route
            // that has to work in the rooms the feature exists for.
            expect(find.text('Host'), findsOneWidget);

            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    }

    // Strictness with no feedback is a Connect button that swallows the press.
    testWidgets('an address the parser refuses says so', (tester) async {
      final container = await _container(tester);
      await mount(tester, container);
      await openPicker(tester);

      await tester.enterText(find.byType(OaaTextField), '192.168.1.20:70000');
      await tester.pumpAndSettle();
      await _tap(tester, find.text('CONNECT'));
      await tester.pumpAndSettle();

      expect(find.textContaining('is not an address'), findsOneWidget);

      // And it marks the attempt rather than the field, so the next keystroke
      // takes it away.
      await tester.enterText(find.byType(OaaTextField), '192.168.1.20:5555');
      await tester.pumpAndSettle();
      expect(find.textContaining('is not an address'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the section offers a pairing code, carrying the address', (
      tester,
    ) async {
      final container = await _container(tester);
      final service = _remoteService();
      await _open(
        tester,
        container,
        SettingsPanel(remote: service, plugins: _pluginLink()),
      );

      // The row is there whether or not this machine has an address; what it
      // does depends on whether it has one.
      expect(find.text('Show a QR code'), findsOneWidget);

      // `localIPv4Addresses` is real I/O, and a `testWidgets` body runs in a
      // fake-async zone the disk never returns to — so the panel's answer only
      // arrives if the test alternates `runAsync` with a pump to drain the
      // continuation. Without this the row is permanently inert and the
      // assertions below would be testing the fake-async zone.
      const nothingYet = 'No network address to publish yet.';
      await settleAddresses(
        tester,
        () => find.text(nothingYet).evaluate().isEmpty,
      );

      // A machine with no non-loopback address — a runner with the network
      // down — legitimately has nothing to encode, and the row says so and
      // does nothing. Both outcomes are correct; what may not happen is a
      // panel with an empty square in it.
      if (find.text(nothingYet).evaluate().isNotEmpty) return;

      await _tap(tester, find.text('Show a QR code'));
      await tester.pumpAndSettle();

      // What the code says is printed under it, so somebody without a camera
      // can read it — and so this test can check the code is of the address
      // rather than merely of something.
      final printed = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((text) => text.data)
          .whereType<String>()
          .firstWhere((text) => text.startsWith('oaa://'));
      final link = PairLink.parse(printed);
      expect(link, isNotNull);
      expect(link!.port, container.read(settingsProvider).remoteDisplayPort);
      expect(find.byType(OaaQrCode), findsOneWidget);

      // Nothing is listening yet, and the panel that hands the address out is
      // where that has to be said: a scan against a closed socket is a
      // connection refused with no explanation anywhere.
      expect(find.textContaining('Publishing is off'), findsOneWidget);
    });
  });
}

/// A search that finds nothing and holds nothing.
///
/// The picker owns a browser and the real one owns a socket, an mDNS query
/// timer and — on Android — a platform lock. None of that is what these cases
/// are about, and a widget test that opened a multicast socket would be a test
/// of the network.
class _StaticDiscovery implements HostDiscovery {
  _StaticDiscovery({List<DiscoveredHost> found = const []})
    : hosts = ValueNotifier(found);

  @override
  final ValueNotifier<List<DiscoveredHost>> hosts;

  @override
  final ValueNotifier<bool> isBrowsing = ValueNotifier(false);

  @override
  final ValueNotifier<String?> failure = ValueNotifier(null);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
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
