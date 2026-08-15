// SPDX-License-Identifier: GPL-3.0-or-later
//
// The persistence layer, tested against a real filesystem.
//
// A temporary directory rather than an in-memory fake: everything this layer
// exists to get right — the atomic rename, the tolerance for a file somebody
// hand-edited badly, the directory that does not exist yet — is a property of
// an actual filesystem, and a fake would only assert that the fake behaves the
// way the author assumed the filesystem does.

import 'dart:convert';
import 'dart:io';

import 'package:bel/src/storage/config_paths.dart';
import 'package:bel/src/storage/config_store.dart';
import 'package:bel/src/storage/startup_config.dart';
import 'package:bel_core/bel_core.dart';
import 'package:flutter_test/flutter_test.dart';

Directory _tempDir() {
  final directory = Directory.systemTemp.createTempSync('bel_test_');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

Future<ConfigStore> _store(Directory root) async {
  final store = await ConfigStore.open(
    environment: {kConfigDirEnvVar: root.path},
  );
  addTearDown(store.dispose);
  return store;
}

void main() {
  group('resolveConfigRoot', () {
    test('macOS uses Application Support', () {
      expect(
        resolveConfigRoot(
          operatingSystem: 'macos',
          environment: {'HOME': '/Users/jo'},
        ),
        '/Users/jo/Library/Application Support/Bel',
      );
    });

    test('Windows uses APPDATA', () {
      expect(
        resolveConfigRoot(
          operatingSystem: 'windows',
          environment: {'APPDATA': r'C:\Users\jo\AppData\Roaming'},
        ),
        r'C:\Users\jo\AppData\Roaming\Bel',
      );
    });

    test('Linux prefers XDG_CONFIG_HOME over HOME', () {
      expect(
        resolveConfigRoot(
          operatingSystem: 'linux',
          environment: {'HOME': '/home/jo', 'XDG_CONFIG_HOME': '/home/jo/.cfg'},
        ),
        '/home/jo/.cfg/bel',
      );
      expect(
        resolveConfigRoot(
          operatingSystem: 'linux',
          environment: {'HOME': '/home/jo'},
        ),
        '/home/jo/.config/bel',
      );
    });

    test('the override beats every platform rule', () {
      for (final os in ['macos', 'windows', 'linux']) {
        expect(
          resolveConfigRoot(
            operatingSystem: os,
            environment: {kConfigDirEnvVar: '/tmp/bel', 'HOME': '/home/jo'},
          ),
          '/tmp/bel',
        );
      }
    });

    test('an environment with nothing in it resolves to nothing', () {
      // A legitimate state — a stripped service environment, some CI
      // containers. Bel runs without persistence rather than guessing `/` and
      // failing at write time.
      expect(
        resolveConfigRoot(operatingSystem: 'linux', environment: {}),
        isNull,
      );
      expect(
        resolveConfigRoot(operatingSystem: 'windows', environment: {}),
        isNull,
      );
    });
  });

  group('slugify', () {
    test('makes a filename out of anything', () {
      expect(slugify('Mastering'), 'mastering');
      expect(slugify('Streaming (−14 LUFS)'), 'streaming-14-lufs');
      expect(slugify('  spaced  out  '), 'spaced-out');
      expect(slugify('a/b\\c:d'), 'a-b-c-d');
    });

    test('never returns something that is not a filename', () {
      expect(slugify(''), 'untitled');
      expect(slugify('///'), 'untitled');
      expect(slugify('...'), 'untitled');
      expect(slugify('a' * 200).length, lessThanOrEqualTo(64));
      for (final name in ['', '///', 'ü', '2001']) {
        expect(slugify(name), isNotEmpty);
        expect(slugify(name).endsWith('-'), isFalse);
      }
    });
  });

  group('ConfigStore', () {
    test('creates its directory and round-trips a document', () async {
      final root = _tempDir();
      final store = await _store(Directory('${root.path}/nested/deeper'));

      expect(store.isAvailable, isTrue);
      expect(await store.writeJson('settings.json', {'fps': 120}), isTrue);
      expect(await store.readJson('settings.json'), {'fps': 120});
    });

    test('writes are atomic and leave no temporary file behind', () async {
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson('presets/one.json', {'name': 'One'});
      final files = Directory(
        '${root.path}/presets',
      ).listSync().map((e) => e.uri.pathSegments.last).toList();

      expect(files, ['one.json']);
    });

    test('a missing file is null, not an error', () async {
      final store = await _store(_tempDir());
      expect(await store.readJson('nothing.json'), isNull);
      expect(store.lastError, isNull);
    });

    test('a corrupt file is reported by name, not thrown', () async {
      final root = _tempDir();
      final store = await _store(root);
      File('${root.path}/settings.json').writeAsStringSync('{ nope, }');

      expect(await store.readJson('settings.json'), isNull);
      expect(store.lastError, contains('settings.json'));
    });

    test('one broken document does not cost the others', () async {
      // The whole argument for a directory of small files rather than one big
      // one: a user who breaks a skin loses that skin.
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson('skins/good.json', {'id': 'good'});
      await store.writeJson('skins/also-good.json', {'id': 'also-good'});
      File('${root.path}/skins/broken.json').writeAsStringSync('not json');
      File('${root.path}/skins/notes.txt').writeAsStringSync('ignored');

      final documents = await store.readDirectory('skins');
      expect(documents.map((d) => d.fileName), ['also-good.json', 'good.json']);
    });

    test('a directory that does not exist reads as empty', () async {
      final store = await _store(_tempDir());
      expect(await store.readDirectory('presets'), isEmpty);
    });

    test('delete removes the file and is idempotent', () async {
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson('presets/one.json', {'name': 'One'});
      expect(await store.delete('presets/one.json'), isTrue);
      expect(File('${root.path}/presets/one.json').existsSync(), isFalse);
      expect(await store.delete('presets/one.json'), isTrue);
    });

    test('a scheduled write lands, and only the last one does', () async {
      final root = _tempDir();
      final store = await _store(root);

      store.scheduleWrite('session.json', {'n': 1});
      store.scheduleWrite('session.json', {'n': 2});
      store.scheduleWrite('session.json', {'n': 3});

      // Nothing yet: the point of the debounce is that a drag costs one write.
      expect(File('${root.path}/session.json').existsSync(), isFalse);

      await Future<void>.delayed(ConfigStore.writeDelay * 2);
      expect(await store.readJson('session.json'), {'n': 3});
    });

    test('flush writes what is pending, now', () async {
      // What happens when the window is closed a second after the last edit.
      final root = _tempDir();
      final store = await _store(root);

      store.scheduleWrite('session.json', {'n': 1});
      await store.flush();

      expect(await store.readJson('session.json'), {'n': 1});
    });

    test('deleting cancels a pending write for the same file', () async {
      final root = _tempDir();
      final store = await _store(root);

      store.scheduleWrite('presets/one.json', {'name': 'One'});
      await store.delete('presets/one.json');
      await Future<void>.delayed(ConfigStore.writeDelay * 2);

      expect(File('${root.path}/presets/one.json').existsSync(), isFalse);
    });

    test('a disabled store answers everything without throwing', () async {
      final store = ConfigStore.disabled();

      expect(store.isAvailable, isFalse);
      expect(await store.readJson('settings.json'), isNull);
      expect(await store.writeJson('settings.json', {}), isFalse);
      expect(await store.delete('settings.json'), isFalse);
      expect(await store.readDirectory('presets'), isEmpty);
      store.scheduleWrite('session.json', {});
      await store.flush();
    });

    test('documents are written indented, for a human to edit', () async {
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson('settings.json', {'a': 1, 'b': 2});
      expect(
        File('${root.path}/settings.json').readAsStringSync(),
        contains('\n'),
      );
    });
  });

  group('loadStartupConfig', () {
    test('an empty directory loads the defaults', () async {
      final config = await loadStartupConfig(await _store(_tempDir()));

      expect(config.settings.targetFps, 60);
      expect(config.calibrations, isEmpty);
      expect(config.skins, isEmpty);
      expect(config.presets, isEmpty);
      expect(config.session, isNull);
      expect(config.notice, isNull);
    });

    test('reads settings, targets, skins and presets', () async {
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson(
        'settings.json',
        const AppSettings(targetFps: 30, skinId: 'daylight').toJson(),
      );
      await store.writeJson(
        'calibrations/house.json',
        const Calibration(
          id: 'house',
          name: 'House standard',
          lufsTarget: -12,
          lufsTolerance: 0.5,
          truePeakMax: -1,
          loudnessRangeMax: 14,
        ).toJson(),
      );
      await store.writeJson('skins/mine.json', {
        'id': 'mine',
        'name': 'Mine',
        'colors': {'accent': '#FF00FF'},
      });
      await store.writeJson('presets/one.json', {
        'name': 'One',
        'tabs': [
          {'name': 'Tab', 'modules': []},
        ],
      });

      final config = await loadStartupConfig(store);

      expect(config.settings.targetFps, 30);
      expect(config.settings.skinId, 'daylight');
      expect(config.calibrations.single.id, 'house');
      expect(config.skins.single.id, 'mine');
      expect(config.presets.single.preset.name, 'One');
      expect(config.notice, isNull);
    });

    test('a broken document is named in the notice, not fatal', () async {
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson('presets/good.json', {
        'name': 'Good',
        'tabs': [
          {'name': 'Tab', 'modules': []},
        ],
      });
      // Parses as JSON, is not a preset: PresetSpec demands a name.
      await store.writeJson('presets/nameless.json', {'tabs': []});

      final config = await loadStartupConfig(store);

      expect(config.presets.single.preset.name, 'Good');
      expect(config.notice, contains('nameless.json'));
    });

    test('the session is not read when restoring is switched off', () async {
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson(
        'settings.json',
        const AppSettings(restoreSession: false).toJson(),
      );
      await store.writeJson('session.json', {
        'active_tab': 0,
        'preset': {
          'name': 'Session',
          'tabs': [
            {'name': 'Tab', 'modules': []},
          ],
        },
      });

      expect((await loadStartupConfig(store)).session, isNull);
    });

    test('a session naming an unknown module kind keeps the rest', () async {
      // Forward compatibility, end to end: a layout written by a newer build
      // opens here without the module this build has not got.
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson('session.json', {
        'active_tab': 0,
        'preset': {
          'name': 'Session',
          'tabs': [
            {
              'name': 'Tab',
              'modules': [
                {
                  'id': 'a',
                  'kind': 'number_box',
                  'rect': {'c': 0, 'r': 0, 'w': 4, 'h': 2},
                },
                {
                  'id': 'b',
                  'kind': 'holographic_meter',
                  'rect': {'c': 4, 'r': 0, 'w': 4, 'h': 2},
                },
              ],
            },
          ],
        },
      });

      final session = (await loadStartupConfig(store)).session!;
      expect(session.preset.tabs.single.modules.map((m) => m.id), ['a']);
    });

    test('a session with a nonsense active tab is clamped', () async {
      final root = _tempDir();
      final store = await _store(root);

      await store.writeJson('session.json', {
        'active_tab': 99,
        'preset': {
          'name': 'Session',
          'tabs': [
            {'name': 'Tab', 'modules': []},
          ],
        },
      });

      expect((await loadStartupConfig(store)).session!.activeTab, 0);
    });

    test('a session round-trips through its own serialiser', () {
      const snapshot = SessionSnapshot(
        preset: PresetSpec(
          name: 'Session',
          tabs: [
            TabSpec(
              name: 'Loudness',
              modules: [
                ModuleSpec(
                  id: 'm1',
                  kind: ModuleKind.lufsMeter,
                  rect: GridRect(column: 1, row: 2, columns: 5, rows: 8),
                  options: {'metric': 'lufs_s'},
                ),
              ],
            ),
          ],
        ),
        activeTab: 0,
      );

      final parsed = SessionSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>,
      )!;

      final module = parsed.preset.tabs.single.modules.single;
      expect(module.id, 'm1');
      expect(module.kind, ModuleKind.lufsMeter);
      expect(
        module.rect,
        const GridRect(column: 1, row: 2, columns: 5, rows: 8),
      );
      expect(module.options['metric'], 'lufs_s');
    });

    test('a store with nowhere to write says so rather than failing', () async {
      final config = await loadStartupConfig(ConfigStore.disabled());
      expect(config.notice, isNotNull);
      expect(config.settings.targetFps, 60);
    });
  });
}
