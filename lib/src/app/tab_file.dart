// SPDX-License-Identifier: GPL-3.0-or-later

/// One tab, taken out of a preset or put into one.
///
/// Somebody who had built a tab they liked asked for two things the preset
/// file did not give them: a copy of that one tab to go back to when an edit
/// went wrong, and a library of tabs to bring in when wanted rather than a
/// strip of every tab they might ever want. Undo covers neither. It is sixty-
/// four steps shared by every tab in the preset, so taking one tab back also
/// takes back whatever was done to the others since, and it is gone at the
/// next launch.
///
/// **A tab file is a preset with one tab in it**, not a format of its own.
/// That is the whole design, and three things follow from it: an exported tab
/// opens with File › Open like any preset; importing reads *any* preset and
/// offers its tabs, so a library of tabs and a folder of presets are the same
/// folder; and there is no second parser to disagree with the first about what
/// a module looks like. The carried delivery target and skin are left out of a
/// tab — they belong to a whole layout, and importing one tab must not retarget
/// the session.
///
/// **Revert** needs no file at all. The preset as it was last opened or saved
/// is already in memory — it is what the modified mark in the menu bar is
/// measured against — so a tab can be put back to that in one undoable step.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

import '../canvas/canvas_notice.dart';
import '../canvas/workspace.dart';
import '../data/providers.dart';
import 'preset_file.dart';

/// The tab at [index] as it is in the preset last opened or saved, or null if
/// there is no such tab or it has not changed.
///
/// With no file this session, the baseline is what the canvas opened with —
/// the same one `presetModifiedProvider` uses, so "revert" and the modified
/// mark cannot disagree about what "saved" means.
///
/// A tab is matched by its place in the strip first and by its name after,
/// because either can have moved: a tab renamed in place is still the tab in
/// that place, and one whose neighbour was deleted is still the tab with that
/// name.
TabSpec? savedTab(WidgetRef ref, int index) {
  final saved =
      ref.read(presetDocumentProvider).saved ??
      ref.read(workspaceProvider.notifier).opened;
  final tabs = ref.read(workspaceProvider).preset.tabs;
  if (index < 0 || index >= tabs.length) return null;
  final current = tabs[index];

  TabSpec? match;
  if (index < saved.tabs.length && saved.tabs[index].name == current.name) {
    match = saved.tabs[index];
  } else {
    match = saved.tabs.where((tab) => tab.name == current.name).firstOrNull;
  }
  if (match == null || identical(match, current)) return null;
  // Compared as written, because an edit that was undone by hand — a module
  // dragged away and back — is a tab with nothing to revert.
  return _same(match, current) ? null : match;
}

bool _same(TabSpec a, TabSpec b) =>
    jsonEncode(a.toJson()) == jsonEncode(b.toJson());

/// Puts the tab at [index] back the way [savedTab] has it.
///
/// **When that was the only difference, the saved preset itself comes back**,
/// not a copy equal to it. The modified mark in the menu bar compares by
/// identity — see `presetModifiedProvider` — so a revert that left a preset
/// equal to the file in every byte would still light it, and the next Open
/// would ask about unsaved changes that are not there.
void revertTab(WidgetRef ref, int index) {
  final tab = savedTab(ref, index);
  if (tab == null) return;
  final workspace = ref.read(workspaceProvider.notifier);
  final baseline = ref.read(presetDocumentProvider).saved ?? workspace.opened;
  final current = ref.read(workspaceProvider).preset;
  final reverted = current.copyWith(
    tabs: [
      for (var i = 0; i < current.tabs.length; i++)
        if (i == index) tab else current.tabs[i],
    ],
  );
  if (jsonEncode(reverted.toJson()) == jsonEncode(baseline.toJson())) {
    workspace.loadPreset(baseline, activeTab: index);
  } else {
    workspace.replaceTab(index, tab);
  }
}

/// Writes the tab at [index] to a file the user chooses.
Future<void> exportTab(WidgetRef ref, int index) async {
  final tabs = ref.read(workspaceProvider).preset.tabs;
  if (index < 0 || index >= tabs.length) return;
  final tab = tabs[index];

  final store = ref.read(configStoreProvider);
  final path = await ref
      .read(presetDialogsProvider)
      .save(
        initialDirectory: await store.ensureDirectory(ConfigDir.presets),
        suggestedName: '${tab.name.replaceAll(RegExp(r'[/\\]'), '-')}.json',
      );
  if (path == null) return;

  // The display target is this machine's and would mean nothing on another.
  final written = PresetSpec(
    name: tab.name,
    tabs: [TabSpec(name: tab.name, modules: tab.modules)],
  );
  final ok = await store.writeJsonAt(path, {
    'version': kConfigSchemaVersion,
    ...written.toJson(),
  });
  if (!ok) {
    ref
        .read(storageNoticeProvider.notifier)
        .report(store.lastError ?? 'Could not write $path.');
    return;
  }
  ref.read(canvasNoticeProvider.notifier).say('Exported "${tab.name}".');
}

/// Reads a preset the user chooses and adds its tabs — one, or those picked
/// from several.
///
/// **It adds, and never replaces.** Replacing is File › Open, which asks about
/// unsaved work first; this cannot lose any, so it asks nothing.
Future<void> importTabs(BuildContext context, WidgetRef ref) async {
  final store = ref.read(configStoreProvider);
  final path = await ref
      .read(presetDialogsProvider)
      .open(initialDirectory: await store.ensureDirectory(ConfigDir.presets));
  if (path == null) return;

  final json = await store.readJsonAt(path);
  if (json == null) {
    ref
        .read(storageNoticeProvider.notifier)
        .report(store.lastError ?? 'Could not read $path.');
    return;
  }
  final preset = PresetSpec.tryFromJson(json);
  if (preset == null) {
    ref
        .read(canvasNoticeProvider.notifier)
        .say('${path.split(Platform.pathSeparator).last} has no tabs in it.');
    return;
  }

  var chosen = preset.tabs;
  if (chosen.length > 1) {
    if (!context.mounted) return;
    final picked = await showOaaPanel<List<TabSpec>>(
      context: context,
      builder: (context) => TabChooserPanel(preset: preset),
    );
    if (picked == null || picked.isEmpty) return;
    chosen = picked;
  }
  ref.read(workspaceProvider.notifier).insertTabs(chosen);
}

/// Which tabs of a preset to bring in.
///
/// A row per tab brings in that one; the footer brings in all of them. No
/// checkboxes: the usual answer is one tab, and a list of choices each of
/// which is a whole answer is one press where a set of toggles is three.
class TabChooserPanel extends StatelessWidget {
  const TabChooserPanel({required this.preset, super.key});

  final PresetSpec preset;

  @override
  Widget build(BuildContext context) {
    return PanelScaffold(
      title: 'Import tabs',
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          const Spacer(),
          OaaButton(
            label: 'Import all ${preset.tabs.length}',
            emphasis: ButtonEmphasis.primary,
            onPressed: () => Navigator.of(context).pop(preset.tabs),
          ),
        ],
      ),
      child: PanelSection(
        title: preset.name,
        note: 'Tap a tab to add it beside the ones already here.',
        ruled: false,
        children: [
          for (final tab in preset.tabs)
            PanelListRow(
              title: tab.name,
              note: switch (tab.modules.length) {
                0 => 'Empty',
                1 => '1 module',
                final n => '$n modules',
              },
              onTap: () => Navigator.of(context).pop([tab]),
            ),
        ],
      ),
    );
  }
}
