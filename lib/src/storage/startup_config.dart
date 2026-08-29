// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/foundation.dart';

import 'config_store.dart';

/// The canvas as it was left, and the file it was left in.
@immutable
class SessionSnapshot {
  const SessionSnapshot({
    required this.preset,
    required this.activeTab,
    this.path,
  });

  final PresetSpec preset;
  final int activeTab;

  /// The preset file the canvas is open on, or null if it has never been saved
  /// to one.
  ///
  /// **The document survives the launch, which is what makes `Save` mean
  /// overwrite.** Without it the layout came back and its file did not, so the
  /// first ⌘S of every morning opened a save panel for a preset that already
  /// had a home — and the obvious answer, accepting the suggested name, wrote a
  /// second copy of it beside the first.
  ///
  /// It is not part of [preset] because it is not part of the document: a
  /// preset copied to another machine has a path there that has nothing to do
  /// with the one it was written at.
  final String? path;

  Map<String, Object?> toJson() => {
    'version': kConfigSchemaVersion,
    'active_tab': activeTab,
    // Absent rather than null for a layout with no file. These documents are
    // meant to be read by hand.
    if (path != null) 'preset_path': path,
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
    final path = json['preset_path'];
    return SessionSnapshot(
      preset: preset,
      activeTab: tab is int ? tab.clamp(0, preset.tabs.length - 1) : 0,
      path: path is String && path.isNotEmpty ? path : null,
    );
  }

  /// The same canvas, no longer claiming a file. See [path].
  SessionSnapshot withoutPath() =>
      SessionSnapshot(preset: preset, activeTab: activeTab);
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

    // **A remembered file that is no longer there is not the document.** The
    // preset may have been renamed, deleted, or be on a drive that is not
    // mounted this morning, and a `Save` onto any of those either recreates a
    // file the user threw away or fails with a notice. Dropping the path here
    // puts the layout back where an unsaved one is: the next `Save` asks where
    // it should go. Checked once, at launch — a file that goes missing during
    // a session is the write's problem, and it reports one.
    final path = session?.path;
    if (path != null && !await store.existsAt(path)) {
      session = session!.withoutPath();
    }
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
