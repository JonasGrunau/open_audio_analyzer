// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/config_paths.dart';
import '../storage/config_store.dart';
import '../storage/startup_config.dart';

/// Configuration state. **Not measurements.**
///
/// Everything in this file changes when a human does something — picks a
/// target, changes the frame rate, loads a preset. That is what makes it a
/// good fit for Riverpod: it is rare, it is user-driven, and rebuilding widgets
/// in response is exactly right.
///
/// Measurements are the opposite on every axis, which is why they are not here
/// and never will be. Routing a 47 Hz stream of readings through a provider
/// would rebuild the widget subtree under every meter forty-seven times a
/// second to change some numbers that a painter could have read directly from
/// native memory for free.
///
/// Since Phase 4 this file is also the write path to disk. The shape is
/// deliberate: **one direction only.** A user action calls a controller, the
/// controller updates its state and asks the store to persist it. Nothing reads
/// back from disk to find out what the state is, because a persistence layer
/// that is also a source of truth is a persistence layer that can disagree with
/// the interface.

// --- Injected at startup ---------------------------------------------------

/// The file store. Overridden in `main()`; defaults to one that persists
/// nothing so that every widget test gets a working, inert application.
final configStoreProvider = Provider<ConfigStore>(
  (ref) => ConfigStore.disabled(),
);

/// What was on disk at launch. Overridden in `main()`.
final startupConfigProvider = Provider<StartupConfig>(
  (ref) => const StartupConfig(),
);

/// The most recent thing that went wrong with persistence, or null.
///
/// Surfaced in the interface rather than logged. A meter that quietly stops
/// saving is a meter that loses a day's work at the moment the user finds out.
final storageNoticeProvider =
    NotifierProvider<StorageNoticeController, String?>(
      StorageNoticeController.new,
    );

class StorageNoticeController extends Notifier<String?> {
  @override
  String? build() => ref.watch(startupConfigProvider).notice;

  void report(String? message) => state = message;
  void clear() => state = null;
}

// --- Settings --------------------------------------------------------------

/// Everything Bel remembers between launches.
final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(startupConfigProvider).settings;

  void setTargetFps(int fps) {
    if (!kTargetFpsOptions.contains(fps) || fps == state.targetFps) return;
    _update(state.copyWith(targetFps: fps));
  }

  void setCalibrationId(String id) {
    if (id == state.calibrationId) return;
    _update(state.copyWith(calibrationId: id));
  }

  void setSkinId(String id) {
    if (id == state.skinId) return;
    _update(state.copyWith(skinId: id));
  }

  /// The remote display's name, port and frame rate.
  ///
  /// Not whether it is publishing: that is deliberately not remembered — see
  /// [AppSettings.remoteDisplayPort].
  void setRemoteDisplay({String? name, int? port, int? fps}) {
    final trimmed = name?.trim();
    _update(
      state.copyWith(
        remoteDisplayName: trimmed != null && trimmed.isNotEmpty
            ? trimmed
            : null,
        remoteDisplayPort: port != null && port >= 1024 && port <= 65535
            ? port
            : null,
        remoteDisplayFps: fps != null && kRemoteFpsOptions.contains(fps)
            ? fps
            : null,
      ),
    );
  }

  void setRestoreSession(bool value) {
    if (value == state.restoreSession) return;
    _update(state.copyWith(restoreSession: value));
  }

  /// Records what the user is listening to, so the next launch reopens it.
  void setSource(AudioSourceKind kind, {String? deviceId, String? deviceName}) {
    if (kind != AudioSourceKind.device) {
      // The device is kept rather than cleared: switching to the test tone for
      // a moment and back is a normal thing to do, and forgetting the interface
      // in between would make it a two-step return.
      _update(state.copyWith(sourceKind: kind));
      return;
    }
    _update(
      state.copyWith(
        sourceKind: kind,
        deviceId: deviceId,
        deviceName: deviceName,
      ),
    );
  }

  void _update(AppSettings next) {
    state = next;
    // Debounced: dragging through the frame-rate menu should cost one write,
    // not three.
    ref
        .read(configStoreProvider)
        .scheduleWrite(ConfigFile.settings, next.toJson());
  }
}

/// How often the meters are allowed to repaint.
final targetFpsProvider = Provider<int>(
  (ref) => ref.watch(settingsProvider.select((s) => s.targetFps)),
);

// --- Calibrations ----------------------------------------------------------

/// Every delivery target available: the built-ins, plus the user's own.
///
/// A user file whose id matches a built-in **replaces** it rather than sitting
/// beside it. That is what makes the built-in list correctable without a
/// release: somebody who disagrees with our reading of ATSC A/85 writes an
/// `atsc-a85.json` and their number wins everywhere, including in presets that
/// already reference the id.
final calibrationLibraryProvider =
    NotifierProvider<CalibrationLibraryController, List<Calibration>>(
      CalibrationLibraryController.new,
    );

class CalibrationLibraryController extends Notifier<List<Calibration>> {
  @override
  List<Calibration> build() => _merge(
    BuiltInCalibrations.all,
    ref.watch(startupConfigProvider).calibrations,
  );

  /// Whether [id] names a target Bel ships with — which is not the same as
  /// whether it can be edited. Editing a built-in writes a user file that
  /// shadows it; only that file can be deleted.
  bool isBuiltIn(String id) => BuiltInCalibrations.byId(id) != null;

  bool isOverridden(String id) => ref
      .read(startupConfigProvider)
      .calibrations
      .any((calibration) => calibration.id == id);

  Calibration? byId(String id) {
    for (final calibration in state) {
      if (calibration.id == id) return calibration;
    }
    return null;
  }

  /// Writes a target and makes it available immediately.
  Future<bool> save(Calibration calibration) async {
    final store = ref.read(configStoreProvider);
    final path = '${ConfigDir.calibrations}/${slugify(calibration.id)}.json';
    final written = await store.writeJson(path, calibration.toJson());

    if (!written) {
      ref.read(storageNoticeProvider.notifier).report(store.lastError);
      return false;
    }

    state = _merge(state, [calibration]);
    return true;
  }

  /// Removes a user target, restoring the built-in of the same id if there was
  /// one.
  Future<bool> remove(String id) async {
    final store = ref.read(configStoreProvider);
    final removed = await store.delete(
      '${ConfigDir.calibrations}/${slugify(id)}.json',
    );

    if (!removed) {
      ref.read(storageNoticeProvider.notifier).report(store.lastError);
      return false;
    }

    final builtIn = BuiltInCalibrations.byId(id);
    state = [
      for (final calibration in state)
        if (calibration.id != id) calibration else ?builtIn,
    ];
    return true;
  }

  static List<Calibration> _merge(
    List<Calibration> base,
    List<Calibration> overrides,
  ) {
    final byId = {for (final calibration in base) calibration.id: calibration};
    for (final calibration in overrides) {
      byId[calibration.id] = calibration;
    }
    return List.unmodifiable(byId.values);
  }
}

/// The active delivery target.
///
/// Derived rather than held: the id is the state, and it lives in the settings
/// because that is what gets written to disk. Two places holding "which
/// calibration" is two places that can disagree after a user deletes the one
/// that was selected.
final calibrationProvider = Provider<Calibration>((ref) {
  final id = ref.watch(settingsProvider.select((s) => s.calibrationId));
  final library = ref.watch(calibrationLibraryProvider);

  for (final calibration in library) {
    if (calibration.id == id) return calibration;
  }
  return BuiltInCalibrations.fallback;
});

// --- Skins -----------------------------------------------------------------

final skinLibraryProvider = NotifierProvider<SkinLibraryController, List<Skin>>(
  SkinLibraryController.new,
);

class SkinLibraryController extends Notifier<List<Skin>> {
  @override
  List<Skin> build() {
    final byId = {for (final skin in BuiltInSkins.all) skin.id: skin};
    for (final skin in ref.watch(startupConfigProvider).skins) {
      byId[skin.id] = skin;
    }
    return List.unmodifiable(byId.values);
  }

  Skin? byId(String id) {
    for (final skin in state) {
      if (skin.id == id) return skin;
    }
    return null;
  }

  /// Re-reads the skins directory.
  ///
  /// Authoring a skin means editing a JSON file, and the loop that makes that
  /// bearable is edit → reload → look. Requiring a restart per iteration is what
  /// makes an open format technically open and practically unused.
  Future<void> reload() async {
    final store = ref.read(configStoreProvider);
    final byId = {for (final skin in BuiltInSkins.all) skin.id: skin};

    for (final document in await store.readDirectory(ConfigDir.skins)) {
      final skin = Skin.fromJson(document.json);
      if (skin != null) byId[skin.id] = skin;
    }

    state = List.unmodifiable(byId.values);
  }

  /// Writes a skin file. Used by "start a skin from this one", which is the
  /// only way to get a complete, correct thirteen-role document without copying
  /// it out of the source.
  Future<bool> save(Skin skin) async {
    final store = ref.read(configStoreProvider);
    final written = await store.writeJson(
      '${ConfigDir.skins}/${slugify(skin.id)}.json',
      skin.toJson(),
    );

    if (!written) {
      ref.read(storageNoticeProvider.notifier).report(store.lastError);
      return false;
    }

    final byId = {for (final existing in state) existing.id: existing};
    byId[skin.id] = skin;
    state = List.unmodifiable(byId.values);
    return true;
  }
}

/// The active skin. Falls back when the settings name one that is not installed
/// — which is what happens the first time a preset is opened on another machine.
final skinProvider = Provider<Skin>((ref) {
  final id = ref.watch(settingsProvider.select((s) => s.skinId));
  final library = ref.watch(skinLibraryProvider);

  for (final skin in library) {
    if (skin.id == id) return skin;
  }
  return BuiltInSkins.fallback;
});

/// The active palette.
///
/// **One instance per skin, and that matters.** Every module painter's
/// `shouldRepaint` compares its palette; building a fresh `BelColors` inside a
/// widget's `build` would allocate thirteen colours per rebuild and — before
/// `BelColors` gained value equality — would have re-rasterised all twelve
/// modules every time anything in the tree changed. A `Provider` caches until
/// its dependencies change, which is exactly the lifetime wanted.
final paletteProvider = Provider<BelColors>(
  (ref) => belColorsFromSkin(ref.watch(skinProvider)),
);

// --- Presets ---------------------------------------------------------------

/// The saved layouts, in filename order.
final presetLibraryProvider =
    NotifierProvider<PresetLibraryController, List<StoredPreset>>(
      PresetLibraryController.new,
    );

class PresetLibraryController extends Notifier<List<StoredPreset>> {
  @override
  List<StoredPreset> build() =>
      List.unmodifiable(ref.watch(startupConfigProvider).presets);

  /// Saves [preset] as a new file, or overwrites [fileName] if one is given.
  ///
  /// Returns the filename written, or null on failure. Naming is by slug with a
  /// numeric suffix on collision rather than by refusing the save: two layouts
  /// called "Mastering" is the user's business, and a dialog that rejects a name
  /// is a dialog that interrupts somebody mid-thought to enforce a rule the
  /// filesystem invented.
  Future<String?> save(PresetSpec preset, {String? fileName}) async {
    final store = ref.read(configStoreProvider);
    final name = fileName ?? _uniqueFileName(preset.name);
    final json = {'version': kConfigSchemaVersion, ...preset.toJson()};

    if (!await store.writeJson('${ConfigDir.presets}/$name', json)) {
      ref.read(storageNoticeProvider.notifier).report(store.lastError);
      return null;
    }

    final entry = (fileName: name, preset: preset);
    final replaced = state.any((stored) => stored.fileName == name);

    final next = replaced
        ? [
            for (final stored in state)
              if (stored.fileName == name) entry else stored,
          ]
        : ([...state, entry]..sort((a, b) => a.fileName.compareTo(b.fileName)));

    state = List.unmodifiable(next);
    return name;
  }

  Future<bool> remove(String fileName) async {
    final store = ref.read(configStoreProvider);
    if (!await store.delete('${ConfigDir.presets}/$fileName')) {
      ref.read(storageNoticeProvider.notifier).report(store.lastError);
      return false;
    }

    state = List.unmodifiable([
      for (final stored in state)
        if (stored.fileName != fileName) stored,
    ]);
    return true;
  }

  String _uniqueFileName(String presetName) {
    final base = slugify(presetName);
    final taken = {for (final stored in state) stored.fileName};

    if (!taken.contains('$base.json')) return '$base.json';
    for (var suffix = 2; suffix < 1000; suffix++) {
      if (!taken.contains('$base-$suffix.json')) return '$base-$suffix.json';
    }
    return '$base-${taken.length}.json';
  }
}
