// SPDX-License-Identifier: GPL-3.0-or-later

/// What Open Audio Analyzer was started with.
///
/// Two flags, and both exist because of something that could not be done
/// otherwise rather than because a flag seemed nice to have.
///
/// **`--config-dir` is not a duplicate of `OAA_CONFIG_DIR`.** Passing an
/// environment variable to a Mac application means launching the binary inside
/// the bundle directly — `Open Audio Analyzer.app/Contents/MacOS/Open Audio
/// Analyzer` — and a bare binary launch changes how TCC attributes the
/// microphone request, so the device
/// silently fails to open and Open Audio Analyzer falls back to the test tone.
/// The net effect is that the config override and device capture could not be
/// exercised in the same launch, which has already been mis-reported once as
/// "the persisted source is ignored". `open --args` passes arguments where it
/// cannot pass an environment, so the flag removes the conflict outright.
///
/// **`--open-panel` is a debug-build affordance and asserts if used in a release
/// build.** Driving Flutter on macOS from a script needs synthetic `CGEvent`s
/// and accessibility permission — `System Events` clicks do nothing — so
/// screenshotting a panel to review it was gated behind a permission dialog on
/// somebody's machine. Naming the panel on the command line is the difference
/// between panels being visually reviewed and being reviewed by whoever happens
/// to have the right permission.
///
/// Parsing is done by hand. `package:args` is a dependency the CLI already
/// carries, but the application deliberately does not, and two flags do not
/// justify one: see the dependency rule in `CLAUDE.md`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What Open Audio Analyzer was started with. Overridden in `main()`; defaults
/// to nothing, so every widget test gets an application launched with a bare
/// command line.
final launchOptionsProvider = Provider<LaunchOptions>(
  (ref) => LaunchOptions.none,
);

/// A panel that can be opened at startup.
///
/// The names are what a user types after `--open-panel=`, so they are short and
/// lower case.
enum StartupPanel {
  settings('settings'),
  presets('presets'),
  calibration('calibration'),
  report('report'),
  shortcuts('shortcuts');

  const StartupPanel(this.flagName);

  final String flagName;

  static StartupPanel? byName(String name) {
    for (final panel in values) {
      if (panel.flagName == name) return panel;
    }
    return null;
  }

  static String get names => [for (final p in values) p.flagName].join(', ');
}

@immutable
class LaunchOptions {
  const LaunchOptions({
    this.configDir,
    this.openPanel,
    this.warnings = const [],
  });

  /// Where to keep settings, presets, calibrations and skins. Beats
  /// `OAA_CONFIG_DIR`, which beats the platform's convention.
  final String? configDir;

  /// A panel to open once the first frame is on screen. Ignored in a release
  /// build — see the library comment.
  final StartupPanel? openPanel;

  /// Anything that was not understood, in the words the user should see.
  ///
  /// Not printed and not thrown: a misspelt flag that killed a metering session
  /// at launch would be a poor trade, and a misspelt flag that did nothing at
  /// all is how somebody spends ten minutes wondering why their config
  /// directory is being ignored. They are shown in the interface, through the
  /// same notice the storage layer uses.
  final List<String> warnings;

  static const LaunchOptions none = LaunchOptions();
}

/// Reads [arguments] as Open Audio Analyzer's command line.
///
/// Accepts `--flag=value` and `--flag value` for both, because both are typed by
/// people and neither is wrong. Unknown arguments are collected rather than
/// rejected: on macOS the process is handed things nobody typed — `-psn_0_…`
/// from the Finder, `-NSDocumentRevisionsDebugMode` from Xcode — and a parser
/// that refuses what it does not recognise would refuse to launch from the
/// Dock.
LaunchOptions parseLaunchOptions(List<String> arguments) {
  String? configDir;
  StartupPanel? openPanel;
  final warnings = <String>[];

  String? valueFor(String argument, String flag, int index) {
    if (argument.startsWith('$flag=')) {
      return argument.substring(flag.length + 1);
    }
    if (argument == flag && index + 1 < arguments.length) {
      return arguments[index + 1];
    }
    return null;
  }

  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];

    final directory = valueFor(argument, '--config-dir', i);
    if (directory != null) {
      if (directory.isEmpty) {
        warnings.add('--config-dir was given no directory; ignoring it.');
      } else {
        configDir = directory;
      }
      if (argument == '--config-dir') i++;
      continue;
    }

    final panel = valueFor(argument, '--open-panel', i);
    if (panel != null) {
      final resolved = StartupPanel.byName(panel);
      if (resolved == null) {
        warnings.add(
          '--open-panel=$panel is not a panel. Try: ${StartupPanel.names}.',
        );
      } else if (kReleaseMode) {
        // Stated rather than silently dropped. Somebody scripting a screenshot
        // against a release build would otherwise be looking at an empty canvas
        // wondering which of the two of them was broken.
        warnings.add('--open-panel only works in a debug build.');
      } else {
        openPanel = resolved;
      }
      if (argument == '--open-panel') i++;
      continue;
    }
  }

  return LaunchOptions(
    configDir: configDir,
    openPanel: openPanel,
    warnings: warnings,
  );
}
