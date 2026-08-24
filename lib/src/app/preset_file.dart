// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

import '../canvas/canvas_notice.dart';
import '../canvas/workspace.dart';
import '../data/providers.dart';
import '../panels/report_panel.dart';

/// The preset as a document: the file it came from, and what was in it.
///
/// The workspace deliberately knows neither. It is the layout being edited, and
/// it is snapshotted whole onto the undo stack — a path and a modified flag
/// pushed through that history would be undone along with the layout, so that
/// undoing an edit could move the document to a different file.
///
/// [saved] is the [PresetSpec] instance that was last read from [path] or
/// written to it, and it is held **by identity**, not by value. Every layout
/// edit builds a new `PresetSpec`, so `identical` is an exact test for "has been
/// touched since" — and it costs nothing, where value equality would mean deep
/// equality on `TabSpec`, `ModuleSpec` and its options `Map`.
///
/// Identity also gets the one case a boolean flag gets wrong for free: undo
/// restores the *same* instance that was current at the time, so undoing back to
/// the state you saved clears the modified mark rather than leaving it lit for
/// the rest of the session.
typedef PresetDocument = ({String? path, PresetSpec? saved});

final presetDocumentProvider =
    NotifierProvider<PresetDocumentController, PresetDocument>(
      PresetDocumentController.new,
    );

/// Whether the layout on screen differs from what was last read or written.
///
/// With no file yet, the baseline is what the canvas opened with — yesterday's
/// session or the built-in default, neither of which anybody has edited. Without
/// that fallback the mark would depend on the moment this provider was first
/// read, which is the moment the status bar first drew it, which depends on how
/// wide the window is.
final presetModifiedProvider = Provider<bool>((ref) {
  final saved = ref.watch(presetDocumentProvider).saved;
  final preset = ref.watch(workspaceProvider).preset;
  return !identical(
    saved ?? ref.read(workspaceProvider.notifier).opened,
    preset,
  );
});

class PresetDocumentController extends Notifier<PresetDocument> {
  /// A launch has no file and nothing saved.
  ///
  /// Null [saved] is not "modified": it means no file has been read or written
  /// yet, and [presetModifiedProvider] measures against what the canvas opened
  /// with instead. Null [path] is why Save on a fresh session asks where to go.
  @override
  PresetDocument build() => (path: null, saved: null);

  /// Reads [path], applies it to the canvas, and adopts it.
  ///
  /// False and a notice on anything that is not a preset. There is no partial
  /// outcome: either the layout is replaced and the file is adopted, or nothing
  /// on screen changed.
  Future<bool> open(String path) async {
    final store = ref.read(configStoreProvider);
    final json = await store.readJsonAt(path);
    if (json == null) {
      ref
          .read(storageNoticeProvider.notifier)
          .report(store.lastError ?? 'Could not read $path.');
      return false;
    }

    // Anything at all can be in a file somebody picked — a skin, a session
    // snapshot, a preset from a build that has changed shape. `tryFromJson`
    // answers null rather than throwing; see its own comment.
    final preset = PresetSpec.tryFromJson(json);
    if (preset == null) {
      ref
          .read(canvasNoticeProvider.notifier)
          .say('${_basename(path)} is not a preset.');
      return false;
    }

    ref.read(workspaceProvider.notifier).loadPreset(preset);

    // Null means "follow whatever is selected" — see [PresetSpec]. Applying only
    // the ids that are there is the entire behaviour the two File menu
    // checkmarks choose between.
    final settings = ref.read(settingsProvider.notifier);
    final calibrationId = preset.calibrationId;
    final skinId = preset.skinId;
    if (calibrationId != null) settings.setCalibrationId(calibrationId);
    if (skinId != null) settings.setSkinId(skinId);

    // The instance the workspace is now holding, not the one parsed above:
    // `loadPreset` stores what it was given, so these are the same object, and
    // reading it back is what keeps that true if it ever stops being.
    state = (path: path, saved: ref.read(workspaceProvider).preset);
    return true;
  }

  /// Writes the open layout to [path] and adopts it.
  ///
  /// **The carried ids are re-stamped from the current selection on the way
  /// out.** A preset that carries a delivery target carries the one that is
  /// selected when you save it, which is what the File menu row prints beside
  /// the checkmark. In memory only the *nullness* of those two fields is ever
  /// read — it is what the checkmark shows and what [open] applies — so the
  /// value written here does not have to be pushed back into the workspace, and
  /// pushing it would put a delivery target into the layout's undo history.
  Future<bool> saveTo(String path) async {
    final preset = ref.read(workspaceProvider).preset;
    final settings = ref.read(settingsProvider);
    final written = preset.copyWith(
      calibrationId: preset.calibrationId == null
          ? null
          : settings.calibrationId,
      skinId: preset.skinId == null ? null : settings.skinId,
    );

    final store = ref.read(configStoreProvider);
    final ok = await store.writeJsonAt(path, {
      'version': kConfigSchemaVersion,
      ...written.toJson(),
    });

    if (!ok) {
      ref
          .read(storageNoticeProvider.notifier)
          .report(store.lastError ?? 'Could not write $path.');
      return false;
    }

    state = (path: path, saved: preset);
    return true;
  }
}

// ---------------------------------------------------------------------------
// The dialogs, behind a seam

/// The two file dialogs, as something a test can replace.
///
/// A native dialog cannot be opened from `flutter test` — it is a modal sheet
/// owned by the platform, and there is nothing to tap. The commands below are
/// the part worth testing, so the dialogs are the part that moves out of the
/// way: [presetDialogsProvider] is overridden with a fake that answers a
/// temporary path.
abstract class PresetDialogs {
  const PresetDialogs();

  /// The path to open, or null if the dialog was dismissed.
  Future<String?> open({String? initialDirectory});

  /// The path to write, or null if the dialog was dismissed.
  Future<String?> save({
    String? initialDirectory,
    required String suggestedName,
  });
}

class NativePresetDialogs extends PresetDialogs {
  const NativePresetDialogs();

  /// Presets are JSON, and the type group says so in every dialog.
  ///
  /// `uniformTypeIdentifiers` as well as `extensions`, because macOS 11 and
  /// later filter on content types: with the extension alone a file written by
  /// another application and typed `public.json` is greyed out in the panel.
  static const XTypeGroup _presets = XTypeGroup(
    label: 'Preset',
    extensions: ['json'],
    uniformTypeIdentifiers: ['public.json'],
  );

  @override
  Future<String?> open({String? initialDirectory}) async {
    final file = await openFile(
      acceptedTypeGroups: const [_presets],
      initialDirectory: initialDirectory,
    );
    return file?.path;
  }

  @override
  Future<String?> save({
    String? initialDirectory,
    required String suggestedName,
  }) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [_presets],
      initialDirectory: initialDirectory,
      suggestedName: suggestedName,
    );
    return location?.path;
  }
}

final presetDialogsProvider = Provider<PresetDialogs>(
  (ref) => const NativePresetDialogs(),
);

// ---------------------------------------------------------------------------
// The commands

/// Everything on the File menu, as one list.
///
/// The menu is drawn twice — in the macOS menu bar and in the status bar
/// everywhere else — and both are built from this. The label lives here; the
/// chord does not, because a chord belongs to `oaaShortcuts` and nowhere else.
enum FileCommand {
  open('open', 'Open…'),
  analyse('analyse', 'Analyse an audio file…'),
  save('save', 'Save'),
  saveAs('saveAs', 'Save as…'),

  /// The two rows that carry a checkmark rather than doing something.
  carryCalibration(
    'carryCalibration',
    'Preset should carry the delivery target',
  ),
  carrySkin('carrySkin', 'Preset should carry the skin');

  const FileCommand(this.id, this.label);

  /// What crosses the platform channel. Not the enum's index — inserting a row
  /// would then silently re-point every item below it.
  final String id;

  final String label;

  /// Whether this row shows a checkmark rather than being an action.
  bool get isToggle =>
      this == FileCommand.carryCalibration || this == FileCommand.carrySkin;

  static FileCommand? byId(String id) =>
      FileCommand.values.where((command) => command.id == id).firstOrNull;
}

/// A divider goes above these, in both menus.
const Set<FileCommand> fileCommandDividers = {
  FileCommand.save,
  FileCommand.carryCalibration,
};

/// Whether a toggle row is ticked. Null for the rows that are actions.
bool? fileCommandChecked(FileCommand command, WidgetRef ref) =>
    switch (command) {
      FileCommand.carryCalibration =>
        ref.watch(workspaceProvider).preset.calibrationId != null,
      FileCommand.carrySkin =>
        ref.watch(workspaceProvider).preset.skinId != null,
      _ => null,
    };

/// Runs one. The only entry point; three callers share it.
///
/// The keyboard, the macOS menu bar and the status bar's own menu all end up
/// here, so there is one implementation of what Save means and one place a
/// dialog is opened from.
Future<void> runFileCommand(
  FileCommand command,
  BuildContext context,
  WidgetRef ref,
) async {
  switch (command) {
    case FileCommand.open:
      await _open(context, ref);
    case FileCommand.analyse:
      await showReportPanel(context);
    case FileCommand.save:
      await _save(ref);
    case FileCommand.saveAs:
      await _saveAs(ref);
    case FileCommand.carryCalibration:
      final workspace = ref.read(workspaceProvider.notifier);
      final carried = ref.read(workspaceProvider).preset.calibrationId;
      workspace.setCarriedCalibration(
        carried == null ? ref.read(settingsProvider).calibrationId : null,
      );
    case FileCommand.carrySkin:
      final workspace = ref.read(workspaceProvider.notifier);
      final carried = ref.read(workspaceProvider).preset.skinId;
      workspace.setCarriedSkin(
        carried == null ? ref.read(settingsProvider).skinId : null,
      );
  }
}

/// Where a dialog starts, or null to let the platform decide.
Future<String?> _presetsDirectory(WidgetRef ref) =>
    ref.read(configStoreProvider).ensureDirectory(ConfigDir.presets);

Future<void> _open(BuildContext context, WidgetRef ref) async {
  // Asked before the dialog, not after it. Somebody who is going to lose an
  // arrangement should find that out before they have chosen a file, not once
  // they believe the job is done.
  if (!await _keepOrDiscard(context, ref)) return;

  final path = await ref
      .read(presetDialogsProvider)
      .open(initialDirectory: await _presetsDirectory(ref));
  if (path == null) return;

  await ref.read(presetDocumentProvider.notifier).open(path);
}

Future<void> _save(WidgetRef ref) async {
  final path = ref.read(presetDocumentProvider).path;
  if (path == null) return _saveAs(ref);
  await ref.read(presetDocumentProvider.notifier).saveTo(path);
}

Future<void> _saveAs(WidgetRef ref) async {
  final preset = ref.read(workspaceProvider).preset;
  final path = await ref
      .read(presetDialogsProvider)
      .save(
        initialDirectory: await _presetsDirectory(ref),
        suggestedName: _suggestedFileName(preset.name),
      );
  if (path == null) return;

  // **The file is the document, so the file's name is the document's name.**
  // That is what lets the name field go: a preset is named by saving it
  // somewhere, exactly once, like every other document on the machine.
  //
  // **Renamed before the write, and the order is load-bearing.** The name goes
  // *into* the file, so renaming afterwards writes the old one — and it leaves
  // the layout differing from the file it was just written to, which lights the
  // modified mark on a save and makes the next command think there is unsaved
  // work to ask about.
  ref.read(workspaceProvider.notifier).renamePreset(_stem(path));
  await ref.read(presetDocumentProvider.notifier).saveTo(path);
}

/// True to carry on, false if the user cancelled.
Future<bool> _keepOrDiscard(BuildContext context, WidgetRef ref) async {
  if (!ref.read(presetModifiedProvider)) return true;

  final name = ref.read(workspaceProvider).preset.name;
  final answer = await showOaaSavePrompt(
    context: context,
    title: 'Unsaved changes',
    message:
        '"$name" has changes that are not in a file. Opening another preset '
        'replaces the layout on the canvas.',
  );

  switch (answer) {
    case SaveAnswer.cancel:
      return false;
    case SaveAnswer.discard:
      return true;
    case SaveAnswer.save:
      await _save(ref);
      // A save that failed said so through the storage notice, and carrying on
      // regardless would discard the work the user just asked to keep.
      return !ref.read(presetModifiedProvider);
  }
}

/// `Mastering.json` from `Mastering`.
///
/// The name itself rather than [slugify]'s version of it. A user-chosen filename
/// does not need to be safe for automatic naming, and round-tripping through the
/// slug would turn "Mastering Setup" into "mastering-setup" the moment it was
/// saved. Only the separators have to go — a name is one path component.
String _suggestedFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[/\\]'), '-').trim();
  return '${cleaned.isEmpty ? 'Preset' : cleaned}.json';
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// The filename without its extension, which is the preset's name.
String _stem(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}
