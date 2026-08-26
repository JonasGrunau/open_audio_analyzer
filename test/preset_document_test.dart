// SPDX-License-Identifier: GPL-3.0-or-later
//
// The preset as a document: opened, saved, and saved somewhere else.
//
// Two layers, and the split is deliberate. `PresetDocumentController` reads and
// writes a path and needs no widget, so most of this file drives it through a
// `ProviderContainer` and asserts against the file on disk. The commands above
// it open a dialog and ask a question, so those cases pump a tree — with the
// dialogs replaced, because a native save panel is a modal sheet owned by the
// platform and there is nothing in a test to tap.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oaa/src/app/file_menu.dart';
import 'package:oaa/src/app/preset_file.dart';
import 'package:oaa/src/canvas/canvas_notice.dart';
import 'package:oaa/src/canvas/workspace.dart';
import 'package:oaa/src/data/providers.dart';
import 'package:oaa/src/storage/config_store.dart';
import 'package:oaa/src/storage/startup_config.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

// ---------------------------------------------------------------------------
// The scaffolding

Directory _tempDir() {
  final directory = Directory.systemTemp.createTempSync('oaa_document_');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

Future<ConfigStore> _store([Directory? root]) async {
  final store = await ConfigStore.open(
    environment: {kConfigDirEnvVar: (root ?? _tempDir()).path},
  );
  addTearDown(store.dispose);
  return store;
}

/// The store, opened outside the fake-async zone.
///
/// **A `testWidgets` body cannot await real file I/O**, and `ConfigStore.open`
/// creates a directory. The future is completed by the disk on the real event
/// loop, which the fake zone never returns to, so the `await` never completes:
/// the runner kills the test with no error and no stack, and every case after it
/// is reported as "did not complete". This was the first line of five of these
/// tests and it hung all five. `runAsync` runs it in the real zone instead.
Future<ConfigStore> _storeFor(WidgetTester tester) async =>
    (await tester.runAsync(_store))!;

/// The dialogs, answering with whatever the test says and recording that it was
/// asked. [saveTo] being null is the user dismissing the panel.
class _FakeDialogs extends PresetDialogs {
  _FakeDialogs({this.openPath, this.savePath});

  String? openPath;
  String? savePath;

  int opens = 0;
  int saves = 0;
  String? suggestedName;
  String? initialDirectory;

  @override
  Future<String?> open({String? initialDirectory}) async {
    opens++;
    this.initialDirectory = initialDirectory;
    return openPath;
  }

  @override
  Future<String?> save({
    String? initialDirectory,
    required String suggestedName,
  }) async {
    saves++;
    this.initialDirectory = initialDirectory;
    this.suggestedName = suggestedName;
    return savePath;
  }
}

ProviderContainer _container(
  ConfigStore store, {
  PresetDialogs? dialogs,
  StartupConfig? config,
}) {
  final container = ProviderContainer(
    overrides: [
      configStoreProvider.overrideWithValue(store),
      startupConfigProvider.overrideWithValue(config ?? const StartupConfig()),
      if (dialogs != null) presetDialogsProvider.overrideWithValue(dialogs),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

PresetSpec _preset(String name, {String? calibrationId, String? skinId}) =>
    PresetSpec(
      name: name,
      tabs: const [
        TabSpec(
          name: 'Tab',
          modules: [
            ModuleSpec(
              id: 'm1',
              kind: ModuleKind.numberBox,
              rect: GridRect(column: 0, row: 0, columns: 4, rows: 2),
              options: {'metric': 'lufs_i'},
            ),
          ],
        ),
      ],
      calibrationId: calibrationId,
      skinId: skinId,
    );

/// A context and a ref below a `Navigator`, which is what a command needs to
/// put a question on screen.
class _Host extends ConsumerWidget {
  const _Host({required this.onReady});

  final void Function(BuildContext context, WidgetRef ref) onReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onReady(context, ref);
    return const SizedBox.expand();
  }
}

Future<({BuildContext context, WidgetRef ref})> _pump(
  WidgetTester tester,
  ProviderContainer container,
) async {
  BuildContext? context;
  WidgetRef? ref;

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) =>
            OaaTheme(colors: OaaColors.precisionInstrument, child: child!),
        home: _Host(
          onReady: (hostContext, hostRef) {
            context = hostContext;
            ref = hostRef;
          },
        ),
      ),
    ),
  );

  return (context: context!, ref: ref!);
}

/// Waits for a command that touches the disk to have had its effect.
///
/// **The alternation is the whole trick, and it is not optional** — the same one
/// `_untilStored` in `test/panels_test.dart` documents. A command started inside
/// a `testWidgets` body lives in two worlds: the disk I/O only progresses when
/// the *real* event loop runs, which is what `runAsync` is for, but the `await`
/// that resumes afterwards is a microtask in the *fake* zone, which only drains
/// when the test pumps. Yield, pump, check, repeat.
///
/// **And it polls a state rather than awaiting the command's own future.** That
/// future belongs to the fake zone and does not complete inside this loop, so
/// awaiting it hangs the test until the runner kills the process — no error, no
/// stack, and every case after it reported as "did not complete". What is
/// observable is what the command did.
Future<void> _until(
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
  // Applying a carried target writes the settings, and a debounced write left
  // outstanding fails the test at teardown rather than where it was started.
  await tester.pump(ConfigStore.writeDelay + const Duration(milliseconds: 50));
}

/// The file, parsed. Read straight off the disk rather than through the store,
/// so that a test cannot pass because both sides share a bug.
Map<String, Object?> _read(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

void main() {
  group('the open document', () {
    test('a launch has no file and nothing to save', () async {
      final container = _container(await _store());

      expect(container.read(presetDocumentProvider).path, isNull);
      // The default layout has not been edited, so there is no mark. A document
      // that reads as modified before it is touched is a mark nobody believes.
      expect(container.read(presetModifiedProvider), isFalse);
    });

    test('an edit marks it, a save clears it, and undo clears it too', () async {
      final container = _container(await _store());
      final workspace = container.read(workspaceProvider.notifier);
      final path = '${_tempDir().path}/mastering.json';

      workspace.renameTab(0, 'Mix');
      expect(container.read(presetModifiedProvider), isTrue);

      expect(
        await container.read(presetDocumentProvider.notifier).saveTo(path),
        isTrue,
      );
      expect(container.read(presetModifiedProvider), isFalse);

      workspace.renameTab(0, 'Master');
      expect(container.read(presetModifiedProvider), isTrue);

      // The identity of the saved `PresetSpec` is the test, so undoing back to
      // the state that was written puts the mark out — which a boolean flag set
      // by an edit could not do.
      workspace.undo();
      expect(container.read(presetModifiedProvider), isFalse);
    });
  });

  group('saving', () {
    test('writes a preset that reads back as itself', () async {
      final container = _container(await _store());
      final path = '${_tempDir().path}/mastering.json';

      container
          .read(workspaceProvider.notifier)
          .loadPreset(_preset('Mastering'));
      await container.read(presetDocumentProvider.notifier).saveTo(path);

      final json = _read(path);
      expect(json['version'], kConfigSchemaVersion);

      final reloaded = PresetSpec.tryFromJson(json)!;
      final module = reloaded.tabs.single.modules.single;
      expect(reloaded.name, 'Mastering');
      expect(module.kind, ModuleKind.numberBox);
      expect(module.rect.columns, 4);
      expect(module.options['metric'], 'lufs_i');
    });

    test(
      'the file is anywhere the user says, not only the config directory',
      () async {
        // The whole point of the rework: a preset can be put on a Desktop and
        // mailed to somebody.
        final store = await _store();
        final container = _container(store);
        final elsewhere = '${_tempDir().path}/on the desktop.json';

        expect(
          await container
              .read(presetDocumentProvider.notifier)
              .saveTo(elsewhere),
          isTrue,
        );
        expect(File(elsewhere).existsSync(), isTrue);
        expect(elsewhere, isNot(contains(store.root!.path)));
      },
    );

    test('a carried target survives being reopened and saved again', () async {
      // This is the defect the two save switches had: they reset to off every
      // time the panel opened and were never read back from the preset being
      // saved, so opening a layout that carried EBU R 128, moving one module and
      // saving wrote a preset that carried nothing.
      final container = _container(await _store());
      final path = '${_tempDir().path}/broadcast.json';
      File(path).writeAsStringSync(
        jsonEncode(_preset('Broadcast', calibrationId: 'ebu-r128').toJson()),
      );

      final document = container.read(presetDocumentProvider.notifier);
      await document.open(path);
      container.read(workspaceProvider.notifier).renameTab(0, 'Mix');
      await document.saveTo(path);

      expect(_read(path)['calibration'], 'ebu-r128');
    });

    test('a preset that carries nothing writes no target at all', () async {
      final container = _container(await _store());
      final path = '${_tempDir().path}/plain.json';

      container.read(workspaceProvider.notifier).loadPreset(_preset('Plain'));
      await container.read(presetDocumentProvider.notifier).saveTo(path);

      // Absent, not null: absent is what `PresetSpec` reads as "follow whatever
      // is selected".
      expect(_read(path).containsKey('calibration'), isFalse);
      expect(_read(path).containsKey('skin'), isFalse);
    });

    test(
      'carrying stamps the target selected at the moment of the save',
      () async {
        final container = _container(await _store());
        final path = '${_tempDir().path}/carried.json';

        container
            .read(workspaceProvider.notifier)
            .loadPreset(_preset('Carried', calibrationId: 'streaming-14'));
        container.read(settingsProvider.notifier).setCalibrationId('ebu-r128');
        await container.read(presetDocumentProvider.notifier).saveTo(path);

        // Not `streaming-14`, which is what the layout was still holding. What
        // the File menu row prints beside the checkmark is the current target,
        // and this is why it can promise that.
        expect(_read(path)['calibration'], 'ebu-r128');
      },
    );
  });

  group('opening', () {
    test('replaces the layout and adopts the file', () async {
      final container = _container(await _store());
      final path = '${_tempDir().path}/mastering.json';
      File(path).writeAsStringSync(jsonEncode(_preset('Mastering').toJson()));

      expect(
        await container.read(presetDocumentProvider.notifier).open(path),
        isTrue,
      );

      expect(container.read(workspaceProvider).preset.name, 'Mastering');
      expect(container.read(presetDocumentProvider).path, path);
      expect(container.read(presetModifiedProvider), isFalse);
    });

    test('a preset carrying a target applies it', () async {
      final container = _container(await _store());
      final path = '${_tempDir().path}/broadcast.json';
      File(path).writeAsStringSync(
        jsonEncode(_preset('Broadcast', calibrationId: 'ebu-r128').toJson()),
      );

      expect(container.read(calibrationProvider).id, 'streaming-14');
      await container.read(presetDocumentProvider.notifier).open(path);
      expect(container.read(calibrationProvider).id, 'ebu-r128');
    });

    test('a preset carrying nothing leaves the target alone', () async {
      final container = _container(await _store());
      final path = '${_tempDir().path}/plain.json';
      File(path).writeAsStringSync(jsonEncode(_preset('Plain').toJson()));

      container.read(settingsProvider.notifier).setCalibrationId('ebu-r128');
      await container.read(presetDocumentProvider.notifier).open(path);
      expect(container.read(calibrationProvider).id, 'ebu-r128');
    });

    test('a file that is not JSON changes nothing and says so', () async {
      final container = _container(await _store());
      final path = '${_tempDir().path}/broken.json';
      File(path).writeAsStringSync('{ this is not json');

      final before = container.read(workspaceProvider).preset;
      expect(
        await container.read(presetDocumentProvider.notifier).open(path),
        isFalse,
      );

      expect(container.read(workspaceProvider).preset, same(before));
      expect(container.read(presetDocumentProvider).path, isNull);
      // Named, because the user can go and fix it.
      expect(container.read(storageNoticeProvider), contains('broken.json'));
    });

    test('JSON that is not a preset changes nothing and says so', () async {
      final container = _container(await _store());
      final path = '${_tempDir().path}/daylight.json';
      // A skin. Anything at all can be in a file somebody picked.
      File(path).writeAsStringSync(
        jsonEncode({'id': 'daylight', 'name': 'Daylight', 'colors': {}}),
      );

      final before = container.read(workspaceProvider).preset;
      expect(
        await container.read(presetDocumentProvider.notifier).open(path),
        isFalse,
      );

      expect(container.read(workspaceProvider).preset, same(before));
      expect(container.read(canvasNoticeProvider), contains('daylight.json'));
    });

    test(
      'a preset with no tabs is refused rather than opening an empty canvas',
      () async {
        final container = _container(await _store());
        final path = '${_tempDir().path}/empty.json';
        File(path).writeAsStringSync(jsonEncode({'name': 'Empty', 'tabs': []}));

        expect(
          await container.read(presetDocumentProvider.notifier).open(path),
          isFalse,
        );
      },
    );
  });

  group('the commands', () {
    testWidgets('Save with no file asks where, and then stops asking', (
      tester,
    ) async {
      final path = '${_tempDir().path}/mastering.json';
      final dialogs = _FakeDialogs(savePath: path);
      final container = _container(await _storeFor(tester), dialogs: dialogs);
      final host = await _pump(tester, container);

      unawaited(runFileCommand(FileCommand.save, host.context, host.ref));
      await _until(
        tester,
        () => container.read(presetDocumentProvider).path != null,
      );

      expect(dialogs.saves, 1);
      expect(container.read(presetDocumentProvider).path, path);

      // The second one writes to the file it already has. Nothing observable
      // changes, so this waits for the write instead.
      File(path).deleteSync();
      unawaited(runFileCommand(FileCommand.save, host.context, host.ref));
      await _until(tester, () => File(path).existsSync());

      expect(dialogs.saves, 1);
    });

    testWidgets('Save as takes the preset name from the filename', (
      tester,
    ) async {
      final dialogs = _FakeDialogs(
        savePath: '${_tempDir().path}/Mastering Setup.json',
      );
      final container = _container(await _storeFor(tester), dialogs: dialogs);
      final host = await _pump(tester, container);

      // The placeholder is what a layout nobody has saved carries, and it is
      // what the save dialog opens with — so the name changing *is* the
      // observable outcome of this command.
      expect(container.read(workspaceProvider).preset.name, kUnnamedPreset);

      unawaited(runFileCommand(FileCommand.saveAs, host.context, host.ref));
      await _until(
        tester,
        () => container.read(workspaceProvider).preset.name != kUnnamedPreset,
      );

      // The file is the document, so the file's name is the document's name.
      // This is what lets the name field go.
      expect(container.read(workspaceProvider).preset.name, 'Mastering Setup');
      expect(dialogs.suggestedName, '$kUnnamedPreset.json');
    });

    testWidgets('the save dialog opens in the presets folder', (tester) async {
      final store = await _storeFor(tester);
      final dialogs = _FakeDialogs(savePath: '${_tempDir().path}/x.json');
      final container = _container(store, dialogs: dialogs);
      final host = await _pump(tester, container);

      unawaited(runFileCommand(FileCommand.saveAs, host.context, host.ref));
      await _until(tester, () => dialogs.saves == 1);

      expect(dialogs.initialDirectory, contains(ConfigDir.presets));
      // Created on the way past. A dialog pointed at a directory that is not
      // there opens wherever the platform last left it and says nothing.
      expect(Directory(dialogs.initialDirectory!).existsSync(), isTrue);
    });

    testWidgets('a dismissed dialog does nothing at all', (tester) async {
      final dialogs = _FakeDialogs();
      final container = _container(await _storeFor(tester), dialogs: dialogs);
      final host = await _pump(tester, container);

      unawaited(runFileCommand(FileCommand.saveAs, host.context, host.ref));
      await _until(tester, () => dialogs.saves == 1);
      expect(container.read(presetDocumentProvider).path, isNull);

      unawaited(runFileCommand(FileCommand.open, host.context, host.ref));
      await _until(tester, () => dialogs.opens == 1);
      expect(container.read(presetDocumentProvider).path, isNull);
    });

    testWidgets('the carry rows tick, untick, and hold the current choice', (
      tester,
    ) async {
      final container = _container(await _storeFor(tester));
      final host = await _pump(tester, container);

      expect(container.read(workspaceProvider).preset.calibrationId, isNull);

      // Synchronous: nothing here touches the disk.
      unawaited(
        runFileCommand(FileCommand.carryCalibration, host.context, host.ref),
      );
      await tester.pump();
      expect(
        container.read(workspaceProvider).preset.calibrationId,
        container.read(settingsProvider).calibrationId,
      );

      unawaited(
        runFileCommand(FileCommand.carryCalibration, host.context, host.ref),
      );
      await tester.pump();
      expect(container.read(workspaceProvider).preset.calibrationId, isNull);
    });
  });

  // **The menu Windows and Linux draw.** The whole suite runs on a macOS host,
  // where the real answer to `fileMenuInWindowProvider` is false and the button
  // is never built — so without pumping it deliberately this path ships
  // untested on the two platforms that are the only ones to use it.
  //
  // The button alone, not the menu bar it lives in: whether the *row* still
  // fits once FILE is in it is a question about widths, and it is swept at
  // every one of them in `test/scaling_test.dart`, which is also the only file
  // that loads the real fonts. Measuring a layout here would measure the
  // fallback font's metrics instead.
  group('the in-window menu', () {
    // **A debug build draws this button on a Mac and this suite must not see
    // it.** `fileMenuInWindowProvider` reads `kDebugMode`, so that the row two
    // thirds of the platforms ship is on screen for somebody running the
    // application on the machine it is written on — and the suite is also a
    // debug build on a macOS host, so the same term would put the Windows
    // arrangement into every widget test in it and leave the row a Mac ships
    // covered by nothing. `FLUTTER_TEST` is what separates the two, and this is
    // the assertion that fails if it is ever tidied away.
    //
    // Off macOS it reads true either way, which is what the platform does, so
    // this proves nothing on a Linux runner and everything on this desk.
    test('a test run is given the platform, not the debug affordance', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(fileMenuInWindowProvider),
        !Platform.isMacOS,
        reason:
            'The suite is seeing the debug build\'s arrangement of the menu '
            'bar rather than this platform\'s. Every width gate in '
            'test/scaling_test.dart is measured against the platform\'s.',
      );
    });

    test('and the arrangement each of the three runs gets', () {
      // A Mac ships the system menu bar and nothing in the window; a debug run
      // on one draws the button as well, so the row can be looked at; and the
      // suite, which is a debug run on a Mac too, is given what a Mac ships.
      expect(
        fileMenuInWindow(macOS: true, debug: false, underTest: false),
        isFalse,
      );
      expect(
        fileMenuInWindow(macOS: true, debug: true, underTest: false),
        isTrue,
      );
      expect(
        fileMenuInWindow(macOS: true, debug: true, underTest: true),
        isFalse,
      );

      // Everywhere else the button is the product, in every build there is.
      for (final debug in [true, false]) {
        for (final underTest in [true, false]) {
          expect(
            fileMenuInWindow(macOS: false, debug: debug, underTest: underTest),
            isTrue,
            reason: 'Windows and Linux have no other File menu to fall back on',
          );
        }
      }
    });

    Future<ProviderContainer> pumpButton(WidgetTester tester) async {
      final store = ConfigStore.disabled();
      addTearDown(store.dispose);
      final container = ProviderContainer(
        overrides: [
          configStoreProvider.overrideWithValue(store),
          startupConfigProvider.overrideWithValue(const StartupConfig()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) =>
                OaaTheme(colors: OaaColors.precisionInstrument, child: child!),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: FileMenuButton(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    testWidgets('FILE opens a menu of every command', (tester) async {
      await pumpButton(tester);
      expect(find.text('FILE'), findsOneWidget);

      await tester.tap(find.text('FILE'));
      await tester.pumpAndSettle();

      // Every row, and the chords printed beside them — which is the whole
      // reason this menu prints them: on Windows and Linux there is no system
      // menu bar to read a chord off.
      // Asserted against the enum rather than against typed strings: what has
      // to be true is that every command has a row and every chord is printed
      // beside it, and the wording of a row is a design decision that may move.
      for (final command in FileCommand.values) {
        // Exact for the actions, because "Save as…" contains "Save"; the two
        // toggles print the value they would store after their label.
        expect(
          command.isToggle
              ? find.textContaining(command.label)
              : find.text(command.label),
          findsOneWidget,
          reason: 'no row for ${command.id}',
        );
      }

      expect(find.text('Ctrl+O'), findsOneWidget);
      expect(find.text('Ctrl+I'), findsOneWidget);
      expect(find.text('Ctrl+S'), findsOneWidget);
      expect(find.text('Ctrl+Shift+S'), findsOneWidget);
    });

    // **One column of labels and one column of chords.** Both were wrong at
    // once and both are invisible to every other assertion in this file: the
    // rows carried their chord packed against the end of the label, so `Ctrl+O`
    // sat 90 px left of `Ctrl+I`, and the two toggles reserved the check's
    // column while the four actions did not, so the labels stepped sideways at
    // the divider. macOS draws this same menu from the same table with all six
    // labels in one column and every chord against the right edge, which is
    // what the two platforms that build *this* one should also get.
    //
    // Measured rather than looked at, and positions only: this file does not
    // load the shipped typefaces, so a label's width here is the fallback
    // font's. Where a label *starts* and where a chord column *ends* are
    // padding and layout, and neither moves with the font.
    testWidgets('every label starts in one column, every chord ends in one', (
      tester,
    ) async {
      await pumpButton(tester);
      await tester.tap(find.text('FILE'));
      await tester.pumpAndSettle();

      final labels = <String, double>{
        for (final command in FileCommand.values)
          command.id: tester
              .getTopLeft(
                command.isToggle
                    ? find.textContaining(command.label)
                    : find.text(command.label),
              )
              .dx,
      };
      final column = labels.values.first;
      for (final entry in labels.entries) {
        expect(
          entry.value,
          moreOrLessEquals(column, epsilon: 0.5),
          reason:
              '${entry.key} starts at ${entry.value.toStringAsFixed(1)} px '
              'where the rest of the menu starts at '
              '${column.toStringAsFixed(1)}. A menu that mixes actions with '
              'ticked rows still has one column of labels — see '
              'OaaMenuRow.reservesCheck.',
        );
      }

      final chords = <String, double>{
        for (final chord in ['Ctrl+O', 'Ctrl+I', 'Ctrl+S', 'Ctrl+Shift+S'])
          chord: tester.getTopRight(find.text(chord)).dx,
      };
      final edge = chords.values.first;
      for (final entry in chords.entries) {
        expect(
          entry.value,
          moreOrLessEquals(edge, epsilon: 0.5),
          reason:
              '${entry.key} ends at ${entry.value.toStringAsFixed(1)} px where '
              'the other chords end at ${edge.toStringAsFixed(1)}. The chords '
              'are a column at the right of the menu, not a suffix on the '
              'label.',
        );
      }
    });

    // A tick is a checkbox here and not one option of several: both rows can
    // be on, both can be off, and neither is unavailable. Muted ink is what a
    // menu of options uses for the values it does not hold, and it read as two
    // commands that could not be pressed.
    testWidgets('an unticked row is drawn in the same ink as an action', (
      tester,
    ) async {
      await pumpButton(tester);
      await tester.tap(find.text('FILE'));
      await tester.pumpAndSettle();

      Color? inkOf(Finder finder) => tester.widget<Text>(finder).style?.color;

      final action = inkOf(find.text(FileCommand.open.label));
      expect(action, OaaColors.precisionInstrument.textPrimary);
      for (final command in FileCommand.values.where((c) => c.isToggle)) {
        expect(
          inkOf(find.textContaining(command.label)),
          action,
          reason: '${command.id} is unticked and drawn as though disabled',
        );
      }
    });

    testWidgets('a carry row ticks from the menu', (tester) async {
      final container = await pumpButton(tester);
      expect(container.read(workspaceProvider).preset.calibrationId, isNull);

      await tester.tap(find.text('FILE'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(FileCommand.carryCalibration.label));
      await tester.pumpAndSettle();

      expect(
        container.read(workspaceProvider).preset.calibrationId,
        container.read(settingsProvider).calibrationId,
      );
    });
  });

  // **What greys the macOS menu, tested where it can be.** The menu itself is
  // AppKit's and does nothing off macOS, but the thing that decides its enabled
  // state is a plain `NavigatorObserver` — and the half that matters is that it
  // comes *back*: a menu that greyed when a panel opened and stayed grey would
  // be a File menu nobody could use for the rest of the session.
  group('the route depth the menu greys on', () {
    testWidgets('rises with a panel and falls again when it closes', (
      tester,
    ) async {
      final depth = RouteDepth();
      late BuildContext context;

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [depth],
          builder: (context, child) =>
              OaaTheme(colors: OaaColors.precisionInstrument, child: child!),
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );

      // The application itself is one route, and one is not busy.
      expect(depth.depth.value, 1);
      expect(depth.isBusy, isFalse);

      final answer = showOaaConfirm(
        context: context,
        title: 'A question',
        message: 'Well?',
        confirmLabel: 'Yes',
      );
      await tester.pumpAndSettle();
      expect(depth.isBusy, isTrue);

      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();
      await answer;

      expect(depth.depth.value, 1);
      expect(depth.isBusy, isFalse);
    });
  });

  group('opening over work that is not saved', () {
    Future<
      ({
        ProviderContainer container,
        _FakeDialogs dialogs,
        BuildContext context,
        WidgetRef ref,
      })
    >
    setUpUnsaved(WidgetTester tester) async {
      final path = '${_tempDir().path}/other.json';
      File(path).writeAsStringSync(jsonEncode(_preset('Other').toJson()));

      final dialogs = _FakeDialogs(
        openPath: path,
        savePath: '${_tempDir().path}/mine.json',
      );
      final container = _container(await _storeFor(tester), dialogs: dialogs);
      final host = await _pump(tester, container);

      container.read(workspaceProvider.notifier).renameTab(0, 'Mine');
      expect(container.read(presetModifiedProvider), isTrue);

      return (
        container: container,
        dialogs: dialogs,
        context: host.context,
        ref: host.ref,
      );
    }

    testWidgets('Cancel leaves the layout and never opens a dialog', (
      tester,
    ) async {
      final it = await setUpUnsaved(tester);
      final before = it.container.read(workspaceProvider).preset;

      unawaited(runFileCommand(FileCommand.open, it.context, it.ref));
      // The question is put up synchronously, so one settle renders it.
      await tester.pumpAndSettle();
      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();

      expect(it.container.read(workspaceProvider).preset, same(before));
      // Asked before the dialog, not after it: somebody about to lose an
      // arrangement should find out before they have chosen a file.
      expect(it.dialogs.opens, 0);
    });

    testWidgets("Don't Save replaces the layout without writing anything", (
      tester,
    ) async {
      final it = await setUpUnsaved(tester);

      unawaited(runFileCommand(FileCommand.open, it.context, it.ref));
      await tester.pumpAndSettle();
      await tester.tap(find.text("DON'T SAVE"));
      await _until(
        tester,
        () => it.container.read(workspaceProvider).preset.name == 'Other',
      );

      expect(it.container.read(workspaceProvider).preset.name, 'Other');
      expect(it.dialogs.saves, 0);
    });

    testWidgets('Save writes first, then opens', (tester) async {
      final it = await setUpUnsaved(tester);

      unawaited(runFileCommand(FileCommand.open, it.context, it.ref));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SAVE'));
      await _until(
        tester,
        () => it.container.read(workspaceProvider).preset.name == 'Other',
      );

      expect(it.dialogs.saves, 1);
      expect(File(it.dialogs.savePath!).existsSync(), isTrue);
      expect(it.container.read(workspaceProvider).preset.name, 'Other');
    });
  });
}
