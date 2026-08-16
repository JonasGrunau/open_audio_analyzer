// SPDX-License-Identifier: GPL-3.0-or-later

/// Every keyboard shortcut Bel has, written down once.
///
/// [belShortcuts] is the only list. Three things are derived from it and none
/// of them is maintained by hand: the bindings the application installs, the
/// sheet that `?` opens, and `docs/site/keyboard.md` on the documentation site.
/// A shortcut that works and is documented nowhere is a shortcut nobody finds;
/// one that is documented and does not work is worse, because it is read as a
/// statement of fact. `test/shortcuts_test.dart` regenerates the Markdown and
/// fails if the checked-in copy has drifted, so the third consumer cannot go
/// stale quietly.
///
/// ---------------------------------------------------------------------------
/// Why the table sits above the whole workspace and not inside the canvas
///
/// Until Phase 8 these were a private map in `grid_canvas.dart`, under a
/// `CallbackShortcuts` whose only descendant was the canvas. That works exactly
/// as long as focus is on the canvas, and focus leaves it the first time
/// somebody opens the source picker or the calibration menu — after which undo
/// silently stops working and there is nothing on screen to explain why. The
/// canvas keeps its `Focus`, because a key event needs a focused node to start
/// from; what it no longer keeps is the table.
///
/// ---------------------------------------------------------------------------
/// Modifiers, and the one thing that is platform-specific
///
/// [Chord.primary] means Cmd on a Mac and Ctrl everywhere else, and Bel binds
/// **both, on every platform**. Choosing which to accept by asking the platform
/// is how a Mac driving an external PC keyboard ends up with no undo, and there
/// is nothing else these chords could mean. Only the *printed* label differs,
/// which is a question about the keyboard in front of the user rather than
/// about the operating system.
///
/// ---------------------------------------------------------------------------
/// Bare keys stand aside for text fields
///
/// Digits switch tabs. Typing `Mix 2` into a tab name would otherwise jump to
/// the second tab halfway through the word, and Backspace would delete the
/// module rather than the character. So every chord that carries neither Ctrl
/// nor Cmd checks the primary focus first and does nothing while an
/// [EditableText] has it. Chords that do carry one are safe without the check:
/// Flutter's own text-editing shortcuts claim Cmd+Z inside a field before it
/// reaches us.
library;

import 'dart:async';

import 'package:bel_core/bel_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/canvas_notice.dart';
import '../canvas/menus.dart';
import '../canvas/workspace.dart';
import '../panels/preset_browser.dart';
import '../panels/report_panel.dart';
import '../panels/settings_panel.dart';
import '../panels/shortcuts_sheet.dart';

// ---------------------------------------------------------------------------
// The vocabulary

/// Where a shortcut appears in the sheet and on the documentation page.
///
/// Declaration order is presentation order in both — and in the sheet it also
/// decides where the two columns break, because the break is the point in this
/// order that leaves them closest in height. What you do to the signal comes
/// first, then what you do to the workspace; the pair either side of that seam
/// is what the sheet reads down.
enum ShortcutGroup {
  canvas('Canvas'),
  measurement('Measurement'),
  tabs('Tabs'),
  configuration('Configuration');

  const ShortcutGroup(this.title);

  final String title;
}

/// One key with its modifiers.
@immutable
class Chord {
  const Chord(
    this.trigger, {
    this.primary = false,
    this.control = false,
    this.shift = false,
    this.alt = false,
  });

  final LogicalKeyboardKey trigger;

  /// Cmd on a Mac, Ctrl everywhere else — bound as both, always. See the
  /// library comment.
  final bool primary;

  /// Ctrl specifically, on every platform. `Ctrl+Tab` cycles tabs on macOS too;
  /// Cmd+Tab belongs to the window manager and is not ours to take.
  final bool control;

  final bool shift;
  final bool alt;

  /// Whether this chord has to stand aside while a text field has focus.
  bool get guarded => !primary && !control;

  /// The activators to bind. Two for a [primary] chord, one otherwise.
  List<SingleActivator> get activators => primary
      ? [
          SingleActivator(trigger, meta: true, shift: shift, alt: alt),
          SingleActivator(trigger, control: true, shift: shift, alt: alt),
        ]
      : [SingleActivator(trigger, control: control, shift: shift, alt: alt)];

  /// How this chord is printed on the keyboard in front of the user.
  ///
  /// Apple's modifier order is Control, Option, Shift, Command and its glyphs
  /// butt up against the key; everywhere else the parts are words joined with
  /// `+`. Getting this wrong is not a bug, but a shortcut sheet that prints
  /// `Ctrl+Z` to a Mac user is a sheet they stop trusting.
  String label({required bool apple}) {
    if (apple) {
      final buffer = StringBuffer();
      if (control) buffer.write('⌃');
      if (alt) buffer.write('⌥');
      if (shift) buffer.write('⇧');
      if (primary) buffer.write('⌘');
      buffer.write(_keyName(trigger, apple: true));
      return buffer.toString();
    }

    return [
      if (primary || control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      _keyName(trigger, apple: false),
    ].join('+');
  }
}

/// A single row of the sheet: what it does, what you press, and what happens.
@immutable
class BelShortcut {
  const BelShortcut({
    required this.group,
    required this.description,
    required this.chords,
    required this.action,
    this.appleKeys,
    this.otherKeys,
  });

  final ShortcutGroup group;

  /// Sentence case, no full stop. It is a row in a table, not prose.
  final String description;

  final List<Chord> chords;

  /// Invoked with the index of the chord that fired.
  ///
  /// That index is how one row can mean nine things: the tab digits and the
  /// four arrows are each a single shortcut whose chord list *is* its argument.
  /// Every other action ignores it.
  final void Function(ShortcutScope scope, int chord) action;

  /// Replaces the joined chord labels where nine keycaps in a row would not
  /// read. Both spellings are given because `⇧ arrows` and `Shift + arrows` are
  /// different strings and neither is worth deriving from the other.
  final String? appleKeys;
  final String? otherKeys;

  /// One entry per keycap the sheet should draw. An override collapses to a
  /// single cap: `arrow keys` is one thing you press, drawn as four keycaps it
  /// looks like a chord.
  List<String> keycaps({required bool apple}) {
    final override = apple ? appleKeys : otherKeys;
    if (override != null) return [override];
    return [for (final chord in chords) chord.label(apple: apple)];
  }

  /// The keys as one string, for a table cell that cannot draw keycaps.
  ///
  /// Joined with "or" rather than a space. `Delete Backspace` and `⌦ ⌫` read as
  /// one key with a strange name; the alternatives have to be spelled out when
  /// the boxes around them are gone.
  String keys({required bool apple}) => keycaps(apple: apple).join(' or ');
}

/// What a shortcut is allowed to reach.
///
/// Deliberately small. A shortcut edits the layout, opens a panel or resets the
/// measurement; nothing here hands it an engine, because a shortcut that could
/// read a meter would be a second path to a number that already has one.
@immutable
class ShortcutScope {
  const ShortcutScope({
    required this.context,
    required this.ref,
    required this.onReset,
  });

  final BuildContext context;
  final WidgetRef ref;

  /// Restarting the measurement is the engine's business and the engine belongs
  /// to the widget that owns its lifetime, so it arrives as a callback.
  final VoidCallback onReset;

  WorkspaceController get workspace => ref.read(workspaceProvider.notifier);

  String? get selectedModuleId => ref.read(workspaceProvider).selectedModuleId;

  void report(String message) =>
      ref.read(canvasNoticeProvider.notifier).say(message);
}

// ---------------------------------------------------------------------------
// The table

const List<BelShortcut> belShortcuts = [
  // --- Canvas --------------------------------------------------------------
  BelShortcut(
    group: ShortcutGroup.canvas,
    description: 'Add a module',
    chords: [Chord(LogicalKeyboardKey.keyN, primary: true)],
    action: _addModule,
  ),
  BelShortcut(
    group: ShortcutGroup.canvas,
    description: 'Duplicate the selected module',
    chords: [Chord(LogicalKeyboardKey.keyD, primary: true)],
    action: _duplicate,
  ),
  BelShortcut(
    group: ShortcutGroup.canvas,
    description: 'Delete the selected module',
    chords: [
      Chord(LogicalKeyboardKey.delete),
      Chord(LogicalKeyboardKey.backspace),
    ],
    action: _delete,
  ),
  BelShortcut(
    group: ShortcutGroup.canvas,
    description: 'Move the selected module one cell',
    chords: _arrows,
    appleKeys: 'arrow keys',
    otherKeys: 'arrow keys',
    action: _move,
  ),
  BelShortcut(
    group: ShortcutGroup.canvas,
    description: 'Grow or shrink the selected module one cell',
    chords: _shiftArrows,
    appleKeys: '⇧ arrow keys',
    otherKeys: 'Shift + arrow keys',
    action: _resize,
  ),
  BelShortcut(
    group: ShortcutGroup.canvas,
    description: 'Clear the selection',
    chords: [Chord(LogicalKeyboardKey.escape)],
    action: _deselect,
  ),
  BelShortcut(
    group: ShortcutGroup.canvas,
    description: 'Undo',
    chords: [Chord(LogicalKeyboardKey.keyZ, primary: true)],
    action: _undo,
  ),
  BelShortcut(
    group: ShortcutGroup.canvas,
    description: 'Redo',
    chords: [Chord(LogicalKeyboardKey.keyZ, primary: true, shift: true)],
    action: _redo,
  ),

  // --- Measurement ---------------------------------------------------------
  BelShortcut(
    group: ShortcutGroup.measurement,
    description: 'Reset the measurement',
    chords: [Chord(LogicalKeyboardKey.keyR, primary: true)],
    action: _reset,
  ),
  BelShortcut(
    group: ShortcutGroup.measurement,
    description: 'Analyse a file',
    chords: [Chord(LogicalKeyboardKey.keyO, primary: true)],
    action: _analyseFile,
  ),

  // --- Tabs ----------------------------------------------------------------
  BelShortcut(
    group: ShortcutGroup.tabs,
    description: 'Go to a tab by number',
    chords: _digits,
    appleKeys: '1 – 9',
    otherKeys: '1 – 9',
    action: _goToTab,
  ),
  BelShortcut(
    group: ShortcutGroup.tabs,
    description: 'Next tab',
    chords: [
      Chord(LogicalKeyboardKey.tab, control: true),
      Chord(LogicalKeyboardKey.bracketRight, primary: true),
    ],
    action: _nextTab,
  ),
  BelShortcut(
    group: ShortcutGroup.tabs,
    description: 'Previous tab',
    chords: [
      Chord(LogicalKeyboardKey.tab, control: true, shift: true),
      Chord(LogicalKeyboardKey.bracketLeft, primary: true),
    ],
    action: _previousTab,
  ),
  BelShortcut(
    group: ShortcutGroup.tabs,
    description: 'New tab',
    chords: [Chord(LogicalKeyboardKey.keyT, primary: true)],
    action: _newTab,
  ),

  // --- Configuration -------------------------------------------------------
  BelShortcut(
    group: ShortcutGroup.configuration,
    description: 'Settings',
    chords: [Chord(LogicalKeyboardKey.comma, primary: true)],
    action: _settings,
  ),
  BelShortcut(
    group: ShortcutGroup.configuration,
    description: 'Presets',
    chords: [Chord(LogicalKeyboardKey.keyP, primary: true)],
    action: _presets,
  ),
  BelShortcut(
    group: ShortcutGroup.configuration,
    description: 'This list',
    // F1 as well as `?`, because `?` is Shift+/ on a US layout and something
    // else entirely on most others — on a German keyboard it is Shift+ß, which
    // is not a key Flutter reports as `slash`. F1 is in the same place on every
    // layout there is.
    chords: [
      Chord(LogicalKeyboardKey.slash, shift: true),
      Chord(LogicalKeyboardKey.f1),
    ],
    action: _help,
  ),
];

/// Left, right, up, down — the order [_move] and [_resize] read as deltas.
const List<Chord> _arrows = [
  Chord(LogicalKeyboardKey.arrowLeft),
  Chord(LogicalKeyboardKey.arrowRight),
  Chord(LogicalKeyboardKey.arrowUp),
  Chord(LogicalKeyboardKey.arrowDown),
];

const List<Chord> _shiftArrows = [
  Chord(LogicalKeyboardKey.arrowLeft, shift: true),
  Chord(LogicalKeyboardKey.arrowRight, shift: true),
  Chord(LogicalKeyboardKey.arrowUp, shift: true),
  Chord(LogicalKeyboardKey.arrowDown, shift: true),
];

const List<Chord> _digits = [
  Chord(LogicalKeyboardKey.digit1),
  Chord(LogicalKeyboardKey.digit2),
  Chord(LogicalKeyboardKey.digit3),
  Chord(LogicalKeyboardKey.digit4),
  Chord(LogicalKeyboardKey.digit5),
  Chord(LogicalKeyboardKey.digit6),
  Chord(LogicalKeyboardKey.digit7),
  Chord(LogicalKeyboardKey.digit8),
  Chord(LogicalKeyboardKey.digit9),
];

// ---------------------------------------------------------------------------
// The actions

void _undo(ShortcutScope scope, int _) => scope.workspace.undo();

void _redo(ShortcutScope scope, int _) => scope.workspace.redo();

void _deselect(ShortcutScope scope, int _) => scope.workspace.select(null);

void _delete(ShortcutScope scope, int _) {
  final id = scope.selectedModuleId;
  if (id != null) scope.workspace.removeModule(id);
}

void _duplicate(ShortcutScope scope, int _) {
  final id = scope.selectedModuleId;
  if (id == null) return;
  if (!scope.workspace.duplicateModule(id)) {
    scope.report('No room on this tab for another copy.');
  }
}

void _addModule(ShortcutScope scope, int _) => unawaited(_pickModule(scope));

Future<void> _pickModule(ShortcutScope scope) async {
  // Anchored at the middle of the workspace. There is no pointer position to
  // anchor to — that is the point of a shortcut — and a menu pinned to a corner
  // reads as an error message.
  final box = scope.context.findRenderObject() as RenderBox?;
  final anchor = box == null
      ? Offset.zero
      : box.localToGlobal(box.size.center(Offset.zero));

  final kind = await showModuleKindMenu(scope.context, anchor);
  if (kind == null || !scope.context.mounted) return;

  if (!scope.workspace.addModule(kind)) {
    scope.report('No room on this tab for a ${kind.label}.');
  }
}

void _move(ShortcutScope scope, int chord) =>
    _nudge(scope, chord, resize: false);

void _resize(ShortcutScope scope, int chord) =>
    _nudge(scope, chord, resize: true);

/// Left, right, up, down, as (column, row) steps.
const List<(int, int)> _steps = [(-1, 0), (1, 0), (0, -1), (0, 1)];

/// Moves or resizes the selected module by one cell.
///
/// **A step with nowhere to go does nothing.** It is not clamped, and it does
/// not slide to the nearest free cell. Clamping would mean the tenth press of →
/// moves the module and the eleventh does not, with no way to feel where the
/// edge was; sliding would mean a module lands somewhere the user was not
/// pointing. This is the same rule the drag follows, which is what stops the
/// keyboard and the mouse from disagreeing about where a module may go.
void _nudge(ShortcutScope scope, int chord, {required bool resize}) {
  final id = scope.selectedModuleId;
  if (id == null) return;

  final tab = scope.ref.read(workspaceProvider).tab;
  final module = tab.moduleById(id);
  if (module == null) return;

  final (dx, dy) = _steps[chord];
  final rect = module.rect;
  final wanted = resize
      ? rect.copyWith(columns: rect.columns + dx, rows: rect.rows + dy)
      : rect.copyWith(column: rect.column + dx, row: rect.row + dy);

  if (wanted.columns < module.kind.minColumns) return;
  if (wanted.rows < module.kind.minRows) return;
  // `accepts` covers the canvas bounds as well as the neighbours.
  if (!tab.accepts(wanted, ignoring: id)) return;

  scope.workspace.placeModule(id, wanted);
}

void _goToTab(ShortcutScope scope, int chord) =>
    scope.workspace.selectTab(chord);

void _nextTab(ShortcutScope scope, int _) => _cycleTab(scope, 1);

void _previousTab(ShortcutScope scope, int _) => _cycleTab(scope, -1);

/// Wraps around, because a cycle that stops at the ends is not a cycle and the
/// user cannot see how many tabs are off the end of the strip.
void _cycleTab(ShortcutScope scope, int step) {
  final workspace = scope.ref.read(workspaceProvider);
  final count = workspace.preset.tabs.length;
  if (count < 2) return;
  scope.workspace.selectTab((workspace.activeTab + step + count) % count);
}

void _newTab(ShortcutScope scope, int _) => scope.workspace.addTab();

void _reset(ShortcutScope scope, int _) => scope.onReset();

void _analyseFile(ShortcutScope scope, int _) =>
    unawaited(showReportPanel(scope.context));

void _settings(ShortcutScope scope, int _) =>
    unawaited(showSettingsPanel(scope.context));

void _presets(ShortcutScope scope, int _) =>
    unawaited(showPresetBrowser(scope.context));

void _help(ShortcutScope scope, int _) =>
    unawaited(showShortcutsSheet(scope.context));

// ---------------------------------------------------------------------------
// Installing them

/// Wraps the workspace in every binding in [belShortcuts].
class BelShortcuts extends ConsumerWidget {
  const BelShortcuts({required this.onReset, required this.child, super.key});

  final VoidCallback onReset;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CallbackShortcuts(
    bindings: belShortcutBindings(
      ShortcutScope(context: context, ref: ref, onReset: onReset),
    ),
    // **The `FocusScope` is not decoration and removing it kills every
    // shortcut, silently.** A key event travels *up* from whatever holds focus,
    // so a binding is only reachable from below it. When a text field goes away
    // — finishing a tab rename, closing a panel — Flutter does not pick a new
    // node; it drops focus to the nearest enclosing scope, and without one of
    // our own that is the `Navigator`'s modal scope, which sits *above* this
    // widget. From there nothing reaches these bindings and the whole keyboard
    // stops working until the user clicks something. The symptom is
    // indistinguishable from the shortcuts never having been installed, which
    // is what makes it expensive to find.
    child: FocusScope(child: child),
  );
}

/// Flattens the table into the map [CallbackShortcuts] wants.
///
/// Every chord of every shortcut becomes one or two activators — see
/// [Chord.activators] — and each maps to a closure that remembers which chord
/// it was.
Map<ShortcutActivator, VoidCallback> belShortcutBindings(ShortcutScope scope) {
  final bindings = <ShortcutActivator, VoidCallback>{};

  for (final shortcut in belShortcuts) {
    for (var index = 0; index < shortcut.chords.length; index++) {
      final chord = shortcut.chords[index];
      final position = index;

      void invoke() {
        if (chord.guarded && isEditingText()) return;
        shortcut.action(scope, position);
      }

      for (final activator in chord.activators) {
        bindings[activator] = invoke;
      }
    }
  }

  return bindings;
}

/// Whether the keystroke belongs to a text field rather than to the canvas.
///
/// [FocusManager.primaryFocus] lands on the `Focus` that [EditableText] builds
/// around itself, so the field is an ancestor of the focused node rather than
/// the node itself — which is why this walks up rather than testing the widget
/// in hand.
bool isEditingText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

// ---------------------------------------------------------------------------
// The printed forms

/// How a key is spelled on a keycap.
String _keyName(LogicalKeyboardKey key, {required bool apple}) => switch (key) {
  LogicalKeyboardKey.arrowLeft => '←',
  LogicalKeyboardKey.arrowRight => '→',
  LogicalKeyboardKey.arrowUp => '↑',
  LogicalKeyboardKey.arrowDown => '↓',
  LogicalKeyboardKey.tab => apple ? '⇥' : 'Tab',
  // `Esc` on both, because that is what is printed on the key. Apple's ⎋ is a
  // real glyph and appears on no keyboard anybody owns.
  LogicalKeyboardKey.escape => 'Esc',
  LogicalKeyboardKey.delete => apple ? '⌦' : 'Delete',
  LogicalKeyboardKey.backspace => apple ? '⌫' : 'Backspace',
  LogicalKeyboardKey.enter => apple ? '↩' : 'Enter',
  LogicalKeyboardKey.f1 => 'F1',
  LogicalKeyboardKey.comma => ',',
  LogicalKeyboardKey.slash => '/',
  LogicalKeyboardKey.bracketLeft => '[',
  LogicalKeyboardKey.bracketRight => ']',
  _ => key.keyLabel,
};

/// Whether to print Apple glyphs, for the keyboard most likely in front of the
/// user.
bool get useAppleKeyNames =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// `docs/site/keyboard.md`, generated from the table above.
///
/// Checked into the repository rather than generated at publish time so that
/// the page is reviewable in a diff, and asserted by `test/shortcuts_test.dart`
/// so that it cannot be checked in stale. Both columns are printed because the
/// documentation site is read on the machine somebody is deciding to install
/// Bel *on*, which is not necessarily the one they will run it on.
String shortcutsMarkdown() {
  final buffer = StringBuffer()
    ..writeln('# Keyboard')
    ..writeln()
    ..writeln(
      'Bel is a meter you leave open, so the shortcuts are the ones you reach',
    )
    ..writeln(
      'for while a mix is playing: rearrange the canvas, jump between tabs,',
    )
    ..writeln('start the measurement again.')
    ..writeln()
    ..writeln('Press `?` or `F1` in the application for the same list.')
    ..writeln()
    ..writeln('`Ctrl` and `Cmd` are both accepted on every platform. Bel does')
    ..writeln('not ask the operating system which one you meant — a Mac with a')
    ..writeln('PC keyboard plugged into it takes either.')
    ..writeln()
    ..writeln(
      'Shortcuts without `Ctrl` or `Cmd` stand aside while you are typing in a',
    )
    ..writeln(
      'field, so a tab named `Mix 2` does not jump you to the second tab',
    )
    ..writeln('halfway through.');

  for (final group in ShortcutGroup.values) {
    final rows = belShortcuts.where((s) => s.group == group);
    if (rows.isEmpty) continue;

    buffer
      ..writeln()
      ..writeln('## ${group.title}')
      ..writeln()
      ..writeln('| Action | macOS | Windows and Linux |')
      ..writeln('| --- | --- | --- |');

    for (final shortcut in rows) {
      buffer.writeln(
        '| ${shortcut.description} '
        '| ${shortcut.keys(apple: true)} '
        '| ${shortcut.keys(apple: false)} |',
      );
    }
  }

  buffer
    ..writeln()
    ..writeln('---')
    ..writeln()
    ..writeln(
      '<!-- Generated from lib/src/app/shortcuts.dart. Do not edit by hand:',
    )
    ..writeln(
      '     test/shortcuts_test.dart regenerates this file and fails if it',
    )
    ..writeln('     has drifted. -->');

  return buffer.toString();
}
