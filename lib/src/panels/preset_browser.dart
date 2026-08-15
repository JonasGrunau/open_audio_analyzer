// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/workspace.dart';
import '../data/providers.dart';

/// Opens the preset browser.
Future<void> showPresetBrowser(BuildContext context) => showBelPanel<void>(
  context: context,
  builder: (context) => const PresetBrowser(),
);

/// Save the arrangement you have; open one you saved before.
///
/// The two toggles are the whole design problem in this panel. A preset can
/// carry a delivery target and a skin, or it can leave both alone —
/// `PresetSpec` stores null for "follow whatever is selected". Getting this
/// wrong in either direction is a real annoyance: a preset that always carries
/// the target silently re-points your meters at −23 LUFS when you open a layout
/// you built during a broadcast job, and a preset that never carries one makes
/// "my podcast setup" impossible to express.
class PresetBrowser extends ConsumerStatefulWidget {
  const PresetBrowser({super.key});

  @override
  ConsumerState<PresetBrowser> createState() => _PresetBrowserState();
}

class _PresetBrowserState extends ConsumerState<PresetBrowser> {
  late final TextEditingController _name = TextEditingController(
    text: ref.read(workspaceProvider).preset.name,
  );

  String? _selected;
  String? _confirmingDelete;
  bool _withCalibration = false;
  bool _withSkin = false;
  String? _status;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final presets = ref.watch(presetLibraryProvider);
    final store = ref.watch(configStoreProvider);

    return PanelScaffold(
      title: 'Presets',
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          if (_status != null)
            Expanded(
              child: Text(
                _status!,
                style: BelType.caption.copyWith(color: colors.textFaint),
              ),
            )
          else
            const Spacer(),
          BelButton(
            label: 'Open',
            emphasis: ButtonEmphasis.primary,
            onPressed: _selected == null ? null : _open,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!store.isAvailable)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: Text(
                'Presets cannot be saved this session — Bel has nowhere to '
                'write. ${store.lastError ?? ''}',
                style: BelType.caption.copyWith(color: colors.warn),
              ),
            ),
          PanelSection(
            title: 'Save the current layout',
            ruled: false,
            children: [
              PanelRow(
                label: 'Name',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BelTextField(
                      controller: _name,
                      width: 220,
                      hintText: 'Mastering',
                      onSubmitted: (_) => _save(),
                    ),
                    const SizedBox(width: Space.sm),
                    BelButton(
                      label: 'Save',
                      onPressed: store.isAvailable ? _save : null,
                    ),
                  ],
                ),
              ),
              PanelRow(
                label: 'Store the delivery target with it',
                note:
                    'Opening the preset switches to that target. Off means the '
                    'preset leaves your current one alone.',
                child: BelToggle(
                  semanticLabel: 'Store the delivery target with it',
                  value: _withCalibration,
                  onChanged: (value) =>
                      setState(() => _withCalibration = value),
                ),
              ),
              PanelRow(
                label: 'Store the skin with it',
                child: BelToggle(
                  semanticLabel: 'Store the skin with it',
                  value: _withSkin,
                  onChanged: (value) => setState(() => _withSkin = value),
                ),
              ),
            ],
          ),
          PanelSection(
            title: 'Saved layouts',
            children: [
              if (presets.isEmpty)
                if (!store.isAvailable)
                  Text(
                    'Nothing to show.',
                    style: BelType.caption.copyWith(color: colors.textFaint),
                  )
                else ...[
                  Text(
                    'Nothing saved yet. Presets are ordinary JSON files, one '
                    'per preset, kept in a "presets" folder inside — you can '
                    'send one to somebody.',
                    style: BelType.caption.copyWith(color: colors.textFaint),
                  ),
                  const SizedBox(height: Space.xs),
                  // Selectable for the same reason as in the settings panel:
                  // on macOS this is a sandbox container path nobody would
                  // guess or be able to retype.
                  SelectableText(
                    store.root!.path,
                    style: BelType.readingSmall.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ]
              else
                for (final stored in presets)
                  PanelListRow(
                    title: stored.preset.name,
                    note: _describe(stored.preset),
                    selected: stored.fileName == _selected,
                    onTap: () => setState(() {
                      _selected = stored.fileName;
                      _confirmingDelete = null;
                      _name.text = stored.preset.name;
                    }),
                    trailing: _confirmingDelete == stored.fileName
                        ? BelButton(
                            label: 'Delete?',
                            emphasis: ButtonEmphasis.destructive,
                            onPressed: () => _delete(stored.fileName),
                          )
                        : BelButton(
                            label: 'Delete',
                            onPressed: () => setState(
                              () => _confirmingDelete = stored.fileName,
                            ),
                          ),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  String _describe(PresetSpec preset) {
    final modules = preset.tabs.fold<int>(
      0,
      (total, tab) => total + tab.modules.length,
    );

    final parts = <String>[
      '${preset.tabs.length} ${preset.tabs.length == 1 ? 'tab' : 'tabs'}',
      '$modules ${modules == 1 ? 'module' : 'modules'}',
      if (preset.calibrationId != null) preset.calibrationId!,
      if (preset.skinId != null) preset.skinId!,
    ];
    return parts.join(' · ');
  }

  Future<void> _save() async {
    final workspace = ref.read(workspaceProvider);
    final name = _name.text.trim();

    if (name.isEmpty) {
      setState(() => _status = 'A preset needs a name.');
      return;
    }

    final settings = ref.read(settingsProvider);
    final preset = PresetSpec(
      name: name,
      tabs: workspace.preset.tabs,
      calibrationId: _withCalibration ? settings.calibrationId : null,
      skinId: _withSkin ? settings.skinId : null,
    );

    // Overwrites the selected file when the name still matches it, and writes a
    // new one otherwise. Typing a new name is how you say "save as"; there is no
    // second command for it.
    final selected = _selected;
    final existing = selected == null
        ? null
        : ref
              .read(presetLibraryProvider)
              .where((stored) => stored.fileName == selected)
              .firstOrNull;
    final overwrite = existing != null && existing.preset.name == name;

    final written = await ref
        .read(presetLibraryProvider.notifier)
        .save(preset, fileName: overwrite ? selected : null);

    if (!mounted) return;
    setState(() {
      _status = written == null
          ? ref.read(storageNoticeProvider) ?? 'Could not save the preset.'
          : 'Saved as $written.';
      if (written != null) _selected = written;
    });

    // The open layout takes the preset's name, so the title and the file agree
    // from here on.
    ref.read(workspaceProvider.notifier).renamePreset(name);
  }

  void _open() {
    final selected = _selected;
    if (selected == null) return;

    final stored = ref
        .read(presetLibraryProvider)
        .where((entry) => entry.fileName == selected)
        .firstOrNull;
    if (stored == null) return;

    final preset = stored.preset;
    ref.read(workspaceProvider.notifier).loadPreset(preset);

    // Null means "follow whatever is selected" — see PresetSpec. Applying only
    // the non-null ones is the entire behaviour the two save toggles exist to
    // choose between.
    final settings = ref.read(settingsProvider.notifier);
    final calibrationId = preset.calibrationId;
    final skinId = preset.skinId;
    if (calibrationId != null) settings.setCalibrationId(calibrationId);
    if (skinId != null) settings.setSkinId(skinId);

    Navigator.of(context).pop();
  }

  Future<void> _delete(String fileName) async {
    final removed = await ref
        .read(presetLibraryProvider.notifier)
        .remove(fileName);

    if (!mounted) return;
    setState(() {
      _confirmingDelete = null;
      if (_selected == fileName) _selected = null;
      _status = removed
          ? 'Deleted $fileName.'
          : ref.read(storageNoticeProvider) ?? 'Could not delete $fileName.';
    });
  }
}
