// SPDX-License-Identifier: GPL-3.0-or-later
//
// What Open Audio Analyzer remembers, tested through the providers rather than
// the widgets.
//
// The layer under test is the one that decides whether a user's work survives
// quitting the application, so the assertions are about the file on disk and
// the state that comes back from it — not about anything being rendered. The
// panels are a thin skin over these calls; if this file is right, they are
// wiring.

import 'dart:io';
import 'dart:ui' show Color;

import 'package:oaa/src/canvas/workspace.dart';
import 'package:oaa/src/data/providers.dart';
import 'package:oaa/src/storage/config_paths.dart';
import 'package:oaa/src/storage/config_store.dart';
import 'package:oaa/src/storage/startup_config.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Directory _tempDir() {
  final directory = Directory.systemTemp.createTempSync('oaa_persist_');
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

ProviderContainer _container(ConfigStore store, [StartupConfig? config]) {
  final container = ProviderContainer(
    overrides: [
      configStoreProvider.overrideWithValue(store),
      startupConfigProvider.overrideWithValue(config ?? const StartupConfig()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

const _houseTarget = Calibration(
  id: 'house',
  name: 'House standard',
  lufsTarget: -12,
  lufsTolerance: 0.5,
  truePeakMax: -1,
  loudnessRangeMax: 14,
);

void main() {
  group('settings', () {
    test('a change reaches the disk', () async {
      final root = _tempDir();
      final store = await _store(root);
      final container = _container(store);

      container.read(settingsProvider.notifier).setTargetFps(30);
      container.read(settingsProvider.notifier).setSkinId('daylight');
      await store.flush();

      final written = await store.readJson(ConfigFile.settings);
      expect(written!['fps'], 30);
      expect(written['skin'], 'daylight');
    });

    test('what was on disk is what the session starts with', () async {
      final store = await _store();
      final container = _container(
        store,
        const StartupConfig(
          settings: AppSettings(targetFps: 120, calibrationId: 'ebu-r128'),
        ),
      );

      expect(container.read(targetFpsProvider), 120);
      expect(container.read(calibrationProvider).id, 'ebu-r128');
    });

    test('selecting a device remembers its name as well as its id', () async {
      // Device ids are not stable across reboots on any of the three
      // platforms; the name is what lets the next launch find the interface
      // the user actually meant.
      final store = await _store();
      final container = _container(store);

      container
          .read(settingsProvider.notifier)
          .setSource(
            AudioSourceKind.device,
            deviceId: 'usb:1234',
            deviceName: 'Scarlett 2i2',
          );

      final settings = container.read(settingsProvider);
      expect(settings.sourceKind, AudioSourceKind.device);
      expect(settings.deviceName, 'Scarlett 2i2');
    });

    test(
      'switching to the test tone keeps the device for coming back',
      () async {
        final store = await _store();
        final container = _container(store);
        final controller = container.read(settingsProvider.notifier);

        controller.setSource(
          AudioSourceKind.device,
          deviceId: 'usb:1234',
          deviceName: 'Scarlett 2i2',
        );
        controller.setSource(AudioSourceKind.testTone);

        expect(container.read(settingsProvider).deviceId, 'usb:1234');
      },
    );
  });

  group('calibrations', () {
    test('the library is the built-ins until a user adds one', () async {
      final container = _container(await _store());
      expect(
        container.read(calibrationLibraryProvider).length,
        BuiltInCalibrations.all.length,
      );
    });

    test('saving a target writes a file and offers it immediately', () async {
      final store = await _store();
      final container = _container(store);

      expect(
        await container
            .read(calibrationLibraryProvider.notifier)
            .save(_houseTarget),
        isTrue,
      );

      expect(
        container.read(calibrationLibraryProvider).map((c) => c.id),
        contains('house'),
      );
      expect(
        await store.readJson('${ConfigDir.calibrations}/house.json'),
        isNotNull,
      );
    });

    test('a user file with a built-in id replaces it rather than duplicating '
        'it', () async {
      // The property that makes the built-in list correctable without a
      // release — including for presets that already reference the id.
      final store = await _store();
      final container = _container(store);
      const corrected = Calibration(
        id: 'ebu-r128',
        name: 'EBU R 128 (corrected)',
        lufsTarget: -23,
        lufsTolerance: 0.5,
        truePeakMax: -2,
        loudnessRangeMax: 20,
      );

      await container.read(calibrationLibraryProvider.notifier).save(corrected);
      final library = container.read(calibrationLibraryProvider);

      expect(library.where((c) => c.id == 'ebu-r128').length, 1);
      expect(library.firstWhere((c) => c.id == 'ebu-r128').truePeakMax, -2);
      expect(library.length, BuiltInCalibrations.all.length);
    });

    test('deleting an override brings the built-in back', () async {
      final store = await _store();
      final container = _container(store);
      const corrected = Calibration(
        id: 'ebu-r128',
        name: 'EBU R 128 (corrected)',
        lufsTarget: -23,
        lufsTolerance: 0.5,
        truePeakMax: -2,
        loudnessRangeMax: 20,
      );

      final notifier = container.read(calibrationLibraryProvider.notifier);
      await notifier.save(corrected);
      await notifier.remove('ebu-r128');

      final restored = container
          .read(calibrationLibraryProvider)
          .firstWhere((c) => c.id == 'ebu-r128');
      expect(restored.truePeakMax, -1);
      expect(restored.name, BuiltInCalibrations.ebuR128.name);
    });

    test('a user target loaded at startup is in the library', () async {
      final container = _container(
        await _store(),
        const StartupConfig(calibrations: [_houseTarget]),
      );

      expect(
        container.read(calibrationLibraryProvider).map((c) => c.id),
        contains('house'),
      );
    });

    test('an id nothing answers to falls back rather than throwing', () async {
      // What happens when a preset names a target the user has since deleted.
      final container = _container(
        await _store(),
        const StartupConfig(settings: AppSettings(calibrationId: 'deleted')),
      );

      expect(
        container.read(calibrationProvider).id,
        BuiltInCalibrations.fallback.id,
      );
    });

    test('the active target follows the setting', () async {
      final container = _container(await _store());

      container.read(settingsProvider.notifier).setCalibrationId('podcast-16');
      expect(container.read(calibrationProvider).id, 'podcast-16');
    });
  });

  group('skins', () {
    test('the palette follows the selected skin', () async {
      final container = _container(await _store());

      expect(container.read(paletteProvider), OaaColors.precisionInstrument);

      container.read(settingsProvider.notifier).setSkinId('daylight');
      expect(container.read(paletteProvider).isLight, isTrue);
    });

    test('the palette is one instance per skin, not one per read', () async {
      // Load-bearing: every module painter compares its palette in
      // shouldRepaint, and a fresh instance per read would re-rasterise all
      // thirteen modules on any rebuild.
      final container = _container(await _store());

      expect(
        identical(
          container.read(paletteProvider),
          container.read(paletteProvider),
        ),
        isTrue,
      );
    });

    test('a skin naming nothing installed falls back', () async {
      final container = _container(
        await _store(),
        const StartupConfig(settings: AppSettings(skinId: 'not-installed')),
      );

      expect(container.read(skinProvider).id, BuiltInSkins.fallback.id);
    });

    test('a user skin overrides only the roles it names', () async {
      const sparse = Skin(
        id: 'mine',
        name: 'Mine',
        colors: {SkinColor.accent: 0xFFFF00FF},
      );
      final container = _container(
        await _store(),
        const StartupConfig(
          skins: [sparse],
          settings: AppSettings(skinId: 'mine'),
        ),
      );

      final palette = container.read(paletteProvider);
      expect(palette.accent, const Color(0xFFFF00FF));
      expect(palette.background, OaaColors.precisionInstrument.background);
    });

    test('reload picks up a skin written since launch', () async {
      final store = await _store();
      final container = _container(store);

      await store.writeJson('${ConfigDir.skins}/mine.json', {
        'id': 'mine',
        'name': 'Mine',
        'colors': {'accent': '#FF00FF'},
      });
      await container.read(skinLibraryProvider.notifier).reload();

      expect(
        container.read(skinLibraryProvider).map((skin) => skin.id),
        contains('mine'),
      );
    });

    test(
      'the built-in palette and the built-in skin have not drifted apart',
      () {
        // The two live in different packages because oaa_core may not import
        // Flutter. This is the check that keeps that from being a slow leak.
        expect(
          oaaColorsFromSkin(BuiltInSkins.precisionInstrument),
          OaaColors.precisionInstrument,
        );
      },
    );

    test('a palette round-trips through a skin document', () {
      final skin = skinFromColors(
        OaaColors.precisionInstrument,
        id: 'copy',
        name: 'Copy',
      );

      expect(skin.colors.length, SkinColor.values.length);
      expect(oaaColorsFromSkin(skin), OaaColors.precisionInstrument);
    });
  });

  group('presets', () {
    PresetSpec preset(String name) => PresetSpec(
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
    );

    test('a saved preset is on disk and in the library', () async {
      final store = await _store();
      final container = _container(store);

      final fileName = await container
          .read(presetLibraryProvider.notifier)
          .save(preset('Mastering'));

      expect(fileName, 'mastering.json');
      expect(
        container.read(presetLibraryProvider).single.preset.name,
        'Mastering',
      );
      expect(
        await store.readJson('${ConfigDir.presets}/mastering.json'),
        isNotNull,
      );
    });

    test('a second preset of the same name gets its own file', () async {
      // Two layouts called "Mastering" is the user's business. Refusing the
      // save would be enforcing a rule the filesystem invented.
      final container = _container(await _store());
      final library = container.read(presetLibraryProvider.notifier);

      expect(await library.save(preset('Mastering')), 'mastering.json');
      expect(await library.save(preset('Mastering')), 'mastering-2.json');
      expect(container.read(presetLibraryProvider).length, 2);
    });

    test('saving over a named file replaces it', () async {
      final container = _container(await _store());
      final library = container.read(presetLibraryProvider.notifier);

      await library.save(preset('Mastering'));
      await library.save(preset('Mastering v2'), fileName: 'mastering.json');

      expect(
        container.read(presetLibraryProvider).single.preset.name,
        'Mastering v2',
      );
    });

    test('a preset survives the round trip through the file', () async {
      final store = await _store();
      final container = _container(store);

      await container
          .read(presetLibraryProvider.notifier)
          .save(preset('Mastering'));
      final reloaded = await loadStartupConfig(store);
      final module = reloaded.presets.single.preset.tabs.single.modules.single;

      expect(module.kind, ModuleKind.numberBox);
      expect(module.rect.columns, 4);
      expect(module.options['metric'], 'lufs_i');
    });

    test('deleting removes both the file and the entry', () async {
      final store = await _store();
      final container = _container(store);
      final library = container.read(presetLibraryProvider.notifier);

      await library.save(preset('Mastering'));
      expect(await library.remove('mastering.json'), isTrue);

      expect(container.read(presetLibraryProvider), isEmpty);
      expect(
        await store.readJson('${ConfigDir.presets}/mastering.json'),
        isNull,
      );
    });

    test('loading one replaces the layout and is undoable', () async {
      final container = _container(await _store());
      final workspace = container.read(workspaceProvider.notifier);
      final before = container.read(workspaceProvider).preset;

      workspace.loadPreset(preset('Mastering'));
      expect(container.read(workspaceProvider).preset.name, 'Mastering');
      expect(container.read(workspaceProvider).activeTab, 0);

      workspace.undo();
      expect(container.read(workspaceProvider).preset, same(before));
    });

    test('an empty preset is refused rather than leaving no canvas', () async {
      final container = _container(await _store());
      final before = container.read(workspaceProvider).preset;

      container
          .read(workspaceProvider.notifier)
          .loadPreset(const PresetSpec(name: 'Empty', tabs: []));

      expect(container.read(workspaceProvider).preset, same(before));
    });
  });

  group('session', () {
    test('the canvas opens on the restored layout', () async {
      final container = _container(
        await _store(),
        StartupConfig(
          session: SessionSnapshot(
            preset: const PresetSpec(
              name: 'Yesterday',
              tabs: [
                TabSpec(name: 'One', modules: []),
                TabSpec(name: 'Two', modules: []),
              ],
            ),
            activeTab: 1,
          ),
        ),
      );

      expect(container.read(workspaceProvider).preset.name, 'Yesterday');
      expect(container.read(workspaceProvider).activeTab, 1);
      expect(container.read(workspaceProvider).tab.name, 'Two');
    });

    test('restoring is not an undoable edit', () async {
      // Yesterday's session is the starting point, not something to undo back
      // out of into a layout the user never had.
      final container = _container(
        await _store(),
        const StartupConfig(
          session: SessionSnapshot(
            preset: PresetSpec(
              name: 'Yesterday',
              tabs: [TabSpec(name: 'One', modules: [])],
            ),
            activeTab: 0,
          ),
        ),
      );

      expect(container.read(workspaceProvider.notifier).canUndo, isFalse);
    });

    test('with nothing saved, the canvas opens on the default', () async {
      final container = _container(await _store());
      expect(
        container.read(workspaceProvider).preset.name,
        defaultPreset().name,
      );
    });
  });

  group('when there is nowhere to write', () {
    test('the application still works, and says why it is not saving', () {
      final store = ConfigStore.disabled();
      addTearDown(store.dispose);
      final container = _container(
        store,
        StartupConfig(notice: store.lastError),
      );

      container.read(settingsProvider.notifier).setTargetFps(30);
      expect(container.read(targetFpsProvider), 30);
      expect(container.read(storageNoticeProvider), isNotNull);
    });

    test('a failed save reports rather than pretending', () async {
      final store = ConfigStore.disabled();
      addTearDown(store.dispose);
      final container = _container(store);

      expect(
        await container
            .read(calibrationLibraryProvider.notifier)
            .save(_houseTarget),
        isFalse,
      );
      expect(container.read(storageNoticeProvider), isNotNull);
    });
  });
}
