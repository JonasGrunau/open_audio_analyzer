// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';

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
/// a fourteenth module kind arrives.
///
/// **Selection changes do not enter the history.** Undo that walks back through
/// every click before it undoes anything is undo that nobody uses.
class WorkspaceController extends Notifier<Workspace> {
  final List<Workspace> _past = [];
  final List<Workspace> _future = [];

  /// The layout the canvas opened with.
  ///
  /// Either yesterday's session or the built-in default, and neither has been
  /// edited — which is what makes it the baseline `presetModifiedProvider`
  /// compares against for a canvas that has never been saved to a file. Held
  /// here rather than read out of the document, because the document provider
  /// cannot know when it was first looked at: a modified mark that depended on
  /// whether the menu bar happened to be wide enough to draw it would be no
  /// mark at all.

  /// Deep enough to cover a working session's worth of mistakes, bounded
  /// because this is a meter that stays open for days.
  static const int historyLimit = 64;

  /// The canvas opens where it was left.
  ///
  /// Restoring here rather than assigning after the first frame is what keeps
  /// the app from painting the default layout and then visibly replacing it.
  /// It also keeps the restore out of the undo history, which is correct:
  /// yesterday's session is the starting point, not an edit to be undone.
  late PresetSpec opened;

  @override
  Workspace build() {
    final session = ref.watch(startupConfigProvider).session;
    final workspace = session != null
        ? Workspace(preset: session.preset, activeTab: session.activeTab)
        : Workspace(preset: defaultPreset(), activeTab: 0);
    opened = workspace.preset;
    return workspace;
  }

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

  // --- Presets ------------------------------------------------------------

  /// Replaces the entire layout with a saved one.
  ///
  /// An undoable edit, deliberately. Loading the wrong preset is exactly the
  /// mistake somebody wants back out of, and having spent the history to get
  /// here is a smaller loss than losing the arrangement it replaced.
  void loadPreset(PresetSpec preset) {
    if (preset.tabs.isEmpty) return;
    _commit(Workspace(preset: preset, activeTab: 0));
  }

  /// Renames the open layout.
  ///
  /// Set from the filename a Save As chose, rather than typed: the file is the
  /// document, so the name inside it and the name of it are the same thing.
  void renamePreset(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == state.preset.name) return;
    _commit(state.copyWith(preset: state.preset.copyWith(name: trimmed)));
  }

  /// Whether the open layout carries a delivery target, and which.
  ///
  /// Null is not "no target" — it is *follow whatever is selected*, which is
  /// what [PresetSpec] documents and what the File menu's checkmark reads. An
  /// undoable edit like any other, because it is an edit to the document: it is
  /// what the next save will write.
  void setCarriedCalibration(String? id) {
    if (state.preset.calibrationId == id) return;
    _commit(
      state.copyWith(
        preset: state.preset.copyWith(
          calibrationId: id,
          clearCalibrationId: id == null,
        ),
      ),
    );
  }

  /// The same for the skin. See [setCarriedCalibration].
  void setCarriedSkin(String? id) {
    if (state.preset.skinId == id) return;
    _commit(
      state.copyWith(
        preset: state.preset.copyWith(skinId: id, clearSkinId: id == null),
      ),
    );
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

/// The name a layout carries until somebody saves it under one of their own.
///
/// One word in one place, because three things read it: the document name
/// centred in the menu bar, the name field the save dialog opens with, and the
/// prompt that asks whether to keep unsaved work. A layout is named by being
/// saved — the file *is* the document, which is what lets the name field go —
/// so until then the honest answer is that it has no name, and printing
/// "Unnamed" is how the window says so without inventing one.
const String kUnnamedPreset = 'Unnamed';

/// What Open Audio Analyzer opens with.
///
/// A working meter bridge on the first tab and the frequency displays on the
/// second, rather than an empty canvas with an invitation to build one. The
/// argument for starting empty is that it shows the canvas is arrangeable; the
/// argument against is that somebody who opened a metering tool wants to meter
/// something, and a blank grid asks them to design a layout before they have
/// heard a single reading.
///
/// The row of number boxes stays across the top because it is the part people
/// actually read. Everything under it is the *why* behind those six numbers —
/// where the loudness has been, how it sits in the target, whether the stereo
/// image survives a mono fold.
///
/// This is the starting point, not a preset. The canvas as it was left is
/// autosaved to `session.json` and restored at launch — see
/// `_WorkspaceState.initState` — and a layout only becomes a preset when
/// somebody names it, because silently mutating the preset a user loaded is how
/// a preset library becomes untrustworthy.
///
/// **Which is why it is called [kUnnamedPreset] and not "Loudness".** It was
/// named after the tab it opens on, and the menu bar then printed a document
/// name nobody had chosen — a fresh install looked like it had a preset called
/// LOUDNESS open, and Save as offered `Loudness.json` as though that were the
/// name to keep. The placeholder says the true thing instead: nothing has been
/// named yet, and the save dialog carries the same word into the name field for
/// the user to replace with their own.
PresetSpec defaultPreset() {
  const metrics = [
    Metric.lufsMomentary,
    Metric.lufsShort,
    Metric.lufsIntegrated,
    Metric.loudnessRange,
    Metric.truePeakMax,
    Metric.samplePeakMax,
  ];

  var next = 0;
  ModuleSpec module(
    ModuleKind kind,
    int column,
    int row,
    int columns,
    int rows, [
    Map<String, Object?> options = const {},
  ]) => ModuleSpec(
    id: 'm${++next}',
    kind: kind,
    rect: GridRect(column: column, row: row, columns: columns, rows: rows),
    options: options,
  );

  return PresetSpec(
    name: kUnnamedPreset,
    tabs: [
      TabSpec(
        name: 'Loudness',
        modules: [
          for (var i = 0; i < metrics.length; i++)
            module(ModuleKind.numberBox, i * 4, 0, 4, 2, {
              'metric': metrics[i].id,
            }),
          module(ModuleKind.lufsMeter, 0, 2, 5, 9),
          module(ModuleKind.superMeter, 5, 2, 8, 9),
          module(ModuleKind.digitalMeter, 13, 2, 4, 9),
          module(ModuleKind.validator, 17, 2, 7, 5),
          module(ModuleKind.vuMeter, 17, 7, 7, 5),
          // Side by side, because they are one measurement asked two
          // questions — *when* was the programme loud, and *how often* — and
          // the answer to either is worth more next to the other. The
          // distribution takes the narrower half: its axis is fixed at the
          // published −60 to 0 and most programmes occupy the right third of
          // it, where the time series uses every pixel it is given.
          module(ModuleKind.histogram, 0, 11, 11, 5),
          module(ModuleKind.loudnessDistribution, 11, 11, 6, 5),
          module(ModuleKind.alertMeter, 17, 12, 7, 4),
        ],
      ),
      TabSpec(
        name: 'Spectrum',
        modules: [
          // The analyser spans the full width because frequency is the axis
          // that benefits most from it: at 24 columns each of its 512 bands
          // gets more than two pixels, and below about half that the display
          // starts throwing away detail the engine measured.
          module(ModuleKind.spectrumAnalyzer, 0, 0, 24, 7),
          // Under it, and just as wide, for the opposite reason: time is the
          // oscilloscope's axis and a second of audio across twelve columns is
          // half the transients. Four rows rather than more because a waveform
          // is read by its shape and gains little from height, where the three
          // displays below it are all square-ish and lose a lot.
          module(ModuleKind.oscilloscope, 0, 7, 24, 4),
          module(ModuleKind.spectrogram, 0, 11, 12, 5),
          module(ModuleKind.phaseScope, 12, 11, 6, 5),
          module(ModuleKind.stereoCloud, 18, 11, 6, 5),
        ],
      ),
    ],
  );
}
