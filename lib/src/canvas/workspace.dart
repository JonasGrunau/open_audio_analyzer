// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The layout the user is editing: tabs, the active one, and the selection.
///
/// This is configuration, not measurement, and that is exactly why it belongs
/// in Riverpod. It changes when a human drags something — a handful of times a
/// minute at most — and rebuilding the canvas in response is the correct
/// reaction. The rule the project holds to is the other direction: no reading
/// ever enters a provider, because a 47 Hz stream of numbers through here would
/// rebuild the widget subtree under every meter forty-seven times a second.
@immutable
class Workspace {
  const Workspace({
    required this.preset,
    required this.activeTab,
    this.selectedModuleId,
  });

  final PresetSpec preset;
  final int activeTab;

  /// The module drawn with the emphasis border, and the one the keyboard acts
  /// on. Null when the last click landed on empty canvas.
  final String? selectedModuleId;

  TabSpec get tab => preset.tabs[activeTab];

  Workspace copyWith({
    PresetSpec? preset,
    int? activeTab,
    String? selectedModuleId,
    bool clearSelection = false,
  }) => Workspace(
    preset: preset ?? this.preset,
    activeTab: activeTab ?? this.activeTab,
    selectedModuleId: clearSelection
        ? null
        : (selectedModuleId ?? this.selectedModuleId),
  );
}

final workspaceProvider = NotifierProvider<WorkspaceController, Workspace>(
  WorkspaceController.new,
);

/// Every layout edit in the application goes through here.
///
/// Two things are deliberate.
///
/// **Undo is a stack of whole [Workspace] values.** Layout state is immutable
/// and small — a few dozen integers and strings — so keeping the previous one
/// costs nothing and is impossible to get wrong. The alternative, a command
/// pattern with an inverse per operation, is where undo bugs come from: the
/// inverse of "delete a module" has to restore its id, its options and its
/// position in the list, and it will be written once and then not updated when
/// a thirteenth module kind arrives.
///
/// **Selection changes do not enter the history.** Undo that walks back through
/// every click before it undoes anything is undo that nobody uses.
class WorkspaceController extends Notifier<Workspace> {
  final List<Workspace> _past = [];
  final List<Workspace> _future = [];

  /// Deep enough to cover a working session's worth of mistakes, bounded
  /// because this is a meter that stays open for days.
  static const int historyLimit = 64;

  @override
  Workspace build() => Workspace(preset: defaultPreset(), activeTab: 0);

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  void _commit(Workspace next) {
    _past.add(state);
    if (_past.length > historyLimit) _past.removeAt(0);
    _future.clear();
    state = next;
  }

  void undo() {
    if (_past.isEmpty) return;
    _future.add(state);
    state = _past.removeLast();
  }

  void redo() {
    if (_future.isEmpty) return;
    _past.add(state);
    state = _future.removeLast();
  }

  // --- Selection ----------------------------------------------------------

  void select(String? id) {
    if (id == state.selectedModuleId) return;
    state = id == null
        ? state.copyWith(clearSelection: true)
        : state.copyWith(selectedModuleId: id);
  }

  // --- Modules ------------------------------------------------------------

  Workspace _withTab(TabSpec tab) => state.copyWith(
    preset: PresetSpec(
      name: state.preset.name,
      tabs: [
        for (var i = 0; i < state.preset.tabs.length; i++)
          if (i == state.activeTab) tab else state.preset.tabs[i],
      ],
      calibrationId: state.preset.calibrationId,
      skinId: state.preset.skinId,
    ),
  );

  /// Adds a module, returning false when the canvas has no room for it.
  ///
  /// The caller is expected to say so. A click that silently does nothing is
  /// indistinguishable from a broken canvas.
  bool addModule(ModuleKind kind, {GridRect? at}) {
    final result = state.tab.adding(kind, at: at);
    if (result == null) return false;
    _commit(_withTab(result.tab).copyWith(selectedModuleId: result.module.id));
    return true;
  }

  /// Moves or resizes a module. The rect must already be legal — the canvas
  /// validates continuously while dragging so that it can show the user, and
  /// re-deciding here would mean two implementations of the same rule.
  void placeModule(String id, GridRect rect) {
    final module = state.tab.moduleById(id);
    if (module == null || module.rect == rect) return;
    _commit(_withTab(state.tab.replacing(module.copyWith(rect: rect))));
  }

  bool duplicateModule(String id, {GridRect? at}) {
    final result = state.tab.duplicating(id, at: at);
    if (result == null) return false;
    _commit(_withTab(result.tab).copyWith(selectedModuleId: result.module.id));
    return true;
  }

  void removeModule(String id) {
    if (state.tab.moduleById(id) == null) return;
    final next = _withTab(state.tab.removing(id));
    _commit(
      id == state.selectedModuleId ? next.copyWith(clearSelection: true) : next,
    );
  }

  void setModuleOption(String id, String key, Object? value) {
    final module = state.tab.moduleById(id);
    if (module == null || module.options[key] == value) return;
    _commit(
      _withTab(
        state.tab.replacing(
          module.copyWith(options: {...module.options, key: value}),
        ),
      ),
    );
  }

  // --- Tabs ---------------------------------------------------------------

  void selectTab(int index) {
    if (index < 0 || index >= state.preset.tabs.length) return;
    if (index == state.activeTab) return;
    // Not a history entry: switching tabs is navigation, not an edit.
    state = state.copyWith(activeTab: index, clearSelection: true);
  }

  void addTab() {
    final tabs = [
      ...state.preset.tabs,
      TabSpec(name: 'Tab ${state.preset.tabs.length + 1}', modules: const []),
    ];
    _commit(
      Workspace(
        preset: PresetSpec(
          name: state.preset.name,
          tabs: tabs,
          calibrationId: state.preset.calibrationId,
          skinId: state.preset.skinId,
        ),
        activeTab: tabs.length - 1,
      ),
    );
  }

  void renameTab(int index, String name) {
    final trimmed = name.trim();
    if (index < 0 || index >= state.preset.tabs.length) return;
    // An empty tab name leaves an unclickable sliver in the strip.
    if (trimmed.isEmpty || trimmed == state.preset.tabs[index].name) return;
    _commit(
      state.copyWith(
        preset: PresetSpec(
          name: state.preset.name,
          tabs: [
            for (var i = 0; i < state.preset.tabs.length; i++)
              if (i == index)
                state.preset.tabs[i].copyWith(name: trimmed)
              else
                state.preset.tabs[i],
          ],
          calibrationId: state.preset.calibrationId,
          skinId: state.preset.skinId,
        ),
      ),
    );
  }

  /// Removes a tab. Refuses to remove the last one — a preset with no tabs has
  /// nowhere to put a module and no way back.
  bool removeTab(int index) {
    if (state.preset.tabs.length <= 1) return false;
    if (index < 0 || index >= state.preset.tabs.length) return false;

    final tabs = [
      for (var i = 0; i < state.preset.tabs.length; i++)
        if (i != index) state.preset.tabs[i],
    ];
    _commit(
      Workspace(
        preset: PresetSpec(
          name: state.preset.name,
          tabs: tabs,
          calibrationId: state.preset.calibrationId,
          skinId: state.preset.skinId,
        ),
        activeTab: state.activeTab.clamp(0, tabs.length - 1),
      ),
    );
    return true;
  }

  void duplicateTab(int index) {
    if (index < 0 || index >= state.preset.tabs.length) return;
    final source = state.preset.tabs[index];
    final tabs = [
      ...state.preset.tabs,
      source.copyWith(name: '${source.name} copy'),
    ];
    _commit(
      Workspace(
        preset: PresetSpec(
          name: state.preset.name,
          tabs: tabs,
          calibrationId: state.preset.calibrationId,
          skinId: state.preset.skinId,
        ),
        activeTab: tabs.length - 1,
      ),
    );
  }
}

/// What Bel opens with.
///
/// Six readings across the top of an otherwise empty canvas: the three loudness
/// integrations, the range, and the two peaks that decide whether a master
/// passes. It is the layout somebody checking a mix actually wants, and it
/// leaves most of the canvas empty so that the first thing a new user sees is
/// obviously arrangeable.
///
/// Nothing persists this yet — a rearranged canvas is gone when the app closes.
/// Preset saving is Phase 4, and saying so in the README is better than a
/// half-implemented autosave that writes a format Phase 4 has to migrate.
PresetSpec defaultPreset() {
  const metrics = [
    Metric.lufsMomentary,
    Metric.lufsShort,
    Metric.lufsIntegrated,
    Metric.loudnessRange,
    Metric.truePeakMax,
    Metric.samplePeakMax,
  ];

  return PresetSpec(
    name: 'Loudness',
    tabs: [
      TabSpec(
        name: 'Loudness',
        modules: [
          for (var i = 0; i < metrics.length; i++)
            ModuleSpec(
              id: 'm${i + 1}',
              kind: ModuleKind.numberBox,
              rect: GridRect(column: i * 4, row: 0, columns: 4, rows: 3),
              options: {'metric': metrics[i].id},
            ),
        ],
      ),
    ],
  );
}
