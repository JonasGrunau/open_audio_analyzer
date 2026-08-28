// SPDX-License-Identifier: GPL-3.0-or-later
//
// The command line.
//
// Small surface, and worth testing anyway for one reason: both flags exist to
// make something *else* testable — a config directory that can be pointed
// somewhere without breaking device capture, and a panel that can be
// screenshotted without accessibility permission. A flag that silently stopped
// parsing would take the thing it enables with it, and the failure would look
// like the config being ignored rather than like an argument being dropped.

import 'package:oaa/src/app/launch_options.dart';
import 'package:oaa/src/app/oaa_app.dart';
import 'package:oaa/src/data/providers.dart';
import 'package:oaa/src/panels/settings_panel.dart';
import 'package:oaa/src/storage/config_store.dart';
import 'package:oaa/src/storage/startup_config.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _panelOpens();

  group('parseLaunchOptions', () {
    test('an empty command line asks for nothing', () {
      final options = parseLaunchOptions(const []);
      expect(options.configDir, isNull);
      expect(options.openPanel, isNull);
      expect(options.warnings, isEmpty);
    });

    test('both spellings of a flag are accepted', () {
      expect(
        parseLaunchOptions(const ['--config-dir=/tmp/oaa']).configDir,
        '/tmp/oaa',
      );
      expect(
        parseLaunchOptions(const ['--config-dir', '/tmp/oaa']).configDir,
        '/tmp/oaa',
      );
    });

    test('a directory containing an = survives', () {
      // `--flag=value` splits on the first = only. A path with one in it is
      // unusual and legal, and losing half of it would put the config
      // somewhere the user cannot find.
      expect(
        parseLaunchOptions(const ['--config-dir=/tmp/a=b']).configDir,
        '/tmp/a=b',
      );
    });

    test('the value of one flag is not read as another flag', () {
      final options = parseLaunchOptions(const [
        '--config-dir',
        '/tmp/oaa',
        '--open-panel',
        'settings',
      ]);
      expect(options.configDir, '/tmp/oaa');
      expect(options.openPanel, StartupPanel.settings);
      expect(options.warnings, isEmpty);
    });

    test('what the Finder and Xcode add is ignored, not refused', () {
      // Launching from the Dock hands the process a process-serial-number
      // argument nobody typed. A parser that rejected unknown arguments would
      // refuse to start.
      final options = parseLaunchOptions(const [
        '-psn_0_1234567',
        '-NSDocumentRevisionsDebugMode',
        'YES',
        '--config-dir=/tmp/oaa',
      ]);
      expect(options.configDir, '/tmp/oaa');
      expect(options.warnings, isEmpty);
    });

    test('a panel that does not exist is named in a warning', () {
      final options = parseLaunchOptions(const ['--open-panel=spectrum']);
      expect(options.openPanel, isNull);
      expect(options.warnings.single, contains('spectrum'));
      // And the warning says what would have worked.
      expect(options.warnings.single, contains('settings'));
    });

    test('every panel name resolves', () {
      for (final panel in StartupPanel.values) {
        expect(
          parseLaunchOptions(['--open-panel=${panel.flagName}']).openPanel,
          panel,
          reason: '${panel.flagName} is offered and does not parse',
        );
      }
    });

    test('a flag with nothing after it is a warning, not a crash', () {
      final options = parseLaunchOptions(const ['--config-dir']);
      expect(options.configDir, isNull);
      expect(options.warnings, isEmpty);

      expect(
        parseLaunchOptions(const ['--config-dir=']).warnings,
        hasLength(1),
      );
    });
  });

  group('resolveConfigRoot precedence', () {
    const home = {'HOME': '/home/someone'};

    test('the flag beats the environment variable', () {
      expect(
        resolveConfigRoot(
          operatingSystem: 'linux',
          environment: const {...home, kConfigDirEnvVar: '/from/env'},
          override: '/from/flag',
        ),
        '/from/flag',
      );
    });

    test('the environment variable beats the platform convention', () {
      expect(
        resolveConfigRoot(
          operatingSystem: 'linux',
          environment: const {...home, kConfigDirEnvVar: '/from/env'},
        ),
        '/from/env',
      );
    });

    test('an empty flag falls through rather than resolving to nowhere', () {
      expect(
        resolveConfigRoot(
          operatingSystem: 'linux',
          environment: const {...home, kConfigDirEnvVar: '/from/env'},
          override: '',
        ),
        '/from/env',
      );
    });

    test('with neither, the platform decides', () {
      expect(
        resolveConfigRoot(operatingSystem: 'linux', environment: home),
        '/home/someone/.config/oaa',
      );
      expect(
        resolveConfigRoot(operatingSystem: 'macos', environment: home),
        '/home/someone/Library/Application Support/Open Audio Analyzer',
      );
      expect(
        resolveConfigRoot(
          operatingSystem: 'windows',
          environment: const {r'APPDATA': r'C:\Users\someone\AppData\Roaming'},
        ),
        r'C:\Users\someone\AppData\Roaming\Open Audio Analyzer',
      );
    });
  });
}

// The other half: the flag has to open the panel it parsed.
//
// `--open-panel=settings` is how the settings panel gets looked at at all — a
// screenshot needs the app running, and `screencapture` returns a black frame
// without screen-recording permission — so a flag that parses and then throws
// is the tooling for reviewing a panel, silently gone.
void _panelOpens() {
  testWidgets('--open-panel=settings opens the settings panel', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
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
        launchOptionsProvider.overrideWithValue(
          parseLaunchOptions(const ['--open-panel=settings']),
        ),
        // A free port would be better; nothing here connects, and a port that
        // is already taken only sets the link's failure notice.
        pluginLinkPortProvider.overrideWithValue(0),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const OaaApp()),
    );
    // One frame to build, one for the post-frame callback that reads the flag,
    // and one for the route it pushes.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SettingsPanel), findsOneWidget);
  });
}
