// SPDX-License-Identifier: GPL-3.0-or-later
//
// The skin editor, through the pointer and the keyboard.
//
// The thing this file exists to hold down is the *draft*. Every colour the
// editor changes goes into `skinDraftProvider`, which `skinProvider` answers
// with — so a bug here is not a panel that looks wrong, it is an application
// that is left wearing a skin nobody saved, or one that quietly writes a file
// per pointer move. Both are invisible in a screenshot.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/data/providers.dart';
import 'package:oaa/src/panels/theme_editor.dart';
import 'package:oaa/src/storage/config_store.dart';
import 'package:oaa/src/storage/startup_config.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

typedef _Harness = ({ProviderContainer container, Directory directory});

/// A container over a real, empty configuration directory.
///
/// Real rather than disabled: this panel's whole second half is about files
/// landing, and with a disabled store every save correctly fails and every
/// assertion after it means nothing. See `test/panels_test.dart`, which says
/// the same thing at more length.
Future<_Harness> _harness(
  WidgetTester tester, {
  String? skinId,
  List<Skin> skins = const [],
}) async {
  final directory = Directory.systemTemp.createTempSync('oaa_theme_');
  final store = (await tester.runAsync(
    () => ConfigStore.open(environment: {kConfigDirEnvVar: directory.path}),
  ))!;

  final container = ProviderContainer(
    overrides: [
      configStoreProvider.overrideWithValue(store),
      startupConfigProvider.overrideWithValue(
        StartupConfig(
          skins: skins,
          settings: AppSettings(
            skinId: skinId ?? BuiltInSkins.precisionInstrument.id,
          ),
        ),
      ),
    ],
  );

  addTearDown(() {
    container.dispose();
    store.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return (container: container, directory: directory);
}

/// Pumps an application and opens the editor the way Settings does.
///
/// The palette goes through `MaterialApp.builder`, above the `Navigator`,
/// because that is where `OaaApp` puts it and a harness that wraps `home`
/// instead cannot see a panel failing to follow the skin it is used to change.
Future<void> _open(WidgetTester tester, _Harness harness, {Skin? base}) async {
  tester.view
    ..physicalSize = const Size(1200, 1800)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: Consumer(
        builder: (context, ref, _) {
          final colors = ref.watch(paletteProvider);
          return MaterialApp(
            theme: oaaThemeData(colors),
            builder: (context, child) =>
                OaaTheme(colors: colors, child: child!),
            home: Material(
              child: Center(
                child: Consumer(
                  builder: (context, ref, _) => GestureDetector(
                    onTap: () => showThemeEditor(
                      context,
                      ref,
                      base: base ?? ref.read(skinProvider),
                    ),
                    child: const Text('open the panel'),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  await tester.tap(find.text('open the panel'));
  await tester.pumpAndSettle();
}

/// See `_untilStored` in `test/panels_test.dart` — the alternation between the
/// real event loop and the fake one is the whole trick and is not optional.
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
  // Saving selects what it saved, which schedules a settings write. Leaving
  // that timer outstanding fails the test at teardown.
  await tester.pump(ConfigStore.writeDelay + const Duration(milliseconds: 50));
}

Future<void> _press(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The well in the row labelled [role].
Finder _well(String role) => find.descendant(
  of: find.ancestor(of: find.text(role), matching: find.byType(Row)).last,
  matching: find.byType(OaaColorWell),
);

Future<void> _expand(WidgetTester tester, String role) =>
    _press(tester, _well(role));

File _skinFile(Directory directory, String id) =>
    File('${directory.path}/skins/$id.json');

void main() {
  group('the draft', () {
    testWidgets('previews on the application without writing anything', (
      tester,
    ) async {
      final harness = await _harness(tester);
      await _open(tester, harness);

      final before = harness.container.read(paletteProvider).accent;
      await _expand(tester, 'Accent');

      // The top-left of the saturation/value plane is white. Nothing about the
      // default skin is white, so this is a change nobody can mistake for a
      // rounding difference.
      final plane = find.bySemanticsLabel('Accent saturation and brightness');
      await tester.tapAt(tester.getRect(plane).topLeft + const Offset(4, 4));
      await tester.pumpAndSettle();

      final after = harness.container.read(paletteProvider).accent;
      expect(after, isNot(before));
      expect(harness.container.read(skinDraftProvider), isNotNull);

      // The whole application is wearing it, including the panel drawn over
      // the canvas — that is what makes this a preview rather than a form.
      expect(
        OaaTheme.read(tester.element(find.byType(PanelScaffold))).accent,
        after,
      );

      // And nothing has been written. A file per pointer move is the failure
      // this arrangement exists to avoid.
      expect(
        _skinFile(
          harness.directory,
          BuiltInSkins.precisionInstrument.id,
        ).existsSync(),
        isFalse,
      );
    });

    testWidgets('is dropped when the panel closes, however it closes', (
      tester,
    ) async {
      final harness = await _harness(tester);
      await _open(tester, harness);
      final before = harness.container.read(paletteProvider).accent;

      await _expand(tester, 'Accent');
      final plane = find.bySemanticsLabel('Accent saturation and brightness');
      await tester.tapAt(tester.getRect(plane).topLeft + const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(harness.container.read(paletteProvider).accent, isNot(before));

      // Dirty, so the first press asks rather than discards.
      await _press(tester, find.text('×'));
      expect(find.byType(PanelScaffold), findsOneWidget);
      expect(find.textContaining('Unsaved changes'), findsOneWidget);

      await _press(tester, find.text('×'));
      expect(find.byType(PanelScaffold), findsNothing);
      expect(harness.container.read(skinDraftProvider), isNull);
      expect(harness.container.read(paletteProvider).accent, before);
    });

    testWidgets('closes on the first press when nothing has been touched', (
      tester,
    ) async {
      final harness = await _harness(tester);
      await _open(tester, harness);

      await _press(tester, find.text('×'));
      expect(find.byType(PanelScaffold), findsNothing);
      expect(harness.container.read(skinDraftProvider), isNull);
    });

    testWidgets('reverts to the skin the editor opened on', (tester) async {
      final harness = await _harness(tester);
      await _open(tester, harness);
      final before = harness.container.read(paletteProvider).accent;

      await _expand(tester, 'Accent');
      final plane = find.bySemanticsLabel('Accent saturation and brightness');
      await tester.tapAt(tester.getRect(plane).topLeft + const Offset(4, 4));
      await tester.pumpAndSettle();

      await _press(tester, find.text('REVERT'));
      expect(harness.container.read(paletteProvider).accent, before);
      // Nothing to revert to any more, so the button is gone.
      expect(find.text('REVERT'), findsNothing);
    });
  });

  group('the colour picker', () {
    testWidgets('takes a hex value on submit', (tester) async {
      final harness = await _harness(tester);
      await _open(tester, harness);
      await _expand(tester, 'Accent');

      await tester.enterText(find.byType(TextField).last, '#FF8800');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        skinArgb(harness.container.read(paletteProvider).accent),
        0xFFFF8800,
      );
    });

    testWidgets('puts an unreadable hex back rather than clearing it', (
      tester,
    ) async {
      final harness = await _harness(tester);
      await _open(tester, harness);
      await _expand(tester, 'Accent');
      final before = harness.container.read(paletteProvider).accent;

      await tester.enterText(find.byType(TextField).last, 'not a colour');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(harness.container.read(paletteProvider).accent, before);
      expect(find.text(Skin.formatHex(skinArgb(before))), findsWidgets);
    });

    testWidgets('moves on the arrow keys, ten times as far with shift', (
      tester,
    ) async {
      final harness = await _harness(tester);
      await _open(tester, harness);
      await _expand(tester, 'Accent');

      final plane = find.bySemanticsLabel('Accent saturation and brightness');
      // A tap both sets the colour and gives the plane focus, which is what
      // puts the arrows on it rather than on the canvas underneath.
      await tester.tapAt(tester.getRect(plane).center);
      await tester.pumpAndSettle();
      final start = HSVColor.fromColor(
        harness.container.read(paletteProvider).accent,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      final one = HSVColor.fromColor(
        harness.container.read(paletteProvider).accent,
      );
      expect(one.saturation, greaterThan(start.saturation));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      final ten = HSVColor.fromColor(
        harness.container.read(paletteProvider).accent,
      );

      // Ten steps against one, allowing for the round trip through eight-bit
      // channels — the point is the ratio, not the third decimal.
      expect(
        ten.saturation - one.saturation,
        greaterThan((one.saturation - start.saturation) * 5),
      );
    });

    testWidgets('only one picker is open at a time', (tester) async {
      final harness = await _harness(tester);
      await _open(tester, harness);

      await _expand(tester, 'Accent');
      expect(find.byType(OaaColorPicker), findsOneWidget);

      await _expand(tester, 'Warn');
      expect(find.byType(OaaColorPicker), findsOneWidget);
      expect(
        find.bySemanticsLabel('Warn saturation and brightness'),
        findsOneWidget,
      );
    });
  });

  group('contrast', () {
    testWidgets('marks a role that falls below its floor, and still saves', (
      tester,
    ) async {
      final harness = await _harness(tester);
      await _open(tester, harness);

      expect(find.textContaining('below the contrast floor'), findsNothing);

      // The panel colour, in the role that has to be read against it — the
      // 1.10:1 meter track that shipped, reproduced through the interface.
      await _expand(tester, 'Meter track');
      await tester.enterText(
        find.byType(TextField).last,
        Skin.formatHex(
          BuiltInSkins.precisionInstrument.colors[SkinColor.panel]!,
        ),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.textContaining('below the contrast floor'), findsOneWidget);
      expect(find.textContaining('below the 1.40:1'), findsOneWidget);

      // And it is a warning rather than a refusal, the same way the file
      // parser tolerates a typo'd key rather than declining to start.
      expect(
        tester
            .widget<OaaButton>(
              find.ancestor(
                of: find.text('SAVE AS NEW'),
                matching: find.byType(OaaButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('the built-in skins are fixed points', () {
    testWidgets('offer neither an in-place save nor a delete', (tester) async {
      final harness = await _harness(tester);
      await _open(tester, harness);

      expect(find.text('SAVE'), findsNothing);
      expect(find.text('DELETE'), findsNothing);
      expect(find.text('SAVE AS NEW'), findsOneWidget);
      // Said before anything is touched rather than after a refusal.
      expect(
        find.textContaining('cannot be changed or deleted'),
        findsOneWidget,
      );
    });

    testWidgets('preview live all the same, and copy on save', (tester) async {
      final harness = await _harness(tester);
      await _open(tester, harness);

      await _expand(tester, 'Accent');
      await tester.enterText(find.byType(TextField).last, '#FF8800');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Editing one is not refused — it is where a new skin comes from.
      expect(
        skinArgb(harness.container.read(paletteProvider).accent),
        0xFFFF8800,
      );

      final copy = _skinFile(harness.directory, 'precision-instrument-copy');
      await _press(tester, find.text('SAVE AS NEW'));
      await _untilStored(tester, copy.existsSync);

      expect(copy.existsSync(), isTrue);
      // The built-in has no file of its own and never gains one.
      expect(
        _skinFile(
          harness.directory,
          BuiltInSkins.precisionInstrument.id,
        ).existsSync(),
        isFalse,
      );
      expect(
        harness.container
            .read(skinLibraryProvider.notifier)
            .byId(BuiltInSkins.precisionInstrument.id),
        BuiltInSkins.precisionInstrument,
      );
      expect(
        harness.container.read(settingsProvider).skinId,
        'precision-instrument-copy',
      );
    });

    testWidgets('a copy leaves the panel open, editing the copy', (
      tester,
    ) async {
      final harness = await _harness(tester);
      await _open(tester, harness);

      final copy = _skinFile(harness.directory, 'precision-instrument-copy');
      await _press(tester, find.text('SAVE AS NEW'));
      await _untilStored(tester, copy.existsSync);

      // Still open, and now the editor for what was written rather than for
      // the built-in it came from. Popping and reopening was the first shape
      // of this and raced the draft's lifetime — see `_save`.
      expect(find.byType(PanelScaffold), findsOneWidget);
      expect(find.textContaining('cannot be changed'), findsNothing);
      expect(find.text('SAVE'), findsOneWidget);
      expect(find.text('DELETE'), findsOneWidget);

      // The name it was given is in the field, and nothing is unsaved.
      expect(find.text('Precision Instrument copy'), findsOneWidget);
      expect(find.text('REVERT'), findsNothing);

      // Saving again writes the same file rather than a second copy.
      await _expand(tester, 'Accent');
      await tester.enterText(find.byType(TextField).last, '#FF8800');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await _press(tester, find.text('SAVE'));
      await _untilStored(
        tester,
        () => copy.readAsStringSync().contains('#FF8800'),
      );

      expect(
        _skinFile(
          harness.directory,
          'precision-instrument-copy-2',
        ).existsSync(),
        isFalse,
      );
    });

    testWidgets('the library refuses a built-in id whoever asks', (
      tester,
    ) async {
      final harness = await _harness(tester);
      await _open(tester, harness);
      final library = harness.container.read(skinLibraryProvider.notifier);

      final saved = await tester.runAsync(
        () => library.save(
          BuiltInSkins.daylight.copyWith(
            colors: {SkinColor.accent: 0xFF00FF00},
          ),
        ),
      );
      expect(saved, isFalse);
      expect(
        _skinFile(harness.directory, BuiltInSkins.daylight.id).existsSync(),
        isFalse,
      );
      expect(
        harness.container.read(storageNoticeProvider),
        contains('cannot be changed'),
      );
      expect(
        await tester.runAsync(() => library.remove(BuiltInSkins.daylight.id)),
        isFalse,
      );
    });

    testWidgets('a file on disk naming a built-in does not shadow it', (
      tester,
    ) async {
      // Somebody who wrote one before this rule existed, or by hand. It loads
      // and is ignored rather than quietly redefining the reference palette.
      final harness = await _harness(
        tester,
        skins: [
          Skin(
            id: BuiltInSkins.precisionInstrument.id,
            name: 'Impostor',
            colors: const {SkinColor.accent: 0xFF00FF00},
          ),
        ],
      );
      await _open(tester, harness);

      expect(
        harness.container
            .read(skinLibraryProvider.notifier)
            .byId(BuiltInSkins.precisionInstrument.id),
        BuiltInSkins.precisionInstrument,
      );
      expect(
        harness.container.read(skinLibraryProvider).map((s) => s.name),
        isNot(contains('Impostor')),
      );
    });
  });

  group('a skin of your own', () {
    Skin mine() => BuiltInSkins.precisionInstrument.resolved().copyWith(
      id: 'mine',
      name: 'Mine',
    );

    testWidgets('saves in place, over its own file', (tester) async {
      final harness = await _harness(tester, skinId: 'mine', skins: [mine()]);
      await _open(tester, harness);

      expect(find.text('SAVE'), findsOneWidget);
      expect(find.textContaining('cannot be changed'), findsNothing);

      await _expand(tester, 'Accent');
      await tester.enterText(find.byType(TextField).last, '#FF8800');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final file = _skinFile(harness.directory, 'mine');
      await _press(tester, find.text('SAVE'));
      await _untilStored(tester, file.existsSync);

      final written = Skin.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
      )!;
      expect(written.id, 'mine');
      expect(written.colors[SkinColor.accent], 0xFFFF8800);
      // Complete, not sparse. A file the editor wrote names all thirteen, so
      // it can be hand-edited afterwards without going to find the rest.
      expect(written.colors, hasLength(SkinColor.values.length));

      // And it survives the draft being dropped — the half that would silently
      // not work if saving forgot to select what it wrote.
      await _press(tester, find.text('×'));
      expect(harness.container.read(skinDraftProvider), isNull);
      expect(
        skinArgb(harness.container.read(paletteProvider).accent),
        0xFFFF8800,
      );
    });

    testWidgets('takes its id from the name it was given', (tester) async {
      final harness = await _harness(tester);
      await _open(tester, harness);

      await tester.enterText(find.byType(TextField).first, 'Midnight');
      await tester.pumpAndSettle();

      final file = _skinFile(harness.directory, 'midnight');
      await _press(tester, find.text('SAVE AS NEW'));
      await _untilStored(tester, file.existsSync);

      expect(file.existsSync(), isTrue);
      // Renamed, so it is not "Midnight copy".
      expect(
        Skin.fromJson(
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
        )!.name,
        'Midnight',
      );
      expect(harness.container.read(settingsProvider).skinId, 'midnight');
    });

    testWidgets('deletes, confirming in place, and falls back', (tester) async {
      final harness = await _harness(tester, skinId: 'mine', skins: [mine()]);
      await _open(tester, harness);

      // Written first, so there is a file to delete: the startup config
      // describes what was on disk, and this suite starts with an empty one.
      final file = _skinFile(harness.directory, 'mine');
      await _press(tester, find.text('SAVE'));
      await _untilStored(tester, file.existsSync);

      // Confirms in place: the button becomes the question and takes a second
      // press. No modal over a modal, and no undo stack for files.
      await _press(tester, find.text('DELETE'));
      expect(find.text('DELETE?'), findsOneWidget);
      await _press(tester, find.text('DELETE?'));

      // Waits for the *end state* rather than for the file. Deleting is two
      // steps — the unlink, and then the pop its continuation performs — and a
      // poll that stops at the first can stop between them: the file is gone
      // on disk while the `await` that noticed has not had a turn in the fake
      // zone yet.
      await _untilStored(
        tester,
        () => find.byType(PanelScaffold).evaluate().isEmpty,
      );

      expect(file.existsSync(), isFalse);
      expect(find.byType(PanelScaffold), findsNothing);
      expect(
        harness.container.read(skinLibraryProvider).map((s) => s.id),
        isNot(contains('mine')),
      );
      // The settings still name it; the provider falls back rather than
      // leaving the application with no palette at all.
      expect(
        harness.container.read(paletteProvider),
        oaaColorsFromSkin(BuiltInSkins.fallback),
      );
    });
  });
}
