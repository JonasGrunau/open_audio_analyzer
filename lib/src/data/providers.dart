// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugin/plugin_link.dart';
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

/// Everything Open Audio Analyzer remembers between launches.
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

  void setDynamicsNaming(DynamicsNaming naming) {
    if (naming == state.dynamicsNaming) return;
    _update(state.copyWith(dynamicsNaming: naming));
  }

  void setSkinId(String id) {
    if (id == state.skinId) return;
    _update(state.copyWith(skinId: id));
  }

  /// The remote display's name, port and frame rate.
  ///
  /// Not whether it is publishing: that is deliberately not remembered — see
  /// [AppSettings.remoteDisplayPort].
  ///
  /// A [name] that trims to nothing clears the stored one, which is how the
  /// display goes back to advertising under the machine's own host name.
  /// Passing null leaves it alone — the two are different requests and used to
  /// be the same one, so the field could never be emptied.
  void setRemoteDisplay({String? name, int? port, int? fps}) {
    final trimmed = name?.trim();
    _update(
      state.copyWith(
        remoteDisplayName: trimmed != null && trimmed.isNotEmpty
            ? trimmed
            : null,
        clearRemoteDisplayName: trimmed != null && trimmed.isEmpty,
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

/// The port the app accepts plugin connections on.
///
/// A provider only so that a test can ask the operating system for a free one:
/// the suite runs its files concurrently, and a fixed port bound by two of them
/// at once — or by a copy of the app the developer has open — is a flake with
/// nothing to do with what was being tested. Production reads the default.
final pluginLinkPortProvider = Provider<int>((ref) => kPluginLinkPort);

/// How often the meters are allowed to repaint.
final targetFpsProvider = Provider<int>(
  (ref) => ref.watch(settingsProvider.select((s) => s.targetFps)),
);

/// What the two dynamics readings are called: `PSR` / `PLR` or `ODR-S` /
/// `ODR-I`. A label, not a measurement — it reaches a module the way the
/// delivery target does, as a constructor argument through `ModuleHost`, and
/// the tablet is sent it over the wire beside the skin and the target.
final dynamicsNamingProvider = Provider<DynamicsNaming>(
  (ref) => ref.watch(settingsProvider.select((s) => s.dynamicsNaming)),
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

  /// Whether [id] names a target Open Audio Analyzer ships with — which is not
  /// the same as whether it can be edited. Editing a built-in writes a user
  /// file that shadows it; only that file can be deleted.
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

  /// Deletes every delivery target the user has saved, leaving the built-ins.
  ///
  /// Returns how many files were removed — zero is a legitimate answer and the
  /// panel says so — or null if one of them could not be deleted, in which case
  /// the store's own message goes to [storageNoticeProvider].
  ///
  /// **The files are enumerated, not the ids.** A target file may be called
  /// anything: [save] names it after the id, but nothing stops somebody writing
  /// `house.json` around an id of `atsc-a85`, and what has to be removed is what
  /// exists. This is the one place in the library that reads the directory, and
  /// it reads it to delete rather than to find out what the state is — the rule
  /// the other direction breaks.
  ///
  /// A file that refuses to go stays in the library, because a reset that says a
  /// target is gone and then finds it again at the next launch is worse than one
  /// that admits it was partial. Nothing here touches
  /// `settings.calibrationId`, for the same reason [remove] does not:
  /// [calibrationProvider] is derived and already falls back when the id it
  /// names has left the library.
  Future<int?> resetToBuiltIns() async {
    final store = ref.read(configStoreProvider);

    var removed = 0;
    String? failure;
    final survivors = <Calibration>[];

    for (final document in await store.readDirectory(ConfigDir.calibrations)) {
      if (await store.delete(
        '${ConfigDir.calibrations}/${document.fileName}',
      )) {
        removed++;
        continue;
      }

      // One unwritable file does not cost the user the rest of the reset — the
      // same reason one broken document does not fail the batch it was read in.
      failure ??= store.lastError;
      try {
        survivors.add(Calibration.fromJson(document.json));
      } on Object {
        // Never in the library to begin with; startup skipped it too.
      }
    }

    state = _merge(BuiltInCalibrations.all, survivors);

    if (failure != null) {
      ref.read(storageNoticeProvider.notifier).report(failure);
      return null;
    }
    return removed;
  }

  /// Shared with the CLI — see [mergeCalibrations].
  static List<Calibration> _merge(
    List<Calibration> base,
    List<Calibration> overrides,
  ) => mergeCalibrations(base, overrides);
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
  List<Skin> build() => _merge(ref.watch(startupConfigProvider).skins);

  /// The two shipped skins, then the user's own.
  ///
  /// **A built-in cannot be shadowed, and this is where that is enforced.** A
  /// user file that names `precision-instrument` is ignored rather than
  /// replacing it. Delivery targets work the other way round on purpose — a
  /// target is a claim about somebody else's published specification and has to
  /// be correctable without a release — but a skin is not a claim about
  /// anything. The two built-ins exist to *prove the roles are semantic*:
  /// `daylight` inverts the entire lightness ordering, and if any painter had
  /// reached for "the dark one" instead of a role it would be obvious
  /// immediately. A pair of reference points a file on disk can quietly
  /// redefine is a pair that proves nothing — and it is also the one
  /// arrangement in which "put it back the way it was" has no answer.
  ///
  /// Copying one and editing the copy costs a single press, and leaves the
  /// thing it was copied from still there to compare against.
  static List<Skin> _merge(List<Skin> user) {
    final byId = <String, Skin>{};
    for (final skin in user) {
      if (BuiltInSkins.byId(skin.id) != null) continue;
      byId[skin.id] = skin;
    }
    return List.unmodifiable([...BuiltInSkins.all, ...byId.values]);
  }

  Skin? byId(String id) {
    for (final skin in state) {
      if (skin.id == id) return skin;
    }
    return null;
  }

  /// Whether [id] names one of the two skins Open Audio Analyzer ships with.
  ///
  /// Which is the same question as whether it can be changed: it cannot. See
  /// [_merge]. [save] and [remove] both refuse one, so that the rule lives in
  /// the library rather than in whichever panel happens to be enforcing it.
  bool isBuiltIn(String id) => BuiltInSkins.byId(id) != null;

  /// Whether there is a file behind [id] — the thing [remove] would delete.
  bool hasFile(String id) =>
      !isBuiltIn(id) &&
      (ref.read(startupConfigProvider).skins.any((skin) => skin.id == id) ||
          _written.contains(id));

  /// Ids written this session. `startupConfigProvider` is what was on disk *at
  /// launch* and never changes after it, so without this a skin saved and then
  /// deleted in one sitting would report as having no file to delete.
  final Set<String> _written = {};

  /// Re-reads the skins directory.
  ///
  /// Authoring a skin means editing a JSON file, and the loop that makes that
  /// bearable is edit → reload → look. Requiring a restart per iteration is what
  /// makes an open format technically open and practically unused.
  Future<void> reload() async {
    final store = ref.read(configStoreProvider);
    final user = <Skin>[];

    for (final document in await store.readDirectory(ConfigDir.skins)) {
      final skin = Skin.fromJson(document.json);
      if (skin != null) user.add(skin);
    }

    state = _merge(user);
  }

  /// Writes a skin file.
  ///
  /// Refuses a built-in id outright rather than leaving that to the interface.
  /// A rule a panel merely declines to offer is a rule the next panel will not
  /// know about.
  Future<bool> save(Skin skin) async {
    if (isBuiltIn(skin.id)) {
      ref
          .read(storageNoticeProvider.notifier)
          .report(
            '${skin.name} ships with Open Audio Analyzer and cannot be '
            'changed. Save it as a new skin instead.',
          );
      return false;
    }

    final store = ref.read(configStoreProvider);
    final written = await store.writeJson(
      '${ConfigDir.skins}/${slugify(skin.id)}.json',
      skin.toJson(),
    );

    if (!written) {
      ref.read(storageNoticeProvider.notifier).report(store.lastError);
      return false;
    }

    final byId = {
      for (final existing in state)
        if (!isBuiltIn(existing.id)) existing.id: existing,
    };
    byId[skin.id] = skin;
    state = _merge(byId.values.toList());
    _written.add(skin.id);
    return true;
  }

  /// Deletes a user skin.
  ///
  /// Refuses a built-in for the same reason [save] does. Nothing is restored in
  /// its place because nothing was displaced: a built-in is always in the
  /// library, and `skinProvider` falls back to one when the settings name a
  /// skin that has just been deleted.
  Future<bool> remove(String id) async {
    if (isBuiltIn(id)) return false;

    final store = ref.read(configStoreProvider);
    final removed = await store.delete(
      '${ConfigDir.skins}/${slugify(id)}.json',
    );

    if (!removed) {
      ref.read(storageNoticeProvider.notifier).report(store.lastError);
      return false;
    }

    _written.remove(id);
    state = List.unmodifiable([
      for (final skin in state)
        if (skin.id != id) skin,
    ]);
    return true;
  }
}

/// The skin being edited, or null when the theme editor is not open.
///
/// **This is what makes the editor a preview rather than a form.** A skin the
/// user is dragging a colour through is the skin in force: the canvas, the
/// fourteen modules, the panel drawn over them and any tablet attached to the
/// session all follow it, because they all read [skinProvider] and it answers
/// with this when it is set. The alternative — a second palette that only the
/// editor knows about — is two answers to "what colour is `accent`", and the
/// one thing this application has never had is two.
///
/// Nothing here is written to disk. The draft is discarded when the editor
/// closes; it is the Save button that turns it into a file, through
/// [SkinLibraryController.save].
final skinDraftProvider = NotifierProvider<SkinDraftController, Skin?>(
  SkinDraftController.new,
);

class SkinDraftController extends Notifier<Skin?> {
  @override
  Skin? build() => null;

  /// Starts previewing [skin]. Resolved, so a sparse document is previewed —
  /// and edited — as the thirteen colours it will actually be drawn with.
  void begin(Skin skin) => state = skin.resolved();

  /// Replaces the draft. Called per pointer move while a colour is dragged.
  void update(Skin skin) => state = skin;

  /// Stops previewing. The committed skin comes back on the next frame.
  void end() => state = null;
}

/// The active skin: the editor's draft if one is open, otherwise the one the
/// settings name.
///
/// Falls back when the settings name a skin that is not installed — which is
/// what happens the first time a preset is opened on another machine.
final skinProvider = Provider<Skin>((ref) {
  // The editor's draft outranks the library, and outranks it for every reader
  // rather than for the canvas alone — see [skinDraftProvider].
  final draft = ref.watch(skinDraftProvider);
  if (draft != null) return draft;

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
/// `shouldRepaint` compares its palette; building a fresh `OaaColors` inside a
/// widget's `build` would allocate thirteen colours per rebuild and — before
/// `OaaColors` gained value equality — would have re-rasterised all fourteen
/// modules every time anything in the tree changed. A `Provider` caches until
/// its dependencies change, which is exactly the lifetime wanted.
final paletteProvider = Provider<OaaColors>(
  (ref) => oaaColorsFromSkin(ref.watch(skinProvider)),
);
