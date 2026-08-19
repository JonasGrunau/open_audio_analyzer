// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/foundation.dart';

import 'config_paths.dart';
import 'config_store.dart';

/// A preset as it exists on disk.
///
/// The filename is the identity, not the name inside the document. Two presets
/// may legitimately be called "Mastering" — one the user wrote and one they
/// imported — and the alternative to tolerating that is refusing a save because
/// of a name collision the user does not consider a collision.
typedef StoredPreset = ({String fileName, PresetSpec preset});

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
    try {
      final preset = PresetSpec.fromJson(raw.cast<String, Object?>());
      if (preset.tabs.isEmpty) return null;
      final tab = json['active_tab'];
      return SessionSnapshot(
        preset: preset,
        activeTab: tab is int ? tab.clamp(0, preset.tabs.length - 1) : 0,
      );
    } on Object {
      // A layout written by a build that has since changed shape. The canvas
      // opening on its defaults is a far better outcome than the app failing
      // to start, and the file is left alone so it can be inspected.
      return null;
    }
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
    this.presets = const [],
    this.session,
    this.notice,
  });

  final AppSettings settings;

  /// User-defined only. The built-ins are merged in by the library providers,
  /// so that a user file with a built-in's id shadows it rather than duplicating
  /// it in the menu.
  final List<Calibration> calibrations;
  final List<Skin> skins;
  final List<StoredPreset> presets;
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

  final presets = <StoredPreset>[];
  for (final document in await store.readDirectory(ConfigDir.presets)) {
    try {
      final preset = PresetSpec.fromJson(document.json);
      if (preset.tabs.isEmpty) {
        failures.add(document.fileName);
        continue;
      }
      presets.add((fileName: document.fileName, preset: preset));
    } on Object {
      failures.add(document.fileName);
    }
  }

  SessionSnapshot? session;
  if (settings.restoreSession) {
    final json = await store.readJson(ConfigFile.session);
    if (json != null) session = SessionSnapshot.fromJson(json);
  }

  return StartupConfig(
    settings: settings,
    calibrations: calibrations,
    skins: skins,
    presets: presets,
    session: session,
    notice: failures.isEmpty
        ? null
        : 'Could not read ${failures.length} configuration '
              '${failures.length == 1 ? 'file' : 'files'} '
              '(${failures.join(', ')}). They have been left alone; the rest of '
              'your configuration loaded normally.',
  );
}
