// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/foundation.dart';

import 'config_store.dart';

/// The canvas as it was left.
@immutable
class SessionSnapshot {
  const SessionSnapshot({required this.preset, required this.activeTab});

  final PresetSpec preset;
  final int activeTab;

  Map<String, Object?> toJson() => {
    'version': kConfigSchemaVersion,
    'active_tab': activeTab,
    'preset': preset.toJson(),
  };

  static SessionSnapshot? fromJson(Map<String, Object?> json) {
    final raw = json['preset'];
    if (raw is! Map) return null;
    // A layout written by a build that has since changed shape answers null
    // rather than throwing — see `PresetSpec.tryFromJson`. The canvas opening on
    // its defaults is a far better outcome than the application failing to
    // start, and the file is left alone so it can be inspected.
    final preset = PresetSpec.tryFromJson(raw.cast<String, Object?>());
    if (preset == null) return null;

    final tab = json['active_tab'];
    return SessionSnapshot(
      preset: preset,
      activeTab: tab is int ? tab.clamp(0, preset.tabs.length - 1) : 0,
    );
  }
}

/// Everything read from disk at launch, in one value.
///
/// Loading synchronously before `runApp` rather than asynchronously afterwards
/// is deliberate. These are four small files; reading them costs a millisecond
/// or two, and doing it first means no provider in the application is ever in an
/// "unknown yet" state. The alternative is every consumer of the settings
/// handling an `AsyncValue` for a value that is, in practice, always there —
/// and a first frame painted in the default skin that then flips to the user's.
@immutable
class StartupConfig {
  const StartupConfig({
    this.settings = const AppSettings(),
    this.calibrations = const [],
    this.skins = const [],
    this.session,
    this.notice,
  });

  final AppSettings settings;

  /// User-defined only. The built-ins are merged in by the library providers,
  /// so that a user file with a built-in's id shadows it rather than duplicating
  /// it in the menu.
  final List<Calibration> calibrations;
  final List<Skin> skins;
  final SessionSnapshot? session;

  /// Why something did not load, if anything did not.
  final String? notice;
}

/// Reads the whole configuration directory.
///
/// Never throws and never returns null. Every individual document that fails to
/// parse is skipped, counted, and reported through [StartupConfig.notice] — the
/// interface says "two skins could not be read" rather than the app silently
/// pretending the user never wrote them.
Future<StartupConfig> loadStartupConfig(ConfigStore store) async {
  if (!store.isAvailable) {
    return StartupConfig(notice: store.lastError);
  }

  final failures = <String>[];

  final settingsJson = await store.readJson(ConfigFile.settings);
  if (settingsJson == null && store.lastError != null) {
    failures.add('settings');
  }
  final settings = settingsJson == null
      ? const AppSettings()
      : AppSettings.fromJson(settingsJson);

  final calibrations = <Calibration>[];
  for (final document in await store.readDirectory(ConfigDir.calibrations)) {
    try {
      calibrations.add(Calibration.fromJson(document.json));
    } on Object {
      failures.add(document.fileName);
    }
  }

  final skins = <Skin>[];
  for (final document in await store.readDirectory(ConfigDir.skins)) {
    final skin = Skin.fromJson(document.json);
    if (skin == null) {
      failures.add(document.fileName);
    } else {
      skins.add(skin);
    }
  }

  // **`presets/` is not read at launch.** It was, until presets became
  // documents: there was a library panel listing everything in it, and the list
  // had to exist before the panel opened. Now a preset is opened by name through
  // a file dialog and may be anywhere on the machine, so scanning one directory
  // at startup would be reading files nothing is going to ask for — and would
  // still miss the one on somebody's Desktop.
  SessionSnapshot? session;
  if (settings.restoreSession) {
    final json = await store.readJson(ConfigFile.session);
    if (json != null) session = SessionSnapshot.fromJson(json);
  }

  return StartupConfig(
    settings: settings,
    calibrations: calibrations,
    skins: skins,
    session: session,
    notice: failures.isEmpty
        ? null
        : 'Could not read ${failures.length} configuration '
              '${failures.length == 1 ? 'file' : 'files'} '
              '(${failures.join(', ')}). They have been left alone; the rest of '
              'your configuration loaded normally.',
  );
}
