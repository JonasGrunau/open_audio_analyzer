// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/bel_app.dart';
import 'src/app/launch_options.dart';
import 'src/data/providers.dart';
import 'src/storage/config_store.dart';
import 'src/storage/startup_config.dart';

/// Configuration is read before the first frame, not after it.
///
/// Four small JSON files cost a millisecond or two, and reading them first means
/// the window opens in the user's skin, on the user's layout, listening to the
/// device they left it on. Loading them asynchronously afterwards would show the
/// defaults for a frame and then visibly replace them, which is the kind of
/// flicker that makes an application feel assembled rather than built.
///
/// **`arguments` reaches here on all three desktop platforms, but only because
/// macOS was made to send it.** The Windows and Linux runners forward the
/// command line to the Dart entrypoint out of the box; the stock macOS runner
/// constructs a bare `FlutterViewController` and forwards nothing, so
/// `macos/Runner/MainFlutterWindow.swift` sets `dartEntrypointArguments`
/// explicitly. Without that, `--config-dir` would work on two platforms out of
/// three and appear to be ignored on the one where it matters most — see
/// `lib/src/app/launch_options.dart` for why it exists at all.
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();

  final options = parseLaunchOptions(arguments);

  final store = await ConfigStore.open(configDir: options.configDir);
  final config = await loadStartupConfig(store);

  runApp(
    ProviderScope(
      overrides: [
        configStoreProvider.overrideWithValue(store),
        startupConfigProvider.overrideWithValue(config),
        launchOptionsProvider.overrideWithValue(options),
      ],
      child: const BelApp(),
    ),
  );
}
