// SPDX-License-Identifier: GPL-3.0-or-later

/// What Open Audio Analyzer was started with.
///
/// Five flags, and every one of them exists because of something that could not
/// be done otherwise rather than because a flag seemed nice to have.
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
/// **`--publish` and `--attach` are the two ends of one photograph.** The
/// website's signal-path section puts a desktop and a tablet side by side under
/// a sentence saying the meter across the room cannot disagree with the one
/// under your hand, and the only way to be sure of that is for the tablet to be
/// a *display* of that desktop, drawing the frame the desktop published. That
/// needs the PUBLISH switch on at one end and a host attached at the other, and
/// both were reachable only by pressing them: a screenshot script therefore had
/// to post synthetic mouse events at somebody's machine, which is how
/// `packaging/ios/screenshots.sh` came to take the pointer away from whoever was
/// sitting at it for two minutes at a time. With these two the pair is shot with
/// no pointer at all.
///
/// **`--publish` argues with a rule and does not break it.**
/// `RemoteDisplayScope` says there is no publish at launch, because opening a
/// port with no password on it is worth asking for every time. This *is* asking
/// every time: somebody types it, on that launch, and nothing persists it — the
/// next launch is off again, which is the whole of what that rule protects. What
/// it must never become is a setting.
///
/// **Neither of these is gated to a debug build, and `--open-panel` is.** That
/// looks inconsistent and is the opposite: the pair above has to work in the
/// build the photographs are taken of, which is the *release* build, because a
/// window photographed from any other one is not the window that ships — and on
/// macOS a differently signed copy of the same bundle identifier is a different
/// subject as far as TCC is concerned, so it would have to be granted Local
/// Network permission again and would draw the yellow notice saying it had not
/// been. `--open-panel` has no such tie: it exists to put a panel on screen for
/// somebody to look at, and a panel looks the same in either build.
///
/// **`--attach` is the tablet's, and reaching a tablet cost a platform channel.**
/// iOS hands Dart's `main` an empty argument list — and an empty
/// `Platform.environment`, so the obvious way round it is not one. The command
/// line is asked for instead; see `launch_arguments.dart`, which is what makes
/// every flag here work on an iPad rather than only this one.
///
/// **`--tab` is the photograph's other half, and it replaced a key.** The
/// window shots and the store screenshots want the Spectrum tab, and the bare
/// digit that selects one is a key — which a script can only deliver to the
/// window that has the focus, and only by taking the focus first. A key
/// handed to the process instead (`CGEventPostToPid`) reaches the application
/// and not Flutter's key handling, so it selects nothing. Naming the tab on the
/// command line is what lets `packaging/app_window_shots.sh` and
/// `packaging/ios/screenshots.sh` open the application behind whatever the
/// person is working in and leave it there. One-based, the way the tab strip
/// and the `1`…`9` shortcuts count; a number with no tab behind it is a warning.
///
/// **The in-window File menu is not one of these, and was for one afternoon.**
/// Drawing the FILE button on a Mac is the same kind of debug-build affordance
/// and it was `--in-window-menu` to begin with, which meant the row two thirds
/// of the platforms ship was on screen only for somebody who remembered a flag.
/// It is what a debug build does now — see `fileMenuInWindowProvider` — and a
/// flag nobody has to pass is a flag that should not exist.
///
/// Parsing is done by hand. `package:args` is a dependency the CLI already
/// carries, but the application deliberately does not, and four flags do not
/// justify one: see the dependency rule in `CLAUDE.md`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/pair_link.dart';

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
  calibration('calibration'),
  theme('theme'),
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
    this.attach,
    this.publish = false,
    this.tab,
    this.warnings = const [],
  });

  /// Where to keep settings, presets, calibrations and skins. Beats
  /// `OAA_CONFIG_DIR`, which beats the platform's convention.
  final String? configDir;

  /// A panel to open once the first frame is on screen. Ignored in a release
  /// build — see the library comment.
  final StartupPanel? openPanel;

  /// A host to become a display of, once the first frame is on screen.
  ///
  /// Already resolved to an address and a port by [PairLink], so the one parser
  /// behind the pairing code and the typed address is behind this as well.
  final ({String host, int port})? attach;

  /// Whether to open the remote-display port at startup. See the library
  /// comment, which is where the argument for this one is.
  final bool publish;

  /// A tab to select once the first frame is on screen, **one-based**. Null
  /// leaves the session's own choice alone.
  final int? tab;

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
/// Accepts `--flag=value` and `--flag value` for the four that take one,
/// because both are typed by people and neither is wrong. Unknown arguments are
/// collected rather than rejected: on macOS the process is handed things nobody
/// typed — `-psn_0_…` from the Finder, `-NSDocumentRevisionsDebugMode` from
/// Xcode — and a parser that refuses what it does not recognise would refuse to
/// launch from the Dock.
///
LaunchOptions parseLaunchOptions(List<String> arguments) {
  String? configDir;
  StartupPanel? openPanel;
  ({String host, int port})? attach;
  var publish = false;
  int? tab;
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

    final host = valueFor(argument, '--attach', i);
    if (host != null) {
      // The same parser as the pairing code and the typed address. A flag with
      // its own idea of what a bare host name means would be a third opinion
      // for those two to drift from.
      attach = PairLink.parse(host);
      if (attach == null) {
        warnings.add('--attach=$host is not an address. Try oaa://host:port.');
      }
      if (argument == '--attach') i++;
      continue;
    }

    final tabText = valueFor(argument, '--tab', i);
    if (tabText != null) {
      final number = int.tryParse(tabText);
      if (number == null || number < 1) {
        warnings.add('--tab=$tabText is not a tab number. Try --tab=2.');
      } else {
        tab = number;
      }
      if (argument == '--tab') i++;
      continue;
    }

    if (argument == '--publish') {
      publish = true;
      continue;
    }
  }

  return LaunchOptions(
    configDir: configDir,
    openPanel: openPanel,
    attach: attach,
    publish: publish,
    tab: tab,
    warnings: warnings,
  );
}
